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

## Week 2, v3: gas fix live, every loop passes on all three chains (2026-11-10)

**Contracts (current)**

| | Address |
|---|---|
| Guard (Lasna) | `0x675a63b8C8e56EDF2e4d4B796d6296F485Ee8707` |
| Vault, Base Sepolia | `0x675a63b8C8e56EDF2e4d4B796d6296F485Ee8707` |
| Vault, Unichain Sepolia | `0x0b7532d60381dBe632bCE7D013a00b17FDE6bC1F` |
| Vault, Ethereum Sepolia | `0x89dBdF104dc6b2A23E05943297D890c1B80E1271` |

The guard and the Base vault share an address by nonce coincidence; they're different contracts on different chains.

**v2 retired via `migrate()`, live.** Each old vault ended frozen with $0. Txs:
- `0xe446a547…8cd1`
- `0xe5589156…669c`
- `0x9df35755…04bd`
- guard lREACT returned: `0x4d7ea607…72cf`

**Loop 1: spend → top-up**

| Chain | Origin | Reactive | Callback | Delay |
|---|---|---|---|---|
| Base Sepolia | `0x5cfa71ae…83b2` (blk 56942433) | `0x9a6d24c2…17ca` | `0x1ff798ab…9b7f` (blk 56942442) | 9 blocks, ~1.8 s |
| Unichain Sepolia | `0xb73dfb85…dc70` (blk 67457934) | `0x6b5254da…fad0` | `0xb31c9bd2…b002` (blk 67457936) | 2 blocks, ~2 s |
| Ethereum Sepolia | `0x09f90efb…f535` (blk 12104356) | `0x218dfb78…8a4d` | `0xc9e5af38…1756` (blk 12104357) | **next block, ≤12 s** |

**Loop 2: unknown payee → agent frozen on every chain.**
- origin `0x56860bba…84a8` (Unichain) → reactive `0x993e90cb…394a`
- `AgentFrozen` on Base `0x7349d262…b131`, on Unichain `0xcbd0b9dc…a429`, on Ethereum Sepolia `0x44069de7…51bb`
- The agent was left at $0.75 on Unichain: the stray payment is never refilled.

**Loop 3: panic on Ethereum Sepolia → every vault frozen.**
- panic `0xd096c24e…f0f7` → reactive `0x188af805…5b1e`
- `Frozen` on Base `0x315f0a0c…ed49`, on Unichain `0xb7a93657…fd33`, on Ethereum Sepolia `0x9c9b35a9…cd69`

**After resets (checked on-chain):** not panicked, agent not quarantined, every vault un-frozen.

Logs: `deployments/deploy-v3-log.txt`, `deployments/week2-loops-v3-log.txt`.

## Week 2: the agent pays over x402 and holds no ETH (2026-11-10)

- **The agent's daily job:** it buys a $0.10 BTC report from our x402 seller (`agent/src/seller.ts`). The seller settles the agent's signed EIP-3009 authorization itself and pays the gas, from `pm-seller` `0xB8232D5437Aa124c235c8321dec2d1003863cB65`.
- **The agent never sends a transaction.** Its nonce was unchanged on every chain: Base 3→3, Unichain 4→4, Ethereum Sepolia 2→2.
- **Pocket Money still sees every payment:** each one is a USDC `Transfer` *from the agent*.

| Chain | Origin (sent by seller; Transfer agent→seller 100000) | Reactive | Top-up callback |
|---|---|---|---|
| Base Sepolia | `0xef205412…fc06` | `0x3716acba…7a56` | `0xbadf2b4b…ea23` (blk 56947033) |
| Unichain Sepolia | `0x2ffa3e4d…20a7` | `0x0120247b…647f` | `0x198ad1dd…0aa5` (blk 67458854) |
| Ethereum Sepolia | `0xe6672f42…97fe` | `0x7d995091…91a1` | `0xfa1a45c7…5604` (blk 12104434) |

- **Checked on-chain:** each origin receipt shows `AuthorizationUsed(agent)` and `Transfer(agent → seller, 0.10 USDC)`, with tx `from` = the seller.
- **Guard afterwards:** 7 receipts in the chain, head `0xbd855a47…2156`; agent spent $1.30 and was topped up $1.05 today (the $0.25 stray payment is never refilled).
- **On Unichain the agent sits at $0.75, not $1.** The vault fills "what was spent" up to the float, and the earlier stray $0.25 is still missing by design.
- **x402's own client-side limits are set too** (only Circle USDC on these chains, ≤ $0.25 per payment), but they live in the agent's process. Pocket Money's limits are on-chain and survive a stolen key.

Log: `deployments/x402-demo-log.txt`.

## Stretch probe: Circle CCTP v2 fast transfer works on our testnets (2026-11-10)

The owner moved $0.10 USDC from Base Sepolia (domain 6) to Unichain Sepolia (domain 10).
- **Contracts:** TokenMessengerV2 `0x8FE6B999…2DAA` and MessageTransmitterV2 `0xE737e5cE…E275`, the same address on every testnet.

| Step | Chain | Tx |
|---|---|---|
| approve | Base Sepolia | `0xd21e2b55…6086` |
| depositForBurn (fast, threshold 1000) | Base Sepolia | `0x14d956bf…5f0d` |
| Circle attestation | iris-api-sandbox | complete after **6 s** |
| receiveMessage (mint) | Unichain Sepolia | `0x29314bc4…5437` |

**Result:** the owner's Unichain balance went up by 99987. The 13-unit fee is 1.3 bps, matching `/v2/burn/USDC/fees/6/10`.
