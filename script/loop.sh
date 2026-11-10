#!/usr/bin/env bash
# Run one live loop against the v2 deployment and print every tx hash in it.
#   script/loop.sh spend   <chain> [amount] [payee]   agent pays; expect a top-up on that chain
#   script/loop.sh stray   <chain> [amount]           agent pays an unknown address; expect the
#                                                     agent frozen on every chain, no top-up
#   script/loop.sh panic   <chain>                    owner presses panic on one vault; expect
#                                                     every vault frozen
# Chains: 84532 (Base Sepolia), 1301 (Unichain Sepolia), 11155111 (Ethereum Sepolia).
set -euo pipefail
cd "$(dirname "$0")/.."
source deployments/testnet.env
LASNA=https://lasna-rpc.rnk.dev/
STRAY=${STRAY:-0x000000000000000000000000000000000000dEaD}
ALL=(84532 1301 11155111)

rpc()   { case $1 in 84532) echo ${BASE_RPC:-https://sepolia.base.org};;
                    1301) echo ${UNI_RPC:-https://sepolia.unichain.org};;
                    11155111) echo ${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com};; esac; }
usdc()  { case $1 in 84532) echo 0x036CbD53842c5426634e7929541eC2318f3dCF7e;;
                    1301) echo 0x31d0220469e10c4E71834a79b1f276d740d3768F;;
                    11155111) echo 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;; esac; }
vault() { eval echo \$VAULT_$1; }
name()  { case $1 in 84532) echo "Base Sepolia";; 1301) echo "Unichain Sepolia";; 11155111) echo "Ethereum Sepolia";; esac; }

# wait_log <rpc> <from-block> <address> <event sig> [seconds] -> prints "tx block" of the newest match
wait_log() {
  local i out
  for ((i = 0; i < ${5:-120}; i++)); do
    out=$(cast logs --from-block $2 --address $3 "$4" --rpc-url $1 --json 2>/dev/null || echo '[]')
    out=$(jq --arg ex "${EXCL:-}" '[.[] | select(.transactionHash != $ex)]' <<<"$out")
    if [[ $(jq length <<<"$out") -gt 0 ]]; then
      jq -r '.[-1] | "\(.transactionHash) \(.blockNumber)"' <<<"$out"; return 0
    fi
    sleep 1
  done
  echo "none -"; return 0
}

mode=$1; c=$2
declare_from() { echo $(cast block-number --rpc-url $(rpc $1)); }
lasna_from=$(cast block-number --rpc-url $LASNA)
froms=""; for x in "${ALL[@]}"; do froms="$froms $x:$(declare_from $x)"; done
from_of() { for kv in $froms; do [[ ${kv%%:*} == $1 ]] && echo ${kv#*:}; done; }

case $mode in
  spend|stray)
    amount=${3:-250000}
    to=$([[ $mode == spend ]] && echo ${4:-$PAYEE} || echo $STRAY)
    echo "agent pays $amount on $(name $c) to $to"
    o=$(cast send $(usdc $c) "transfer(address,uint256)" $to $amount --rpc-url $(rpc $c) --account pm-agent --json)
    echo "origin    $(jq -r .transactionHash <<<"$o")  block $(jq -r .blockNumber <<<"$o" | cast to-dec)  ($(name $c))"
    read -r tx _ <<<"$(wait_log $LASNA $lasna_from $PM 'Spent(address indexed,uint256 indexed,address indexed,uint256,uint256,uint256,bytes32)')"
    echo "reactive  $tx  (Lasna)"
    if [[ $mode == spend ]]; then
      read -r tx b <<<"$(wait_log $(rpc $c) $(from_of $c) $(vault $c) 'TopUp(address indexed,uint64 indexed,uint256,uint256,uint256)')"
      [[ $b != - ]] && b=$(cast to-dec $b)
      echo "callback  $tx  block $b  ($(name $c))"
    else
      for x in "${ALL[@]}"; do
        read -r tx _ <<<"$(wait_log $(rpc $x) $(from_of $x) $(vault $x) 'AgentFrozen(address indexed,bytes32)')"
        echo "frozen    $tx  ($(name $x))"
      done
    fi
    echo "agent balance on $(name $c): $(cast call $(usdc $c) 'balanceOf(address)(uint256)' $AGENT --rpc-url $(rpc $c))"
    ;;
  panic)
    echo "owner presses panic on $(name $c)"
    o=$(cast send $(vault $c) "panic()" --rpc-url $(rpc $c) --account pm-owner --json)
    EXCL=$(jq -r .transactionHash <<<"$o")
    echo "panic     $EXCL  ($(name $c))"
    read -r tx _ <<<"$(wait_log $LASNA $lasna_from $PM 'PanicSeen(uint256 indexed,address indexed,uint256)')"
    echo "reactive  $tx  (Lasna)"
    for x in "${ALL[@]}"; do
      read -r tx _ <<<"$(wait_log $(rpc $x) $(from_of $x) $(vault $x) 'Frozen(bytes32)')"
      echo "frozen    $tx  ($(name $x))"
    done
    ;;
  *) echo "usage: $0 spend|stray|panic <chain> [amount] [payee]"; exit 1;;
esac
