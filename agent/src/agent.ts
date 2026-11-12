/**
 * The agent's daily job: buy the morning BTC report over x402 on one chain (see buy.ts).
 *   tsx src/agent.ts [chainId]   (84532 Base Sepolia, 1301 Unichain Sepolia, 11155111 Ethereum Sepolia)
 */
import { buyReport } from "./buy.ts";

const r = await buyReport(Number(process.argv[2] ?? 84532));
if (!r.ok) {
  console.error(`seller said ${r.status}: ${r.said}`);
  process.exit(1);
}
console.log(JSON.stringify({ chain: r.chain, agent: r.agent, report: r.report, settlement: r.settlement }, null, 2));
