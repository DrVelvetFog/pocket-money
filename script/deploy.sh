#!/usr/bin/env bash
# Deploy Pocket Money: the guard on Reactive Lasna, a vault on Base Sepolia, Unichain Sepolia and
# Ethereum Sepolia (each wired to Circle CCTP and to its sibling vaults), the Sui spend inbox on
# Base Sepolia, one household agent, and the approved payees (owner + x402 seller).
# Testnet only. Asks for the pm-owner keystore password ONCE, keeps it in a private temp file for
# this run (mode 600), and deletes it on exit.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p deployments
exec > >(tee -a "deployments/deploy-$(date +%Y%m%d-%H%M%S).log") 2>&1

LASNA=https://lasna-rpc.rnk.dev/
rpc()   { case $1 in 84532) echo ${BASE_RPC:-https://sepolia.base.org};;
                    1301) echo ${UNI_RPC:-https://sepolia.unichain.org};;
                    11155111) echo ${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com};; esac; }
proxy() { case $1 in 84532) echo 0x476F44b11F5C942c58f4c8E3d0300E5710743585;;
                    1301) echo 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;;
                    11155111) echo 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4;; esac; }
domain(){ case $1 in 84532) echo 6;; 1301) echo 10;; 11155111) echo 0;; esac; }
vusdc() { case $1 in 84532) echo ${VAULT_USDC_BASE:-3200000};; 1301) echo ${VAULT_USDC_UNI:-5000000};;
                    11155111) echo ${VAULT_USDC_ETH:-8000000};; esac; }  # uneven on purpose: Base runs low first
TOKEN_MESSENGER=0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA  # Circle CCTP v2, same on every testnet
usdc()  { case $1 in 84532) echo 0x036CbD53842c5426634e7929541eC2318f3dCF7e;;
                    1301) echo 0x31d0220469e10c4E71834a79b1f276d740d3768F;;
                    11155111) echo 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;; esac; }
CHAINS=(${CHAINS:-84532 1301 11155111})

CEILING=${CEILING:-5000000}        # household: $5/day
ALLOWANCE=${ALLOWANCE:-3000000}    # agent: $3/day
FLOAT=${FLOAT:-1000000}            # $1 float per chain
LOW_WATER=${LOW_WATER:-3000000}    # rebalance a vault below $3 ...
TARGET=${TARGET:-4000000}          # ... back up to $4
MAX_FEE=${MAX_FEE:-1000}           # CCTP fast-transfer fee ceiling ($0.001)
REBALANCE_CAP=${REBALANCE_CAP:-5000000}
PM_FUND=${PM_FUND:-2.2ether}       # lREACT for reactive fees
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
# Public testnet RPCs sometimes hand back a stale nonce; wait and retry instead of dying.
send() {
  local i out
  for i in 1 2 3 4; do
    if out=$(cast send "$@" "${SIGN[@]}" --json 2>&1); then
      jq -r '"   tx \(.transactionHash) status \(.status)"' <<<"$out"; return 0
    fi
    grep -qi 'nonce' <<<"$out" || { echo "$out" >&2; return 1; }
    echo "   (stale nonce, retrying)"; sleep 4
  done
  echo "$out" >&2; return 1
}
num() { cut -d' ' -f1; }
ZERO=0x0000000000000000000000000000000000000000

if [[ -n "${RESUME:-}" ]]; then
  source $OUT
  step "resuming with PocketMoney $PM"
fi

if [[ -z "${RESUME:-}" && -f $OUT ]]; then
  step "0b retire the previous deployment (vaults migrate() to the owner, guard returns its lREACT)"
  PREV_PM=$(grep '^PM=' $OUT | cut -d= -f2)
  for c in "${CHAINS[@]}"; do
    V=$(grep "^VAULT_$c=" $OUT | cut -d= -f2); [[ -z "$V" ]] && continue
    u=$(cast call $(usdc $c) "balanceOf(address)(uint256)" $V --rpc-url $(rpc $c) | num)
    e=$(cast balance $V --rpc-url $(rpc $c))
    if [[ "$u" != "0" || "$e" != "0" ]]; then send $V "migrate(address)" $OWNER --rpc-url $(rpc $c) || exit 1
    else echo "   vault on $c already empty"; fi
  done
  # The old guard keeps reacting (and paying fees) while we retire it, so leave a margin.
  bal=$(cast balance $PREV_PM --rpc-url $LASNA)
  amt=$(echo "$bal - 50000000000000000" | bc)
  if [[ "${amt:0:1}" != "-" && "$amt" != "0" ]]; then
    send $PREV_PM "withdraw(address,uint256)" $OWNER $amt --rpc-url $LASNA || exit 1
  fi
  mkdir -p deployments/archive
  mv $OUT deployments/archive/testnet-$(date +%Y%m%d-%H%M%S).env
fi

if [[ -z "${RESUME:-}" ]]; then
  step "1 deploy PocketMoney on Lasna"
  PM=$(forge create src/PocketMoney.sol:PocketMoney --rpc-url $LASNA "${SIGN[@]}" --broadcast \
    --value $PM_FUND --json --constructor-args $CEILING | jq -r .deployedTo)
  echo "   PocketMoney $PM"
  { echo "OWNER=$OWNER"; echo "AGENT=$AGENT"; echo "PAYEE=$PAYEE"; echo "PM=$PM"; } > $OUT
fi

# Every step checks chain state first, so a re-run (RESUME=1) only does what is missing.
for c in "${CHAINS[@]}"; do
  R=$(rpc $c); U=$(usdc $c)
  step "2 vault on chain $c"
  V=$(eval echo \${VAULT_$c:-})
  if [[ -z "$V" ]]; then
    V=$(forge create src/Vault.sol:Vault --rpc-url $R "${SIGN[@]}" --broadcast \
      --value $VAULT_ETH --json --constructor-args $(proxy $c) $PM $U $TOKEN_MESSENGER | jq -r .deployedTo)
    echo "VAULT_$c=$V" >> $OUT
  fi
  echo "   Vault $V"
  [[ $(cast call $V "floatOf(address)(uint256)" $AGENT --rpc-url $R | num) == $FLOAT ]] ||
    send $V "setFloat(address,uint256)" $AGENT $FLOAT --rpc-url $R
  vb=$(cast call $U "balanceOf(address)(uint256)" $V --rpc-url $R | num)
  want=$(vusdc $c)
  (( vb < want )) && send $U "transfer(address,uint256)" $V $((want - vb)) --rpc-url $R
  a=$(cast call $U "balanceOf(address)(uint256)" $AGENT --rpc-url $R | num)
  (( a < FLOAT )) && send $U "transfer(address,uint256)" $AGENT $((FLOAT - a)) --rpc-url $R
  [[ $(cast balance $AGENT --rpc-url $R) == 0 ]] && send $AGENT --value $AGENT_ETH --rpc-url $R
  step "3 register chain $c on the guard"
  reg=$(cast call $PM "chains(uint256)(address,address,uint32)" $c --rpc-url $LASNA | sed -n 2p)
  [[ $(tr A-F a-f <<<"$reg") == $(tr A-F a-f <<<"$V") ]] ||
    send $PM "addChain(uint256,address,address,uint32)" $c $U $V $(domain $c) --rpc-url $LASNA
  # funds arrived before the guard watched this vault: tell it the starting balance
  vb=$(cast call $U "balanceOf(address)(uint256)" $V --rpc-url $R | num)
  send $PM "noteVaultBalance(uint256,uint256)" $c $vb --rpc-url $LASNA
done

step "3b CCTP: every vault may send to its siblings, up to the cap"
source $OUT
for c in "${CHAINS[@]}"; do
  V=$(eval echo \$VAULT_$c); R=$(rpc $c)
  [[ $(cast call $V "rebalanceCap()(uint256)" --rpc-url $R | num) == $REBALANCE_CAP ]] ||
    send $V "setRebalanceCap(uint256)" $REBALANCE_CAP --rpc-url $R
  for d in "${CHAINS[@]}"; do
    [[ $d == $c ]] && continue
    P=$(eval echo \$VAULT_$d)
    peer=$(cast call $V "peerOf(uint32)(bytes32)" $(domain $d) --rpc-url $R)
    [[ $(tr A-F a-f <<<"$peer") == *$(tr A-F a-f <<<"${P:2}") ]] ||
      send $V "setPeer(uint32,address)" $(domain $d) $P --rpc-url $R
  done
done
send $PM "setRebalancePolicy(uint256,uint256,uint256)" $LOW_WATER $TARGET $MAX_FEE --rpc-url $LASNA

step "3c Sui spend inbox on Base Sepolia (attester = the seller's service key)"
if [[ -z "${INBOX:-}" ]]; then
  INBOX=$(forge create src/SpendInbox.sol:SpendInbox --rpc-url $(rpc 84532) "${SIGN[@]}" --broadcast \
    --json --constructor-args ${ATTESTER:-$SELLER} | jq -r .deployedTo)
  echo "INBOX=$INBOX" >> $OUT
fi
echo "   SpendInbox $INBOX"
[[ $(cast call $PM "inboxOf(uint256)(address)" 84532 --rpc-url $LASNA | tr A-F a-f) == $(tr A-F a-f <<<"$INBOX") ]] ||
  send $PM "addInbox(uint256,address)" 84532 $INBOX --rpc-url $LASNA

step "4 household: payees, then the agent (which pushes its budget mirror to every vault)"
send $PM "setPayee(address,bool)" $PAYEE true --rpc-url $LASNA
send $PM "setPayee(address,bool)" $SELLER true --rpc-url $LASNA
[[ -n "${SUI_SHOP:-}" ]] && send $PM "setForeignPayee(bytes32,bool)" $SUI_SHOP true --rpc-url $LASNA
send $PM "setAgent(address,uint256)" $AGENT $ALLOWANCE --rpc-url $LASNA

echo; echo "Deployed. Saved to $OUT"; cat $OUT
