/**
 * One x402 purchase: the BTC report from the seller, paid on one chain.
 * The agent only signs an EIP-3009 authorization; the seller submits it. So the agent never sends
 * a transaction and needs no ETH: the only thing its key can move is its USDC float, and every move
 * shows up as a USDC Transfer that Pocket Money is watching.
 */
import { x402Client, wrapFetchWithPayment, decodePaymentResponseHeader } from "@x402/fetch";
import { ExactEvmScheme } from "@x402/evm/exact/client";
import { privateKeyToAccount } from "viem/accounts";
import { NETS, netById, pk } from "./chains.ts";

export type Purchase =
  | { ok: true; chain: string; agent: string; report: unknown; settlement: unknown }
  | { ok: false; chain: string; status: number; said: string };

export async function buyReport(chainId: number): Promise<Purchase> {
  const net = netById(chainId);
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
  if (!res.ok) return { ok: false, chain: net.name, status: res.status, said: await res.text() };
  const header = res.headers.get("PAYMENT-RESPONSE");
  return { ok: true, chain: net.name, agent: account.address, report: await res.json(), settlement: header ? decodePaymentResponseHeader(header) : undefined };
}
