#!/usr/bin/env bash
# The agent's daily job, end to end, on each chain:
#   agent buys the BTC report over x402 (signs only, holds no ETH)
#   -> seller settles the USDC on that chain (origin tx, sent by the SELLER)
#   -> Pocket Money books it on Reactive -> the vault tops the agent back up.
# Asks for the pm-seller and pm-agent keystore passwords once each. Keys are decrypted into this
# process's environment only and never printed.
#   script/x402-demo.sh [chain ...]     default: all three
set -euo pipefail
cd "$(dirname "$0")/.."
source deployments/testnet.env
source deployments/wallets.env
LASNA=https://lasna-rpc.rnk.dev/
rpc() { case $1 in 84532) echo ${BASE_RPC:-https://sepolia.base.org};;
                  1301) echo ${UNI_RPC:-https://sepolia.unichain.org};;
                  11155111) echo ${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com};; esac; }
usdc() { case $1 in 84532) echo 0x036CbD53842c5426634e7929541eC2318f3dCF7e;;
                   1301) echo 0x31d0220469e10c4E71834a79b1f276d740d3768F;;
                   11155111) echo 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;; esac; }
CHAINS=("${@:-84532 1301 11155111}"); CHAINS=(${CHAINS[*]})
PORT=${PORT:-4021}

key() { # key <keystore name> <prompt>  -> private key on stdout (captured, never shown)
  local p k
  read -rs -p "$2 keystore password: " p </dev/tty; echo >&2
  k=$(CAST_UNSAFE_PASSWORD="$p" cast wallet decrypt-keystore "$1" 2>/dev/null | grep -oE '0x[0-9a-fA-F]{64}' || true)
  [[ -n "$k" ]] || { echo "could not decrypt $1 (wrong password?)" >&2; exit 1; }
  printf '%s' "$k"
}
export SELLER_PK=$(key pm-seller pm-seller)
export AGENT_PK=$(key pm-agent pm-agent)

(cd agent && PORT=$PORT npx tsx src/seller.ts >../deployments/seller.log 2>&1) &
SELLER_JOB=$!
trap 'kill $SELLER_JOB 2>/dev/null; pkill -f "tsx src/seller.ts" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -sf localhost:$PORT/health >/dev/null && break; sleep 1; done
echo "seller up: $(curl -s localhost:$PORT/health)"

wait_log() { # wait_log <rpc> <from> <address> <sig> -> "tx block"
  local i out
  for ((i = 0; i < 120; i++)); do
    out=$(cast logs --from-block $2 --address $3 "$4" --rpc-url $1 --json 2>/dev/null || echo '[]')
    [[ $(jq length <<<"$out") -gt 0 ]] && { jq -r '.[-1] | "\(.transactionHash) \(.blockNumber)"' <<<"$out"; return; }
    sleep 1
  done
  echo "none -"
}

for c in "${CHAINS[@]}"; do
  V=$(eval echo \$VAULT_$c); R=$(rpc $c)
  lf=$(cast block-number --rpc-url $LASNA); cf=$(cast block-number --rpc-url $R)
  agent_nonce=$(cast nonce $AGENT --rpc-url $R)
  echo; echo "================ chain $c ================"
  out=$(cd agent && SELLER_URL=http://localhost:$PORT npx tsx src/agent.ts $c)
  jq '{chain, report: .report | {btcUsd, verdict, gapToLow, gapToHigh}, settlement: .settlement | {success, transaction, payer}}' <<<"$out"
  st=$(jq -r .settlement.transaction <<<"$out")
  from=$(cast tx $st from --rpc-url $R)
  echo "origin    $st  (sent by $from — the seller, not the agent)"
  echo "agent nonce before/after: $agent_nonce/$(cast nonce $AGENT --rpc-url $R)  (unchanged = agent sent nothing)"
  read -r tx _ <<<"$(wait_log $LASNA $lf $PM 'Spent(address indexed,uint256 indexed,address indexed,uint256,uint256,uint256,bytes32)')"
  echo "reactive  $tx  (Lasna)"
  read -r tx b <<<"$(wait_log $R $cf $V 'TopUp(address indexed,uint64 indexed,uint256,uint256,uint256)')"
  echo "callback  $tx  block $( [[ $b == - ]] && echo - || cast to-dec $b)"
  echo "agent USDC now: $(cast call $(usdc $c) 'balanceOf(address)(uint256)' $AGENT --rpc-url $R)"
done
