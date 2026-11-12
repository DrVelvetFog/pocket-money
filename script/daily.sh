#!/usr/bin/env bash
# The agent's morning job, run unattended once a day during the live run:
#   start the x402 seller and the CCTP relayer -> the agent buys the BTC report on today's chain
#   (rotating Base / Unichain / Ethereum Sepolia) -> wait for Reactive's top-up -> verify the whole
#   receipt chain -> write deployments/daily/<date>.json -> stop everything.
# Keystore passwords come from script/keychain-setup.sh: the macOS login Keychain, or on Linux a
# private file (see keypass in script/lib.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
source script/lib.sh
set -a; source deployments/testnet.env; source deployments/wallets.env; set +a
export PATH="$HOME/.foundry/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
DAY=$(date +%Y-%m-%d); OUT=deployments/daily/$DAY.json; mkdir -p deployments/daily
exec > >(tee -a "deployments/daily/$DAY.log") 2>&1
PORT=${PORT:-4021}

kc() { keypass "$1" || { echo "no stored password for $1 (run script/keychain-setup.sh)" >&2; exit 1; }; }
unlock() { local k; k=$(CAST_UNSAFE_PASSWORD="$(kc "$1")" cast wallet decrypt-keystore "$1" 2>/dev/null | grep -oE '0x[0-9a-fA-F]{64}' || true)
  [[ -n "$k" ]] || { echo "could not unlock $1" >&2; exit 1; }; printf '%s' "$k"; }
SELLER_PK=$(unlock pm-seller); AGENT_PK=$(unlock pm-agent); export SELLER_PK AGENT_PK; export RELAYER_PK=$SELLER_PK

# exec: no wrapper shell is left behind to print "Terminated" when the job stops these at the end
(cd agent && PORT=$PORT exec npx tsx src/seller.ts >>../deployments/daily/$DAY-seller.log 2>&1) &
(cd agent && exec npx tsx src/relayer.ts >>../deployments/daily/$DAY-relayer.log 2>&1) &
trap 'pkill -f "tsx src/seller.ts" 2>/dev/null; pkill -f "tsx src/relayer.ts" 2>/dev/null; true' EXIT
for _ in $(seq 1 60); do curl -sf localhost:$PORT/health >/dev/null && break; sleep 1; done

idx=$(( 10#$(date +%j) % ${#CHAINS[@]} )); CHAIN=${CHAIN:-${CHAINS[$idx]}}
before=$(left $CHAIN); cf=$(cast block-number --rpc-url $(rpc $CHAIN)); V=$(eval echo \$VAULT_$CHAIN)
echo "== $DAY: buying the morning report on $CHAIN (mirror says $before left)"
buy=$( (cd agent && SELLER_URL=http://localhost:$PORT npx tsx src/agent.ts $CHAIN) 2>&1 || true)
settled=$(jq -r '.settlement.transaction // empty' <<<"$buy" 2>/dev/null || true)
read -r topup _ <<<"$(wait_log $(rpc $CHAIN) $cf $V 'TopUp(address indexed,uint64 indexed,uint256,uint256,uint256)' 180)"
sleep 20 # let any CCTP refill land before verifying
verify=$(script/verify.sh 2>&1 | tail -2 | tr '\n' ' ' || true)

jq -n --arg day "$DAY" --arg chain "$CHAIN" --arg settled "$settled" --arg topup "$topup" \
  --arg before "$before" --arg after "$(left $CHAIN)" --arg verify "$verify" \
  --argjson report "$(jq '.report // null' <<<"$buy" 2>/dev/null || echo null)" \
  --arg refusal "$(grep -o 'seller said .*' <<<"$buy" || true)" \
  '{day:$day, chain:($chain|tonumber), report:$report, settlement:$settled, topUp:$topup,
    mirrorBefore:$before, mirrorAfter:$after, refusal:$refusal, verify:$verify}' > "$OUT"
cat "$OUT"
echo "== done. Saved to $OUT; the seller and relayer are stopped."
