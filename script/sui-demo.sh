#!/usr/bin/env bash
# Idea 2, live: spending on Sui (which Reactive can't watch) counts against the same budget.
#   1. the agent pays the shop $0.10 on Sui -> the attester reports it to the inbox on Base ->
#      the guard books it and the budget mirror drops on every EVM chain
#   2. the agent pays an unknown Sui address -> the agent is frozen on every EVM chain
#   3. reset
# Asks for pm-agent-sui, pm-seller (attester) and pm-owner passwords once each.
set -euo pipefail
cd "$(dirname "$0")/.."
exec > >(tee -a "deployments/sui-demo-$(date +%Y%m%d-%H%M%S).log") 2>&1
source script/lib.sh
set -a; source deployments/testnet.env; source deployments/wallets.env; set +a

AGENT_SUI_PK=$(key pm-agent-sui); export AGENT_SUI_PK
SELLER_PK=$(key pm-seller); export SELLER_PK
owner_init
(cd agent && npx tsx src/sui-attester.ts >../deployments/attester.log 2>&1) &
trap 'rm -rf "$OWNER_PW_DIR"; pkill -f "tsx src/sui-attester.ts" 2>/dev/null; true' EXIT
sleep 6; head -1 deployments/attester.log

pay() { (cd agent && npx tsx src/sui-pay.ts "$@"); }
before=$(left 1301)

echo; echo "================ 1. the agent pays the shop \$0.10 on Sui ================"
lf=$(cast block-number --rpc-url $LASNA); bf=$(cast block-number --rpc-url $(rpc 84532))
pay shop 100000 | jq -r '"   sui payment \(.digest)  ok=\(.ok)"'
read -r tx _ <<<"$(wait_log $(rpc 84532) $bf $INBOX 'ForeignSpend(address indexed,bytes32 indexed,uint256,bytes32,bytes32)' 120)"
echo "   attester reported it:   $tx (Base Sepolia inbox)"
read -r tx _ <<<"$(wait_log $LASNA $lf $PM 'Spent(address indexed,uint256 indexed,bytes32 indexed,uint256,uint256,uint256,bytes32)' 120)"
echo "   guard booked it:        $tx (Lasna)"
for _ in $(seq 1 60); do [[ $(left 1301) != $before ]] && break; sleep 2; done
for c in "${CHAINS[@]}"; do echo "   mirror on $c: $(left $c) left (was $before)"; done

echo; echo "================ 2. the agent pays an unknown Sui address ================"
lf=$(cast block-number --rpc-url $LASNA)
froms=""; for c in "${CHAINS[@]}"; do froms="$froms $(cast block-number --rpc-url $(rpc $c))"; done; froms=($froms)
pay stray 10000 | jq -r '"   sui payment \(.digest)  ok=\(.ok)"'
read -r tx _ <<<"$(wait_log $LASNA $lf $PM 'Quarantined(address indexed,uint256 indexed,bytes32,uint256)' 180)"
echo "   guard quarantined the agent: $tx (Lasna)"
i=0; for c in "${CHAINS[@]}"; do
  read -r tx _ <<<"$(wait_log $(rpc $c) ${froms[$i]} $(eval echo \$VAULT_$c) 'AgentFrozen(address indexed,bytes32)' 180)"
  echo "   frozen on $c: $tx"; i=$((i + 1))
done

echo; echo "================ reset ================"
owner $PM "resumeAgent(address)" $AGENT --rpc-url $LASNA
for c in "${CHAINS[@]}"; do owner $(eval echo \$VAULT_$c) "unfreezeAgent(address)" $AGENT --rpc-url $(rpc $c); done
grep '^reported' deployments/attester.log | sed 's/^/   attester: /'
