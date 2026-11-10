#!/usr/bin/env bash
# One full loop: the agent pays on Base Sepolia, Reactive books it on Lasna, the vault tops up.
# Prints the three tx hashes (origin -> reactive -> callback) and the top-up delay.
# Usage: script/spend.sh [amount-in-usdc-units] [payee]
set -euo pipefail
cd "$(dirname "$0")/.."
source deployments/base-sepolia.env
LASNA=https://lasna-rpc.rnk.dev/
BASE=${BASE_RPC:-https://sepolia.base.org}
AMOUNT=${1:-250000}   # $0.25
TO=${2:-$PAYEE}

lasna_from=$(cast block-number --rpc-url $LASNA)
base_from=$(cast block-number --rpc-url $BASE)

echo "agent pays $AMOUNT to $TO"
origin=$(cast send $USDC "transfer(address,uint256)" $TO $AMOUNT --rpc-url $BASE --account pm-agent --json)
origin_tx=$(jq -r .transactionHash <<<"$origin")
t0=$(cast block $(jq -r .blockNumber <<<"$origin") --rpc-url $BASE -f timestamp)
echo "origin   $origin_tx"

for _ in $(seq 1 60); do
  spent=$(cast logs --from-block $lasna_from --address $PM \
    'Spent(uint256 indexed,address indexed,uint256,uint256,uint256,bytes32)' --rpc-url $LASNA --json)
  [[ $(jq length <<<"$spent") -gt 0 ]] && break; sleep 1
done
echo "reactive $(jq -r '.[-1].transactionHash' <<<"$spent")"

for _ in $(seq 1 90); do
  topup=$(cast logs --from-block $base_from --address $VAULT \
    'TopUp(uint64 indexed,uint256,uint256,uint256)' --rpc-url $BASE --json)
  skipped=$(cast logs --from-block $base_from --address $VAULT \
    'TopUpSkipped(uint64 indexed,bytes32)' --rpc-url $BASE --json)
  [[ $(jq length <<<"$topup") -gt 0 || $(jq length <<<"$skipped") -gt 0 ]] && break; sleep 1
done
if [[ $(jq length <<<"$topup") -gt 0 ]]; then
  cb_tx=$(jq -r '.[-1].transactionHash' <<<"$topup")
  t1=$(cast block $(jq -r '.[-1].blockNumber' <<<"$topup") --rpc-url $BASE -f timestamp)
  echo "callback $cb_tx"
  echo "top-up delay: $((t1 - t0))s (block timestamps)"
else
  echo "no top-up (skipped or not delivered) — check PocketMoney events on lasna.reactscan.net"
fi
echo "agent balance: $(cast call $USDC 'balanceOf(address)(uint256)' $AGENT --rpc-url $BASE)"
