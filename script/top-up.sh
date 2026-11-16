#!/usr/bin/env bash
# Top up what a long run burns, from the owner's Ethereum Sepolia ETH:
#   lREACT for the guard (it pays for every reaction), Base Sepolia gas for the owner, and Base
#   Sepolia settlement gas for the shop.
# Needs about 0.04 Sepolia ETH on the owner. Asks for the pm-owner password once.
#   LREACT_BUY=0.03 BRIDGE_ETH=0.005 SHOP_GAS=0.0005 script/top-up.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source script/lib.sh
set -a; source deployments/testnet.env; source deployments/wallets.env; set +a
SEPOLIA=$(rpc 11155111); BASE=$(rpc 84532)
LREACT_FAUCET=0x9b9BB25f1A81078C544C829c5EB7822d747Cf434   # Reactive: Ethereum Sepolia ETH -> lREACT, 1 : 100
BASE_BRIDGE=0xfd0Bf71F60660E2f608ed56e1659C450eB113120     # Base Sepolia's L1StandardBridge on Ethereum Sepolia
LREACT_BUY=${LREACT_BUY:-0.03}; BRIDGE_ETH=${BRIDGE_ETH:-0.005}; SHOP_GAS=${SHOP_GAS:-0.0005}
ge() { [[ $(echo "$1 >= $2" | bc) == 1 ]]; }
eth() { cast balance $1 --rpc-url $2 --ether; }

have=$(eth $OWNER $SEPOLIA); need=$(echo "$LREACT_BUY + $BRIDGE_ETH + 0.002" | bc)
ge $have $need || { echo "the owner has $have Sepolia ETH; this needs $need. Claim more: https://cloud.google.com/application/web3/faucet/ethereum/sepolia"; exit 1; }
owner_init; trap 'rm -rf "$OWNER_PW_DIR"' EXIT

echo "== buying lREACT with $LREACT_BUY Sepolia ETH"
before=$(eth $OWNER $LASNA); got=$(echo "$LREACT_BUY * 100" | bc)
owner $LREACT_FAUCET "request(address)" $OWNER --value ${LREACT_BUY}ether --rpc-url $SEPOLIA
echo "== bridging $BRIDGE_ETH ETH to Base Sepolia"
base_before=$(eth $OWNER $BASE)
owner $BASE_BRIDGE "depositETH(uint32,bytes)" 200000 0x --value ${BRIDGE_ETH}ether --rpc-url $SEPOLIA

echo "   waiting for the lREACT on Reactive Lasna..."
until ge $(eth $OWNER $LASNA) $(echo "$before + $got - 0.5" | bc); do sleep 6; done
echo "== sending $got lREACT to the guard"
owner $PM --value ${got}ether --rpc-url $LASNA

echo "   waiting for the bridge (a couple of minutes)..."
until ge $(eth $OWNER $BASE) $(echo "$base_before + $BRIDGE_ETH - 0.0005" | bc); do sleep 10; done
echo "== shop settlement gas on Base Sepolia"
owner $SELLER --value ${SHOP_GAS}ether --rpc-url $BASE

echo
echo "guard  $(eth $PM $LASNA) lREACT"
echo "owner  $(eth $OWNER $LASNA) lREACT, $(eth $OWNER $SEPOLIA) Sepolia ETH, $(eth $OWNER $BASE) Base Sepolia ETH"
echo "shop   $(eth $SELLER $BASE) Base Sepolia ETH"
