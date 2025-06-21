# Invoice Financing Protocol

A decentralized invoice financing system with integrated credit scoring, risk-adjusted interest rates, and liquidity pool support — ready for immediate deployment.

---

## Core Features

* **Invoice Lifecycle**

  * `create-invoice`: Sellers create invoices for buyers.
  * `finance-invoice`: Investors fund invoices based on seller credit score.
  * `collect-payment`: Buyer repays, returns funds + interest to pool.
  * `mark-default`: Automatically or manually default overdue invoices.

* **Credit Scoring**

  * Dynamic scoring based on successful/failed repayments.
  * Influences financing eligibility and interest rates.

* **Liquidity Pool**

  * `add-liquidity` & `withdraw-liquidity` let investors fund or exit the pool.
  * Interest and principal returned upon collection.

* **Risk & Fees**

  * Platform and collection fees are deducted from financing flow.
  * Risk-based APR from credit score (e.g., 5–20%).

---

## Key Constants

| Constant              | Value | Description                               |
| --------------------- | ----- | ----------------------------------------- |
| `MAX-FINANCING-RATIO` | 90%   | Max invoice amount eligible for financing |
| `MIN-CREDIT-SCORE`    | 500   | Required score to qualify for funding     |
| `PLATFORM-FEE-RATE`   | 2%    | Deducted upfront on financing             |
| `COLLECTION-FEE-RATE` | 5%    | Penalty if invoice is overdue             |

---

## Read-Only Functions

* `get-invoice`, `get-user-stats`, `get-credit-score`
* `calculate-financing-terms`: Returns max financing, interest, and fees
* `is-invoice-overdue`: Flags unpaid invoices past due
* `calculate-updated-credit-score`: Used internally for score adjustments

---

## Admin & Controls

* `toggle-contract-active`: Pause/unpause core functions
* `withdraw-platform-fees`: Claim accumulated fees
* `manual-credit-adjustment`: Override a user’s credit score
* `emergency-pause`: Hard stop in emergencies

---

## Example Flow

1. Seller calls `create-invoice`
2. Funder calls `finance-invoice` → funds sent to seller
3. Buyer calls `collect-payment` or invoice is marked defaulted
4. Credit scores update, funds cycle back to pool
