# Evidence log

Every claim in the README should point at a row here.

## Week 1: first full loop on testnet (2026-11-10)

**Contracts**

| | Chain | Address |
|---|---|---|
| PocketMoney (guard) | Reactive Lasna (5318007) | `0x2f48C06CfEA23Bc3Ec702691d0d3AF01a06AA4CD` |
| Vault | Base Sepolia (84532) | `0x2f48C06CfEA23Bc3Ec702691d0d3AF01a06AA4CD` |

Same address on both chains because each was the owner's first deploy (nonce 0) on that chain.

**Loop 1: spend → top-up.** The agent paid $0.25 to an approved payee.

| Step | Chain | Tx | Block |
|---|---|---|---|
| Agent's USDC payment (origin) | Base Sepolia | `0x466feb3ca53d33cfd18f04400ce2e7b96c03d84d764555c65315864e13fc1982` | 56931196 |
| `react()` books it, requests top-up | Lasna | `0xc5b72220b58e08853caca59e5f6d95798c87e4dcb62f055d61f8be0673d7cb70` | 7996637 |
| Vault `topUp` (callback) | Base Sepolia | `0x44963b2fc1a7e5b3923d7f824b3ef485d01acc24ef5bf9eb25613f2af4a9d760` | 56931204 |

**Result**
- The agent's balance went back to exactly $1.00, its float.
- The vault went from $5.00 to $4.75.
- Guard state afterwards: `spentToday` = `toppedUpToday` = 250000; receipt #1 head = `0x9537a24c…841e21`.
- The `TopUp` event shows requested 250000, sent 250000, agent balance 1000000.

**Top-up delay**
- **8 Base Sepolia blocks**, about **1.6 s** at 200 ms per block, from the origin block to the callback block.
- Block timestamps (1 s resolution) show 1 s. The Lasna timestamp reads 1 s *before* the origin's, so the chains' clocks aren't comparable at sub-second precision. Count Base blocks instead.
