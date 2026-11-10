import {
  address,
  createKeyPairSignerFromPrivateKeyBytes,
  createSolanaRpc,
  createSolanaRpcSubscriptions,
  getAddressEncoder,
  type KeyPairSigner,
} from "@solana/kit";
import { hexToBytes, toHex } from "viem";

/** Circle USDC on Solana devnet (developers.circle.com). 6 decimals, like everywhere else. */
export const SOL_USDC = address("4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU");
export const SOL_RPC = process.env.SOLANA_RPC ?? "https://api.devnet.solana.com";
export const SOL_WS = process.env.SOLANA_WS ?? "wss://api.devnet.solana.com";

export const rpc = createSolanaRpc(SOL_RPC);
export const rpcSubscriptions = createSolanaRpcSubscriptions(SOL_WS);

/**
 * A Solana Ed25519 identity from a 32-byte secret kept in an encrypted Foundry keystore.
 * Testnet only: the shop is the seller's Solana identity so it is the same shop on every chain.
 */
export function solSigner(hex: `0x${string}`): Promise<KeyPairSigner> {
  return createKeyPairSignerFromPrivateKeyBytes(hexToBytes(hex));
}

/** A Solana address as the guard's 32-byte payee id. */
export function payeeId(addr: string): `0x${string}` {
  return toHex(getAddressEncoder().encode(address(addr)) as Uint8Array);
}
