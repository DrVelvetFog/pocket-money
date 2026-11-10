/**
 * The agent pays in USDC on Sui testnet: to the shop (the seller's Sui identity) or, for the
 * stray-payment drill, to an address nobody approved.
 *   tsx src/sui-pay.ts shop|stray [amountUnits]
 */
import { Transaction, coinWithBalance } from "@mysten/sui/transactions";
import { pk } from "./chains.ts";
import { SUI_USDC, sui, suiKeypair } from "./sui.ts";

const STRAY = "0x000000000000000000000000000000000000000000000000000000000000dead";
const [who = "shop", units = "100000"] = process.argv.slice(2);

const agent = suiKeypair(pk("AGENT_SUI_PK"));
const to = who === "stray" ? STRAY : suiKeypair(pk("SELLER_PK")).toSuiAddress();

const tx = new Transaction();
tx.setSender(agent.toSuiAddress());
tx.transferObjects([coinWithBalance({ type: SUI_USDC, balance: BigInt(units) })], to);

const r = await sui.signAndExecuteTransaction({ signer: agent, transaction: tx, include: { effects: true } });
const res = (r as { Transaction?: { digest: string; effects?: { status?: unknown } }; FailedTransaction?: { digest: string; status?: unknown } });
const digest = res.Transaction?.digest ?? res.FailedTransaction?.digest;
await sui.waitForTransaction({ digest: digest! });
console.log(JSON.stringify({ from: agent.toSuiAddress(), to, units, digest, ok: !!res.Transaction }));
