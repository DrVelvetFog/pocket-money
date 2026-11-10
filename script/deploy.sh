#!/usr/bin/env bash
# Deploy Pocket Money v2: the guard on Reactive Lasna + a vault on Base Sepolia, Unichain Sepolia
# and Ethereum Sepolia, one household agent, one approved payee.
# Testnet only. Asks for the pm-owner keystore password ONCE, keeps it in a private temp file for
# this run (mode 600), and deletes it on exit.
set -euo pipefail
cd "$(dirname "$0")/.."

LASNA=https://lasna-rpc.rnk.dev/
rpc()   { case $1 in 84532) echo ${BASE_RPC:-https://sepolia.base.org};;
                    1301) echo ${UNI_RPC:-https://sepolia.unichain.org};;
                    11155111) echo ${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com};; esac; }
proxy() { case $1 in 84532) echo 0x476F44b11F5C942c58f4c8E3d0300E5710743585;;
                    1301) echo 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;;
                    11155111) echo 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4;; esac; }
usdc()  { case $1 in 84532) echo 0x036CbD53842c5426634e7929541eC2318f3dCF7e;;
                    1301) echo 0x31d0220469e10c4E71834a79b1f276d740d3768F;;
                    11155111) echo 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;; esac; }
CHAINS=(${CHAINS:-84532 1301 11155111})

CEILING=${CEILING:-5000000}        # household: $5/day
ALLOWANCE=${ALLOWANCE:-3000000}    # agent: $3/day
FLOAT=${FLOAT:-1000000}            # $1 float per chain
VAULT_USDC=${VAULT_USDC:-5000000}  # $5 per vault
PM_FUND=${PM_FUND:-2.5ether}       # lREACT for reactive fees
VAULT_ETH=${VAULT_ETH:-0.0002ether}
AGENT_ETH=${AGENT_ETH:-0.00002ether} # until the x402 seller: plain transfers need gas

source deployments/wallets.env
PAYEE=${PAYEE:-$OWNER}
OUT=deployments/testnet.env

pwdir=$(mktemp -d); chmod 700 "$pwdir"; trap 'rm -rf "$pwdir"' EXIT
read -rs -p "pm-owner keystore password: " pw; echo
printf '%s' "$pw" > "$pwdir/pw"; chmod 600 "$pwdir/pw"; unset pw
SIGN=(--account pm-owner --password-file "$pwdir/pw")

step() { echo; echo "== $*"; }
send() { cast send "$@" "${SIGN[@]}" --json | jq -r '"   tx \(.transactionHash) status \(.status)"'; }

if [[ -f deployments/base-sepolia.env && -z "${KEEP_V1:-}" ]]; then
  step "0 wind down v1 (recover lREACT and the Base vault's funds)"
  V1PM=$(grep '^PM=' deployments/base-sepolia.env | cut -d= -f2)
  bal=$(cast balance $V1PM --rpc-url $LASNA)
  [[ "$bal" != "0" ]] && send $V1PM "withdraw(address,uint256)" $OWNER $bal --rpc-url $LASNA
  u=$(cast call $(usdc 84532) "balanceOf(address)(uint256)" $V1PM --rpc-url $(rpc 84532) | cut -d' ' -f1)
  [[ "$u" != "0" ]] && send $V1PM "withdraw(address,address,uint256)" $(usdc 84532) $OWNER $u --rpc-url $(rpc 84532)
  e=$(cast balance $V1PM --rpc-url $(rpc 84532))
  [[ "$e" != "0" ]] && send $V1PM "withdraw(address,address,uint256)" 0x0000000000000000000000000000000000000000 $OWNER $e --rpc-url $(rpc 84532)
fi

step "1 deploy PocketMoney v2 on Lasna"
PM=$(forge create src/PocketMoney.sol:PocketMoney --rpc-url $LASNA "${SIGN[@]}" --broadcast \
  --value $PM_FUND --json --constructor-args $CEILING | jq -r .deployedTo)
echo "   PocketMoney $PM"
{ echo "OWNER=$OWNER"; echo "AGENT=$AGENT"; echo "PAYEE=$PAYEE"; echo "PM=$PM"; } > $OUT

for c in "${CHAINS[@]}"; do
  step "2 vault on chain $c"
  V=$(forge create src/Vault.sol:Vault --rpc-url $(rpc $c) "${SIGN[@]}" --broadcast \
    --value $VAULT_ETH --json --constructor-args $(proxy $c) $PM $(usdc $c) | jq -r .deployedTo)
  echo "   Vault $V"
  echo "VAULT_$c=$V" >> $OUT
  send $V "setFloat(address,uint256)" $AGENT $FLOAT --rpc-url $(rpc $c)
  send $(usdc $c) "transfer(address,uint256)" $V $VAULT_USDC --rpc-url $(rpc $c)
  a=$(cast call $(usdc $c) "balanceOf(address)(uint256)" $AGENT --rpc-url $(rpc $c) | cut -d' ' -f1)
  (( a < FLOAT )) && send $(usdc $c) "transfer(address,uint256)" $AGENT $((FLOAT - a)) --rpc-url $(rpc $c)
  send $AGENT --value $AGENT_ETH --rpc-url $(rpc $c)
  step "3 register chain $c on the guard"
  send $PM "addChain(uint256,address,address)" $c $(usdc $c) $V --rpc-url $LASNA
done

step "4 household: agent allowance, ceiling, payee"
send $PM "setAgent(address,uint256)" $AGENT $ALLOWANCE --rpc-url $LASNA
send $PM "setPayee(address,bool)" $PAYEE true --rpc-url $LASNA

echo; echo "Deployed. Saved to $OUT"; cat $OUT
