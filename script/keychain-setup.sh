#!/usr/bin/env bash
# Store the two testnet keystore passwords the unattended daily job needs (pm-agent, pm-seller).
# Owner actions (drills, resets, limits) stay manual: the pm-owner password is never stored.
#   macOS:  your login Keychain (service "pocket-money"). macOS prompts; nothing is written to disk.
#   Linux:  ~/.config/pocket-money/<key>.pass, readable only by you. That is weaker than a keychain:
#           anyone who can read your home directory can read it. Use it for testnet keys only.
set -euo pipefail
cd "$(dirname "$0")/.."
source script/lib.sh
for acct in pm-agent pm-seller; do
  echo "Password for the $acct keystore:"
  if is_mac; then security add-generic-password -U -s pocket-money -a "$acct" -w
  else
    mkdir -p "$PASS_DIR"; chmod 700 "$PASS_DIR"
    read -rs p </dev/tty; echo
    (umask 077; printf '%s' "$p" > "$PASS_DIR/$acct.pass"); unset p
  fi
  opens "$acct" && echo "  ✓ stored, and it opens $acct" ||
    { is_mac || rm -f "$PASS_DIR/$acct.pass"; echo "  ✗ that password does not open $acct; run this again"; exit 1; }
done
