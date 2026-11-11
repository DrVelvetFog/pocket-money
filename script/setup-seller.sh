#!/usr/bin/env bash
# One-time: fund the pm-seller testnet key with settlement gas on each chain and add it to the
# guard's approved payees. Run after `cast wallet new ~/.foundry/keystores pm-seller`.
#   script/setup-seller.sh [address]     default: SELLER from deployments/wallets.env
# Asks for the pm-owner password once (mode-600 temp file, deleted on exit).
set -euo pipefail
cd "$(dirname "$0")/.."
source deployments/testnet.env
LASNA=https://lasna-rpc.rnk.dev/
rpc() { case $1 in 84532) echo ${BASE_RPC:-https://sepolia.base.org};;
                  1301) echo ${UNI_RPC:-https://sepolia.unichain.org};;
                  11155111) echo ${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com};; esac; }
gas() { case $1 in 84532) echo 0.00005ether;; 1301) echo 0.0002ether;; 11155111) echo 0.0005ether;; esac; }

source deployments/wallets.env  # SELLER= is added after `cast wallet new` prints the address
SELLER=${1:-${SELLER:-}}
[[ -n "${SELLER:-}" ]] || { echo "add SELLER=<address> to deployments/wallets.env first" >&2; exit 1; }
echo "seller $SELLER"

d=$(mktemp -d); chmod 700 "$d"; trap 'rm -rf "$d"' EXIT
read -rs -p "pm-owner keystore password: " p; echo; printf '%s' "$p" > "$d/o"; unset p; chmod 600 "$d/o"
send() { for i in 1 2 3 4; do out=$(cast send "$@" --account pm-owner --password-file "$d/o" --json 2>&1) &&
  { jq -r '"   tx \(.transactionHash) status \(.status)"' <<<"$out"; return 0; }; sleep 4; done; echo "$out" >&2; return 1; }

for c in $(grep -oE '^VAULT_[0-9]+' deployments/testnet.env | cut -d_ -f2); do
  echo "== settlement gas on $c"
  send $SELLER --value $(gas $c) --rpc-url $(rpc $c)
done
echo "== approve the seller as a payee on the guard"
send $PM "setPayee(address,bool)" $SELLER true --rpc-url $LASNA
