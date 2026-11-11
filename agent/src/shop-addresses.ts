/** Prints the (public) addresses the seller key stands for: the EVM seller, and the Sui and Solana shops. */
import { normalizeSuiAddress } from "@mysten/sui/utils";
import { privateKeyToAccount } from "viem/accounts";
import { pk } from "./chains.ts";
import { payeeId, solSigner } from "./solana.ts";
import { suiKeypair } from "./sui.ts";

const key = pk("SELLER_PK");
const sol = await solSigner(key);
console.log(`SELLER=${privateKeyToAccount(key).address}`);
console.log(`SUI_SHOP=${normalizeSuiAddress(suiKeypair(key).toSuiAddress())}`);
console.log(`SOL_SHOP=${sol.address}`);
console.log(`SOL_SHOP_ID=${payeeId(sol.address)}`);
process.exit(0);
