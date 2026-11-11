#!/usr/bin/env bash
# Start (or stop) the live run.
#   script/go-live.sh           preflight -> turn on the guard's daily cron -> install the 08:00 job
#   script/go-live.sh --check   preflight only
#   script/go-live.sh --stop    remove the 08:00 job and turn the cron off
# Asks for the pm-owner password once (for setCron). Everything else is read-only or local.
set -euo pipefail
cd "$(dirname "$0")/.."
source script/lib.sh
set -a; source deployments/testnet.env; source deployments/wallets.env; set +a
REPO=$(pwd)
LABEL=com.uigstudios.pocketmoney.daily
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
MODE=${1:-start}

ok=1
check() { if eval "$2"; then echo "  ✓ $1"; else echo "  ✗ $1"; ok=0; fi; }
ge() { [[ $(echo "$1 >= $2" | bc) == 1 ]]; }

echo "== preflight"
g=$(cast balance $PM --rpc-url $LASNA --ether)
check "guard has ≥ 3 lREACT for 13 days of reactions (has $g)" "ge $g 3"
for c in "${CHAINS[@]}"; do
  V=$(eval echo \$VAULT_$c)
  e=$(cast balance $V --rpc-url $(rpc $c) --ether)
  u=$(cast call $(usdc $c) "balanceOf(address)(uint256)" $V --rpc-url $(rpc $c) | cut -d' ' -f1)
  check "vault on $c has callback gas ($e ETH) and ≥ \$3 USDC ($u)" "ge $e 0.0001 && (( u >= 3000000 ))"
  check "nothing frozen on $c" "[[ \$(cast call $V 'frozen()(bool)' --rpc-url $(rpc $c)) == false && \$(cast call $V 'agentFrozen(address)(bool)' $AGENT --rpc-url $(rpc $c)) == false ]]"
done
check "agent not quarantined, no panic" "[[ \$(cast call $PM 'panicked()(bool)' --rpc-url $LASNA) == false ]]"
opens() { local k; k=$(security find-generic-password -s pocket-money -a "$1" -w 2>/dev/null) && CAST_UNSAFE_PASSWORD="$k" cast wallet decrypt-keystore "$1" >/dev/null 2>&1; }
check "Keychain passwords open the pm-agent and pm-seller keystores" "opens pm-agent && opens pm-seller"
check "receipt chain verifies" "script/verify.sh >/dev/null 2>&1"
[[ $MODE == --check ]] && { (( ok )) && echo "ready." || echo "not ready."; exit $(( 1 - ok )); }

if [[ $MODE == --stop ]]; then
  launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true; rm -f "$PLIST"
  owner_init; trap 'rm -rf "$OWNER_PW_DIR"' EXIT
  owner $PM "setCron(bool)" false --rpc-url $LASNA
  echo "stopped: daily job removed, cron off."; exit 0
fi

(( ok )) || { echo "preflight failed; fix the ✗ lines (or run with --check to recheck)."; exit 1; }
owner_init; trap 'rm -rf "$OWNER_PW_DIR"' EXIT
echo "== cron on: the guard closes each day and prints its statement on Reactive's ~3h timer"
owner $PM "setCron(bool)" true --rpc-url $LASNA
echo "== installing the 08:00 job ($PLIST)"
mkdir -p "$HOME/Library/LaunchAgents" deployments/daily
sed "s#__REPO__#$REPO#g" deploy/$LABEL.plist > "$PLIST"
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$PLIST"
echo "live. First run: tomorrow 08:00 (or now: launchctl kickstart gui/$(id -u)/$LABEL)."
