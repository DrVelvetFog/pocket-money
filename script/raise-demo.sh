#!/usr/bin/env bash
# "Ask for a raise", live: the agent runs out of budget and is refused before settling; the owner
# approves a one-day raise from ANY chain's vault; Reactive lifts the budget on every chain; the
# agent's next purchase goes through. Asks for pm-seller, pm-agent and pm-owner passwords once each.
set -euo pipefail
cd "$(dirname "$0")/.."
source script/lib.sh
set -a; source deployments/testnet.env; source deployments/wallets.env; set +a
PORT=${PORT:-4021}; SMALL=${SMALL:-200000}; RAISE=${RAISE:-300000}; NORMAL=${NORMAL:-3000000}

SELLER_PK=$(key pm-seller); export SELLER_PK
AGENT_PK=$(key pm-agent); export AGENT_PK
owner_init
(cd agent && PORT=$PORT npx tsx src/seller.ts >../deployments/seller.log 2>&1) &
trap 'rm -rf "$OWNER_PW_DIR"; pkill -f "tsx src/seller.ts" 2>/dev/null; true' EXIT
for _ in $(seq 1 30); do curl -sf localhost:$PORT/health >/dev/null && break; sleep 1; done
buy() { (cd agent && SELLER_URL=http://localhost:$PORT npx tsx src/agent.ts $1 2>&1) || true; }
settled() { jq -r '.settlement.transaction // empty' 2>/dev/null <<<"$1" || true; }

echo "================ the agent gets \$0.20 for today and spends it on Base ================"
owner $PM "setAgent(address,uint256)" $AGENT $SMALL --rpc-url $LASNA
for _ in $(seq 1 90); do [[ $(left 1301) == $SMALL ]] && break; sleep 2; done
for i in 1 2; do out=$(buy 84532); echo "   buy $i settled $(settled "$out")"; sleep 6; done
for _ in $(seq 1 60); do [[ $(left 1301) == 0 ]] && break; sleep 2; done
echo "   mirror on Unichain: $(left 1301) left"

echo; echo "================ out of budget: refused before settling ================"
buy 1301 | tail -1 | sed 's/^/   agent: /'
echo "   agent -> owner: \"I'm out of budget for today. May I have \$0.30 more?\""

echo; echo "================ the owner approves from Ethereum Sepolia ================"
lf=$(cast block-number --rpc-url $LASNA)
owner $VAULT_11155111 "approveRaise(address,uint256)" $AGENT $RAISE --rpc-url $(rpc 11155111)
read -r tx _ <<<"$(wait_log $LASNA $lf $PM 'RaiseGranted(address indexed,uint256 indexed,uint256,uint256)' 180)"
echo "   guard granted it: $tx (Lasna)"
for _ in $(seq 1 90); do [[ $(left 1301) == $RAISE ]] && break; sleep 2; done
for c in "${CHAINS[@]}"; do echo "   mirror on $c: $(left $c) left"; done

echo; echo "================ the agent tries again on Unichain ================"
out=$(buy 1301); echo "   settled $(settled "$out")"
grep -E '^refused' deployments/seller.log | tail -1 | sed 's/^/   (earlier) seller: /'

echo; echo "================ reset ================"
owner $PM "setAgent(address,uint256)" $AGENT $NORMAL --rpc-url $LASNA
