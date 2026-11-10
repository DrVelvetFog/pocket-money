#!/usr/bin/env bash
# Verify the guard's receipt chain against the chains where the money actually moved. No keys.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source deployments/testnet.env; set +a
cd agent && exec npx tsx src/verify-receipts.ts
