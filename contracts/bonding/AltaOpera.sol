// SPDX-License-Identifier: AltaOpera-Source-1.0
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AltaOpera – Quadratic bonding curve ERC20 with internal ETH reserve
contract AltaOpera is ERC20, Ownable, ReentrancyGuard {
    // -------- Custom errors --------
    error AmountZero();
    error InsufficientEth();
    error InsufficientBalance();
    error PoolBalanceTooLow();
    error NoExcess();
    error FeeTooHigh();
    error ZeroAddress();
    error WithdrawAmountTooHigh();
    error InvalidA();
    error InvalidB();
    error SupplyUnderflow();

    // -------- Curve parameters --------
    // Price: P(s) = a * (s/1e18)^2 + b, where s is total supply in 18-decimal units.
    // We store aOver3 = a / 3 to use the exact integral form:
    // ∫(a s^2 + b) ds = (a/3) s^3 + b s  (in continuous terms).
    uint256 public immutable aOver3; // effective quadratic coefficient (a/3)
    uint256 public immutable b;      // base price in wei

    // 1 whole token (18 decimals)
    uint256 public constant ONE = 1e18;
    uint256 public constant ONE_SQ = 1e36;

    // -------- Fee & treasury --------
    // feeBps in basis points: 100 = 1%, 500 = 5% (max)
    uint256 public feeBps;
    address public treasury;

    // -------- Events --------
    event Bought(
        address indexed buyer,
        uint256 amount,
        uint256 baseCost,
        uint256 fee
    );

    event Sold(
        address indexed seller,
        uint256 amount,
        uint256 netRefund,
        uint256 fee
    );

    event FeeUpdated(uint256 newFeeBps);
    event TreasuryUpdated(address indexed newTreasury);
    event Withdrawn(address indexed to, uint256 amount);

    constructor(
        uint256 _a,          // "mathematical" a (MUST be multiple of 3)
        uint256 _b,          // e.g. 1e14 = 0.0001 ETH
        uint256 _feeBps,     // e.g. 500 = 5%
        address _treasury,
        address initialOwner
    )
        ERC20("AltaOpera", "ALTA")
        Ownable(initialOwner) // OpenZeppelin v5 style
    {
        if (_a == 0 || _a % 3 != 0) revert InvalidA();
        if (_b == 0) revert InvalidB();
        if (_feeBps > 500) revert FeeTooHigh();
        if (_treasury == address(0)) revert ZeroAddress();

        aOver3 = _a / 3;
        b = _b;
        feeBps = _feeBps;
        treasury = _treasury;
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    // =========================================================
    //                      CURVE / COST
    // =========================================================

    /// @notice Integral cost in ETH to move from startSupply to startSupply + amount
    /// @dev startSupply and amount are in 18-decimal units (wad)
    function _calculateCost(uint256 startSupply, uint256 amount)
        internal
        view
        returns (uint256 cost)
    {
        if (amount == 0) return 0;

        // s0 and s1 expressed in wad (18 decimals)
        uint256 s0 = startSupply;
        uint256 s1 = startSupply + amount;

        // Compute s^3 / ONE^3 using mulDiv to control overflow:
        //   s^2 / ONE      -> t
        //   t * s / ONE^2  -> s^3 / ONE^3
        uint256 s0_sq_div = Math.mulDiv(s0, s0, ONE);             // s0^2 / ONE
        uint256 s0_cube_div = Math.mulDiv(s0_sq_div, s0, ONE_SQ); // s0^3 / ONE^3

        uint256 s1_sq_div = Math.mulDiv(s1, s1, ONE);             // s1^2 / ONE
        uint256 s1_cube_div = Math.mulDiv(s1_sq_div, s1, ONE_SQ); // s1^3 / ONE^3

        uint256 cubicDiff_div = s1_cube_div - s0_cube_div;        // (s1^3 - s0^3) / ONE^3

        // cubic term: (a/3) * ((s1^3 - s0^3) / ONE^3)
        uint256 cubicTerm = aOver3 * cubicDiff_div;

        // linear term: b * (s1 - s0) / ONE  ==  b * amount / ONE
        uint256 linearTerm = Math.mulDiv(b, (s1 - s0), ONE);

        cost = cubicTerm + linearTerm;
    }

    // =========================================================
    //                          BUY
    // =========================================================

    /// @notice Buy `amount` ALTA (18 decimals) paying ETH, with fee
    function buy(uint256 amount) external payable nonReentrant {
        if (amount == 0) revert AmountZero();

        uint256 currentSupply = totalSupply();
        uint256 baseCost = _calculateCost(currentSupply, amount);

        uint256 feeBpsLocal = feeBps;
        uint256 fee = (baseCost * feeBpsLocal) / 10_000;
        uint256 totalCost = baseCost + fee;

        if (msg.value < totalCost) revert InsufficientEth();

        // EFFECTS
        _mint(msg.sender, amount);

        // INTERACTIONS
        address treasuryLocal = treasury;
        if (fee > 0) {
            (bool okT, ) = treasuryLocal.call{value: fee}("");
            require(okT, "Fee transfer failed");
        }

        uint256 refund = msg.value - totalCost;
        if (refund > 0) {
            (bool okR, ) = msg.sender.call{value: refund}("");
            require(okR, "Refund failed");
        }

        emit Bought(msg.sender, amount, baseCost, fee);
    }

    // =========================================================
    //                          SELL
    // =========================================================

    /// @notice Sell `amount` ALTA for ETH (burn + refund), with fee
    function sell(uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountZero();

        uint256 userBalance = balanceOf(msg.sender);
        if (userBalance < amount) revert InsufficientBalance();

        uint256 currentSupply = totalSupply();
        if (currentSupply < amount) revert SupplyUnderflow();

        uint256 baseRefund = _calculateCost(currentSupply - amount, amount);

        uint256 feeBpsLocal = feeBps;
        uint256 fee = (baseRefund * feeBpsLocal) / 10_000;
        uint256 netRefund = baseRefund - fee;

        uint256 poolBalance = address(this).balance;
        if (poolBalance < baseRefund) revert PoolBalanceTooLow();

        // EFFECTS
        _burn(msg.sender, amount);

        // INTERACTIONS
        address treasuryLocal = treasury;
        if (fee > 0) {
            (bool okT, ) = treasuryLocal.call{value: fee}("");
            require(okT, "Fee transfer failed");
        }

        (bool okR, ) = msg.sender.call{value: netRefund}("");
        require(okR, "Refund failed");

        emit Sold(msg.sender, amount, netRefund, fee);
    }

    // =========================================================
    //                       RESERVE & WITHDRAW
    // =========================================================

    /// @notice Theoretical reserve required if all current supply was bought via the curve
    function getReserveRequirement() public view returns (uint256) {
        return _calculateCost(0, totalSupply());
    }

    /// @notice Owner can withdraw only the excess above the required reserve
    function withdraw(address payable to, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountZero();

        uint256 reserve = getReserveRequirement();
        uint256 balance = address(this).balance;

        if (balance <= reserve) revert NoExcess();

        uint256 excess = balance - reserve;
        if (amount > excess) revert WithdrawAmountTooHigh();

        (bool ok, ) = to.call{value: amount}("");
        require(ok, "Withdraw failed");

        emit Withdrawn(to, amount);
    }

    // =========================================================
    //                     FEE / TREASURY PARAMS
    // =========================================================

    /// @notice Update fee (not the curve), up to 5%
    function updateFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > 500) revert FeeTooHigh();
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    /// @notice Update treasury address
    function updateTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    // =========================================================
    //                          QUOTES
    // =========================================================

    /// @notice Total (base + fee) ETH required to buy `amount`
    function quoteBuy(uint256 amount) external view returns (uint256 totalCost) {
        if (amount == 0) revert AmountZero();

        uint256 currentSupply = totalSupply();
        uint256 baseCost = _calculateCost(currentSupply, amount);
        uint256 fee = (baseCost * feeBps) / 10_000;
        totalCost = baseCost + fee;
    }

    /// @notice Net ETH (after fee) received when selling `amount`
    function quoteSell(uint256 amount) external view returns (uint256 netRefund) {
        if (amount == 0) revert AmountZero();

        uint256 currentSupply = totalSupply();
        if (currentSupply < amount) revert SupplyUnderflow();

        uint256 baseRefund = _calculateCost(currentSupply - amount, amount);
        uint256 fee = (baseRefund * feeBps) / 10_000;
        netRefund = baseRefund - fee;
    }

    /// @notice Current spot price for 1 token (18 decimals) at the exact current supply
    function getCurrentPrice() external view returns (uint256) {
        uint256 s = totalSupply();                // 18 decimals
        uint256 aFull = aOver3 * 3;               // reconstruct a
        uint256 s2 = Math.mulDiv(s, s, ONE);      // s^2 / 1e18
        // P(s) = a * (s/1e18)^2 + b  =>  a * s2 / 1e18 + b
        return Math.mulDiv(aFull, s2, ONE) + b;
    }

    /// @notice Average buy price per token for a hypothetical buy of `amount`
    function getAverageBuyPrice(uint256 amount) external view returns (uint256) {
        if (amount == 0) revert AmountZero();
        uint256 cost = _calculateCost(totalSupply(), amount);
        // price per token (18 decimals) in wei
        return Math.mulDiv(cost, ONE, amount);
    }

    /// @notice Exact marginal price for buying 1 full token (1e18 units) at current supply
    function getMarginalPrice() external view returns (uint256) {
        // cost in wei to buy exactly 1 ALTA (1e18 units) from current supply
        return _calculateCost(totalSupply(), ONE);
    }

    receive() external payable {}
}
