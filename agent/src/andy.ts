/**
 * Andy: a language model that runs an errand under Pocket Money.
 *
 * The model decides what to do; it never sees a key. It has four tools: read its budget, buy the
 * BTC report over x402, ask the owner for a one-day raise, and wait for the answer. A raise request
 * is a message signed by the agent's key. It reaches the owner as a phone alert and a link to the
 * passbook, where the owner's desk verifies the signature and the owner approves it or doesn't.
 *
 *   tsx src/andy.ts ["what to do"]
 * The brain is a local model through Ollama by default (no account, nothing leaves the machine):
 *   ANDY_MODEL=hermes3            any Ollama model that supports tools
 *   ANDY_MODEL=claude             Claude through the Anthropic API (needs ANTHROPIC_API_KEY)
 */
import Anthropic from "@anthropic-ai/sdk";
import { betaTool } from "@anthropic-ai/sdk/helpers/beta/json-schema";
import { createPublicClient, http, parseAbi, hexToString } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { NETS, pk } from "./chains.ts";
import { buyReport } from "./buy.ts";

const account = privateKeyToAccount(pk("AGENT_PK"));
const usd = (units: bigint) => "$" + (Number(units) / 1e6).toFixed(2);
const VAULT_ABI = parseAbi(["function canSpend(address,uint256) view returns (bool,uint256,bytes32)"]);
const USDC_ABI = parseAbi(["function balanceOf(address) view returns (uint256)"]);
// Only the chains this deployment has a vault on.
const chains = NETS.filter((n) => process.env[`VAULT_${n.id}`]).map((n) => ({
  ...n, vault: process.env[`VAULT_${n.id}`] as `0x${string}`, rpcClient: createPublicClient({ chain: n.chain, transport: http(n.rpc) }),
}));
if (!chains.length) throw new Error("no VAULT_<chainId> in the environment (run through script/andy.sh)");
const byName = (name: string) => chains.find((c) => c.name.toLowerCase().startsWith(String(name).toLowerCase().split(" ")[0]));

async function budget() {
  return Promise.all(chains.map(async (c) => {
    const [[ok, left, why], held] = await Promise.all([
      c.rpcClient.readContract({ address: c.vault, abi: VAULT_ABI, functionName: "canSpend", args: [account.address, 1n] }),
      c.rpcClient.readContract({ address: c.usdc, abi: USDC_ABI, functionName: "balanceOf", args: [account.address] }),
    ]);
    return { chain: c.name, left, ok, why: hexToString(why, { size: 32 }), held };
  }));
}

type Tool = {
  name: string; description: string;
  schema: { type: "object"; properties: Record<string, { type: "string" | "number"; description: string }>; required?: string[]; additionalProperties: false };
  run: (args: Record<string, unknown>) => Promise<string>;
};
let asked = false;
const TOOLS: Tool[] = [
  {
    name: "check_budget",
    description: "Read what you may still spend today. The allowance is shared across every chain; the amount in your wallet on each chain is separate and small.",
    schema: { type: "object", properties: {}, additionalProperties: false },
    run: async () => (await budget()).map((b) => `${b.chain}: ${usd(b.left)} left today${b.ok ? "" : ` (blocked: ${b.why})`}, ${usd(b.held)} in the wallet`).join("\n"),
  },
  {
    name: "buy_btc_report",
    description: `Buy today's BTC report from the shop for $0.10, paid on one chain. Returns the report, or the shop's refusal. Chains: ${chains.map((c) => c.name).join(", ")}.`,
    schema: { type: "object", properties: { chain: { type: "string", description: "Which chain to pay on" } }, required: ["chain"], additionalProperties: false },
    run: async (a) => {
      const c = byName(String(a.chain ?? ""));
      if (!c) return `Unknown chain. Use one of: ${chains.map((x) => x.name).join(", ")}.`;
      let r;
      try { r = await buyReport(c.id); }
      catch { return "The shop could not be reached. That is a network problem, not a refusal and not about your budget. Stop and tell your owner."; }
      if (r.ok) return `Paid $0.10 on ${r.chain}. The report: ${JSON.stringify(r.report)}. The errand is done; write your short report for the owner.`;
      // Say what the refusal means and what is allowed next; small models need the next step spelled out.
      if (/over_budget/.test(r.said)) return `The shop refused and took no money: you are over today's allowance. ${asked ? "You already asked for a raise; call wait_for_owner." : "You may now call ask_owner_for_raise once, for the $0.10 this costs, with a one-sentence reason."}`;
      if (/frozen|quarantin/i.test(r.said)) return "The shop refused and took no money: your owner's guard has frozen you. Only the owner can lift that. Stop and say so.";
      return `The shop refused and took no money (${r.status}): ${r.said.slice(0, 200)}. Stop and tell your owner.`;
    },
  },
  {
    name: "ask_owner_for_raise",
    description: "Ask your owner for extra spending for today only. Use it once, and only after a shop refused you for being over budget. Give the smallest amount that covers the errand and one honest sentence saying why.",
    schema: { type: "object", properties: { amount_usd: { type: "number", description: "Dollars, for example 0.3" }, reason: { type: "string", description: "One sentence for the owner" } }, required: ["amount_usd", "reason"], additionalProperties: false },
    run: async (a) => {
      const amount = Number(a.amount_usd), reason = String(a.reason ?? "").replace(/\s+/g, " ").trim().slice(0, 200);
      if (!(amount > 0 && amount <= 5) || !reason) return "Give an amount between 0.01 and 5 dollars and a one-sentence reason.";
      if (asked) return "You already asked once for this errand. Wait for the answer instead.";
      asked = true;
      const units = Math.round(amount * 1e6), at = Math.floor(Date.now() / 1000);
      // Signed by the agent's own key, so the owner's desk can tell it from a forged link.
      const sig = await account.signMessage({ message: raiseMessage(units, at, reason) });
      const link = `${process.env.DASHBOARD_URL ?? "http://localhost:4173"}/?ask=${units}&at=${at}&why=${encodeURIComponent(reason)}&sig=${sig}`;
      const line = `${process.env.AGENT_NAME ?? "Andy"} asks for ${usd(BigInt(units))} more today: ${reason}`;
      console.log(`\n   ${line}\n   Approve or ignore it at the owner's desk:\n   ${link}\n`);
      if (process.env.ALERT_URL) await fetch(process.env.ALERT_URL, { method: "POST", body: line, headers: { Title: "Pocket Money", Click: link, Tags: "raising_hand" } }).catch(() => {});
      return "Your request was sent to the owner. Now call wait_for_owner with 5 minutes to see whether it is approved.";
    },
  },
  {
    name: "wait_for_owner",
    description: "Wait up to a few minutes for the owner to answer a raise request. Returns as soon as your budget goes up, or says there was no answer.",
    schema: { type: "object", properties: { minutes: { type: "number", description: "How long to wait, 1 to 10" } }, required: ["minutes"], additionalProperties: false },
    run: async (a) => {
      const until = Date.now() + Math.min(10, Math.max(1, Number(a.minutes) || 3)) * 60_000;
      const before = (await budget()).reduce((m, b) => (b.left > m ? b.left : m), 0n);
      while (Date.now() < until) {
        await new Promise((r) => setTimeout(r, 4000));
        const now = (await budget()).reduce((m, b) => (b.left > m ? b.left : m), 0n);
        if (now > before) return `Approved. You now have ${usd(now)} left today. Buy the report now.`;
      }
      return "No answer yet. The owner has not approved it. Do not spend, and say so in your report.";
    },
  },
];
/** The exact text the agent signs; the passbook rebuilds it to check the signature. */
export function raiseMessage(units: number, at: number, reason: string) {
  return `Pocket Money raise request\nagent ${account.address.toLowerCase()}\namount ${units}\nat ${at}\nreason ${reason}`;
}

const SYSTEM = `You are ${process.env.AGENT_NAME ?? "Andy"}, an AI agent that runs small errands for your owner and pays for them yourself from a wallet with a daily allowance.

How the money works: your owner set one daily allowance that covers every chain together. Your wallet on each chain holds only a small float, refilled after each payment. A shop checks your allowance before taking payment and refuses if you are over it. You cannot change the allowance; only your owner can.

When a shop refuses you for being over budget, you may ask your owner for a raise for today: once, for the smallest amount that covers the errand, with one honest sentence of reason. Then wait for the answer. If it is approved, finish the errand. If there is no answer, stop without spending and say so. Never try to get around a refusal another way.

Check your budget before you spend. When you are done, report in two or three plain sentences: what you bought and on which chain, what it cost, what the report says, and anything your owner should know.`;

const say = (who: string, text: string) => console.log(`${who.padEnd(6)} ${text.replace(/\n/g, "\n       ")}`);
async function call(name: string, args: Record<string, unknown>) {
  const t = TOOLS.find((x) => x.name === name);
  say("andy →", `${name}${Object.keys(args).length ? " " + JSON.stringify(args) : ""}`);
  const out = t ? await t.run(args).catch((e) => `That failed: ${e.message}`) : `There is no tool called ${name}.`;
  say("     ←", out);
  return out;
}

const task = process.argv[2] ?? "Buy today's BTC report and tell me what it says.";
const model = process.env.ANDY_MODEL ?? "hermes3";
say("owner", task);

if (model.startsWith("claude")) {
  const client = new Anthropic();
  const final = await client.beta.messages.toolRunner({
    model: model === "claude" ? "claude-opus-5-5" : model,
    max_tokens: 16000,
    thinking: { type: "adaptive" },
    output_config: { effort: "medium" },
    // If a safety classifier declines the request, the API retries it on a fallback model in the same call.
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    system: SYSTEM,
    tools: TOOLS.map((t) => betaTool({ name: t.name, description: t.description, inputSchema: t.schema, run: (a) => call(t.name, a as Record<string, unknown>) })),
    messages: [{ role: "user", content: task }],
  });
  if (final.stop_reason === "refusal") say("andy", "(the model declined this request)");
  for (const b of final.content) if (b.type === "text") say("andy", b.text);
} else {
  // A local model through Ollama's chat API. Same tools, same rules; nothing leaves this machine.
  const host = process.env.OLLAMA_HOST ?? "http://localhost:11434";
  const messages: Record<string, unknown>[] = [{ role: "system", content: SYSTEM }, { role: "user", content: task }];
  const tools = TOOLS.map((t) => ({ type: "function", function: { name: t.name, description: t.description, parameters: t.schema } }));
  for (let turn = 0; turn < 12; turn++) {
    const res = await fetch(`${host}/api/chat`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ model, messages, tools, stream: false, options: { temperature: 0 } }) });
    if (!res.ok) throw new Error(`Ollama said ${res.status}: ${await res.text()} (is it running, and is "${model}" pulled?)`);
    const msg = (await res.json()).message as { content?: string; tool_calls?: { function: { name: string; arguments: Record<string, unknown> | string } }[] };
    messages.push(msg);
    if (!msg.tool_calls?.length) { say("andy", (msg.content ?? "").trim() || "(no answer)"); break; }
    for (const tc of msg.tool_calls) {
      const args = typeof tc.function.arguments === "string" ? JSON.parse(tc.function.arguments || "{}") : tc.function.arguments ?? {};
      messages.push({ role: "tool", tool_name: tc.function.name, content: await call(tc.function.name, args) });
    }
  }
}
