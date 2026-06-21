# HTLC OTC — Robinhood Chain ⇄ Ethereum L1

Trustless cross-chain OTC swap of native ETH between **Robinhood Chain (4663)** and **Ethereum L1**, using **Hashed Timelock Contracts (HTLC)** — no bridge, no custodian, no oracle.

**Design principle:** worst case = **refund**, never loss. RPC outages only *delay* a transaction; funds stay locked in the contract until one of two exits fires (`claim` or `refund`).

## Live demo
🔗 **https://htlc-otc-demo-clawbid-2924s-projects.vercel.app/**

Client-side simulation (0 backend, 0 LLM). Real `keccak256` in the browser (verified against `cast keccak`). Walk the 4-step flow, kill either chain's RPC mid-swap, and watch the protection: locked funds, RETRY state, auto-resume on RPC recovery, and timeout→refund.

## Architecture (3 layers)

1. **Settlement (trustless core):** `HTLC.sol` deployed once per chain. `lock(recipient, hashlock, timelock)` / `claim(swapId, secret)` / `refund(swapId)`.
2. **Matching (UX):** off-chain RFQ — solver/OTC desk quotes a price (spread + gas). Never touches funds.
3. **Frontend automation:** orchestrates `lock → watch → claim → auto-refund`. Taker signs 1–2 tx; watcher does the rest.

## Why it's safe

- **Asymmetric timelocks:** the party that reveals the secret first holds the **longer** timelock. The buffer (`T_long − T_short`) is the safety window if RPC stalls. Demo uses 12h (Robinhood) vs 6h (L1).
- **Permissionless claim:** anyone can *push* a claim; funds always land at `recipient`. This lets a solver pay gas on the cheap chain → **gasless taker UX**.
- **Reveal guard:** never reveal the secret when remaining time < safe margin (2h). Prefer refund over a risky late reveal.
- **Claim/refund mutual exclusivity:** claim only before expiry, refund only after — no boundary race.

## Who pays the fee / gas

Taker pays in **one asset (ETH L1)** only. Gas on both chains is fronted by the solver and netted into the quote (Robinhood gas is cheap → absorbed as acquisition cost). Taker sees a single net number: "give 1.0 ETH L1, get 0.985 ETH Robinhood".

## Tests

```
forge test -vv
```

10/10 passing:
- `test_HappyPath_AtomicSwap` — full two-chain atomic swap
- `test_PermissionlessClaim_SolverPaysGas` — gasless taker
- `test_Timeout_RefundBothSides` — RPC-down / griefing → both refund, no loss
- `test_Revert_ClaimWrongSecret`, `test_Revert_ClaimAfterExpiry`, `test_Revert_RefundBeforeExpiry`, `test_Revert_RefundNotSender`, `test_Revert_DoubleClaim`, `test_Revert_TimelockNotInFuture`
- `testFuzz_LockClaim` — 256 runs

## Status

Demo + contract + tests only. **Not yet wired to live wallets/chains.** Next step: Permit2 pull on L1 (gasless lock), watcher with multi-RPC fallback (poptye 429-resistant), and testnet deployment before any real funds.

## Layout

```
src/HTLC.sol        # the contract (deploy per chain)
test/HTLC.t.sol     # 10 tests, two-chain simulation
demo/index.html     # interactive client-side demo (deployed to Vercel)
```
