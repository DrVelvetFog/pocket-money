/**
 * Sui attester: lets the guard on Reactive see the agent's spending on Sui, which Reactive can't
 * watch directly. It follows the agent's Sui transactions, reads the net USDC balance changes
 * (what actually moved, not what was intended), and reports each payment once to the SpendInbox
 * on Base Sepolia. The guard books it against the same budget; an unapproved payee freezes the
 * agent on every EVM chain.
 *
 * Trust, stated plainly: this process is a trusted relay. A false report can only tighten the
 * budget or freeze the agent; silence is bounded by the floats. It never moves funds.
 */
import { createWalletClient, http, parseAbi, publicActions, stringToHex, toHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";
import { fromBase58, normalizeStructTag, normalizeSuiAddress } from "@mysten/sui/utils";
import { netById, pk } from "./chains.ts";
import { SUI_USDC, sentBy, suiKeypair } from "./sui.ts";

const INBOX = process.env.INBOX as `0x${string}`;
const AGENT = process.env.AGENT as `0x${string}`; // the agent's EVM identity in the household
const agentSui = normalizeSuiAddress(suiKeypair(pk("AGENT_SUI_PK")).toSuiAddress());
const SOURCE = stringToHex("sui:testnet", { size: 32 });
const ABI = parseAbi(["function report(address,bytes32,uint256,bytes32,bytes32)", "function reported(bytes32) view returns (bool)"]);

const base = netById(84532);
const w = createWalletClient({ account: privateKeyToAccount(pk("SELLER_PK")), chain: baseSepolia, transport: http(base.rpc) }).extend(publicActions);
const startedAt = Date.now() - 60_000;
const seen = new Set<string>();
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function tick() {
  for (const t of (await sentBy(agentSui)).reverse()) {
    if (seen.has(t.digest) || Date.parse(t.timestamp) < startedAt || t.status !== "SUCCESS") continue;
    seen.add(t.digest);
    // what actually moved: the agent's USDC went down, someone else's went up
    const usdc = t.changes.filter((c) => normalizeStructTag(c.coinType) === normalizeStructTag(SUI_USDC));
    const out = usdc.find((c) => c.owner === agentSui && BigInt(c.amount) < 0n);
    const into = usdc.find((c) => c.owner && c.owner !== agentSui && BigInt(c.amount) > 0n);
    if (!out || !into) continue; // not a USDC payment
    const amount = -BigInt(out.amount);
    const payee = normalizeSuiAddress(into.owner!) as `0x${string}`;
    const ref = toHex(fromBase58(t.digest));
    if (await w.readContract({ address: INBOX, abi: ABI, functionName: "reported", args: [ref] })) continue;
    const hash = await w.writeContract({ address: INBOX, abi: ABI, functionName: "report", args: [AGENT, payee, amount, SOURCE, ref] });
    await w.waitForTransactionReceipt({ hash });
    console.log(`reported sui ${t.digest} (${amount} units to ${payee}) -> base ${hash}`);
  }
}

console.log(`attester watching ${agentSui} on Sui testnet -> inbox ${INBOX} as ${w.account.address}`);
for (;;) {
  try {
    await tick();
  } catch (e) {
    console.log(`tick: ${(e as Error).message.split("\n")[0]}`);
  }
  await sleep(3000);
}
