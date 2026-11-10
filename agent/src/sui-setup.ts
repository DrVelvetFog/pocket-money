/**
 * Prints the agent's and the shop's Sui testnet addresses (public) and the shop's payee id for
 * the guard, and asks the Sui testnet faucet for gas for the agent.
 */
import { getFaucetHost, requestSuiFromFaucetV2 } from "@mysten/sui/faucet";
import { normalizeSuiAddress } from "@mysten/sui/utils";
import { pk } from "./chains.ts";
import { SUI_USDC, sui, suiKeypair } from "./sui.ts";

const agent = suiKeypair(pk("AGENT_SUI_PK")).toSuiAddress();
const shop = normalizeSuiAddress(suiKeypair(pk("SELLER_PK")).toSuiAddress());
console.log(`AGENT_SUI=${agent}`);
console.log(`SUI_SHOP=${shop}`);

if (process.argv.includes("--faucet")) {
  try {
    await requestSuiFromFaucetV2({ host: getFaucetHost("testnet"), recipient: agent });
    console.log("faucet: requested SUI gas for the agent");
  } catch (e) {
    console.log(`faucet: ${(e as Error).message.split("\n")[0]}`);
  }
}
const [g, u] = await Promise.all([sui.getBalance({ owner: agent, coinType: "0x2::sui::SUI" }), sui.getBalance({ owner: agent, coinType: SUI_USDC })]);
console.log(`agent balances: ${g.balance.balance} MIST SUI, ${u.balance.balance} USDC units`);
