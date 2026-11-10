/**
 * The agent's daily job: buy the morning BTC report over x402 on one chain.
 * It only signs an EIP-3009 authorization; the seller submits it. So the agent never sends a
 * transaction and needs no ETH: the only thing it can move is its USDC float, and every move
 * shows up as a USDC Transfer that Pocket Money is watching.
 *   tsx src/agent.ts [chainId]   (84532 Base Sepolia, 1301 Unichain Sepolia, 11155111 Ethereum Sepolia)
 */
import { x402Client, wrapFetchWithPayment, decodePaymentResponseHeader } from "@x402/fetch";
import { ExactEvmScheme } from "@x402/evm/exact/client";
import { privateKeyToAccount } from "viem/accounts";
import { NETS, netById, pk } from "./chains.ts";

const net = netById(Number(process.argv[2] ?? 84532));
const url = `${process.env.SELLER_URL ?? "http://localhost:4021"}/btc`;
const account = privateKeyToAccount(pk("AGENT_PK"));

const client = new x402Client((_v, reqs) => {
  const pick = reqs.find((r) => r.network === `eip155:${net.id}`);
  if (!pick) throw new Error(`seller doesn't accept ${net.name}`);
  return pick;
})
  .register("eip155:*", new ExactEvmScheme(account))
  // x402's own client-side cap: only Circle USDC on our three chains, at most $0.25 a payment.
  // It lives in this process, so a stolen key skips it; Pocket Money's limits live on-chain.
  .setSpendControls({
    allowedAssets: NETS.map((n) => ({ network: `eip155:${n.id}`, asset: n.usdc, maxAmountPerPayment: "250000" })),
  });

const res = await wrapFetchWithPayment(fetch, client)(url);
if (!res.ok) {
  console.error(`seller said ${res.status}: ${await res.text()}`);
  process.exit(1);
}
const report = await res.json();
const header = res.headers.get("PAYMENT-RESPONSE");
const settle = header ? decodePaymentResponseHeader(header) : undefined;
console.log(JSON.stringify({ chain: net.name, agent: account.address, report, settlement: settle }, null, 2));
