import { SuiGraphQLClient } from "@mysten/sui/graphql";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { hexToBytes } from "viem";

/** Circle USDC on Sui testnet (developers.circle.com). */
export const SUI_USDC = "0xa1ec7fc00a6f40db9693ad1415d0c193ad3906494428cf252621037bd7117e29::usdc::USDC";

/** Public fullnodes retired JSON-RPC, so everything goes through Sui GraphQL. */
export const SUI_GRAPHQL = process.env.SUI_GRAPHQL ?? "https://graphql.testnet.sui.io/graphql";
export const sui = new SuiGraphQLClient({ url: SUI_GRAPHQL, network: "testnet" });

/**
 * A Sui Ed25519 identity from a 32-byte secret kept in an encrypted Foundry keystore.
 * Testnet only: the seller's Sui "shop" address is derived from the seller's secret so it is the
 * same shop on every chain.
 */
export function suiKeypair(hex: `0x${string}`): Ed25519Keypair {
  return Ed25519Keypair.fromSecretKey(hexToBytes(hex));
}

export type SuiSpend = {
  digest: string;
  status: string;
  timestamp: string;
  changes: { owner: string | null; amount: string; coinType: string }[];
};

/** The latest transactions an address sent, with what actually moved. */
export async function sentBy(address: string, last = 20): Promise<SuiSpend[]> {
  const r = await sui.query({
    query: `query($a: SuiAddress!, $n: Int) { transactions(filter: { sentAddress: $a }, last: $n) { nodes {
      digest effects { status timestamp balanceChanges { nodes { owner { address } amount coinType { repr } } } } } } }`,
    variables: { a: address, n: last },
  });
  if (r.errors?.length) throw new Error(r.errors.map((e) => e.message).join("; "));
  type Node = {
    digest: string;
    effects: { status: string; timestamp: string; balanceChanges: { nodes: { owner: { address: string } | null; amount: string; coinType: { repr: string } }[] } };
  };
  const nodes = ((r.data as { transactions: { nodes: Node[] } }).transactions.nodes) ?? [];
  return nodes.map((n) => ({
    digest: n.digest,
    status: n.effects.status,
    timestamp: n.effects.timestamp,
    changes: n.effects.balanceChanges.nodes.map((c) => ({ owner: c.owner?.address ?? null, amount: c.amount, coinType: c.coinType.repr })),
  }));
}
