#!/usr/bin/env bash
# Two sellers that know nothing about Pocket Money except each chain's registry address enforce
# one cross-chain budget:
#   1. the allowance is set to $0.30 on Reactive
#   2. the agent buys from seller B on Unichain, seller A on Base, seller B on Ethereum Sepolia
#   3. a 4th purchase, from seller B on Unichain, is refused before settling; nothing moves
#   4. the agent's own key can't lift or move its registry entry
# Seller B is a separate key (pm-seller2) on another port. Neither seller is given a vault address.
# Asks for the pm-seller, pm-seller2, pm-agent and pm-owner passwords once each.
set -euo pipefail
cd "$(dirname "$0")/.."
source script/lib.sh
exec > >(tee -a "deployments/registry-demo-$(date +%Y%m%d-%H%M%S).log") 2>&1
set -a; source deployments/testnet.env; source deployments/wallets.env; set +a
SMALL=${SMALL:-300000}; NORMAL=${NORMAL:-3000000}
for c in "${CHAINS[@]}"; do [[ -n "$(eval echo \${REGISTRY_$c:-})" ]] || { echo "no REGISTRY_$c; run script/deploy-registry.sh" >&2; exit 1; }; done
[[ -n "${SELLER2:-}" ]] || { echo "add SELLER2=<address> to deployments/wallets.env, then script/setup-seller.sh \$SELLER2" >&2; exit 1; }

A_PK=$(key pm-seller); B_PK=$(key pm-seller2); AGENT_PK=$(key pm-agent); export AGENT_PK
owner_init
novault() { env -u VAULT_84532 -u VAULT_1301 -u VAULT_11155111 "$@"; }
(cd agent && SELLER_PK=$A_PK PORT=4021 novault npx tsx src/seller.ts >../deployments/seller.log 2>&1) &
(cd agent && SELLER_PK=$B_PK PORT=4022 novault npx tsx src/seller.ts >../deployments/seller2.log 2>&1) &
trap 'rm -rf "$OWNER_PW_DIR"; pkill -f "tsx src/seller.ts" 2>/dev/null; true' EXIT
for p in 4021 4022; do for _ in $(seq 1 30); do curl -sf localhost:$p/health >/dev/null && break; sleep 1; done; done
echo "seller A: $(curl -s localhost:4021/health)"
echo "seller B: $(curl -s localhost:4022/health)"

bal() { cast call $(usdc $1) 'balanceOf(address)(uint256)' $AGENT --rpc-url $(rpc $1) | cut -d' ' -f1; }
buy() { # buy <port> <chain>
  local c=$2 out st lf cf tx
  lf=$(cast block-number --rpc-url $LASNA); cf=$(cast block-number --rpc-url $(rpc $c))
  out=$( (cd agent && SELLER_URL=http://localhost:$1 npx tsx src/agent.ts $c) 2>&1 || true)
  st=$(jq -r '.settlement.transaction // empty' <<<"$out" 2>/dev/null || true)
  if [[ -z "$st" ]]; then echo "   agent: $(tail -1 <<<"$out")"; return; fi
  echo "   origin    $st  (settled by $(cast tx $st from --rpc-url $(rpc $c)))"
  read -r tx _ <<<"$(wait_log $LASNA $lf $PM 'Spent(address indexed,uint256 indexed,bytes32 indexed,uint256,uint256,uint256,bytes32)')"
  echo "   reactive  $tx  (Lasna)"
  read -r tx _ <<<"$(wait_log $(rpc $c) $cf $(eval echo \$VAULT_$c) 'TopUp(address indexed,uint64 indexed,uint256,uint256,uint256)' 180)"
  echo "   callback  $tx"
}

echo; echo "================ 1. allowance set on Reactive so that \$0.30 is left today ================"
# The day window may already hold spending (an earlier demo), so set the allowance relative to it.
spent=$(cast call $PM "agents(address)(bool,bool,uint256,uint256,uint256)" $AGENT --rpc-url $LASNA | sed -n 4p | cut -d' ' -f1)
echo "   spent so far today: $spent; allowance -> $((spent + SMALL))"
owner $PM "setAgent(address,uint256)" $AGENT $((spent + SMALL)) --rpc-url $LASNA
for _ in $(seq 1 90); do [[ $(left 84532) == $SMALL && $(left 1301) == $SMALL && $(left 11155111) == $SMALL ]] && break; sleep 2; done
[[ $(left 1301) == $SMALL ]] || { echo "the mirrors did not reach $SMALL; stopping before any purchase" >&2; owner $PM "setAgent(address,uint256)" $AGENT $NORMAL --rpc-url $LASNA; exit 1; }
for c in "${CHAINS[@]}"; do echo "   mirror on $c says $(left $c) left"; done

echo; echo "================ 2. three \$0.10 purchases, two sellers, three chains ================"
echo "-- seller B, Unichain Sepolia";  buy 4022 1301
echo "-- seller A, Base Sepolia";      buy 4021 84532
echo "-- seller B, Ethereum Sepolia";  buy 4022 11155111

echo; echo "================ 3. a 4th purchase from seller B on Unichain: refused before settling ================"
for _ in $(seq 1 90); do [[ $(left 1301) == 0 ]] && break; sleep 2; done
echo "   mirror on Unichain says $(left 1301) left"
before=$(bal 1301); n=$(cast nonce $SELLER2 --rpc-url $(rpc 1301))
buy 4022 1301
grep -E '^refused' deployments/seller2.log | tail -1 | sed 's/^/   seller B: /'
echo "   agent USDC on Unichain: $before -> $(bal 1301)  (unchanged = nothing moved)"
echo "   seller B nonce on Unichain: $n -> $(cast nonce $SELLER2 --rpc-url $(rpc 1301))  (unchanged = it sent nothing)"

echo; echo "================ 4. the agent's own key can't touch its registry entry ================"
R=$REGISTRY_1301; Z=0x0000000000000000000000000000000000000000
try() { # try <label> <error name> <call...>: an eth_call from the agent's address; shows the revert
  local label=$1 err=$2 out; shift 2
  out=$(cast call $R "$@" --from $AGENT --rpc-url $(rpc 1301) 2>&1 || true)
  if grep -q "$(cast sig "$err(address)")" <<<"$out"; then echo "   $label reverts $err"; else echo "   $label: $out"; fi
}
try "setMirror(agent, 0) as the agent:   " NotController 'setMirror(address,address)' $AGENT $Z
try "bind(agent, 0) again as the agent:  " AlreadyBound 'bind(address,address)' $AGENT $Z
echo "   mirrorOf(agent) is still $(cast call $R 'mirrorOf(address)(address)' $AGENT --rpc-url $(rpc 1301))"

echo; echo "================ reset: back to the normal allowance ================"
owner $PM "setAgent(address,uint256)" $AGENT $NORMAL --rpc-url $LASNA
