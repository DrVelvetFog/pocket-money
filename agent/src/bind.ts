/**
 * The agent's one-time consent to a controller, per chain: an EIP-712 `Bind(payer, controller)`
 * signature for that chain's SpendLimitRegistry. The controller submits it (bindWithSig), so the
 * agent still sends no transaction. Prints the signature only.
 *   tsx src/bind.ts <chainId> <registry> <controller>
 */
import { privateKeyToAccount } from "viem/accounts";
import { netById, pk } from "./chains.ts";

const [chain, registry, controller] = process.argv.slice(2);
if (!chain || !registry || !controller) throw new Error("usage: bind.ts <chainId> <registry> <controller>");
const account = privateKeyToAccount(pk("AGENT_PK"));
const sig = await account.signTypedData({
  domain: { name: "SpendLimitRegistry", version: "1", chainId: netById(Number(chain)).id, verifyingContract: registry as `0x${string}` },
  types: { Bind: [{ name: "payer", type: "address" }, { name: "controller", type: "address" }] },
  primaryType: "Bind",
  message: { payer: account.address, controller: controller as `0x${string}` },
});
console.log(sig);
