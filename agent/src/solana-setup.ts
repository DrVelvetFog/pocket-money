/** Prints the agent's and the shop's Solana devnet addresses (public) and the shop's payee id. */
import { pk } from "./chains.ts";
import { payeeId, solSigner } from "./solana.ts";

const a = await solSigner(pk("AGENT_SOL_PK"));
const s = await solSigner(pk("SELLER_PK"));
console.log(`AGENT_SOL=${a.address}`);
console.log(`SOL_SHOP=${s.address}`);
console.log(`SOL_SHOP_ID=${payeeId(s.address)}`);
process.exit(0);
