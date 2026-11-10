#!/usr/bin/env bash
# Feasibility probe for CCTP v2 on our testnets: the owner moves a little USDC from one chain to
# another (burn -> Circle attestation -> mint) and prints each tx. Asks for pm-owner once.
#   script/cctp-probe.sh [from-chain] [to-chain] [amount]   default 84532 -> 1301, 100000 ($0.10)
set -euo pipefail
cd "$(dirname "$0")/.."
source deployments/wallets.env
TM=0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA   # TokenMessengerV2 (same address on every testnet)
MT=0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275   # MessageTransmitterV2
IRIS=https://iris-api-sandbox.circle.com
rpc()    { case $1 in 84532) echo ${BASE_RPC:-https://sepolia.base.org};;
                     1301) echo ${UNI_RPC:-https://sepolia.unichain.org};;
                     11155111) echo ${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com};; esac; }
usdc()   { case $1 in 84532) echo 0x036CbD53842c5426634e7929541eC2318f3dCF7e;;
                     1301) echo 0x31d0220469e10c4E71834a79b1f276d740d3768F;;
                     11155111) echo 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;; esac; }
domain() { case $1 in 84532) echo 6;; 1301) echo 10;; 11155111) echo 0;; esac; }
FROM=${1:-84532}; TO=${2:-1301}; AMT=${3:-100000}

d=$(mktemp -d); chmod 700 "$d"; trap 'rm -rf "$d"' EXIT
read -rs -p "pm-owner keystore password: " p; echo; printf '%s' "$p" > "$d/o"; unset p; chmod 600 "$d/o"
send() { cast send "$@" --account pm-owner --password-file "$d/o" --json; }

before=$(cast call $(usdc $TO) "balanceOf(address)(uint256)" $OWNER --rpc-url $(rpc $TO) | cut -d' ' -f1)
echo "== approve + burn $AMT on $FROM for $TO (fast transfer)"
send $(usdc $FROM) "approve(address,uint256)" $TM $AMT --rpc-url $(rpc $FROM) | jq -r '"   approve \(.transactionHash) \(.status)"'
recipient=0x000000000000000000000000${OWNER:2}
burn=$(send $TM "depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)" \
  $AMT $(domain $TO) $recipient $(usdc $FROM) 0x0000000000000000000000000000000000000000000000000000000000000000 \
  1000 1000 --rpc-url $(rpc $FROM))
btx=$(jq -r .transactionHash <<<"$burn"); echo "   burn $btx $(jq -r .status <<<"$burn")"

echo "== waiting for Circle's attestation"
t0=$(date +%s)
for _ in $(seq 1 180); do
  r=$(curl -s "$IRIS/v2/messages/$(domain $FROM)?transactionHash=$btx")
  [[ $(jq -r '.messages[0].status // empty' <<<"$r") == complete ]] && break
  sleep 5
done
echo "   attested after $(( $(date +%s) - t0 ))s: $(jq -r '.messages[0].status' <<<"$r")"
msg=$(jq -r '.messages[0].message' <<<"$r"); att=$(jq -r '.messages[0].attestation' <<<"$r")

echo "== mint on $TO"
send $MT "receiveMessage(bytes,bytes)" $msg $att --rpc-url $(rpc $TO) | jq -r '"   mint \(.transactionHash) \(.status)"'
after=$(cast call $(usdc $TO) "balanceOf(address)(uint256)" $OWNER --rpc-url $(rpc $TO) | cut -d' ' -f1)
echo "owner USDC on $TO: $before -> $after (+$((after - before)))"
