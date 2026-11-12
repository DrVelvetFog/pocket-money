#!/usr/bin/env bash
# Tell me when something needs me: the agent was frozen or quarantined, someone hit panic, the
# guard is running out of lREACT, a vault is running out of USDC or callback gas, or a payment
# was booked. Read-only; no passwords.
#   script/watch.sh            check every 60 seconds until stopped
#   script/watch.sh --once     check once (for cron or launchd)
# Alerts go to the terminal and to a macOS notification. To also get them on your phone, run
# script/alerts-setup.sh once (or set ALERT_URL=https://ntfy.sh/<a-topic-only-you-know>); each alert
# is then POSTed there as plain text. Only the alert line is sent: no keys.
set -uo pipefail
cd "$(dirname "$0")/.."
source script/lib.sh
set -a; source deployments/testnet.env; source deployments/wallets.env; set +a
STATE=deployments/.watch-state; EVERY=${EVERY:-60}; ALERT_URL=$(alert_url)
ge() { [[ $(echo "$1 >= $2" | bc) == 1 ]]; }
name() { case $1 in 84532) echo "Base Sepolia";; 1301) echo "Unichain Sepolia";; 11155111) echo "Ethereum Sepolia";; esac; }
usd() { printf '$%s' "$(echo "scale=2; $1 / 1000000" | bc | sed 's/^\./0./')"; }
alert() {
  echo "$(date '+%Y-%m-%d %H:%M')  $1"
  command -v osascript >/dev/null && osascript -e "display notification \"${1//\"/}\" with title \"Pocket Money\"" 2>/dev/null
  [[ -n "${ALERT_URL:-}" ]] && curl -fsS -m 10 -d "Pocket Money: $1" "$ALERT_URL" >/dev/null 2>&1
  return 0
}
# flag <key> <1|0> <message when it turns on> [message when it clears]: alert on change only
flag() {
  local was; was=$(grep "^$1=" $STATE 2>/dev/null | cut -d= -f2)
  [[ "$2" == "${was:-0}" ]] && return
  [[ $2 == 1 ]] && alert "$3" || { [[ -n "${4:-}" ]] && alert "$4"; }
  { grep -v "^$1=" $STATE 2>/dev/null; echo "$1=$2"; } > $STATE.tmp && mv $STATE.tmp $STATE
}
check() {
  local g q n c V R u f e
  g=$(cast balance $PM --rpc-url $LASNA --ether 2>/dev/null) || { flag rpc 1 "can't reach Reactive Lasna"; return; }
  flag rpc 0 "" "Reactive Lasna is reachable again"
  flag lreact $(ge $g 0.5 && echo 0 || echo 1) "the guard has only $g lREACT left; top-ups stop when it runs out. Send lREACT to $PM" "the guard's lREACT is topped up ($g)"
  flag panic $([[ $(cast call $PM 'panicked()(bool)' --rpc-url $LASNA) == true ]] && echo 1 || echo 0) "PANIC: the household is stopped on every chain" "panic lifted on the guard"
  q=$(cast call $PM 'agents(address)(bool,bool,uint256,uint256,uint256)' $AGENT --rpc-url $LASNA | sed -n 2p)
  flag quarantine $([[ $q == true ]] && echo 1 || echo 0) "the agent paid an address you hadn't approved and is quarantined on every chain" "the agent is out of quarantine"
  n=$(cast call $PM 'receiptCount()(uint256)' --rpc-url $LASNA | cut -d' ' -f1)
  local was; was=$(grep "^receipts=" $STATE 2>/dev/null | cut -d= -f2)
  if [[ -n "$was" && "$n" != "$was" ]]; then alert "$((n - was)) new payment(s) booked; $(usd $(left ${CHAINS[0]})) left today"; fi
  { grep -v "^receipts=" $STATE 2>/dev/null; echo "receipts=$n"; } > $STATE.tmp && mv $STATE.tmp $STATE
  for c in "${CHAINS[@]}"; do
    V=$(eval echo \$VAULT_$c); R=$(rpc $c)
    u=$(cast call $(usdc $c) 'balanceOf(address)(uint256)' $V --rpc-url $R 2>/dev/null | cut -d' ' -f1) || continue
    f=$(cast call $V 'floatOf(address)(uint256)' $AGENT --rpc-url $R | cut -d' ' -f1)
    e=$(cast balance $V --rpc-url $R --ether)
    flag usdc_$c $(( u < f ? 1 : 0 )) "the $(name $c) vault holds $(usd $u), less than one float; top-ups there will stop" "the $(name $c) vault is refilled"
    flag gas_$c $(ge $e 0.00005 && echo 0 || echo 1) "the $(name $c) vault is nearly out of callback gas ($e ETH). Send a little ETH to $V" "the $(name $c) vault has callback gas again"
    flag frozen_$c $([[ $(cast call $V 'frozen()(bool)' --rpc-url $R) == true || $(cast call $V 'agentFrozen(address)(bool)' $AGENT --rpc-url $R) == true ]] && echo 1 || echo 0) \
      "frozen on $(name $c)" "unfrozen on $(name $c)"
  done
}
touch $STATE
if [[ ${1:-} == --once ]]; then check; else echo "watching (every ${EVERY}s; Ctrl-C to stop)"; while true; do check; sleep $EVERY; done; fi
