#!/usr/bin/env bash
# Drills for the live run. You run these yourself; each one ends by putting
# things back. Asks for the pm-agent and pm-owner passwords once each.
#   script/drill.sh stray   [chain]  the agent pays an unknown address -> frozen everywhere
#   script/drill.sh stolen           a "stolen key" drains every float to a thief -> loss = floats
#   script/drill.sh panic   [chain]  you press panic on one chain -> every vault frozen
#   script/drill.sh dry              the guard runs out of lREACT -> top-ups stop (fail closed)
set -euo pipefail
cd "$(dirname "$0")/.."
source script/lib.sh
set -a; source deployments/testnet.env; source deployments/wallets.env; set +a
DRILL=${1:?stray|stolen|panic|dry}; CH=${2:-1301}
exec > >(tee -a "deployments/drill-$DRILL-$(date +%Y%m%d-%H%M%S).log") 2>&1
THIEF=0x000000000000000000000000000000000000bEEF

d=$(mktemp -d); chmod 700 "$d"
read -rs -p "pm-agent keystore password: " p </dev/tty; echo; printf '%s' "$p" > "$d/a"; unset p; chmod 600 "$d/a"
owner_init; trap 'rm -rf "$d" "$OWNER_PW_DIR"' EXIT
agent() { cast send "$@" --account pm-agent --password-file "$d/a" --json | jq -r '"   agent tx \(.transactionHash)"'; }
froms() { F=""; for c in "${CHAINS[@]}"; do F="$F $(cast block-number --rpc-url $(rpc $c))"; done; F=($F); }
expect_everywhere() { # expect_everywhere <event sig> <label>
  local i=0 tx
  for c in "${CHAINS[@]}"; do
    read -r tx _ <<<"$(wait_log $(rpc $c) ${F[$i]} $(eval echo \$VAULT_$c) "$1" 180)"
    echo "   $2 on $c: $tx"; i=$((i + 1))
  done
}
bal() { cast call $(usdc $1) "balanceOf(address)(uint256)" $2 --rpc-url $(rpc $1) | cut -d' ' -f1; }
unfreeze_agent() { owner $PM "resumeAgent(address)" $AGENT --rpc-url $LASNA
  for c in "${CHAINS[@]}"; do owner $(eval echo \$VAULT_$c) "unfreezeAgent(address)" $AGENT --rpc-url $(rpc $c); done; }

case $DRILL in
  stray)
    echo "== the agent is tricked into paying an unknown address on $CH"
    lf=$(cast block-number --rpc-url $LASNA); froms
    agent $(usdc $CH) "transfer(address,uint256)" 0x000000000000000000000000000000000000dEaD 250000 --rpc-url $(rpc $CH)
    read -r tx _ <<<"$(wait_log $LASNA $lf $PM 'Quarantined(address indexed,uint256 indexed,bytes32,uint256)' 180)"
    echo "   guard quarantined the agent: $tx"
    expect_everywhere 'AgentFrozen(address indexed,bytes32)' frozen
    echo "== put it back"; unfreeze_agent ;;
  stolen)
    echo "== someone has the agent's key and drains every float"
    lf=$(cast block-number --rpc-url $LASNA); froms; lost=0
    for c in "${CHAINS[@]}"; do
      b=$(bal $c $AGENT); [[ $b == 0 ]] && continue
      agent $(usdc $c) "transfer(address,uint256)" $THIEF $b --rpc-url $(rpc $c); lost=$((lost + b))
    done
    echo "   thief took $lost units in total (the sum of the floats)"
    read -r tx _ <<<"$(wait_log $LASNA $lf $PM 'Quarantined(address indexed,uint256 indexed,bytes32,uint256)' 180)"
    echo "   guard quarantined the agent after the first payment: $tx"
    expect_everywhere 'AgentFrozen(address indexed,bytes32)' frozen
    echo "== put it back: unfreeze, then the owner refills the floats by hand"
    unfreeze_agent
    for c in "${CHAINS[@]}"; do
      f=$(cast call $(eval echo \$VAULT_$c) "floatOf(address)(uint256)" $AGENT --rpc-url $(rpc $c) | cut -d' ' -f1)
      owner $(usdc $c) "transfer(address,uint256)" $AGENT $((f - $(bal $c $AGENT))) --rpc-url $(rpc $c)
    done ;;
  panic)
    echo "== you press panic on $CH"
    lf=$(cast block-number --rpc-url $LASNA); froms
    owner $(eval echo \$VAULT_$CH) "panic()" --rpc-url $(rpc $CH)
    read -r tx _ <<<"$(wait_log $LASNA $lf $PM 'PanicSeen(uint256 indexed,address indexed,uint256)' 180)"
    echo "   guard saw the panic: $tx"
    expect_everywhere 'Frozen(bytes32)' frozen
    echo "== put it back"
    owner $PM "resume()" --rpc-url $LASNA
    for c in "${CHAINS[@]}"; do owner $(eval echo \$VAULT_$c) "unfreeze()" --rpc-url $(rpc $c); done ;;
  dry)
    echo "== the guard runs out of lREACT; nothing should be topped up (fail closed)"
    keep=$(cast balance $PM --rpc-url $LASNA)
    owner $PM "withdraw(address,uint256)" $OWNER $keep --rpc-url $LASNA
    echo "   guard balance now $(cast balance $PM --rpc-url $LASNA --ether) lREACT"
    cf=$(cast block-number --rpc-url $(rpc $CH)); before=$(bal $CH $AGENT)
    agent $(usdc $CH) "transfer(address,uint256)" $PAYEE 100000 --rpc-url $(rpc $CH)
    sleep 60
    read -r tx _ <<<"$(wait_log $(rpc $CH) $cf $(eval echo \$VAULT_$CH) 'TopUp(address indexed,uint64 indexed,uint256,uint256,uint256)' 30)"
    echo "   top-up after 90 s: $tx  (none = failed closed); agent $before -> $(bal $CH $AGENT)"
    echo "== put it back: refund the guard and settle its debt"
    owner $PM --value $keep --rpc-url $LASNA
    owner $PM "coverDebt()" --rpc-url $LASNA
    echo "   guard balance $(cast balance $PM --rpc-url $LASNA --ether) lREACT" ;;
  *) echo "usage: $0 stray|stolen|panic|dry [chain]"; exit 1 ;;
esac
