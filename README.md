<p align="center">
  <img src="assets/altaopera-logo.svg" alt="AltaOpera Logo" width="140" />
</p>


**AltaOpera** is an on-chain liquidity engine built on a **quadratic bonding curve**.

The AltaOpera token has:

- built-in buy/sell liquidity,
- deterministic curve-based pricing,
- transparent protocol fees.

This repository contains the core **AltaOpera** bonding-curve ERC20 contract.

---

## Core idea

> Liquidity by math, not by promises.

In typical DeFi, liquidity depends on:

- third-party LPs,
- DEX pools,
- and the goodwill of a team.

If the pool disappears, late holders are stuck.

AltaOpera flips this model:

- the **contract itself** is the market maker,
- the ETH reserve is determined by a **bonding curve**,
- the ability to sell is guaranteed by code and invariants, not by promises.

---

##  How the bonding curve works

AltaOpera uses a quadratic price function of the form:

- `P(s) = a * s^2 + b`
- `s` = circulating supply in whole tokens (18 decimals internally)
- `a` = curvature (how fast price grows)
- `b` = base price (in wei)

As supply increases, price increases non-linearly.  
As supply decreases (users sell), price moves back along the same curve (minus fees and rounding).

The contract uses **integral pricing**, not a simple `price * amount`.  
It computes the ETH cost/refund between two supply levels with a closed-form formula, so reserve accounting is consistent and path-independent.

---

##  Internal ETH reserve

The AltaOpera contract acts as:

- a standard **ERC20** token, and  
- an **ETH vault** that tracks the bonding curve.

### Buy (`buy(amount)`)

- Reads current supply `S`.
- Computes `baseCost = _calculateCost(S, amount)`.
- Computes `fee = baseCost * feeBps / 10_000` (max 5%).
- Requires `msg.value >= baseCost + fee`.
- Mints `amount` AltaOpera tokens to the buyer.
- Keeps `baseCost` inside the contract as **reserve**.
- Sends the `fee` to the **treasury**.
- Refunds any extra ETH sent.

### Sell (`sell(amount)`)

- Reads current supply `S`.
- Computes `baseRefund = _calculateCost(S - amount, amount)`.
- Computes `fee = baseRefund * feeBps / 10_000`.
- Burns `amount` AltaOpera tokens from the seller.
- Ensures the contract balance covers `baseRefund`.
- Sends the `fee` to the treasury.
- Sends `netRefund = baseRefund - fee` to the seller.

Result: the ETH reserve always follows the curve defined by the bonding function.

---

## 🛡 Safety guarantees

### Reserve invariant

The required reserve for the current supply is:

```solidity
function getReserveRequirement() public view returns (uint256) {
    return _calculateCost(0, totalSupply());
}

The owner’s withdraw() can only touch excess above that requirement:
	•	if balance <= reserveRequirement → the call reverts (NoExcess),
	•	only donations / surplus / rounding dust can be withdrawn.

This means that ETH paid by buyers to move along the curve stays in the contract to serve future sellers.

As long as the contract is live, holders can always sell back into the curve
at the mathematical curve value (minus a transparent fee).

Reentrancy and CEI
	•	buy, sell and withdraw are protected with nonReentrant.
	•	They follow Checks → Effects → Interactions:
	•	state is updated before any external call,
	•	ETH transfers use low-level call with checks.

Immutable curve parameters
	•	aOver3 (and effectively a) and b are immutable.
	•	The curve shape cannot be changed after deployment.
	•	Only feeBps (capped at 5%) and treasury can be updated by the owner.

⸻

⚙️ Contract overview

Main contract: contracts/bonding/AltaOpera.sol

Key public functions:
	•	Trading
	•	buy(uint256 amount)
	•	sell(uint256 amount)
	•	Quotes
	•	quoteBuy(uint256 amount)
	•	quoteSell(uint256 amount)
	•	getCurrentPrice()
	•	Reserve
	•	getReserveRequirement()
	•	Admin
	•	updateFee(uint256 newFeeBps)
	•	updateTreasury(address newTreasury)
	•	withdraw(address payable to, uint256 amount)

⸻

🧪 Example parameters

Example deployment of AltaOpera:

AltaOpera token = new AltaOpera(
    3_960_000,                // _a: quadratic coefficient
    100_000_000_000_000,      // _b: 0.0001 ETH base price
    500,                      // feeBps: 5% protocol fee
    0x...,                    // treasury address
    msg.sender                // initialOwner
);

This preset roughly gives:
	•	starting price around 0.0001 ETH,
	•	low price around 10,000 supply,
	•	around 50,000 supply → price near 0.01 ETH,
	•	around 100,000 supply → price near 0.04 ETH,
	•	ETH reserve grows with demand as the curve is pushed.

⸻

🔧 Using this repository
	•	Use the AltaOpera contract as your bonding-curve ERC20 token.
	•	Integrate buy, sell, quoteBuy, quoteSell and getCurrentPrice into your frontend.
	•	Adjust _a, _b and feeBps to fit your desired curve and economics.

⸻

License

This repository is licensed under the Alta Opera Source License v1.0.

The source code is available to read and audit, but it is not open source.
You are not allowed to deploy, copy, fork, modify, or use this code in any
product or protocol without explicit written permission from arabafenice599rae.

See the LICENSE file for the full terms.

