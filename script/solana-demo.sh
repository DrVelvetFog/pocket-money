#!/usr/bin/env bash
# Solana spending counts against the same budget (same inbox as Sui):
#   1. the agent pays the shop $0.10 on Solana devnet -> attester -> inbox on Base -> guard books
#      it -> the mirror drops on every EVM chain
#   2. the agent pays an unknown Solana address -> frozen on every EVM chain
#   3. reset
# Asks for pm-agent-sol, pm-seller (attester) and pm-owner passwords once each.
set -euo pipefail
cd "$(dirname "$0")/.."
exec > >(tee -a "deployments/solana-demo-$(date +%Y%m%d-%H%M%S).log") 2>&1
source script/lib.sh
set -a; source deployments/testnet.env; source deployments/wallets.env; set +a

AGENT_SOL_PK=$(key pm-agent-sol); export AGENT_SOL_PK
SELLER_PK=$(key pm-seller); export SELLER_PK
owner_init
(cd agent && npx tsx src/solana-attester.ts >../deployments/sol-attester.log 2>&1) &
trap 'rm -rf "$OWNER_PW_DIR"; pkill -f "tsx src/solana-attester.ts" 2>/dev/null; true' EXIT
sleep 6; head -1 deployments/sol-attester.log
pay() { (cd agent && npx tsx src/solana-pay.ts "$@"); }
before=$(left 1301)

echo; echo "================ 1. the agent pays the shop \$0.10 on Solana ================"
lf=$(cast block-number --rpc-url $LASNA); bf=$(cast block-number --rpc-url $(rpc 84532))
pay shop 100000 | jq -r '"   solana payment \(.signature)"'
read -r tx _ <<<"$(wait_log $(rpc 84532) $bf $INBOX 'ForeignSpend(address indexed,bytes32 indexed,uint256,bytes32,bytes32)' 180)"
echo "   attester reported it:   $tx (Base Sepolia inbox)"
read -r tx _ <<<"$(wait_log $LASNA $lf $PM 'Spent(address indexed,uint256 indexed,bytes32 indexed,uint256,uint256,uint256,bytes32)' 120)"
echo "   guard booked it:        $tx (Lasna)"
for _ in $(seq 1 60); do [[ $(left 11155111) != $before ]] && break; sleep 2; done
for c in "${CHAINS[@]}"; do echo "   mirror on $c: $(left $c) left (was $before)"; done

echo; echo "================ 2. the agent pays an unknown Solana address ================"
lf=$(cast block-number --rpc-url $LASNA)
froms=""; for c in "${CHAINS[@]}"; do froms="$froms $(cast block-number --rpc-url $(rpc $c))"; done; froms=($froms)
pay stray 10000 | jq -r '"   solana payment \(.signature)"'
read -r tx _ <<<"$(wait_log $LASNA $lf $PM 'Quarantined(address indexed,uint256 indexed,bytes32,uint256)' 180)"
echo "   guard quarantined the agent: $tx (Lasna)"
i=0; for c in "${CHAINS[@]}"; do
  read -r tx _ <<<"$(wait_log $(rpc $c) ${froms[$i]} $(eval echo \$VAULT_$c) 'AgentFrozen(address indexed,bytes32)' 180)"
  echo "   frozen on $c: $tx"; i=$((i + 1))
done

echo; echo "================ reset ================"
owner $PM "resumeAgent(address)" $AGENT --rpc-url $LASNA
for c in "${CHAINS[@]}"; do owner $(eval echo \$VAULT_$c) "unfreezeAgent(address)" $AGENT --rpc-url $(rpc $c); done
grep '^reported' deployments/sol-attester.log | sed 's/^/   attester: /'
