#!/usr/bin/env bash
# How fast is the loop? For every EVM payment the guard has booked, read three public timestamps:
# the payment's block on its own chain, the guard's reaction on Reactive Lasna, and the top-up
# callback back on the payment's chain. Read-only; no keys. Block times are whole seconds, so each
# figure is good to about a second (and Lasna's clock can read a second behind the origin's).
set -euo pipefail
cd "$(dirname "$0")/.."
source script/lib.sh
set -a; source deployments/testnet.env; source deployments/wallets.env; set +a
FROM=${FROM_BLOCK:-$(grep -oE 'fromBlock: [0-9]+' dashboard/config.js | cut -d' ' -f2)}
ts() { cast block $2 --rpc-url $1 --json | jq -r '.timestamp' | xargs printf '%d'; }
name() { case $1 in 84532) echo Base;; 1301) echo Unichain;; 11155111) echo Ethereum;; esac; }
SPENT='Spent(address indexed,uint256 indexed,bytes32 indexed,uint256,uint256,uint256,bytes32)'
TOPUP='TopUp(address indexed,uint64 indexed,uint256,uint256,uint256)'
head=$(cast block-number --rpc-url $LASNA); logs='[]'
for ((a = FROM; a <= head; a += 20000)); do
  b=$((a + 19999)); (( b > head )) && b=$head
  logs=$(jq -s 'add' <(echo "$logs") <(cast logs --from-block $a --to-block $b --address $PM "$SPENT" --rpc-url $LASNA --json))
done
printf '%-9s %-12s %10s %10s\n' chain origin "to guard" "to top-up"; all=()
while read -r rtx rblock chain origin; do
  c=$((chain)); R=$(rpc $c); [[ -n "$R" ]] || continue
  ob=$(cast tx $origin blockNumber --rpc-url $R 2>/dev/null || true); [[ -n "$ob" ]] || continue  # Sui/Solana: no origin tx here
  t0=$(ts $R $ob); t1=$(ts $LASNA $((rblock)))
  tu=$(cast logs --from-block $ob --to-block $((ob + 150)) --address $(eval echo \$VAULT_$c) "$TOPUP" --rpc-url $R --json | jq -r '.[0].blockNumber // empty')
  if [[ -n "$tu" ]]; then t2=$(ts $R $((tu))); d2="$((t2 - t0)) s"; all+=($((t2 - t0))); else d2="none"; fi
  printf '%-9s %-12s %8s s %10s\n' "$(name $c)" "${origin:0:10}…" $((t1 - t0)) "$d2"
done < <(jq -r '.[] | "\(.transactionHash) \(.blockNumber) \(.topics[2]) 0x\(.data[66:130])"' <<<"$logs")
(( ${#all[@]} )) || { echo "no topped-up payments found"; exit 0; }
sorted=($(printf '%s\n' "${all[@]}" | sort -n)); n=${#sorted[@]}
echo; echo "payment to top-up, $n loops: median ${sorted[$((n / 2))]} s, fastest ${sorted[0]} s, slowest ${sorted[$((n - 1))]} s"
