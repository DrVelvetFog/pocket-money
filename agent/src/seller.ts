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
import { createWalletClient, http, publicActions } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { NETS, USDC_DOMAIN, pk } from "./chains.ts";

const PORT = Number(process.env.PORT ?? 4021);
const PRICE = process.env.PRICE_UNITS ?? "100000"; // $0.10 in USDC's 6 decimals
const BAND_LOW = Number(process.env.BREAKEVEN_LOW ?? 95000);
const BAND_HIGH = Number(process.env.BREAKEVEN_HIGH ?? 102000);

const account = privateKeyToAccount(pk("SELLER_PK"));
const facilitator = new x402Facilitator();

for (const n of NETS) {
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

const server = new x402ResourceServer(facilitator as never).register("eip155:*", new ExactServerScheme());

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
