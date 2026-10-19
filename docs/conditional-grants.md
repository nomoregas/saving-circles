# Conditional grants

*A grantor gives one grantee a zero-interest advance and escrows a grant that unlocks once the
advance is paid back. For example, Bread advances a community center 1,000 USDT for computers, and
once the center pays that back, another 1,000 USDT is released to it for free.*

This is the design rationale for `src/contracts/ConditionalGrants.sol`.

---

## 0. What problem it solves

The other stack types are built for groups that save together. Some partners need something
different: one organization receiving money up front and paying it back over time, with an
incentive to finish. Microfinance calls this progressive lending, where paying back one loan earns
access to the next. Here the next step is a grant rather than a bigger advance, so the grantor
absorbs the grant as the cost of the program, but only once the grantee has shown it can pay back.

## 1. The mechanism

A conditional grant has immutable terms fixed at `create`: `(token, vault, advance, grant, acceptBy,
payBackPeriod, termsHash)`. The caller becomes the grantor and pays `advance + grant` into escrow in
the same transaction, so the grantee can verify on-chain that both the advance and the grant are
real before agreeing to anything.

State is derived, never stored:

```
cancelled                       → Cancelled   (terminal)
not accepted, now < acceptBy    → Offered
not accepted, now >= acceptBy   → Expired     (grantor can cancel for a refund)
grant reclaimed                 → Defaulted   (terminal for the grant)
paidBack >= disbursed           → PaidBack    (grant waiting) or Completed (grant paid, or no grant)
no deadline, or now < payBackBy → Active
otherwise                       → Overdue
```

- **Grantee.** Named at `create`, or left empty and set once with `setGrantee`. This matches the
  app flow where someone asks to join off-chain and the grantor adds them. Only the grantee can
  accept.
- **Acceptance.** `accept(id, termsHash)` must pass the hash of the off-chain agreement (for example
  an IPFS document with the conditions in plain language). This records on-chain exactly which
  terms the grantee agreed to. The advance is paid out immediately and the clock starts:
  `payBackBy = acceptedAt + payBackPeriod`. The pay-back period is capped at 10 years
  (`MAX_PAY_BACK_PERIOD`) so a typo can't create an offer that is impossible to accept.
- **No deadline.** A pay-back period of 0 makes the grant open-ended: it stays Active however long
  paying back takes, and the grant can't be reclaimed. So the grant is never locked forever if the
  grantee disappears, the grantor can later `setPayBackBy` once, at least
  `DEADLINE_NOTICE_PERIOD` (30 days) in the future. From then on it behaves like any other
  deadline: it can be extended, and reclaiming opens 7 days after it. `extendPayBackBy` refuses
  open-ended grants, so the notice can't be skipped. The grantee accepts this up front: an
  open-ended offer means "no deadline unless the grantor gives 30 days' notice".
- **Paying back.** `payBack` accepts any amount at any time, from the grantee or anyone paying on
  their behalf. Overpayment is capped, so only what is owed is pulled. Payments are credited to the
  grantor and paid out with `collect`, which anyone can trigger.
- **Grant unlock.** Once cumulative payments reach the disbursed advance, `releaseGrant` pays the
  grant to the grantee. It is permissionless, so the app or an automation can trigger it, but the
  grant can only ever go to the grantee.
- **Late payment.** After `payBackBy` the conditional grant is Overdue. The grantee can still pay back
  and claim the grant until the grantor acts. The grantor can either `extendPayBackBy` to give more
  time (the new deadline must be later and in the future) or `reclaimGrant` to take the grant back.
  Reclaiming only opens `RECLAIM_GRACE_PERIOD` (7 days) after the deadline, so a grantee sending
  their final payment around the deadline can't be front-run. The advance remains owed after a
  reclaim and can still be paid back, but the grant is gone.
- **Unreleased grant.** If the advance is fully paid back but nobody releases the grant for
  `STUCK_GRANT_PERIOD` (90 days), for example because the token issuer blocklisted the grantee's
  address, the grantor may reclaim it so it isn't locked forever. `reclaimableAt(id)` returns the
  earliest reclaim time for either case.
- **Cancellation.** Before acceptance the grantor can `cancel` and get everything back, including
  yield.

## 2. Yield on escrow

Money waits in escrow twice: the advance between offer and acceptance, and the grant for the whole
pay-back period. Each conditional grant can name an ERC-4626 vault from an admin allowlist, and
escrow is deposited there instead of sitting idle. On Celo the natural choice is Aave v3, which
supports USDT through its ERC-4626 wrapper, waCelUSDT (`0x5264B1F45616dB619Bb3c8DCeBD86fB33FA0e53F`, from
bgd-labs' aave-address-book; `asset()` is Celo USDT). `yarn test:fork` runs the contract against it on a
mainnet fork: a waiting grant earns Aave's supply rate for the grantor (about 0.29% a year at the pinned
block), the grantee receives exactly the grant, and cancel and reclaim return escrow plus yield.

All yield belongs to the grantor. When escrow empties (grant paid, reclaimed, or offer cancelled),
whatever is left beyond what was owed out is credited to the grantor. Each conditional grant tracks
its own vault shares, so two of them in the same vault never touch each other's yield.

Using a generic ERC-4626 interface keeps the contract chain-agnostic. A conditional grant with
`vault = address(0)` keeps escrow as a plain token balance.

## 3. Safety

- **Solvency.** Without a vault, the contract's token balance equals the sum of escrow held plus
  grantor credits. With vaults, the contract's vault shares equal the sum of per-grant shares.
  Every increment is matched by a transfer in, and every decrement by a transfer out.
- **Roles over existing funds.** The grantor can cancel only before acceptance and reclaim the grant
  only once the advance is Overdue; neither touches the grantee's advance or payments. The
  allowlist admin can only change which tokens and vaults new conditional grants may use; existing
  ones keep their token and vault. The contract is upgradeable, though: whoever controls the proxy
  admin can replace the implementation and so has custody of everything in escrow. In production
  that key belongs behind a multisig.
- **Vault losses.** If the vault loses value, payouts are capped at what escrow can cover. The
  grantee only owes what was actually disbursed (`disbursed`, not `advance`), so a vault loss never
  leaves them owing money they did not receive.
- **Vault liquidity.** If the vault cannot pay out at the moment (for example Aave at 100%
  utilization), acceptance, grant release and cancellation revert until liquidity returns. No funds
  are lost, but actions can be delayed. Allowlist only vaults with deep liquidity.
- **Re-entrancy.** Every token-moving function is `nonReentrant` and updates state before
  transfers, except where a vault's return value is needed to update shares.
- **Weird tokens.** Fee-on-transfer and rebasing tokens must never be allowlisted, matching repo
  policy. USDT on Celo uses 6 decimals, which the tests exercise.

## 4. Decisions worth defending

- **Grantor initiates, grantee accepts.** Conditional grants start from the grantor, who sets every
  term. The grantee's only choice is to accept as written, which keeps the offer verifiable and
  avoids a negotiation protocol on-chain. A grantee-initiated request flow can live in the app.
- **No interest.** The product is a zero-interest advance with a reward for paying it back. The
  grantor earns yield on escrow instead, which partly offsets the cost of the grant.
- **Grant is all-or-nothing.** There is no partial release for partial payment. That keeps the
  incentive clear and the accounting simple.
- **Separate contract.** The ASCA in #184 caps credit at the member's own savings, which is the
  right safety rule for a savings group but rules out advancing money to someone with no savings.
  Loosening that cap would weaken the ASCA, so this lives on its own.

## 5. Scope (v1) and follow-ups

Implemented: grantor-funded offers, late-bound grantee, terms-hash acceptance, flexible paying back
by anyone, permissionless grant release, reclaim on default, deadline extensions, open-ended grants
with a notice period for setting a deadline, ERC-4626 escrow yield, a reclaim grace period and an
unreleased-grant fallback, and the view surface, behind an OZ v5 `TransparentUpgradeableProxy`, with
50 unit tests, a lifecycle fuzz test and 5 end-to-end scenarios
that check solvency after each journey.

Deferred: multiple grantors funding one conditional grant, more than one step (e.g. 500 then 1,000
then a grant), installment schedules with per-installment deadlines, yield routed to the grantee or
a solidarity fund, and Chainlink automation for `releaseGrant` and `collect`.
