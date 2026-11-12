#!/usr/bin/env bash
# Replace a seller key. Everything the old key was allowed to do is moved to the new one, and the
# old one is revoked on the guard.
#   script/rotate-seller.sh seller2   pm-seller2: the second x402 seller
#   script/rotate-seller.sh seller    pm-seller: the x402 shop and CCTP relayer, and ALSO the
#                                     SpendInbox attester and the Sui and Solana shop addresses
# Before running, move the old keystore aside and create the new one under the same name:
#   mv ~/.foundry/keystores/pm-seller ~/.foundry/keystores/pm-seller-old
#   cast wallet new ~/.foundry/keystores pm-seller
# What it does:
#   - funds the new address with settlement gas on each chain, approves it as a payee, and
#     un-approves the old one
#   - for `seller`: approves the new Sui and Solana shops and un-approves the old ones; deploys a
#     new SpendInbox whose attester is the new key and points the guard at it (the attester is
#     immutable, and the guard ignores any inbox but the current one); rewrites dashboard/config.js
# The old address keeps whatever testnet USDC and gas it holds. Asks for the new keystore's
# password and the pm-owner password once each.
set -euo pipefail
cd "$(dirname "$0")/.."
source script/lib.sh
WHICH=${1:-}; [[ $WHICH == seller || $WHICH == seller2 ]] || { sed -n 2,16p "$0"; exit 1; }
exec > >(tee -a "deployments/rotate-$WHICH-$(date +%Y%m%d-%H%M%S).log") 2>&1
set -a; source deployments/testnet.env; source deployments/wallets.env; set +a
[[ $WHICH == seller ]] && { KS=pm-seller; VAR=SELLER; } || { KS=pm-seller2; VAR=SELLER2; }
OLD=$(eval echo \$$VAR)
gas() { case $1 in 84532) echo 0.00005ether;; 1301) echo 0.0002ether;; 11155111) echo 0.0005ether;; esac; }
setenv() { # setenv <file> <NAME> <value>: replace the line in place
  grep -q "^$2=" "$1" || { echo "$2 is not in $1" >&2; exit 1; }
  sed -i '' "s|^$2=.*|$2=$3|" "$1"
}
retire() { # retire <NAME> <old value>: remember a rotated-out address so the dashboard can still label past payments
  grep -q "^$1_OLD=" deployments/wallets.env && sed -i '' "s|^$1_OLD=.*|$1_OLD=$2|" deployments/wallets.env || echo "$1_OLD=$2" >> deployments/wallets.env
}
lower() { tr A-F a-f <<<"$1"; }

SELLER_PK=$(key $KS); export SELLER_PK
new=$(cd agent && npx tsx src/shop-addresses.ts); unset SELLER_PK
NEW=$(grep '^SELLER=' <<<"$new" | cut -d= -f2)
[[ $(lower $NEW) != $(lower $OLD) ]] || { echo "$KS still holds the old key ($OLD). Create the new keystore first." >&2; exit 1; }
echo "$VAR: $OLD -> $NEW"
owner_init; trap 'rm -rf "$OWNER_PW_DIR"' EXIT

for c in "${CHAINS[@]}"; do
  echo "== settlement gas on $c"
  owner $NEW --value $(gas $c) --rpc-url $(rpc $c)
done
echo "== guard: approve the new payee, un-approve the old one"
owner $PM "setPayee(address,bool)" $NEW true --rpc-url $LASNA
owner $PM "setPayee(address,bool)" $OLD false --rpc-url $LASNA
retire $VAR $OLD; setenv deployments/wallets.env $VAR $NEW

if [[ $WHICH == seller ]]; then
  for k in SUI_SHOP SOL_SHOP_ID; do
    n=$(grep "^$k=" <<<"$new" | cut -d= -f2); o=$(eval echo \${$k:-})
    echo "== guard: $k $o -> $n"
    owner $PM "setForeignPayee(bytes32,bool)" $n true --rpc-url $LASNA
    [[ -n "$o" ]] && owner $PM "setForeignPayee(bytes32,bool)" $o false --rpc-url $LASNA
    [[ -n "$o" ]] && retire $k $o; setenv deployments/wallets.env $k $n
  done
  setenv deployments/wallets.env SOL_SHOP "$(grep '^SOL_SHOP=' <<<"$new" | cut -d= -f2)"

  echo "== new SpendInbox on Base Sepolia, attester = the new key"
  NEW_INBOX=$(forge create src/SpendInbox.sol:SpendInbox --rpc-url $(rpc 84532) --account pm-owner \
    --password-file "$OWNER_PW_DIR/o" --broadcast --json --constructor-args $NEW | jq -r .deployedTo)
  echo "   inbox $INBOX -> $NEW_INBOX"
  owner $PM "addInbox(uint256,address)" 84532 $NEW_INBOX --rpc-url $LASNA
  setenv deployments/testnet.env INBOX $NEW_INBOX
  script/dashboard-config.sh
fi

echo; echo "== check"
ok() { [[ $(lower "$2") == $(lower "$3") ]] && echo "  ✓ $1" || echo "  ✗ $1 (got $2, want $3)"; }
id() { cast to-uint256 $1; }
ok "new payee approved" "$(cast call $PM 'approvedPayee(bytes32)(bool)' $(id $NEW) --rpc-url $LASNA)" true
ok "old payee revoked"  "$(cast call $PM 'approvedPayee(bytes32)(bool)' $(id $OLD) --rpc-url $LASNA)" false
if [[ $WHICH == seller ]]; then
  ok "guard reads the new inbox" "$(cast call $PM 'inboxOf(uint256)(address)' 84532 --rpc-url $LASNA)" $NEW_INBOX
  ok "new inbox's attester is the new key" "$(cast call $NEW_INBOX 'attester()(address)' --rpc-url $(rpc 84532))" $NEW
  if opens pm-seller; then echo "  ✓ the stored password opens the new pm-seller keystore (the daily job will work)"
  else echo "  ✗ the stored password does NOT open the new pm-seller keystore: run script/keychain-setup.sh"; fi
fi
