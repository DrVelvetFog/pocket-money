#!/usr/bin/env bash
# Store the testnet keystore passwords the unattended daily job needs in your macOS login Keychain
# (service "pocket-money"). macOS prompts you for each one; nothing is written to disk or shown.
# Only pm-agent and pm-seller: owner actions (drills, resets) stay manual.
set -euo pipefail
for acct in pm-agent pm-seller; do
  echo "Password for the $acct keystore:"
  security add-generic-password -U -s pocket-money -a "$acct" -w
done
echo "Stored. Check with: security find-generic-password -s pocket-money -a pm-agent >/dev/null && echo ok"
