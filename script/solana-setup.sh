#!/usr/bin/env bash
# One-time Solana setup: show the agent's and the shop's Solana devnet addresses, save them
# (public), and approve the shop as a payee on the guard.
# Run after `cast wallet new ~/.foundry/keystores pm-agent-sol`.
set -euo pipefail
cd "$(dirname "$0")/.."
source script/lib.sh
set -a; source deployments/testnet.env; source deployments/wallets.env; set +a

AGENT_SOL_PK=$(key pm-agent-sol); export AGENT_SOL_PK
SELLER_PK=$(key pm-seller); export SELLER_PK
out=$(cd agent && npx tsx src/solana-setup.ts)
echo "$out"
for k in AGENT_SOL SOL_SHOP SOL_SHOP_ID; do
  v=$(grep "^$k=" <<<"$out" | cut -d= -f2); grep -q "^$k=" deployments/wallets.env || echo "$k=$v" >> deployments/wallets.env
done
source deployments/wallets.env

owner_init; trap 'rm -rf "$OWNER_PW_DIR"' EXIT
echo "== approve the Solana shop as a payee on the guard"
owner $PM "setForeignPayee(bytes32,bool)" $SOL_SHOP_ID true --rpc-url $LASNA
echo
echo "Next: devnet SOL for fees (faucet.solana.com) and devnet USDC (faucet.circle.com, Solana Devnet) -> $AGENT_SOL"
