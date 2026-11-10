/**
 * The agent pays in USDC on Solana devnet: to the shop (the seller's Solana identity) or, for the
 * stray-payment drill, to an address nobody approved.
 *   tsx src/solana-pay.ts shop|stray [amountUnits]
 */
import {
  address,
  appendTransactionMessageInstructions,
  createTransactionMessage,
  getSignatureFromTransaction,
  pipe,
  sendAndConfirmTransactionFactory,
  setTransactionMessageFeePayerSigner,
  setTransactionMessageLifetimeUsingBlockhash,
  signTransactionMessageWithSigners,
} from "@solana/kit";
import {
  TOKEN_PROGRAM_ADDRESS,
  findAssociatedTokenPda,
  getCreateAssociatedTokenIdempotentInstructionAsync,
  getTransferCheckedInstruction,
} from "@solana-program/token";
import { pk } from "./chains.ts";
import { SOL_USDC, rpc, rpcSubscriptions, solSigner } from "./solana.ts";

const STRAY = address("11111111111111111111111111111112"); // nobody's shop
const [who = "shop", units = "100000"] = process.argv.slice(2);

const agent = await solSigner(pk("AGENT_SOL_PK"));
const to = who === "stray" ? STRAY : (await solSigner(pk("SELLER_PK"))).address;
const [from] = await findAssociatedTokenPda({ owner: agent.address, mint: SOL_USDC, tokenProgram: TOKEN_PROGRAM_ADDRESS });
const [dest] = await findAssociatedTokenPda({ owner: to, mint: SOL_USDC, tokenProgram: TOKEN_PROGRAM_ADDRESS });

const { value: blockhash } = await rpc.getLatestBlockhash().send();
const message = pipe(
  createTransactionMessage({ version: 0 }),
  (m) => setTransactionMessageFeePayerSigner(agent, m),
  (m) => setTransactionMessageLifetimeUsingBlockhash(blockhash, m),
  async (m) =>
    appendTransactionMessageInstructions(
      [
        await getCreateAssociatedTokenIdempotentInstructionAsync({ payer: agent, owner: to, mint: SOL_USDC }),
        getTransferCheckedInstruction({ source: from, mint: SOL_USDC, destination: dest, authority: agent, amount: BigInt(units), decimals: 6 }),
      ],
      m,
    ),
);
const signed = await signTransactionMessageWithSigners(await message);
await sendAndConfirmTransactionFactory({ rpc, rpcSubscriptions })(signed as never, { commitment: "confirmed" });
console.log(JSON.stringify({ from: agent.address, to, units, signature: getSignatureFromTransaction(signed) }));
process.exit(0);
