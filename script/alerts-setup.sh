#!/usr/bin/env bash
# Get Pocket Money's alerts on your phone, through ntfy (https://ntfy.sh, free, no account).
#   script/alerts-setup.sh                  make a private topic, save it, send a test alert
#   script/alerts-setup.sh <address>        use your own push address instead (any URL that accepts a POST)
# What gets sent there: one plain line per alert (frozen agent, panic, low balances, new payments,
# a raise request). Never a key or a password. Anyone who knows the topic name can read those lines,
# so the name is random and stored where only you can read it.
set -euo pipefail
cd "$(dirname "$0")/.."
source script/lib.sh
mkdir -p "$PASS_DIR"; chmod 700 "$PASS_DIR"
url=${1:-$(cat "$PASS_DIR/alert-url" 2>/dev/null || true)}
[[ -n "$url" ]] || url="https://ntfy.sh/pocket-money-$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')"
(umask 077; printf '%s' "$url" > "$PASS_DIR/alert-url")
echo "Alerts will go to: $url"
if [[ $url == https://ntfy.sh/* ]]; then
  echo "On your phone: install the ntfy app, tap +, and subscribe to this topic:"
  echo "    ${url#https://ntfy.sh/}"
  read -r -p "Press Enter once you've subscribed, and a test alert will be sent. " _ </dev/tty
fi
if curl -fsS -m 10 -H "Title: Pocket Money" -d "Test alert: this is where Pocket Money will reach you." "$url" >/dev/null; then echo "  ✓ sent. Did your phone buzz?"
else echo "  ✗ could not reach $url"; exit 1; fi
echo "script/watch.sh uses it from now on; script/go-live.sh keeps a watcher running in the background."
