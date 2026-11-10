/**
 * Solana attester: lets the guard on Reactive see the agent's spending on Solana, which Reactive
 * can't watch directly. It follows the agent's Solana signatures, reads the net USDC token-balance
 * changes of each transaction (what actually moved, not what was intended), and reports each
 * payment once to the same SpendInbox on Base Sepolia that the Sui attester uses.
 *
 * Trust, stated plainly: a trusted relay. A false report can only tighten the budget or freeze the
 * agent; silence is bounded by the floats. It never moves funds.
 */
import { createWalletClient, http, parseAbi, publicActions, stringToHex, toHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";
import { getBase58Encoder, type Signature } from "@solana/kit";
import { netById, pk } from "./chains.ts";
import { SOL_USDC, payeeId, rpc, solSigner } from "./solana.ts";

const INBOX = process.env.INBOX as `0x${string}`;
const AGENT = process.env.AGENT as `0x${string}`;
const agentSol = (await solSigner(pk("AGENT_SOL_PK"))).address;
const SOURCE = stringToHex("solana:devnet", { size: 32 });
const ABI = parseAbi(["function report(address,bytes32,uint256,bytes32,bytes32)", "function reported(bytes32) view returns (bool)"]);

const w = createWalletClient({ account: privateKeyToAccount(pk("SELLER_PK")), chain: baseSepolia, transport: http(netById(84532).rpc) }).extend(publicActions);
const startedAt = Math.floor(Date.now() / 1000) - 60;
const seen = new Set<string>();
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

type TokenBal = { owner?: string; mint: string; uiTokenAmount: { amount: string } };
const usdcOf = (bals: readonly TokenBal[] | null | undefined, owner: string) =>
  BigInt((bals ?? []).find((b) => b.mint === SOL_USDC && b.owner === owner)?.uiTokenAmount.amount ?? "0");

async function tick() {
  const sigs = await rpc.getSignaturesForAddress(agentSol, { limit: 20 }).send();
  for (const s of [...sigs].reverse()) {
    if (seen.has(s.signature) || s.err || Number(s.blockTime ?? 0) < startedAt) continue;
    seen.add(s.signature);
    const tx = await rpc
      .getTransaction(s.signature as Signature, { maxSupportedTransactionVersion: 0, encoding: "json", commitment: "confirmed" })
      .send();
    const pre = tx?.meta?.preTokenBalances as TokenBal[] | undefined;
    const post = tx?.meta?.postTokenBalances as TokenBal[] | undefined;
    const spent = usdcOf(pre, agentSol) - usdcOf(post, agentSol);
    if (spent <= 0n) continue; // not an outgoing USDC payment
    const owners = new Set((post ?? []).filter((b) => b.mint === SOL_USDC && b.owner && b.owner !== agentSol).map((b) => b.owner!));
    const payee = [...owners].find((o) => usdcOf(post, o) > usdcOf(pre, o));
    if (!payee) continue;
    const ref = toHex(getBase58Encoder().encode(s.signature) as Uint8Array).slice(0, 66) as `0x${string}`; // first 32 bytes
    if (await w.readContract({ address: INBOX, abi: ABI, functionName: "reported", args: [ref] })) continue;
    const hash = await w.writeContract({ address: INBOX, abi: ABI, functionName: "report", args: [AGENT, payeeId(payee), spent, SOURCE, ref] });
    await w.waitForTransactionReceipt({ hash });
    console.log(`reported solana ${s.signature} (${spent} units to ${payee}) -> base ${hash}`);
  }
}

console.log(`attester watching ${agentSol} on Solana devnet -> inbox ${INBOX} as ${w.account.address}`);
for (;;) {
  try {
    await tick();
  } catch (e) {
    console.log(`tick: ${(e as Error).message.split("\n")[0]}`);
  }
  await sleep(4000);
}
