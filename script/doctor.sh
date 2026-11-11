#!/usr/bin/env bash
# Health check of a Pocket Money setup. Read-only: it sends nothing and asks for no password.
# Exit code 0 = healthy. Each ✗ says what to do about it.
set -uo pipefail
cd "$(dirname "$0")/.."
source script/lib.sh
[[ -f deployments/testnet.env && -f deployments/wallets.env ]] || { echo "No deployment here yet. Run ./quickstart."; exit 1; }
set -a; source deployments/testnet.env; source deployments/wallets.env; set +a
bad=0
ok()   { echo "  ✓ $1"; }
no()   { echo "  ✗ $1"; echo "      -> $2"; bad=1; }
warn() { echo "  ! $1"; echo "      -> $2"; }
ge() { [[ $(echo "$1 >= $2" | bc) == 1 ]]; }
low() { tr A-F a-f <<<"$1"; }
name() { case $1 in 84532) echo "Base Sepolia";; 1301) echo "Unichain Sepolia";; 11155111) echo "Ethereum Sepolia";; esac; }
usd() { printf '$%s' "$(echo "scale=2; $1 / 1000000" | bc | sed 's/^\./0./')"; }

echo "== guard (Reactive Lasna) $PM"
g=$(cast balance $PM --rpc-url $LASNA --ether 2>/dev/null) || { no "can't reach Reactive Lasna" "check your connection, or $LASNA"; exit 1; }
if ge $g 1; then ok "has $g lREACT to pay for reactions"
elif ge $g 0.2; then warn "only $g lREACT left" "top it up soon: send lREACT to $PM. When it runs out, top-ups stop (the agent keeps only its float)"
else no "only $g lREACT left: top-ups will stop" "send lREACT to $PM"; fi
[[ $(cast call $PM 'panicked()(bool)' --rpc-url $LASNA) == false ]] && ok "no panic" ||
  no "the household is in panic: everything is stopped" "when it's safe: resume() on the guard, then unfreeze() on each vault"
read -r _ q allow spent _ <<<"$(cast call $PM 'agents(address)(bool,bool,uint256,uint256,uint256)' $AGENT --rpc-url $LASNA | cut -d' ' -f1 | tr '\n' ' ')"
[[ $q == false ]] && ok "agent $AGENT is not quarantined" ||
  no "the agent is quarantined (it paid an address you hadn't approved)" "check the ledger, then resumeAgent($AGENT) on the guard and unfreezeAgent on each vault"
echo "    allowance $(usd $allow) a day, spent $(usd $spent) in the current day"
[[ $(cast call $PM 'approvedPayee(bytes32)(bool)' $(cast to-uint256 $SELLER) --rpc-url $LASNA) == true ]] && ok "the seller is an approved payee" ||
  warn "the seller $SELLER is not an approved payee" "paying it would freeze the agent: setPayee($SELLER, true) on the guard"

for c in "${CHAINS[@]}"; do
  V=$(eval echo \$VAULT_$c); R=$(rpc $c)
  echo "== $(name $c): vault $V"
  e=$(cast balance $V --rpc-url $R --ether 2>/dev/null) || { no "can't reach $(name $c)" "check $R"; continue; }
  ge $e 0.00005 && ok "vault has callback gas ($e ETH)" || no "vault is nearly out of callback gas ($e ETH)" "send a little ETH to $V; without it top-ups can't land"
  f=$(cast call $V 'floatOf(address)(uint256)' $AGENT --rpc-url $R | cut -d' ' -f1)
  u=$(cast call $(usdc $c) 'balanceOf(address)(uint256)' $V --rpc-url $R | cut -d' ' -f1)
  (( u >= f )) && ok "vault holds $(usd $u) (float is $(usd $f))" || no "vault holds $(usd $u), less than one float ($(usd $f))" "send USDC to $V, or wait for a CCTP refill from a sibling vault"
  a=$(cast call $(usdc $c) 'balanceOf(address)(uint256)' $AGENT --rpc-url $R | cut -d' ' -f1)
  (( a <= f )) && ok "agent holds $(usd $a), within its float" || warn "agent holds $(usd $a), more than its float $(usd $f)" "the float only caps top-ups; move the extra out if you didn't put it there on purpose"
  [[ $(cast call $V 'frozen()(bool)' --rpc-url $R) == false && $(cast call $V 'agentFrozen(address)(bool)' $AGENT --rpc-url $R) == false ]] && ok "not frozen" ||
    no "frozen on this chain" "after checking why: unfreeze() or unfreezeAgent($AGENT) on $V"
  echo "    mirror says $(usd $(left $c)) left to spend today"
  REG=$(eval echo \${REGISTRY_$c:-})
  if [[ -n "$REG" ]]; then
    [[ $(low $(cast call $REG 'mirrorOf(address)(address)' $AGENT --rpc-url $R)) == $(low $V) ]] && ok "registry points the agent at this vault" ||
      no "the registry does not point the agent at this vault" "run script/deploy-registry.sh, or setMirror($AGENT, $V) as the controller"
    [[ $(low $(cast call $REG 'controllerOf(address)(address)' $AGENT --rpc-url $R)) == $(low $OWNER) ]] && ok "the owner controls the registry entry" ||
      no "someone other than the owner controls the agent's registry entry" "if you didn't hand it over, treat the agent key as compromised"
  else warn "no registry on this chain" "other sellers can't find the limit here: run script/deploy-registry.sh"; fi
done

if [[ -n "${INBOX:-}" ]]; then
  echo "== Sui / Solana inbox $INBOX"
  [[ $(low $(cast call $PM 'inboxOf(uint256)(address)' 84532 --rpc-url $LASNA)) == $(low $INBOX) ]] && ok "the guard reads this inbox" ||
    no "the guard reads a different inbox" "addInbox(84532, $INBOX) on the guard"
fi

echo "== receipts"
if out=$(script/verify.sh 2>&1); then ok "$(grep -m1 VERIFIED <<<"$out" | cut -c1-60)"
else no "the receipt chain does not verify" "run script/verify.sh and read its output"; fi

echo; (( bad )) && echo "Problems found." || echo "Healthy."
exit $bad
