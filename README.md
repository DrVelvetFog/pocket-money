# Pocket Money

**A cross-chain allowance for AI agents. Worst case, you lose the float.**

Built for the [Reactive Omni Buildathon](https://dorahacks.io/hackathon/reactive-omni-buildathon) · track *Set It and Forget It* · testnet.

You give an AI agent a wallet and it pays for things on its own, often over [x402](https://x402.org), on whichever chain is cheapest. Pocket Money gives that agent **one daily allowance that holds across every chain at once**, refuses payments that would go over it **before they settle**, and freezes the agent everywhere the moment it pays someone you didn't approve, including on chains Reactive can't watch.

Everything here runs on testnets, and every claim below links to a transaction in [`deployments/EVIDENCE.md`](deployments/EVIDENCE.md).

---

## In 30 seconds

**The setup:**
- **Small floats only.** On each chain the agent holds a small **float** of USDC (say $1), and no ETH at all. x402 payments are gasless for the payer, so the only thing the agent's key can move is that float.
- **Watching every payment.** A **guard** contract on Reactive Network watches the agent's USDC transfers on Base, Unichain and Ethereum Sepolia. It books every payment against **one shared daily budget** and chains it into a receipt hash.
- **Topping up.** After each approved payment, the guard asks that chain's **vault** to refill the float. Top-ups stop when the budget is gone.

**Every vault also keeps a budget mirror.** It's a copy of the agent's remaining *cross-chain* budget, pushed by the guard after every payment. An x402 facilitator calls `canSpend(agent, amount)` and refuses an over-budget payment before settling it. Our own x402 seller does exactly that.

**What happens when something goes wrong:**
- **An unapproved payee freezes the agent everywhere.** One payment to an address you didn't approve freezes that agent on **every** chain. That includes payments on **Sui and Solana**: a relay reports them to an inbox on Base, so they count against the same budget.
- **Panic on any chain.** Pressing panic on any one chain freezes every vault.
- **A raise from any chain.** Approving a one-day raise on any chain re-syncs every mirror within seconds.

**Vault liquidity is managed too.** When a vault runs low, the guard has the fullest sibling vault send USDC over Circle CCTP.

## Why this needs Reactive

**No single chain can see an agent's spending on the others.** A smart-account allowance on Base knows nothing about what the same agent spent on Unichain five seconds ago.

Pocket Money's budget, receipt chain, quarantine and liquidity view live in one Reactive contract, which hears every chain's events and answers with callbacks. **Take Reactive away and there's no cross-chain budget left to enforce.**

**Why Omni's ~1 s blocks matter here:**
- **The float has to cover the delay.** It has to cover whatever the agent can spend while a top-up is still in flight: `float ≥ spend rate × top-up delay`.
- **The delay shrinks with block time.** We measured spend → top-up live: 8–11 Base blocks (~1.6–2.2 s), 2 Unichain blocks (~2 s), and the next block on Ethereum Sepolia.
- **That means less money at risk.** On the previous Reactive (~7 s blocks), the Reactive leg alone would add seconds to every top-up. Shorter blocks let the float be smaller.

## How it fits together

```mermaid
flowchart LR
  subgraph EVM["Base · Unichain · Ethereum Sepolia"]
    A[Agent wallet<br/>USDC float, no ETH] -- x402 / transfer --> S[Payee]
    V[Vault<br/>float cap · mirror · CCTP]
  end
  subgraph Other["Sui · Solana"]
    A2[Agent on Sui / Solana] --> S2[Payee]
  end
  R[Attesters<br/>trusted relay] -->|report| I[SpendInbox<br/>on Base Sepolia]
  A2 -. watched by .-> R
  A -- USDC Transfer event --> G
  I -- ForeignSpend event --> G
  V -- Panic / RaiseApproved / USDC in-out --> G
  G[PocketMoney guard<br/>on Reactive Lasna<br/>budget · receipts · quarantine · liquidity] -- topUp / syncBudget / freeze / rebalance callbacks --> V
  F[x402 facilitator] -- canSpend before settling --> V
```

| Contract | Where | Job |
|---|---|---|
| [`PocketMoney`](src/PocketMoney.sol) | Reactive Lasna | Books every payment on every chain, keeps the household's allowances and ceiling, chains receipts, quarantines, panics, grants raises, tracks vault balances and requests CCTP refills |
| [`Vault`](src/Vault.sol) | each EVM chain | Holds the owner's USDC. Tops up floats (capped locally at the agent's float), mirrors the budget (`canSpend`), freezes, and sends CCTP refills only to owner-approved peers under a cap |
| [`SpendInbox`](src/SpendInbox.sol) | Base Sepolia | Where the Sui and Solana attesters report payments, each one exactly once |

**Off-chain pieces** (no special powers, all in [`agent/`](agent/src)):
- **The x402 seller and the agent's daily job**
- **The CCTP relayer:** anyone may relay.
- **The Sui and Solana attesters**
- **The receipt verifier**

## The loops, live

Every row is on-chain. The tx hashes are in [`deployments/EVIDENCE.md`](deployments/EVIDENCE.md).

| Loop | What happened |
|---|---|
| Spend → top-up | The agent paid over x402 on each of the three chains; each float was refilled (Base, Unichain, Ethereum Sepolia) |
| Refuse before settling | The budget was used up, so the seller refused with `pocket_money_over_budget` on a chain the agent hadn't touched that day. **Nothing moved.** |
| Ask for a raise | The owner approved +$0.30 **on Ethereum Sepolia**; the agent's retry **on Unichain** settled |
| Unknown payee → frozen everywhere | A stray payment on Unichain, on Sui, and on Solana each froze the agent on all three EVM chains |
| Panic | Panic on Ethereum Sepolia froze all three vaults |
| CCTP refill | The Base vault dropped below its floor; the guard had Ethereum Sepolia's vault burn 1.10 USDC; Circle attested in 20 s; the relayer minted on Base |
| Fail safe | An Ethereum Sepolia top-up ran out of gas (that chain's proxy overhead is 150k). Nothing was sent and nothing was corrupted. Fixed with a per-chain callback gas limit |

## Safety: what we prove, and how

See [`SECURITY.md`](SECURITY.md) for the threat model, the trust assumptions, and the full static-analysis triage.

**Unit tests:**
- 43 Foundry unit tests run against a Reactive Network simulator. It matches every emitted log against the guard's real subscriptions, feeds it to `react()`, and delivers the requested callbacks (or delivers each one twice, to prove every callback is safe to repeat).
- The heaviest `react()` uses 193k gas (cap: 900k).

**Invariant fuzzing (8 properties):**
- **What gets fuzzed:** random payments to the shop or a thief, on any chain or on Sui, plus panics, allowance changes, raises, midnight rollovers and CCTP refills.
- **The properties:**
  - no agent ever holds more than its float
  - top-ups stay within the allowance and the ceiling
  - a stolen key's take is bounded by the floats
  - freezes reach every chain
  - the mirror matches the guard
  - the guard's view of vault balances matches the chain
  - USDC is conserved
  - every payment has exactly one receipt
- **Scale:** the deep run used 30,720 random actions per property.
- **It found two real bugs:**
  - one agent's after-midnight spending missing from other agents' mirrors
  - a raise outliving its day

  Both are fixed and kept as regression tests that fail on the old code.

**Static analysis:** Slither, with every finding fixed or explained.

## Check it yourself in 2 minutes

You need [Foundry](https://getfoundry.sh) and Node 20+. No keys.

**Rebuild the receipt chain from the chains where the money actually moved:**
- **EVM payments** are matched to the USDC Transfer in the origin transaction.
- **Sui and Solana payments** are matched to the inbox's record.
- The rebuilt chain is compared with the guard's own receipt head.

```bash
cd agent && npm ci && cd .. && script/verify.sh
```

Tamper test (it must say FAILED):

```bash
TAMPER=1 script/verify.sh
```

Read the mirror on any chain (here, Unichain Sepolia):

```bash
cast call 0x614EB7577B127870F8c2223deE869E9a799e78CC "canSpend(address,uint256)(bool,uint256,bytes32)" 0x7Cd681561d75805156568ccF6D8f1Cf0536da06b 100000 --rpc-url https://sepolia.unichain.org
```

**The dashboard** ([`dashboard/`](dashboard)) is a static page that reads the same chains directly:

```bash
python3 -m http.server 4173 --directory dashboard
```

## Current deployment (testnet)

| | Address |
|---|---|
| Guard · Reactive Lasna | `0x77BE935e39274963E18E32567e980387aAAae6b8` |
| Vault · Base Sepolia | `0xeceCBacAb0429915459E2874100b994E8dC3d222` |
| Vault · Unichain Sepolia | `0x614EB7577B127870F8c2223deE869E9a799e78CC` |
| Vault · Ethereum Sepolia | `0xa7860BF18A0eBd6397d672b45b4e17E47d1D0172` |
| SpendInbox · Base Sepolia | `0xfEf8522B931Ded31aeAe2F8FF5cb6B5e60E1289d` |

Earlier versions were retired on-chain with the vaults' logged `migrate()`, so their history stays visible.

## Run your own

**1. Tools:** Foundry, Node 20+, and `jq`.

**2. Testnet-only keystores:** create one per role with `cast wallet new ~/.foundry/keystores <name>`:
- `pm-owner`
- `pm-agent`
- `pm-seller`
- `pm-agent-sui` (optional)
- `pm-agent-sol` (optional)

**3. Fund them** (see [`deployments/EVIDENCE.md`](deployments/EVIDENCE.md) for which faucets worked):
- a little Base Sepolia ETH
- Ethereum Sepolia ETH, which `script/deploy.sh` swaps for lREACT through Reactive's faucet contract
- Circle test USDC on each chain

**4. Deploy and run:**
- `script/deploy.sh` deploys the guard, the vaults and the inbox, and wires everything up.
- `script/setup-seller.sh` funds the seller and approves it as a payee.
- Demos:
  - `script/x402-demo.sh`: x402 payments on every chain
  - `script/v4-demo.sh`: the mirror refusal and a CCTP refill
  - `script/raise-demo.sh`
  - `script/sui-demo.sh`
  - `script/solana-demo.sh`
  - `script/drill.sh stray|stolen|panic|dry`

**5. Unattended:**
- `script/keychain-setup.sh` stores the agent's and seller's keystore passwords in the macOS Keychain.
- [`deploy/com.uigstudios.pocketmoney.daily.plist`](deploy/com.uigstudios.pocketmoney.daily.plist) runs `script/daily.sh` every morning.

**Testing:**

```bash
forge test
```

Deep fuzzing:

```bash
FOUNDRY_INVARIANT_RUNS=512 FOUNDRY_INVARIANT_DEPTH=60 forge test --mc PocketMoneyInvariants
```

## Why not just a per-chain cap?

**A per-chain cap is a fence around one field.** An agent with a $3 cap on each of three chains has a $9 budget, and no chain can tell when the agent has already spent its $3 elsewhere. Pocket Money keeps **one** budget across every chain (and Sui and Solana), and still keeps a hard local cap on each chain: the float.

**The two layers are independent:**
- **If the guard is wrong,** a vault still never fills the agent past its float.
- **If an agent key is stolen,** the floats are all it can take.

## Limits, stated plainly

- **Root of trust:** the owner key sets limits and payees, and can migrate funds. Keep it on a different device from any agent.
- **Sui and Solana run through a trusted relay.** A false report can only tighten the budget or freeze the agent; silence is bounded by the floats. Sui and Solana have no vault, so payments there are counted and policed but not topped up.
- **Mirror lag:** a vault's mirror updates about one block (of its own chain) after the guard books a payment. That's ~12 s on Ethereum Sepolia. The float bounds that window.
- **Reorgs:** Reactive's docs don't say whether it waits for origin-chain confirmations. A reorged payment could already have been topped up; the float bounds it.
- **Only USDC is guarded.** Other tokens are out of scope.
- **Testnet only.** Not audited.

## Also in this repo

- [`docs/x402-spend-limit-extension.md`](docs/x402-spend-limit-extension.md): a **draft** x402 extension so any facilitator can check a payer's owner-controlled spend limit before settling. Not submitted.
- [`SECURITY.md`](SECURITY.md): threat model, invariants, and static-analysis triage.
- [`deployments/EVIDENCE.md`](deployments/EVIDENCE.md): every live claim, with transaction hashes, including the failures.

## Built during the event

All of Pocket Money's code was written during the buildathon. Prior work enters only as dependencies:
- [`reactive-lib-omni`](https://github.com/Reactive-Network/reactive-lib-omni)
- Coinbase's [`@x402/*`](https://github.com/x402-foundation/x402) packages
- `viem`
- `@mysten/sui`
- `@solana/kit`
- Foundry's `forge-std`

Circle's USDC and CCTP are the on-chain dependencies.

**Live dashboard:** [pocket-money-passbook.netlify.app](https://pocket-money-passbook.netlify.app)

## License

MIT © 2026 Tony Jagodka. See [`LICENSE`](LICENSE).
