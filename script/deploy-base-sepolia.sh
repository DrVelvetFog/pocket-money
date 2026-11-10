#!/usr/bin/env bash
# Week-1 deploy: PocketMoney on Reactive Lasna + one Vault on Base Sepolia.
# Testnet only. Every signing step uses the encrypted `pm-owner` keystore and asks for its password.
# Needs on pm-owner: ~0.05 Ethereum Sepolia ETH (bought into lREACT), ~0.0007 Base Sepolia ETH, ~10 test USDC.
set -euo pipefail
cd "$(dirname "$0")/.."

LASNA=https://lasna-rpc.rnk.dev/
BASE=${BASE_RPC:-https://sepolia.base.org}
SEPOLIA=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
CHAIN=84532
PROXY=0x476F44b11F5C942c58f4c8E3d0300E5710743585      # Base Sepolia callback proxy (docs)
USDC=0x036CbD53842c5426634e7929541eC2318f3dCF7e       # Circle USDC, Base Sepolia
LREACT_FAUCET=0x9b9BB25f1A81078C544C829c5EB7822d747Cf434  # Eth Sepolia -> Lasna, 1 ETH = 100 lREACT

BUDGET=${BUDGET:-3000000}        # $3/day
FLOAT=${FLOAT:-1000000}          # $1 float
VAULT_USDC=${VAULT_USDC:-5000000}  # $5 into the vault
LREACT_BUY=${LREACT_BUY:-0.045ether} # -> 4.5 lREACT
PM_FUND=${PM_FUND:-2ether}       # lREACT kept in PocketMoney for reactive fees
VAULT_ETH=${VAULT_ETH:-0.0003ether} # callback fees on Base Sepolia
AGENT_ETH=${AGENT_ETH:-0.00005ether} # week 1 only: plain transfers need gas (x402 later = zero ETH)

source deployments/wallets.env  # public addresses only
PAYEE=${PAYEE:-$OWNER}           # week 1: the owner doubles as the approved shop
OUT=deployments/base-sepolia.env
mkdir -p deployments
echo "owner $OWNER  agent $AGENT  payee $PAYEE"

step() { echo; echo "== $*"; }

if [[ -z "${SKIP_FAUCET:-}" ]]; then
  step "1/7 buy lREACT from the faucet ($LREACT_BUY Ethereum Sepolia ETH)"
  cast send $LREACT_FAUCET "request(address)" $OWNER --value $LREACT_BUY --rpc-url $SEPOLIA --account pm-owner
  echo "waiting for lREACT on Lasna..."
  for _ in $(seq 1 60); do
    bal=$(cast balance $OWNER --rpc-url $LASNA); [[ "$bal" != "0" ]] && break; sleep 5
  done
  echo "lasna balance: $(cast balance $OWNER --rpc-url $LASNA --ether) lREACT"
fi

step "2/7 deploy PocketMoney on Lasna"
PM=$(forge create src/PocketMoney.sol:PocketMoney --rpc-url $LASNA --account pm-owner --broadcast \
  --value $PM_FUND --json --constructor-args $AGENT $BUDGET | jq -r .deployedTo)
echo "PocketMoney $PM"

step "3/7 deploy Vault on Base Sepolia"
VAULT=$(forge create src/Vault.sol:Vault --rpc-url $BASE --account pm-owner --broadcast \
  --value $VAULT_ETH --json --constructor-args $PROXY $PM $USDC $AGENT $FLOAT | jq -r .deployedTo)
echo "Vault $VAULT"

cat > $OUT <<EOF
OWNER=$OWNER
AGENT=$AGENT
PAYEE=$PAYEE
PM=$PM
VAULT=$VAULT
USDC=$USDC
CHAIN=$CHAIN
EOF

step "4/7 register the chain on PocketMoney (subscribes to agent transfers + vault panic)"
cast send $PM "addChain(uint256,address,address)" $CHAIN $USDC $VAULT --rpc-url $LASNA --account pm-owner

step "5/7 approve the payee"
cast send $PM "setPayee(address,bool)" $PAYEE true --rpc-url $LASNA --account pm-owner

step "6/7 fund the vault with USDC and give the agent its float"
cast send $USDC "transfer(address,uint256)" $VAULT $VAULT_USDC --rpc-url $BASE --account pm-owner
cast send $USDC "transfer(address,uint256)" $AGENT $FLOAT --rpc-url $BASE --account pm-owner

step "7/7 week-1 gas for the agent"
cast send $AGENT --value $AGENT_ETH --rpc-url $BASE --account pm-owner

echo; echo "Deployed. Addresses saved to $OUT"; cat $OUT
