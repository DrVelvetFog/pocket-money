#!/usr/bin/env bash
# Run every live loop once, end to end, and leave the system un-frozen and ready.
# Asks for the pm-agent and pm-owner keystore passwords once each (kept in a mode-600 temp dir,
# deleted on exit).
set -euo pipefail
cd "$(dirname "$0")/.."
source deployments/testnet.env
LASNA=https://lasna-rpc.rnk.dev/
rpc() { case $1 in 84532) echo ${BASE_RPC:-https://sepolia.base.org};;
                  1301) echo ${UNI_RPC:-https://sepolia.unichain.org};;
                  11155111) echo ${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com};; esac; }

d=$(mktemp -d); chmod 700 "$d"; trap 'rm -rf "$d"' EXIT
read -rs -p "pm-agent keystore password: " p; echo; printf '%s' "$p" > "$d/a"
read -rs -p "pm-owner keystore password: " p; echo; printf '%s' "$p" > "$d/o"; unset p
chmod 600 "$d"/*
export PM_AGENT_PW_FILE="$d/a" PM_OWNER_PW_FILE="$d/o"
OWN=(--account pm-owner --password-file "$d/o")
owner() { for i in 1 2 3 4; do cast send "$@" "${OWN[@]}" --json >/dev/null 2>&1 && return 0; sleep 4; done; echo "owner tx failed: $*" >&2; return 1; }

hr() { echo; echo "================ $* ================"; }

hr "loop 1: spend -> top-up, on each chain"
for c in 84532 1301 11155111; do ./script/loop.sh spend $c 250000; echo; done

hr "loop 2: unknown payee -> agent frozen on every chain"
./script/loop.sh stray 1301 250000

hr "reset: lift the agent's quarantine"
owner $PM "resumeAgent(address)" $AGENT --rpc-url $LASNA
for c in 84532 1301 11155111; do owner $(eval echo \$VAULT_$c) "unfreezeAgent(address)" $AGENT --rpc-url $(rpc $c); done
echo "done"

hr "loop 3: panic on one chain -> every vault frozen"
./script/loop.sh panic 11155111

hr "reset: lift the panic"
owner $PM "resume()" --rpc-url $LASNA
for c in 84532 1301 11155111; do owner $(eval echo \$VAULT_$c) "unfreeze()" --rpc-url $(rpc $c); done
echo "done"
