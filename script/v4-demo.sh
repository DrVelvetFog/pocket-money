#!/usr/bin/env bash
# Prove the three stretch features live:
#   1. budget mirror: a budget set on Reactive shows up on every chain; the x402 seller refuses an
#      over-budget payment BEFORE settling (no money moves)
#   3. liquidity: a vault that runs low is refilled from the fullest sibling over Circle CCTP
# (2, Sui, has its own script.) Asks for pm-seller, pm-agent and pm-owner passwords once each.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source deployments/testnet.env; source deployments/wallets.env; set +a
LASNA=https://lasna-rpc.rnk.dev/
rpc() { case $1 in 84532) echo ${BASE_RPC:-https://sepolia.base.org};;
                  1301) echo ${UNI_RPC:-https://sepolia.unichain.org};;
                  11155111) echo ${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com};; esac; }
usdc() { case $1 in 84532) echo 0x036CbD53842c5426634e7929541eC2318f3dCF7e;;
                   1301) echo 0x31d0220469e10c4E71834a79b1f276d740d3768F;;
                   11155111) echo 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;; esac; }
PORT=${PORT:-4021}
SMALL=${SMALL:-300000}   # $0.30 for the demo
NORMAL=${NORMAL:-3000000}

key() {
  local p k
  read -rs -p "$2 keystore password: " p </dev/tty; echo >&2
  k=$(CAST_UNSAFE_PASSWORD="$p" cast wallet decrypt-keystore "$1" 2>/dev/null | grep -oE '0x[0-9a-fA-F]{64}' || true)
  [[ -n "$k" ]] || { echo "could not decrypt $1 (wrong password?)" >&2; exit 1; }
  printf '%s' "$k"
}
SELLER_PK=$(key pm-seller pm-seller); export SELLER_PK
AGENT_PK=$(key pm-agent pm-agent); export AGENT_PK
export RELAYER_PK=$SELLER_PK
d=$(mktemp -d); chmod 700 "$d"
read -rs -p "pm-owner keystore password: " p </dev/tty; echo; printf '%s' "$p" > "$d/o"; unset p; chmod 600 "$d/o"
owner() { for i in 1 2 3 4; do out=$(cast send "$@" --account pm-owner --password-file "$d/o" --json 2>&1) &&
  { echo "   owner tx $(jq -r .transactionHash <<<"$out")"; return 0; }; sleep 4; done; echo "$out" >&2; return 1; }

(cd agent && PORT=$PORT npx tsx src/seller.ts >../deployments/seller.log 2>&1) &
(cd agent && npx tsx src/relayer.ts >../deployments/relayer.log 2>&1) &
trap 'rm -rf "$d"; pkill -f "tsx src/seller.ts" 2>/dev/null; pkill -f "tsx src/relayer.ts" 2>/dev/null; true' EXIT
for _ in $(seq 1 30); do curl -sf localhost:$PORT/health >/dev/null && break; sleep 1; done
echo "seller and relayer up"

wait_log() { # wait_log <rpc> <from> <address> <sig> [secs] -> "tx block"
  local i out
  for ((i = 0; i < ${5:-120}; i++)); do
    out=$(cast logs --from-block $2 --address $3 "$4" --rpc-url $1 --json 2>/dev/null || echo '[]')
    [[ $(jq length <<<"$out") -gt 0 ]] && { jq -r '.[-1] | "\(.transactionHash) \(.blockNumber)"' <<<"$out"; return; }
    sleep 1
  done
  echo "none -"
}
left() { cast call $(eval echo \$VAULT_$1) "canSpend(address,uint256)(bool,uint256,bytes32)" $AGENT 100000 --rpc-url $(rpc $1) | sed -n 2p | cut -d' ' -f1; }
buy() { (cd agent && SELLER_URL=http://localhost:$PORT npx tsx src/agent.ts $1 2>&1) || true; }

echo; echo "================ 1. budget set on Reactive shows up on every chain ================"
owner $PM "setAgent(address,uint256)" $AGENT $SMALL --rpc-url $LASNA
for _ in $(seq 1 90); do [[ $(left 1301) == $SMALL ]] && break; sleep 2; done
for c in 84532 1301 11155111; do echo "   mirror on $c says the agent has $(left $c) left"; done

echo; echo "================ 2. three purchases on Base Sepolia; the last drains the Base vault below \$3 ================"
lf=$(cast block-number --rpc-url $LASNA); ef=$(cast block-number --rpc-url $(rpc 11155111)); bf=$(cast block-number --rpc-url $(rpc 84532))
for i in 1 2 3; do
  out=$(buy 84532)
  echo "   buy $i: settled $(jq -r '.settlement.transaction // "?"' <<<"$out" 2>/dev/null || echo "$out" | tail -1)"
  sleep 8
done
echo "   Base vault now $(cast call $(usdc 84532) 'balanceOf(address)(uint256)' $VAULT_84532 --rpc-url $(rpc 84532) | cut -d' ' -f1)"
read -r tx _ <<<"$(wait_log $LASNA $lf $PM 'RebalanceRequested(uint256 indexed,uint256 indexed,uint256)' 180)"
echo "   guard asked for a refill:      $tx (Lasna)"
read -r tx _ <<<"$(wait_log $(rpc 11155111) $ef $VAULT_11155111 'RebalanceSent(uint32 indexed,bytes32 indexed,uint256)' 180)"
echo "   Ethereum Sepolia vault burned: $tx"
read -r tx _ <<<"$(wait_log $LASNA $lf $PM 'RebalanceLanded(uint256 indexed,uint256)' 400)"
echo "   guard saw the mint land:       $tx (Lasna)"
grep -E '^mint' deployments/relayer.log | tail -1 | sed 's/^/   relayer: /'
echo "   Base vault now $(cast call $(usdc 84532) 'balanceOf(address)(uint256)' $VAULT_84532 --rpc-url $(rpc 84532) | cut -d' ' -f1)"

echo; echo "================ 3. a 4th purchase, on Unichain: over budget, refused before settling ================"
for _ in $(seq 1 60); do [[ $(left 1301) == 0 ]] && break; sleep 2; done
echo "   mirror on Unichain says $(left 1301) left"
before=$(cast call $(usdc 1301) 'balanceOf(address)(uint256)' $AGENT --rpc-url $(rpc 1301) | cut -d' ' -f1)
buy 1301 | tail -1 | sed 's/^/   agent: /'
grep -E '^refused' deployments/seller.log | tail -1 | sed 's/^/   seller: /'
echo "   agent USDC on Unichain: $before -> $(cast call $(usdc 1301) 'balanceOf(address)(uint256)' $AGENT --rpc-url $(rpc 1301) | cut -d' ' -f1)  (unchanged = nothing moved)"

echo; echo "================ reset: back to the normal allowance ================"
owner $PM "setAgent(address,uint256)" $AGENT $NORMAL --rpc-url $LASNA
