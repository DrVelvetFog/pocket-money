> **DRAFT. Not submitted.** Written for discussion. Per the x402 specs contributing guide, the first step would be an x402 Discussion, and nothing is posted without the author's approval of the exact text. Reference implementation: Pocket Money (`src/Vault.sol` `canSpend`, `agent/src/seller.ts`).

# Extension: `spend-limit`

## Summary

The `spend-limit` extension lets a facilitator (or resource server) **refuse a payment before settling it** when the payer is an automated agent whose owner set a spending limit, and that limit is already used up.

**Why it's needed:**
- **Limits today live in the wrong place.** They sit in the agent's own process, like x402's client-side spend controls. A compromised agent key skips them.
- **Chain-level limits don't add up across chains.** An allowance enforced by a smart account only covers one chain, but agents pay on several.

**What this extension adds:**
- **Where the limit lives:** a *spend-limit mirror*, an on-chain contract the payer's owner controls. It reports how much the payer may still spend, and it may reflect spending on other chains.
- **What the facilitator does:** reads the mirror, a single `eth_call`, before verifying and again before settling, and refuses if the payment would exceed the limit.
- **Effect:** the limit is enforced by the infrastructure that moves the money, not by the agent that wants to spend it.

---

## The mirror interface

A mirror is any contract on the payment's network exposing:

```solidity
/// @return ok      true if `amount` of the requirement's asset is within the payer's limit right now
/// @return left    what the payer may still spend (same asset units)
/// @return reason  bytes32 short reason when !ok, e.g. "over budget", "frozen", "agent frozen";
///                 "unknown agent" means the mirror does not govern this payer
function canSpend(address payer, uint256 amount) external view returns (bool ok, uint256 left, bytes32 reason);
```

The mirror's owner, never the payer, controls it.

**Example:** in Pocket Money, the mirror is the per-chain vault. Reactive Network updates it after every payment the agent makes on *any* chain, and also when the owner grants a one-day raise from any chain.

---

## Discovery: where is the payer's mirror?

The facilitator must find the mirror **without trusting the payer to declare it**. A payer that wanted to overspend would simply leave the declaration out. Two options, open for discussion:

1. **Registry (preferred).** A well-known registry contract per network maps `payer → mirror`. The facilitator calls `registry.mirrorOf(payer)`, and a zero address means no limit applies.
   - **Who writes an entry:** the payer binds itself once to a *controller*, either in its own transaction or by signing an EIP-712 `Bind(payer, controller)` message that the controller submits (so a payer with no native gas can still be bound). From then on only the controller can change or lift the entry; the payer key can't.
   - **Why this shape:** nobody can register a mirror for a payer that hasn't consented, and a payer key stolen after binding can't loosen anything.
   - **Limit:** binding is opt-in. An unbound payer has no limit here.
   - A reference contract is [`src/SpendLimitRegistry.sol`](../src/SpendLimitRegistry.sol).
2. **Server-declared.** A resource server that knows its customers (for example, an enterprise allow-list) names the mirror in `PaymentRequired`. It's weaker, because it only covers that server's own customers.

Payers *may* also echo their mirror in `PaymentPayload` as a hint, but a facilitator **MUST NOT** treat a missing hint as "no limit".

---

## `PaymentRequired`

A server or facilitator that enforces spend limits says so, so clients know a refusal can come back with a `spend_limit_*` reason:

```json
{
  "extensions": {
    "spend-limit": {
      "info": {
        "enforced": true,
        "registry": "eip155:84532:0x0000000000000000000000000000000000000000"
      },
      "schema": {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "properties": {
          "enforced": { "type": "boolean" },
          "registry": { "type": "string", "description": "CAIP-10 address of the payer -> mirror registry" }
        },
        "required": ["enforced"]
      }
    }
  }
}
```

---

## Verification and settlement

When enforcing, the facilitator **MUST**:
1. Resolve the payer from the payment payload (for `exact` EVM, `authorization.from`).
2. Resolve the payer's mirror (registry or server-declared). If there is none, continue as normal.
3. Call `canSpend(payer, requirement.amount)` on the requirement's network.
   - If `ok == false`: return `isValid: false` with `invalidReason: "spend_limit_<reason>"` (spaces become underscores), and **do not settle**. One exception: for a *server-declared* mirror, `reason == "unknown agent"` means the payer isn't that server's customer, and the payment continues. A registry entry was set by the payer's controller, so there any refusal stands.
   - If the call itself fails (revert or RPC error): **refuse** with `invalidReason: "spend_limit_check_failed"` (fail closed).
4. Repeat step 3 immediately before settling. The limit may have moved since verification.

A refusal is not an error in the payment: no funds have moved. Clients **SHOULD** show the reason to a human, who can raise the limit through the mirror's owner.

---

## Security considerations

**What it covers:**
- **A compromised agent key** can't use a facilitator that enforces this extension to go past the owner's limit. Other routes (plain transfers, non-enforcing facilitators) still need a second layer. In Pocket Money, that's small per-chain floats topped up on-chain, so the worst case is the floats.

**Freshness and races:**
- **Mirror freshness:** a mirror fed from other chains lags by about one block of the mirror's chain. Facilitators on slow chains see a slightly stale limit; the owner's second layer bounds that window.
- **Concurrent payments:** two payments verified at the same moment can both pass. Settlement-time re-checks narrow the window but don't close it; a mirror can expose a reservation call to close it fully (left open here).

**Failure modes:**
- **Fail closed:** an unreachable mirror refuses the payment. Operators that prefer availability can choose otherwise, but must say so.
- **Privacy:** `left` reveals the payer's remaining budget to anyone. A mirror may return a boolean only (`left = 0`) if that matters.

---

## Reference implementation

Pocket Money (Reactive Omni Buildathon, testnet):
- **The mirror:** `Vault.canSpend` on Base, Unichain and Ethereum Sepolia, updated by a Reactive contract that books the agent's payments on every chain, including Sui and Solana via an attested inbox.
- **The registry:** `src/SpendLimitRegistry.sol`, with tests in `test/SpendLimitRegistry.t.sol`.
- **The facilitator check:** `agent/src/seller.ts` wraps an in-process x402 facilitator with the check before both verify and settle.
- **Live evidence** (`deployments/EVIDENCE.md`):
  - a purchase refused with `pocket_money_over_budget` before settling, with no funds moved
  - the owner approving a one-day raise on Ethereum Sepolia, after which the same purchase settled on Unichain
