/**
 * Verify Pocket Money's receipt chain without trusting the guard.
 *
 * For every Spent event the guard emitted on Reactive, this goes back to where the money moved:
 *  - EVM payments: fetch the origin transaction on its chain and find the USDC Transfer from that
 *    agent to that payee for that amount (which also gives the log index the hash commits to);
 *  - Sui / Solana payments: find the attester's ForeignSpend report in the inbox (a trusted relay)
 *    and print the source-chain id so anyone can look it up there.
 * Then it rebuilds receiptHead = keccak256(abi.encode(prev, chainId, txHash, logIndex, agent,
 * payee, amount)) step by step and checks every intermediate head and the guard's current head.
 *
 *   tsx src/verify-receipts.ts        (reads PM, INBOX, VAULT_* from the environment)
 *   TAMPER=1 tsx src/verify-receipts.ts   self-test: forges one unit and must report FAILED
 * Needs no keys. Exit code 0 only if everything matches.
 */
import {
  createPublicClient,
  decodeEventLog,
  defineChain,
  encodeAbiParameters,
  http,
  keccak256,
  pad,
  parseAbi,
  parseAbiItem,
  toHex,
  type Hex,
  type Log,
} from "viem";
import { NETS, netById } from "./chains.ts";

const lasna = defineChain({
  id: 5318007,
  name: "Reactive Lasna",
  nativeCurrency: { name: "lREACT", symbol: "lREACT", decimals: 18 },
  rpcUrls: { default: { http: [process.env.LASNA_RPC ?? "https://lasna-rpc.rnk.dev/"] } },
});
const PM = process.env.PM as Hex;
const INBOX = process.env.INBOX as Hex | undefined;
const SPENT = parseAbiItem(
  "event Spent(address indexed agent, uint256 indexed chainId, bytes32 indexed payee, uint256 amount, uint256 txHash, uint256 receiptIndex, bytes32 receiptHead)",
);
const TRANSFER = parseAbi(["event Transfer(address indexed from, address indexed to, uint256 value)"]);
const GUARD = parseAbi(["function receiptHead() view returns (bytes32)", "function receiptCount() view returns (uint256)"]);

const reactive = createPublicClient({ chain: lasna, transport: http() });
const evm = new Map(NETS.map((n) => [n.id, createPublicClient({ chain: n.chain, transport: http(n.rpc) })]));

async function creationBlock(addr: Hex): Promise<bigint> {
  // Public nodes prune old state ("header not found"), so missing history counts as "not deployed
  // yet" and the search only goes back as far as SEARCH_BACK blocks.
  let hi = await reactive.getBlockNumber();
  const back = BigInt(process.env.SEARCH_BACK ?? 500000);
  let lo = hi > back ? hi - back : 0n;
  const hasCode = async (b: bigint) => {
    try {
      const code = await reactive.getCode({ address: addr, blockNumber: b });
      return !!code && code !== "0x";
    } catch {
      return false;
    }
  };
  while (lo < hi) {
    const mid = (lo + hi) / 2n;
    if (await hasCode(mid)) hi = mid;
    else lo = mid + 1n;
  }
  return lo;
}

async function logsInChunks<T>(get: (from: bigint, to: bigint) => Promise<T[]>, from: bigint, to: bigint, step = 20000n) {
  const out: T[] = [];
  for (let a = from; a <= to; a += step) out.push(...(await get(a, a + step - 1n > to ? to : a + step - 1n)));
  return out;
}

/** EVM payees are stored left-padded to 32 bytes; show them as addresses. */
const showPayee = (p: Hex) => (p.slice(2, 26) === "0".repeat(24) ? `0x${p.slice(26, 32)}…${p.slice(-4)}` : `${p.slice(0, 10)}… (32-byte id)`);

type Check = { index: number; where: string; detail: string; ok: boolean };

async function main() {
  const start = await creationBlock(PM);
  const head = await reactive.getBlockNumber();
  const spent = await logsInChunks((a, b) => reactive.getLogs({ address: PM, event: SPENT, fromBlock: a, toBlock: b }), start, head);
  spent.sort((x, y) => Number(x.args.receiptIndex! - y.args.receiptIndex!));

  // spends on chains Reactive can't watch: the inbox records every ref it accepted
  const INBOX_ABI = parseAbi(["function reported(bytes32) view returns (bool)"]);
  const attested = async (ref: Hex) =>
    !!INBOX && (await evm.get(84532)!.readContract({ address: INBOX, abi: INBOX_ABI, functionName: "reported", args: [ref] }));

  let h: Hex = pad("0x0", { size: 32 });
  const checks: Check[] = [];
  for (const s of spent) {
    const { agent, chainId, payee, txHash, receiptIndex, receiptHead } = s.args as Required<typeof s.args>;
    // TAMPER=1 forges one unit onto the first receipt: the run must then fail (self-test)
    const amount = s.args.amount! + (process.env.TAMPER && receiptIndex === 0n ? 1n : 0n);
    const ref = pad(toHex(txHash), { size: 32 });
    let logIndex = 0n;
    let where = "";
    let ok = false;

    const net = NETS.find((n) => BigInt(n.id) === chainId);
    const evmPayee = ("0x" + payee.slice(26)) as Hex;
    if (net && payee.slice(2, 26) === "0".repeat(24)) {
      // looks like an EVM payment: prove it on the origin chain
      try {
        const rc = await evm.get(net.id)!.getTransactionReceipt({ hash: ref });
        const hit = (rc.logs as Log[]).find((l) => {
          if (l.address.toLowerCase() !== netById(net.id).usdc.toLowerCase()) return false;
          try {
            const e = decodeEventLog({ abi: TRANSFER, data: l.data, topics: l.topics });
            return e.args.from.toLowerCase() === agent.toLowerCase() && e.args.to.toLowerCase() === evmPayee.toLowerCase() && e.args.value === amount;
          } catch {
            return false;
          }
        });
        if (hit) {
          logIndex = BigInt(hit.logIndex!);
          where = `${net.name} tx ${ref.slice(0, 12)}… log ${logIndex}`;
          ok = true;
        }
      } catch {
        /* not an EVM tx on that chain: fall through to the inbox */
      }
    }
    if (!ok) {
      if (await attested(ref)) {
        where = `Sui/Solana payment, attested in the inbox, ref ${ref.slice(0, 12)}…`;
        ok = true;
      } else {
        where = `NOT FOUND: chain ${chainId} ref ${ref}`;
      }
    }

    h = keccak256(
      encodeAbiParameters(
        [{ type: "bytes32" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }, { type: "address" }, { type: "bytes32" }, { type: "uint256" }],
        [h, chainId, txHash, logIndex, agent, payee, amount],
      ),
    );
    const headOk = h === receiptHead;
    checks.push({
      index: Number(receiptIndex),
      where,
      detail: `${amount} units from ${agent.slice(0, 8)}… to ${showPayee(payee)}${headOk ? "" : "  HEAD MISMATCH"}`,
      ok: ok && headOk,
    });
  }

  const [guardHead, guardCount] = await Promise.all([
    reactive.readContract({ address: PM, abi: GUARD, functionName: "receiptHead" }),
    reactive.readContract({ address: PM, abi: GUARD, functionName: "receiptCount" }),
  ]);
  for (const c of checks) console.log(`${c.ok ? "✓" : "✗"} #${c.index}  ${c.where}  ${c.detail}`);
  const allOk = checks.every((c) => c.ok) && h === guardHead && BigInt(checks.length) === guardCount;
  console.log(
    `\n${allOk ? "VERIFIED" : "FAILED"}: ${checks.length} receipts from block ${start}; rebuilt head ${h}\n` +
      `guard says ${guardCount} receipts, head ${guardHead}`,
  );
  process.exit(allOk ? 0 : 1);
}

void main();
