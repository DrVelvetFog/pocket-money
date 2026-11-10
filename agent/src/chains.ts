import { baseSepolia, sepolia, unichainSepolia } from "viem/chains";
import type { Chain } from "viem";

export type Net = { id: number; name: string; chain: Chain; rpc: string; usdc: `0x${string}` };

/** The three testnets Pocket Money guards. Circle USDC addresses from developers.circle.com. */
export const NETS: Net[] = [
  {
    id: 84532,
    name: "Base Sepolia",
    chain: baseSepolia,
    rpc: process.env.BASE_RPC ?? "https://sepolia.base.org",
    usdc: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
  },
  {
    id: 1301,
    name: "Unichain Sepolia",
    chain: unichainSepolia,
    rpc: process.env.UNI_RPC ?? "https://sepolia.unichain.org",
    usdc: "0x31d0220469e10c4E71834a79b1f276d740d3768F",
  },
  {
    id: 11155111,
    name: "Ethereum Sepolia",
    chain: sepolia,
    rpc: process.env.SEPOLIA_RPC ?? "https://ethereum-sepolia-rpc.publicnode.com",
    usdc: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
  },
];

/** Circle's testnet USDC signs EIP-3009 authorizations under this EIP-712 domain on all three. */
export const USDC_DOMAIN = { name: "USDC", version: "2" };

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
