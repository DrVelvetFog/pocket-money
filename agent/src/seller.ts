/**
 * A small paid API the agent buys from every morning: BTC spot price and the gap to a mining
 * breakeven band. It charges per call over x402 and settles its own payments (EIP-3009
 * transferWithAuthorization) on Base, Unichain and Ethereum Sepolia, because the public x402
 * facilitator only covers Base Sepolia. The seller pays settlement gas; the payer holds none.
 */
import express from "express";
import { paymentMiddleware, x402ResourceServer } from "@x402/express";
import { x402Facilitator } from "@x402/core/facilitator";
import { toFacilitatorEvmSigner } from "@x402/evm";
import { ExactEvmScheme as ExactFacilitatorScheme } from "@x402/evm/exact/facilitator";
import { ExactEvmScheme as ExactServerScheme } from "@x402/evm/exact/server";
import { createPublicClient, createWalletClient, hexToString, http, parseAbi, publicActions } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { NETS, USDC_DOMAIN, pk } from "./chains.ts";

const PORT = Number(process.env.PORT ?? 4021);
const PRICE = process.env.PRICE_UNITS ?? "100000"; // $0.10 in USDC's 6 decimals
const BAND_LOW = Number(process.env.BREAKEVEN_LOW ?? 95000);
const BAND_HIGH = Number(process.env.BREAKEVEN_HIGH ?? 102000);

const account = privateKeyToAccount(pk("SELLER_PK"));
const facilitator = new x402Facilitator();
const readers = new Map<number, ReturnType<typeof createPublicClient>>();

for (const n of NETS) {
  readers.set(n.id, createPublicClient({ chain: n.chain, transport: http(n.rpc) }));
  const c = createWalletClient({ account, chain: n.chain, transport: http(n.rpc) }).extend(publicActions);
  const signer = toFacilitatorEvmSigner({
    address: account.address,
    readContract: (a) => c.readContract(a as never),
    verifyTypedData: (a) => c.verifyTypedData(a as never),
    writeContract: (a) => c.writeContract({ ...a, account, chain: n.chain } as never),
    sendTransaction: (a) => c.sendTransaction({ ...a, account, chain: n.chain } as never),
    waitForTransactionReceipt: (a) => c.waitForTransactionReceipt(a as never),
    getCode: (a) => c.getCode(a as never),
  } as never);
  facilitator.register(`eip155:${n.id}`, new ExactFacilitatorScheme(signer));
}

// ---- Pocket Money pre-check: ask this chain's vault before verifying or settling ----
const CAN_SPEND = parseAbi(["function canSpend(address,uint256) view returns (bool,uint256,bytes32)"]);
type Req = { network: string; amount: string };
type Payload = { payload?: { authorization?: { from?: string } } };

/** Returns a refusal reason, or undefined to let the payment through. */
async function pocketMoneyCheck(payload: Payload, req: Req): Promise<string | undefined> {
  const chainId = Number(req.network.split(":")[1]);
  const vault = process.env[`VAULT_${chainId}`] as `0x${string}` | undefined;
  const payer = payload.payload?.authorization?.from as `0x${string}` | undefined;
  if (!vault || !payer) return undefined;
  const [ok, left, why] = await readers.get(chainId)!.readContract({
    address: vault, abi: CAN_SPEND, functionName: "canSpend", args: [payer, BigInt(req.amount)],
  });
  const reason = hexToString(why, { size: 32 }).replace(/\0+$/, "");
  if (ok || reason === "unknown agent") return undefined; // not a household agent: not ours to police
  console.log(`refused ${payer} on ${chainId}: ${reason} (left ${left})`);
  return `pocket_money_${reason.replace(/ /g, "_")}`;
}

const guarded = {
  getSupported: () => facilitator.getSupported(),
  async verify(payload: Payload, req: Req) {
    const why = await pocketMoneyCheck(payload, req);
    if (why) return { isValid: false, invalidReason: why, payer: payload.payload?.authorization?.from };
    return facilitator.verify(payload as never, req as never);
  },
  async settle(payload: Payload, req: Req) {
    const why = await pocketMoneyCheck(payload, req); // re-check: the budget may have moved since verify
    if (why) return { success: false, errorReason: why, transaction: "", network: req.network, payer: payload.payload?.authorization?.from };
    return facilitator.settle(payload as never, req as never);
  },
};

const server = new x402ResourceServer(guarded as never).register("eip155:*", new ExactServerScheme());

const app = express();
app.use(
  paymentMiddleware(
    {
      "GET /btc": {
        accepts: NETS.map((n) => ({
          scheme: "exact",
          network: `eip155:${n.id}`,
          payTo: account.address,
          price: { amount: PRICE, asset: n.usdc, extra: USDC_DOMAIN },
          maxTimeoutSeconds: 300,
        })),
        description: "BTC spot price and the gap to a mining breakeven band",
        mimeType: "application/json",
      },
    } as never,
    server,
  ),
);

app.get("/btc", async (_req, res) => {
  const r = await fetch("https://api.coinbase.com/v2/prices/BTC-USD/spot");
  const usd = Number(((await r.json()) as { data: { amount: string } }).data.amount);
  res.json({
    asOf: new Date().toISOString(),
    btcUsd: usd,
    breakevenBand: [BAND_LOW, BAND_HIGH],
    gapToLow: Math.round(usd - BAND_LOW),
    gapToHigh: Math.round(usd - BAND_HIGH),
    verdict: usd >= BAND_HIGH ? "above band" : usd >= BAND_LOW ? "inside band" : "below band",
  });
});

app.get("/health", (_req, res) => res.json({ ok: true, payTo: account.address, chains: NETS.map((n) => n.id) }));

app.listen(PORT, () => console.log(`seller on http://localhost:${PORT}  payTo ${account.address}`));
