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

## Week 2: three chains, household guard (v2, 2026-11-10, retired the same day for the gas fix)

**Contracts**

| | Address |
|---|---|
| Guard (Lasna) | `0xB66459cE2711987c07048ac9570fcBC8AEC73820` |
| Vault, Base Sepolia | `0xd89544bc7054229E1F3e34E8C8DF1c84697E682e` |
| Vault, Unichain Sepolia | `0x2f48C06CfEA23Bc3Ec702691d0d3AF01a06AA4CD` |
| Vault, Ethereum Sepolia | `0x5EB89Db6f0AAf259326A7Fb2d16E8FdcCc4B77fb` |

**Loop 1: spend → top-up**

| Chain | Origin | Reactive | Callback | Delay |
|---|---|---|---|---|
| Base Sepolia | `0x881badee…83ee` (blk 56937560) | `0x6374a91e…c3d7` | `0xffbb5a6c…4557` (blk 56937571) | 11 blocks, ~2.2 s |
| Unichain Sepolia | `0x150aabc3…c184` (blk 67456959) | `0x481b1f79…51d5` | `0x22153065…d893` (blk 67456961) | **2 blocks, ~2 s** |
| Ethereum Sepolia | `0x266f25f7…7a09` (blk 12104275) | `0xc8f87552…0ee8` | **CallbackFailure**: proxy tx `0xca08d686…5517` (blk 12104276) | see below |

**Bug found live: Ethereum Sepolia top-up ran out of gas.**
- The callback was delivered one block after the origin, but the proxy logged `CallbackFailure(vault, topUp(...))`.
- **Cause:** Ethereum Sepolia's proxy withholds 150k gas of overhead (Base and Unichain withhold 80k). A top-up there costs ~182k (`cast estimate`) versus 52–66k elsewhere, so the fixed 400k limit was too tight.
- **Fail-closed in practice:** nothing was sent, and the vault's state was unchanged (`lastSeq` stayed 0). The agent just stayed $0.25 short.
- **Fix in d917abc:** a per-chain callback gas limit, default 1,000,000. Callbacks bill gas used, not the limit.

**Loop 2: unknown payee → that agent frozen on every chain.** The agent paid $0.25 to `0x…dEaD` on Unichain.
- origin `0xc820a416…f7b` → reactive `0x6318f396…fdad`
- `AgentFrozen` on Base `0x3606a036…24ba`, on Unichain `0x535075e8…01b4`, on Ethereum Sepolia `0x2d72c8ec…ae2`
- no top-up for the stray payment

**Loop 3: panic on Ethereum Sepolia → every vault frozen.**
- panic `0x7815ee3c…b836` → reactive `0xb72cea99…60fd`
- `Frozen` on Base `0x32f5a21a…f6e8`, on Unichain `0x41214a5f…ce7c`, on Ethereum Sepolia `0x9ee57ae6…3f07`

**Resets:** after each drill, `resumeAgent` / `resume` on the guard plus `unfreezeAgent` / `unfreeze` on each vault left everything un-frozen (checked on-chain).

Full output: `deployments/week2-loops-log.txt`.
