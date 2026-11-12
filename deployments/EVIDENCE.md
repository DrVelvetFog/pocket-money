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

**Contracts (v3, since retired)**

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

## v4: budget mirror, refusal before settling, and a CCTP refill, all live (2026-11-10)

**Contracts (v4, since retired)**

| | Address |
|---|---|
| Guard (Lasna) | `0x3F6A1d1F9782Cf24b106E7839F0ca420CdF7f5C2` |
| Vault, Base Sepolia | `0xefa6F7C7b4225A08C5b0e40CF6862F1A5d79e58f` |
| Vault, Unichain Sepolia | `0x105074aE7C7949de0e6e5870bE2Cc0498552d45D` |
| Vault, Ethereum Sepolia | `0x900025EBFb12b06F08fb22972e11964FffD2d576` |
| SpendInbox (Base Sepolia) | `0xa7860BF18A0eBd6397d672b45b4e17E47d1D0172` |

**1. The mirror.** The owner set the agent's allowance to $0.30 on Reactive (`0x40674081…fa5e`). The guard's self-subscription synced every vault.
- The Ethereum Sepolia vault's `BudgetSynced` history: v1 $3.00 → v2 $0.30 → v3 $0.20 → v4 $0.10 → v5 $0 → v6 $2.70 (after the reset).
- Ethereum Sepolia's 12 s blocks lag: when the script checked, its mirror still read $3.00; the $0.30 update landed in block 12104578.

**2. CCTP refill.** Three x402 purchases on Base Sepolia:
- settled `0xa6ea9fe0…46cc`, `0x9d368c65…ce50`, `0xc043ecaa…9fcc`
- They drained the Base vault to $2.90, under the $3 low-water mark.

| Step | Where | Tx |
|---|---|---|
| guard requests a refill from the fullest vault | Lasna | `0xb090179b…46c6` |
| Ethereum Sepolia vault burns 1.10 USDC (CCTP v2 fast) | Ethereum Sepolia | `0xcadbf6b4…c106` |
| relayer mints on Base (attested after 20 s) | Base Sepolia | `0x84e554c7…4de6` |
| guard sees the mint land | Lasna | `0x4f984215…0da8` |

**Result:** Base vault $2.90 → $3.99989 (1 bps CCTP fee); Ethereum Sepolia vault $8 → $6.90. The guard's tracked balances match on-chain exactly.

**3. Refused before settling.** A 4th purchase on Unichain, where the agent hadn't spent at all that day.
- The Unichain mirror said $0 left, so the seller returned `402 pocket_money_over_budget` and logged "refused … over budget (left 0)".
- The agent's Unichain USDC stayed at 1000000. **Nothing moved.**

**Reset:** `0x887229b4…194a`. Every vault now reports $2.70 left (the $3 allowance minus the $0.30 spent today).

Logs: `deployments/v4-demo-log.txt`, `deployments/deploy-v4-log.txt`.

## v4: Sui spending counts against the same budget (2026-11-10)

Reactive can't watch Sui. A trusted attester (`agent/src/sui-attester.ts`, using the seller's service key) follows the agent's Sui testnet transactions over Sui GraphQL, because public fullnodes retired JSON-RPC. It reads the *net USDC balance changes* and reports each payment once to the SpendInbox on Base Sepolia.

- Agent on Sui: `0xf2a997b8…c75f`
- Shop (the seller's Sui identity, an approved payee): `0x2a316b4e…ff33`

**1. The agent paid the shop $0.10 on Sui.**

| Step | Where | Tx |
|---|---|---|
| USDC payment | Sui testnet | `2RW6ZSAnq9gKzvCssRBCAUiWFLYze9yzPsKk5cQmm8wF` |
| attester reports it (ForeignSpend) | Base Sepolia inbox | `0xf0952750…78a0` |
| guard books it | Lasna | `0x6125ff7b…7928` |

The budget mirror dropped on every EVM chain: $2.70 → $2.60, then $2.59 after drill 2. All three vaults reached sync version 8 (Ethereum Sepolia caught up a block later).

**2. The agent paid $0.01 to an unknown Sui address (`0x…dead`).**

| Step | Where | Tx |
|---|---|---|
| USDC payment | Sui testnet | `CLgZAEKncRGmxwNMuqmXZXDYCJjbkhVfy2j8wMKqRCHm` |
| attester reports it | Base Sepolia inbox | `0x847aa54c…f116` |
| guard quarantines the agent | Lasna | `0x5c86e188…ed2a` |
| `AgentFrozen` | Base Sepolia | `0x34aa8c17…3ade` |
| `AgentFrozen` | Unichain Sepolia | `0xf63f19ea…4288` |
| `AgentFrozen` | Ethereum Sepolia | `0xbf46c7ff…cdbe` |

**Reset:** `resumeAgent` + `unfreezeAgent` on each vault. Checked on-chain: not quarantined, unfrozen on all three chains.

**Limits, stated:**
- **The attester is a trusted relay.** A false report can only tighten the budget or freeze the agent; silence is bounded by the floats.
- **Sui has no vault,** so Sui spending is booked and policed but not topped up.
- **Mirror lag:** the mirror reaches each chain about one of that chain's blocks after the guard books a spend (12 s on Ethereum Sepolia). A facilitator on a slow chain can briefly see a slightly stale budget; the float bounds that window.

Log: `deployments/sui-demo-log.txt`.

## v5: ask for a raise, approved from any chain (2026-11-10)

**Contracts (v5, since retired)**

| | Address |
|---|---|
| Guard (Lasna) | `0x77BE935e39274963E18E32567e980387aAAae6b8` |
| Vault, Base Sepolia | `0xeceCBacAb0429915459E2874100b994E8dC3d222` |
| Vault, Unichain Sepolia | `0x614EB7577B127870F8c2223deE869E9a799e78CC` |
| Vault, Ethereum Sepolia | `0xa7860BF18A0eBd6397d672b45b4e17E47d1D0172` |
| SpendInbox (Base Sepolia) | `0xfEf8522B931Ded31aeAe2F8FF5cb6B5e60E1289d` |

This version includes both fuzzer-found fixes.

| Step | Where | Tx |
|---|---|---|
| allowance set to $0.20 | Lasna | `0x7af2b9da…4ccd` |
| x402 purchase 1, 2 | Base Sepolia | `0xb6bb2e18…039a`, `0x706fdc9f…6db9` |
| 3rd purchase on Unichain refused before settling (`pocket_money_over_budget`) | — | (no tx, nothing moved) |
| owner approves a $0.30 raise **on Ethereum Sepolia** (`approveRaise`) | Ethereum Sepolia | `0xc45efba4…94f0` |
| guard grants it (`RaiseGranted`) and re-syncs every mirror | Lasna | `0xf2a876e9…412c` |
| retry on Unichain settles | Unichain Sepolia | `0x7dfe5f44…8339` |
| reset to $3 | Lasna | `0x585ccd40…cf949` |

**The Ethereum Sepolia vault's mirror,** from its `BudgetSynced` log: $3.00 → $0.20 → $0.10 → $0 → **$0.30 (raise)** → $0.20 → $3.00 after the reset. That last figure is the $3 allowance plus today's $0.30 raise, minus the $0.30 spent.

**Retirement:** retiring v4 hit a race the first time. The old guard paid fees for reacting to the vaults' `migrate()` transfers between our balance read and the withdrawal. It now withdraws with a margin (`0xf1220bbe…a5a1`).

Logs: `deployments/deploy-*.log`, `deployments/raise-demo-*.log`.

## v5: Solana spending counts against the same budget (2026-11-10)

The same SpendInbox and the same guard as Sui. The Solana attester (`agent/src/solana-attester.ts`) follows the agent's signatures on Solana devnet and reads each transaction's net USDC token-balance changes.

- Agent on Solana: `5r1ZGoTwDemrrTXzS82RRC8xGkKms1neC2C42ScSGqRu`
- Shop (the seller's Solana identity, approved): `AWx4Tw82rgSGR8FKDoLsaMrfJzhehApMU7fX52ia9rkR`

| Step | Where | Tx |
|---|---|---|
| agent pays the shop $0.10 | Solana devnet | `2uTzymn94zx5RQ98uPpUj2V9t5YXxDX3bqZXF8cq3rAycsZb4Wo2jCHb5LvM3bs2KYX8ryZH3M7eEyqpnfbJs1kd` |
| attester reports it | Base Sepolia inbox | `0x222564cd…312b` |
| guard books it; the mirror drops $3.00 → $2.90 on **all three** EVM chains | Lasna | `0x2fc242e5…d324` |
| agent pays $0.01 to an unapproved address | Solana devnet | `n816BXBzXKK7yv3VafLP5KAz5HZ2JN36RsfEsi1esniMxX4p5Fv2pG6zMf3bqsQu3zyk7LdK1C7kJ2qnbvBRcW9` |
| attester reports it | Base Sepolia inbox | `0x9aa756a0…26a6` |
| guard quarantines the agent | Lasna | `0x516f2210…6e3d` |
| `AgentFrozen` | Base / Unichain / Ethereum Sepolia | `0x47ee4935…a74c` / `0xc0604c1b…973e` / `0x5f9d5018…05f9` |

**Reset:** `resumeAgent` + `unfreezeAgent` ×3. Checked on-chain afterwards: not quarantined, unfrozen everywhere.

**Getting devnet SOL:** the public RPC airdrop is closed, and the web faucet requires GitHub and asks AI agents not to use it. Tony requested the SOL himself.

## Receipt verifier (2026-11-10)

`script/verify.sh` needs no keys. It checks the guard's receipt chain against the chains where the money moved:
- **EVM payments:** the USDC `Transfer` in the origin transaction.
- **Sui and Solana payments:** the inbox's `reported(ref)`.

It then rebuilds every receipt hash.
- **Live result:** `VERIFIED: 5 receipts`. The rebuilt head `0x613d1e7c…18b9` equals the guard's.
- **Self-test:** `TAMPER=1` (one unit forged on receipt #0) breaks every later head and reports `FAILED`.

## Dry run of the unattended daily job (2026-11-10)

`script/daily.sh` was run twice by hand before the live run. It unlocks the keys from the macOS Keychain, starts the x402 seller and the CCTP relayer, buys the morning report, waits for the top-up, verifies the receipt chain, writes the day's JSON, and stops everything.

| Run | Chain | x402 settlement (sent by seller) | Top-up | Mirror | Verifier |
|---|---|---|---|---|---|
| 1, normal shell | Ethereum Sepolia | `0xbe43ce80…4798` | `0x6c3a983d…6480` | $2.89 → $2.79 | VERIFIED, 6 receipts |
| 2, bare environment like launchd (`env -i`, PATH=/usr/bin:/bin) | Unichain Sepolia | `0x8798ff04…0874` | `0x9f25bc9a…65cf` | $2.79 → $2.69 | VERIFIED, 7 receipts |

**Checks:**
- No password prompts.
- The agent was back to its $1.00 float each time.
- The seller and relayer stopped after each run.

Records: `deployments/daily/2026-11-10-run1.json`, `deployments/daily/2026-11-10-run2-bare-env.json`.

## v6: a repeated callback can't burn twice; redeployed and re-proven (2026-11-10)

**Why.** Reactive can deliver one requested callback twice. A new test makes the simulator do that for every callback. Top-ups, mirror syncs and freezes were already safe to repeat; a repeated rebalance would have sent a second CCTP transfer. The guard now numbers each rebalance per donor chain, and the vault declines any number it has already seen. Details: `SECURITY.md`, bug 3. Commit `a90ea1fb`.

**Retiring v5.** The three vaults `migrate()`d to the owner, and the guard returned its lREACT:
- `0xb5c4f069…7ecd`, `0x9abd83fb…eda8`, `0xc5038a1c…e4a0`, `0xed41501f…2dc6`
- The first redeploy then stopped: deploying the guard needed about 0.5 lREACT of gas on top of its 1.7 fund. Rerun with a 1.0 lREACT fund.

**Contracts (current)**

| | Address |
|---|---|
| Guard (Lasna) | `0x5Bc6C4F0dC05B47413AD86EE39C632E408677A5A` |
| Vault, Base Sepolia | `0x4eE05aab7Afd0EAF7098620cC9FaaA3c27fB98B5` |
| Vault, Unichain Sepolia | `0x9408E947d6654417BAcF45548070A0453690AdA3` |
| Vault, Ethereum Sepolia | `0xfEf8522B931Ded31aeAe2F8FF5cb6B5e60E1289d` |
| SpendInbox (Base Sepolia) | `0x7d2a761d8262415c00803c3F5Fc3F08Fc47B49e6` |

**The v4 demo, rerun on v6:**
- **Mirror:** the allowance was set to $0.30 (`0x7edcabdb…24ae`). Base and Unichain read it right away; Ethereum Sepolia lagged a block, as before.
- **Refill:** three x402 purchases on Base settled: `0x5a74911c…2995`, `0xc32ab2b9…b43e`, `0xdccd1f39…8ffc`. The Base vault fell to $2.90.

| Step | Where | Tx |
|---|---|---|
| guard requests a refill (rebalance #1 from Ethereum Sepolia) | Lasna | `0xc1c90814…f277` |
| Ethereum Sepolia vault burns (CCTP v2 fast) | Ethereum Sepolia | `0x3372fdaa…5e25` |
| relayer mints on Base (attested after 17 s) | Base Sepolia | `0x7853c03d…736d` |
| guard sees the mint land | Lasna | `0x07d3f38d…b61d` |

- **Result:** Base vault $2.90 → $3.99989. The Ethereum Sepolia vault's `lastRebalanceSeq()` reads 1.
- **Refused before settling:** a 4th purchase on Unichain got `402 pocket_money_over_budget`. The agent's Unichain USDC stayed at 1000000.
- **Reset:** `0x4f43003e…ae44`.
- **Receipts:** `script/verify.sh` VERIFIED 3 receipts; the rebuilt head matches the guard (`0xa1948266…546b`).

**Cost:** the redeploy, setup and demo took the new guard from 1.0 to 0.77 lREACT.

Logs: `deployments/deploy-20261110-103005.log`, `deployments/v4-demo-20261110-103509.log`.

---

## Registry: two sellers, no vault addresses (2026-11-11)

Until now only our own seller knew where the agent's budget mirror was. `SpendLimitRegistry` (one per chain) maps a payer to its mirror, so any x402 facilitator can find it. The guard and the vaults were not changed or redeployed.

**Registries, and the agent's binding on each.** The agent signed an EIP-712 `Bind(agent, owner)` message per registry; the owner submitted it. The agent's nonce did not change on any chain (3, 4 and 2 before and after).

| Chain | Registry | `bindWithSig` tx (sent by the owner) |
|---|---|---|
| Base Sepolia | `0xD48A658E4862682FA47C57464E52Cfa3b376E3e1` | `0x58b23e95a374aed006122e82d29c47e8f02156a8766f30c5fe53cb12d1c1b073` |
| Unichain Sepolia | `0x77BE935e39274963E18E32567e980387aAAae6b8` | `0xeecbbde386a3be56ec09231f52d4b8f757adc5e53ed09fc5939fabf840dcca49` |
| Ethereum Sepolia | `0x51954B6F45739d549644B292DC42b9f63BdFd312` | `0x2a9c43571b628939a8e62a837c285da95e629ab51f8f744666eff080915cef1b` |

On each, `controllerOf(agent)` is the owner and `mirrorOf(agent)` is that chain's vault.

**A second seller.** Seller B is a separate key, `0xE7F43b71C95A8965a376322071c8C2e6feb83fCa`, on its own port. It was funded with settlement gas and approved as a payee (`0x32aaf5ce07761f3f4a637f821947aa074e0931079b6706595f95efe76e213aca` on Lasna). Both sellers were started with the three registry addresses and **no vault addresses**; `/health` reported `"limits":["registry","registry","registry"]` for each.

**The run** (`script/registry-demo.sh`). The day's window already held $0.60 of spending, so the allowance was set to $0.90 (`0x73268882a4a703d8ad45995fb4e758a54ffea087f7a268df2b145f8eff2d1265`), and all three mirrors read 300000 left.

| Purchase ($0.10) | Origin (settled by the seller) | Reactive (Lasna) | Top-up callback |
|---|---|---|---|
| Seller B, Unichain Sepolia | `0xe9d97ec318a48fcae9df584654210b845d0165687e1648d8e1284df3c93146b5` | `0x98fd6b47be36fd4f93478e29bb6ea473ff3c23e6d651a511c876972074af4351` | `0x9f1f0fa764f652588878e8533767beb3d797d47f8e823be26d5e8317e611ae79` |
| Seller A, Base Sepolia | `0x63e221248107bdc50cd559571b82266fe14af4a2cefbc057426c6eb460814a5e` | `0x5adcdb89541e4c132374a081868dbffc332e91032eb6857e83ee1288469bd0ee` | `0x5b488cb411b16a48862ab8e78bce560212f6e57efec70e03304367c84d654133` |
| Seller B, Ethereum Sepolia | `0xb68faa329ca2e950174b76425a9de8d5ccb33ac986a4b0d23b5cadf6a76901d2` | `0x28db0eea08497bb6358c73379653364e941fce382fd2a6e1a0fd1ed6f34e6822` | `0xc181faeef7ca062ca7edde9e83b83a7ead481c7db0ae668fccfdc16a23f36c18` |

- **Refused before settling:** a 4th purchase, from seller B on Unichain, got `402 pocket_money_over_budget`. Seller B's log: `refused 0x7Cd6…a06b on 1301: over budget (left 0, mirror 0x9408…AdA3 via registry)`. The agent's Unichain USDC stayed at 1000000 and seller B's nonce there stayed at 2, so nothing was sent.
- **The agent's key can't loosen its entry:** called from the agent's address, `setMirror(agent, 0)` reverts `NotController` and `bind(agent, 0)` reverts `AlreadyBound`. `mirrorOf(agent)` was unchanged.
- **Reset:** `0x1c513971de8bed20cf5ea47a5e1fd1261fc9117641d8c52d6338db27db1bc25c`.
- **Receipts:** `script/verify.sh` VERIFIED 9 receipts; the rebuilt head matches the guard (`0x9657d66abaaeea28319a0a4b81e525908ade4cdea42e1537b11a1764148fb498`).

**What went wrong on the way** (both were script faults, and no funds were at risk):
- The first run set the allowance to a flat $0.30. Yesterday's demo had already spent $0.30 inside the same 24-hour window, so the mirrors read 0 and the script waited. It now sets the allowance to "spent so far + $0.30" and stops before buying if the mirrors don't reach that.
- The second run settled and topped up all three purchases (origins `0x3cde6dfc5c1646ac237aae0b2888bda34dc844c92d1582e3c1df14b6f14c8f17`, `0x20c73754ab296b43c8fc7f0ad87da7c98ef91893ac3cb5b45be83953b61ea640`, `0xcff4fcc15f1dedf63feb0bd59b9d4707d73d99b73e10384ef2bc7c16571a20f6`) but printed `reactive none`, because the script searched Lasna with an old `Spent` signature. The two-minute wait that caused pushed the Base top-up outside the 200-block range Base's public RPC allows for `eth_getLogs`. It was stopped by hand before the refusal step. The signature is fixed.

**Cost:** the three runs took the guard from 3.77 to 3.45 lREACT.

Logs: `deployments/registry-deploy-20261111-062617.log`, `deployments/registry-demo-20261111-065349.log` (the clean run), and the two earlier `registry-demo-20261111-06*.log`.

---

## Seller keys rotated (2026-11-11)

**Why:** while debugging the registry demo, a process listing on the development Mac showed the two sellers' testnet private keys (the scripts pass them to the seller process as environment variables). Nothing was taken, but `pm-seller` is also the inbox attester, and a leaked attester key can file a false report and freeze the agent. Both keys were replaced the same day. The guard and the vaults were not redeployed.

**What changed** (`script/rotate-seller.sh`):

| | Old | New |
|---|---|---|
| Seller A (x402 shop, CCTP relayer, attester) | `0xB8232D5437Aa124c235c8321dec2d1003863cB65` | `0xF5779c263B87d0310315742cd89598E06297b3b2` |
| Seller B | `0xE7F43b71C95A8965a376322071c8C2e6feb83fCa` | `0xfF2F85b520131AFdF6342A0ea0a446c5dFcC15f1` |
| Sui shop | `0x2a316b4e56041b8c237f985a823af7b8054cccd7cc73200055cb220fc857ff33` | `0xc1f5e8589dfcaf0e89005e6945fc4265b326222f25c444c438c58e9d97abe1c2` |
| Solana shop (payee id) | `0x8d6548338301e8d2c785828cb219f8e9e7dc66c491b70145a16e90f4748bfeea` | `0xadbfd2ae5a02b82a4fcae61549025a7a0eaa197931fcd9739c6dacccf212006f` |
| SpendInbox (Base Sepolia) | `0x7d2a761d8262415c00803c3F5Fc3F08Fc47B49e6` | `0xD7c7732520FCb454673aB42229Eb60356E96A8A8` |

Owner transactions on Lasna:
- Seller A: approve new `0x788e2a905dbe76aa3ed4a0a3dc1234f278b56816abd16ccfedc1d2d60cdc900e`, revoke old `0x1d12c31c11789fe864bfb664d483414e2acfaf77d411f47f4102070ff1ba732d`
- Seller B: approve new `0x016723441c738f46889c8cb428e27d002519ebf80647049b5ca90a4a0ccb659a`, revoke old `0xa58863d83d6a3909973547bf775f5830868f48a9df30db04c371fb8c12eb5358`
- Sui shop: approve new `0x0edfbfe6319cfdc2667da9cf91193eb96ab19005f3ec36af9c4e030d0d35ac78`, revoke old `0xf707bbef5d2174ce70b9b848ca482416b70103d317a0829278d42b2ddafe6c26`
- Solana shop: approve new `0xadb96935d12c276c4976cf302d34fc1aedf9fafb35ea301289812b7653b22031`, revoke old `0x7b9f166304512f68d3b7325c1142d8b89e47db6716afe5dda7439c8b30f6fcb1`
- Guard pointed at the new inbox: `0x3439305e9597329bb1f6742a6b38538d38baa484e773c337da73ea1f2bf2aaa5`

**Why the old attester key is now harmless:** the inbox's attester is immutable, so a new inbox was deployed with the new key as attester. The guard only acts on reports from the inbox it currently names (`inboxOf(84532)`), so anything the old key reports to the old inbox is ignored.

**Checked afterwards:**
- on the guard, all four new payees read approved and all four old ones read not approved
- `inboxOf(84532)` is the new inbox and its `attester()` is the new seller A
- `script/verify.sh` VERIFIED 9 receipts, head unchanged
- the go-live preflight passes. It now tests that the Keychain passwords really open the keystores; before, it only checked that an entry existed, and it had reported ready while the Keychain still held the old seller's password

**Re-run afterwards:** the daily job and the Sui and Solana demos, all against the new keys (next section). Earlier sections of this file show the old addresses, as they were at the time.

Logs: `deployments/rotate-seller2-*.log`, `deployments/rotate-seller-*.log`.

---

## After the rotation: daily job, Sui and Solana re-run (2026-11-11)

Everything below used the new seller key, the new inbox and the registries.

**The unattended daily job, bare environment** (`env -i` with only HOME, USER and `PATH=/usr/bin:/bin`, like launchd). No prompts.

| Chain | x402 settlement (sent by the new seller A) | Top-up | Mirror | Verifier |
|---|---|---|---|---|
| Base Sepolia | `0x2311603f2c9586f3606a0e9e0356673f53b35e8fd6bb17133d81bde5ed08bfdf` | `0x42306a3b92d644e806c44daaa2e1c514cbed6bb894d96292e238998723bcf81f` | $2.10 → $2.00 | VERIFIED, 10 receipts |

The agent was back to its $1.00 float and the seller and relayer stopped. Record: `deployments/daily/2026-11-11-dryrun-bare-env.json`.

**Sui** (`script/sui-demo.sh`). The attester ran as the new seller A against the new inbox.

| Step | Where | Tx |
|---|---|---|
| agent pays the new Sui shop $0.10 | Sui testnet | `CdxTaLWeMAmu6vQU3zmYNLCLnJhj9khC1YxDXTYih432` |
| attester reports it | Base Sepolia inbox | `0x37685c5582c7773b1f1212367a65e1f64c530662d8fe59c194f9212cab58ebf0` |
| guard books it | Lasna | `0x63f362b9d508a2f4f0da7e86d2423b8b4df2afcea3645be140fd138adeea6462` |
| agent pays a stray address $0.01 | Sui testnet | `Ay3Qt7f8Nnre7GhBCdXXxkPqjbWbPCmXdhsPmamampVw` |
| attester reports it | Base Sepolia inbox | `0x1f5ec1b50ae2d16bbc1b91f4c4bb572612e03915fca84a9bad708c74c7bcd563` |
| guard quarantines the agent | Lasna | `0x281e269c34040144953032717e8a8720ac86cda2628b9f0e2455255c1a8bea5b` |
| frozen on Base Sepolia | Base Sepolia | `0xa95b2bc9b26d6e50034b379156d05e4c8a00ac460444fca0d115ad3d3b5be29c` |
| frozen on Unichain Sepolia | Unichain Sepolia | `0xb2d8e677895ad9f7a1f6476aa5a1e6b85a7dda53b785f42ddf38fa7d40530535` |
| frozen on Ethereum Sepolia | Ethereum Sepolia | `0x8a16daa0c1c50af10093ae1e81a4112a09a38a0e267c50b56449ad5ed2b2edd3` |

After the shop payment the mirrors on Base and Unichain read $1.90 (from $2.00). Ethereum Sepolia still read $2.00 when the script looked, the one-block lag noted under "Limits"; it had caught up by the next step.

**Solana** (`script/solana-demo.sh`).

| Step | Where | Tx |
|---|---|---|
| agent pays the new Solana shop $0.10 | Solana devnet | `CGASuMQNUccu52EH995n8NjChcJxs8vmsMA5y4sLT6tRCeMwBA1M9YSEHznQSLzzd7Eua9qTckEsSSNyx6hDeCW` |
| attester reports it | Base Sepolia inbox | `0xa11eccfb37b19003b6caec5929800a55823570e287f1a1a13491b7adf09152c5` |
| guard books it | Lasna | `0x230d9915484e9c390c07a98b96fdc6e1660f67cd937f7a46b53df98cdd51d88a` |
| agent pays a stray address $0.01 | Solana devnet | `3eioALVUoBKX8G4nsmPmpd8JbB3xDGoubyeoETraX2NxCBoxa7CeshPqsqsGuayMAUg1Bsyq6Fh11AzJH1ASL8Dj` |
| attester reports it | Base Sepolia inbox | `0xf70f289531dac9941209b0f637412d8919dacd925eaaae4e03aa7a047d75e4b5` |
| guard quarantines the agent | Lasna | `0x0501920b5e873d8d80564a12ccca6aaf83ac52ced38ddb68472b23c6907d8492` |
| frozen on Base Sepolia | Base Sepolia | `0x98b9e5bf5fd1f30b90fd28d3fa850837310ccb03d4de2d14388c7c7ba3b9fc60` |
| frozen on Unichain Sepolia | Unichain Sepolia | `0x4917ea84a4c351fe80794d25c90e7c971b3874a4a89b42411a65dacf4296e95c` |
| frozen on Ethereum Sepolia | Ethereum Sepolia | `0x95a75bbfb1ea57649eaf4b03b7905ed57e4a36c6423bfdc285fb73da7443f4da` |

All three mirrors read $1.79 (from $1.89) after the shop payment.

**Afterwards:** both runs ended with the owner's reset (resume on the guard, unfreeze on each vault). `script/verify.sh` VERIFIED 14 receipts, head `0xc41a38cd7e0903edb00eb8ea705c48921a1968daf453c4ddb899323c2be55799`, and the go-live preflight passes with the guard at 3.31 lREACT.

Logs: `deployments/sui-demo-20261111-073349.log`, `deployments/solana-demo-20261111-073819.log`, and each run's `-attester.log`.

---

## Speed, verification, and a second machine (2026-11-12)

**How fast the loop is.** `script/latency.sh` reads three public block timestamps for every EVM payment the guard has booked: the payment on its own chain, the guard's reaction on Lasna, and the top-up callback back on the payment's chain. Block times are whole seconds, and Lasna's clock can read a second behind the origin's, which is why two rows show -1 s.

| Chain | Payment | To the guard | To the top-up |
|---|---|---|---|
| Base | `0x5a74911c…` | 0 s | 2 s |
| Base | `0xc32ab2b9…` | -1 s | 4 s |
| Base | `0xdccd1f39…` | 0 s | 2 s |
| Unichain | `0x3cde6dfc…` | 0 s | 3 s |
| Base | `0x20c73754…` | 0 s | 2 s |
| Ethereum | `0xcff4fcc1…` | 1 s | 12 s |
| Unichain | `0xe9d97ec3…` | -1 s | 2 s |
| Base | `0x63e22124…` | 0 s | 1 s |
| Ethereum | `0xb68faa32…` | 0 s | 12 s |
| Base | `0x2311603f…` | 0 s | 2 s |

Payment to top-up over 10 loops: median 2 s, fastest 1 s, slowest 12 s. Both 12 s rows are Ethereum Sepolia, whose blocks are 12 s apart.

**The deployed code is this code.** All eight contracts are verified on Sourcify as exact matches (runtime and creation bytecode): the guard on Lasna, the three vaults, the spend inbox, and the three registries. Addresses are in the README's deployment table.

**Someone else's machine.** `./quickstart` was run from a fresh clone on a second computer (Ubuntu under WSL on a Windows laptop) with its own new keys, so nothing was shared with the deployment above.

| What | Where |
|---|---|
| Owner | `0xae8Db5e71e434CcCCcB5005AF5c9cFdcDFc5bBdc` |
| Agent | `0xfCD2f43eDFb9e5A7d6324BB7bB0D65ad172359f9` |
| Guard · Reactive Lasna | `0x86965ab71FB32217BA00252a5F2a56947fa257B3` |
| Vault · Base Sepolia | `0x86965ab71FB32217BA00252a5F2a56947fa257B3` |
| Vault · Ethereum Sepolia | `0xaDE8EEA87768CC1Ec541FCf1abD3C2b00a4a566A` |
| Registry · Base Sepolia | `0x53af28b70ae88a7AbA67750b5e5fFD393F9eb978` |
| Registry · Ethereum Sepolia | `0x46182c943D289C8afb660FE68A5A5334fB875141` |

The guard and the Base vault share an address because each was that new owner's first contract on its chain.

- Setup made one real x402 purchase on each chain, and `./quickstart check` reported Healthy with 2 verified receipts.
- The unattended daily job then ran once there: settlement `0x5c8b2d76132352d56e41840fd3c2ca03ad7e53353cd1186017a5deae06229e80` on Base Sepolia, top-up `0x6697be97edc7f2496361c4ca34725abbf3c04648a6d95f1f041def29950cf45b`, mirror $2.80 to $2.70, 3 receipts verified against that guard.
- The run found three faults in the setup script (it tried an unfunded chain, wrote an empty dashboard config on a two-chain setup, and accepted a mistaken "yes"). All three are fixed in the history: `9db69189`, `aa73c7f4`, `b87384d4`.

