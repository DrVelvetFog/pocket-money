/**
 * CCTP relayer for Pocket Money refills. When the guard asks one vault to refill another, the
 * donor burns USDC with Circle CCTP v2 (fast). This watches every vault for RebalanceSent,
 * fetches Circle's attestation, and calls receiveMessage on the destination to mint. It holds no
 * special power: the burn names the destination vault, and anyone may submit the attestation.
 */
import { createPublicClient, createWalletClient, http, parseAbi, parseAbiItem, publicActions } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { NETS, pk } from "./chains.ts";

const IRIS = process.env.IRIS ?? "https://iris-api-sandbox.circle.com";
const MESSAGE_TRANSMITTER = "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275"; // same on every testnet
const DOMAIN: Record<number, number> = { 84532: 6, 1301: 10, 11155111: 0 };
const byDomain = (d: number) => NETS.find((n) => DOMAIN[n.id] === d)!;
const SENT = parseAbiItem("event RebalanceSent(uint32 indexed destDomain, bytes32 indexed destVault, uint256 amount)");
const RECEIVE = parseAbi(["function receiveMessage(bytes message, bytes attestation) returns (bool)"]);

const account = privateKeyToAccount(pk("RELAYER_PK"));
const done = new Set<string>();
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function relay(srcChain: number, burnTx: `0x${string}`) {
  const t0 = Date.now();
  for (let i = 0; i < 120; i++) {
    const r = (await (await fetch(`${IRIS}/v2/messages/${DOMAIN[srcChain]}?transactionHash=${burnTx}`)).json()) as {
      messages?: { status: string; message: `0x${string}`; attestation: `0x${string}`; decodedMessage?: { destinationDomain: string } }[];
    };
    const m = r.messages?.[0];
    if (m?.status === "complete") {
      const dest = byDomain(Number(m.decodedMessage?.destinationDomain));
      const w = createWalletClient({ account, chain: dest.chain, transport: http(dest.rpc) }).extend(publicActions);
      try {
        const hash = await w.writeContract({ address: MESSAGE_TRANSMITTER, abi: RECEIVE, functionName: "receiveMessage", args: [m.message, m.attestation] });
        const rc = await w.waitForTransactionReceipt({ hash });
        console.log(`mint on ${dest.name}: ${hash} (${rc.status}), attested after ${Math.round((Date.now() - t0) / 1000)}s`);
      } catch (e) {
        console.log(`mint on ${dest.name} not sent: ${(e as Error).message.split("\n")[0]}`);
      }
      return;
    }
    await sleep(3000);
  }
  console.log(`no attestation for ${burnTx} after 6 min`);
}

async function main() {
  const vaults = NETS.map((n) => ({ n, vault: process.env[`VAULT_${n.id}`] as `0x${string}` })).filter((v) => v.vault);
  const clients = new Map(vaults.map(({ n }) => [n.id, createPublicClient({ chain: n.chain, transport: http(n.rpc) })]));
  const from = new Map<number, bigint>();
  for (const { n } of vaults) from.set(n.id, (await clients.get(n.id)!.getBlockNumber()) - 50n);
  console.log(`relayer ${account.address} watching ${vaults.map((v) => v.n.name).join(", ")}`);
  for (;;) {
    for (const { n, vault } of vaults) {
      const c = clients.get(n.id)!;
      try {
        const to = await c.getBlockNumber();
        if (from.get(n.id)! > to) continue; // no new blocks yet
        const logs = await c.getLogs({ address: vault, event: SENT, fromBlock: from.get(n.id)!, toBlock: to });
        from.set(n.id, to + 1n);
        for (const l of logs) {
          if (done.has(l.transactionHash!)) continue;
          done.add(l.transactionHash!);
          console.log(`burn on ${n.name}: ${l.transactionHash} -> domain ${l.args.destDomain}, ${l.args.amount} units`);
          void relay(n.id, l.transactionHash!);
        }
      } catch (e) {
        console.log(`${n.name}: ${(e as Error).message.split("\n")[0]}`);
      }
    }
    await sleep(3000);
  }
}

void main();
