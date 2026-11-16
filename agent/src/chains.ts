import { base, baseSepolia, sepolia, unichain, unichainSepolia } from "viem/chains";
import type { Chain } from "viem";

export type Net = { id: number; name: string; chain: Chain; rpc: string; usdc: `0x${string}`; usdcName: string };

/** The three testnets Pocket Money guards. Circle USDC addresses from developers.circle.com. */
const TESTNETS: Net[] = [
  {
    id: 84532,
    name: "Base Sepolia",
    chain: baseSepolia,
    rpc: process.env.BASE_RPC ?? "https://sepolia.base.org",
    usdc: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
    usdcName: "USDC",
  },
  {
    id: 1301,
    name: "Unichain Sepolia",
    chain: unichainSepolia,
    rpc: process.env.UNI_RPC ?? "https://sepolia.unichain.org",
    usdc: "0x31d0220469e10c4E71834a79b1f276d740d3768F",
    usdcName: "USDC",
  },
  {
    id: 11155111,
    name: "Ethereum Sepolia",
    chain: sepolia,
    rpc: process.env.SEPOLIA_RPC ?? "https://ethereum-sepolia-rpc.publicnode.com",
    usdc: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
    usdcName: "USDC",
  },
];

/**
 * NETWORK=mainnet: the same two low-fee chains with real USDC. Reactive supports both as origin and
 * destination. Ethereum is left out: a top-up there costs more than the purchase it follows.
 */
const MAINNETS: Net[] = [
  {
    id: 8453,
    name: "Base",
    chain: base,
    rpc: process.env.BASE_RPC ?? "https://mainnet.base.org",
    usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    usdcName: "USD Coin",
  },
  {
    id: 130,
    name: "Unichain",
    chain: unichain,
    rpc: process.env.UNI_RPC ?? "https://mainnet.unichain.org",
    usdc: "0x078D782b760474a361dDA0AF3839290b0EF57AD6",
    usdcName: "USDC",
  },
];

export const NETS: Net[] = process.env.NETWORK === "mainnet" ? MAINNETS : TESTNETS;

/**
 * The EIP-712 domain USDC signs EIP-3009 authorizations under. The name is whatever the token's
 * name() returns, and it differs by chain: "USDC" on the testnets and Unichain, "USD Coin" on Base.
 * A payment signed under the wrong name is rejected by the token.
 */
export const usdcDomain = (n: Net) => ({ name: n.usdcName, version: "2" });

export function netById(id: number): Net {
  const n = NETS.find((x) => x.id === id);
  if (!n) throw new Error(`unknown chain ${id}; use one of ${NETS.map((x) => x.id).join(", ")}`);
  return n;
}

export function pk(name: string): `0x${string}` {
  const v = process.env[name];
  if (!v || !/^0x[0-9a-fA-F]{64}$/.test(v)) throw new Error(`${name} is not set (run through script/*.sh)`);
  return v as `0x${string}`;
}
