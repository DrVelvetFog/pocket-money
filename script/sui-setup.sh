#!/usr/bin/env bash
# One-time Sui setup: show the agent's and the shop's Sui testnet addresses, ask the Sui faucet for
# gas, save the (public) addresses, and approve the shop as a payee on the guard.
# Run after `cast wallet new ~/.foundry/keystores pm-agent-sui`.
set -euo pipefail
cd "$(dirname "$0")/.."
source script/lib.sh
set -a; source deployments/testnet.env; source deployments/wallets.env; set +a

export AGENT_SUI_PK=$(key pm-agent-sui)
export SELLER_PK=$(key pm-seller)
out=$(cd agent && npx tsx src/sui-setup.ts --faucet)
echo "$out"
AGENT_SUI=$(grep '^AGENT_SUI=' <<<"$out" | cut -d= -f2); SUI_SHOP=$(grep '^SUI_SHOP=' <<<"$out" | cut -d= -f2)
grep -q '^AGENT_SUI=' deployments/wallets.env || echo "AGENT_SUI=$AGENT_SUI" >> deployments/wallets.env
grep -q '^SUI_SHOP=' deployments/wallets.env || echo "SUI_SHOP=$SUI_SHOP" >> deployments/wallets.env

owner_init; trap 'rm -rf "$OWNER_PW_DIR"' EXIT
echo "== approve the Sui shop as a payee on the guard"
owner $PM "setForeignPayee(bytes32,bool)" $SUI_SHOP true --rpc-url $LASNA
echo
echo "Next: get Sui testnet USDC for the agent at faucet.circle.com (network: Sui Testnet) -> $AGENT_SUI"
