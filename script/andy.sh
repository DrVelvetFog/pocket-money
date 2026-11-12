#!/usr/bin/env bash
# Let a real model run an errand under Pocket Money: it checks its budget, buys over x402, and if the
# shop refuses it for being over budget it asks you for a raise and waits for your answer.
#   script/andy.sh                      "Buy today's BTC report and tell me what it says."
#   script/andy.sh "your own errand"
# The model runs on this machine through Ollama (https://ollama.com), hermes3 by default:
#   ANDY_MODEL=<an Ollama model with tool support> script/andy.sh
#   ANDY_MODEL=claude script/andy.sh    Claude instead; needs ANTHROPIC_API_KEY in your environment
# The model never sees a key: it can only call the four tools in agent/src/andy.ts. A raise request
# is signed by the agent's key and shown at the owner's desk on the passbook, and on your phone if
# you ran script/alerts-setup.sh. Uses the stored pm-agent and pm-seller passwords, or asks.
set -euo pipefail
cd "$(dirname "$0")/.."
source script/lib.sh
set -a; source deployments/testnet.env; source deployments/wallets.env; set +a
PORT=${PORT:-4021}; MODEL=${ANDY_MODEL:-hermes3}
TASK=${1:-}; [[ -n "$TASK" ]] || TASK="Buy today's BTC report and tell me what it says."
if [[ $MODEL != claude* ]]; then
  curl -sf -m 3 "${OLLAMA_HOST:-http://localhost:11434}/api/tags" | grep -q "\"$MODEL" ||
    { echo "Ollama isn't running here, or it doesn't have \"$MODEL\". Install it from https://ollama.com, then: ollama pull $MODEL"; exit 1; }
elif [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then echo "ANDY_MODEL=claude needs ANTHROPIC_API_KEY in your environment."; exit 1; fi
SELLER_PK=$(unlock pm-seller); AGENT_PK=$(unlock pm-agent); export SELLER_PK AGENT_PK
(cd agent && PORT=$PORT exec npx tsx src/seller.ts >>../deployments/andy-seller.log 2>&1) &
trap 'pkill -f "tsx src/seller.ts" 2>/dev/null; true' EXIT
for _ in $(seq 1 60); do curl -sf localhost:$PORT/health >/dev/null && break; sleep 1; done
cd agent
ANDY_MODEL=$MODEL ALERT_URL=$(alert_url) AGENT_NAME=${AGENT_NAME:-Andy} DASHBOARD_URL=${DASHBOARD_URL:-http://localhost:4173} \
  SELLER_URL=http://localhost:$PORT npx tsx src/andy.ts "$TASK"
