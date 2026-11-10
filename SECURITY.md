# Pocket Money: security notes

Testnet software built for the Reactive Omni Buildathon. Not audited. This file covers what we assume, what we prove, and how we checked it.

## What it protects against

| Threat | What happens | Bound |
|---|---|---|
| Agent key stolen | Thief spends the agent's floats; the first payment to an unapproved payee freezes the agent on every chain | Loss ≤ sum of that agent's floats (P3) |
| Agent tricked into paying an unknown address (prompt injection) | Same as above, on any EVM chain or on Sui | Agent frozen everywhere after one payment |
| Agent overspends its budget | Top-ups stop at the allowance; x402 facilitators that read the mirror refuse **before** settling | Daily spend ≤ allowance + floats (P2) |
| Forged or replayed top-up | Vault accepts callbacks only from the callback proxy **and** our guard (two checks); top-ups carry a monotonic sequence | Rejected / skipped |
| Buggy or compromised guard | Vault caps every top-up at the agent's real balance vs its float; CCTP refills only go to owner-approved peer vaults, under an owner cap | Agent never above float (P1); no drain via CCTP |
| Guard or vault out of gas money | Reactive delivers nothing to a contract in debt | Fails closed: spending stops, never grows |
| Owner panic on any chain | Every vault freezes | All top-ups stop |

## Trust assumptions (stated, not hidden)

- **The owner key is the root of trust.** It sets allowances, payees, floats, peers and caps, and can migrate funds. Keep it on a different device from any agent.
- **The Sui attester is a trusted relay.** It can only make things stricter (a false report tightens the budget or freezes the agent). If it goes silent, the floats still bound the loss.
- **Reorgs on origin chains:** the Reactive docs don't say whether Reactive waits for origin-chain confirmations. A reorged payment could already have been topped up; the float bounds it.
- **Mirror lag:** a vault's mirror updates about one of its chain's blocks after the guard books a spend (≈12 s on Ethereum Sepolia). The float bounds that window.
- **Only USDC is guarded.** Other tokens are out of scope.

## How we checked

### Unit tests (35)
`forge test --mc PocketMoneyTest`.
- **Approach:** a Reactive Network simulator (`test/ReactiveSim.sol`) matches every emitted log against the guard's real subscriptions, feeds it to `react()`, and delivers the callbacks it requests through a proxy mock. It repeats until nothing new happens.
- **Covers:** every loop, callback authentication, replay, the float cap, the household ceiling, foreign spend, CCTP refills, migration, and the 900k gas cap (the worst `react()` measures 187k).

### Invariant fuzzing (8 properties)
`forge test --mc PocketMoneyInvariants`.
- **Approach:** a handler drives a two-agent, three-chain household through random sequences: agents pay the shop or a thief on any chain or on Sui, the owner panics or changes allowances, days roll over, and CCTP refills are relayed.

| # | Property |
|---|---|
| P1 | No agent ever holds more than its float on any chain |
| P2 | Top-ups never exceed the household ceiling or an agent's allowance in a day |
| P3 | A thief's take from an agent's key is bounded by that agent's floats |
| P4 | A quarantine reaches every chain; a panic freezes every vault |
| P9 | The budget mirror on every chain matches the guard, across day boundaries |
| P10 | The guard's view of every vault's USDC matches the chain |
| P11 | USDC is conserved across all chains (every CCTP burn is minted back) |
| P12 | Every payment gets exactly one receipt |

**Bug the fuzzer found:**
- **What broke:** after midnight, a vault reset the *household* spend from the paying agent's own sync, so other agents' mirrors ignored today's household spending.
- **How it was caught:** the fuzzer shrank it to 3 steps.
- **Fix:** vaults now keep the household's day boundary from the newest sync of any agent.
- **Regression test:** the shrunk case is `test_regression_householdSpendAfterMidnightReachesOtherAgentsMirror`; it fails on the old vault and passes now.

### Static analysis: Slither 0.11.6
Run: `slither . --filter-paths "lib/|test/" --exclude-dependencies`

**Fixed after the first pass:**
- `setAgent` writes state before calling the system contract.
- The `approve` return value is checked.
- The inbox rejects a zero attester.
- Uninitialized locals and uncached loop bounds are cleaned up.

**Remaining findings, each reviewed:**

| Detector | Where | Verdict |
|---|---|---|
| arbitrary-send-eth (High) | `Vault._send` | Only reachable through owner-only `withdraw` and `migrate`. Intended. |
| reentrancy-balance (High) | `Vault.topUp` | The only external calls are to the fixed Circle USDC address set at deploy. The replay sequence is written before them, and the float cap re-reads the balance. Not exploitable with USDC. |
| reentrancy-no-eth (Medium) | `PocketMoney._onTransfer` | External calls go only to Reactive's system contract (fixed address), inside `react()`, which only that contract can call. |
| divide-before-multiply (Medium) | `PocketMoney._roll` | Intentional: rounds the clock down to whole days. |
| incorrect-equality (Medium) | `Vault._send` | `amount == 0` early return. |
| reentrancy-events (Low ×12) | various | Events after calls to the trusted system contract or USDC. Ordering is cosmetic. |
| calls-loop (Low ×2) | `_watch`, `_toAllVaults` | Owner-only setup, or bounded by the number of chains (3). |
| timestamp (Low ×2) | `_roll`, `spendLeft` | Day windows; validator time drift of seconds is irrelevant. |
| low-level-calls (Info) | `Vault._send` | Plain ETH send with the result checked. |

## Live evidence

`deployments/EVIDENCE.md` records every on-chain claim with its transaction hash, including the failures:
- the Ethereum Sepolia top-up that ran out of gas, then the fix
- the live freeze, panic, refill and refusal drills
