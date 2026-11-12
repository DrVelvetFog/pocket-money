# Shared helpers for the Pocket Money scripts (bash 3.2 safe). Source after `cd` to the repo root.
LASNA=https://lasna-rpc.rnk.dev/
rpc()  { case $1 in 84532) echo ${BASE_RPC:-https://sepolia.base.org};;
                   1301) echo ${UNI_RPC:-https://sepolia.unichain.org};;
                   11155111) echo ${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com};; esac; }
usdc() { case $1 in 84532) echo 0x036CbD53842c5426634e7929541eC2318f3dCF7e;;
                   1301) echo 0x31d0220469e10c4E71834a79b1f276d740d3768F;;
                   11155111) echo 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;; esac; }
# The chains this deployment has a vault on (all three unless you deployed fewer).
CHAINS=($({ grep -oE '^VAULT_[0-9]+' deployments/testnet.env 2>/dev/null || true; } | cut -d_ -f2))
(( ${#CHAINS[@]} )) || CHAINS=(84532 1301 11155111)

# key <keystore name>: decrypt a testnet key into stdout (captured by the caller, never shown)
key() {
  local p k
  read -rs -p "$1 keystore password: " p </dev/tty; echo >&2
  k=$(CAST_UNSAFE_PASSWORD="$p" cast wallet decrypt-keystore "$1" 2>/dev/null | grep -oE '0x[0-9a-fA-F]{64}' || true)
  [[ -n "$k" ]] || { echo "could not decrypt $1 (wrong password?)" >&2; exit 1; }
  printf '%s' "$k"
}

# owner_init: read the pm-owner password once into a mode-600 temp file; owner <cast send args>
owner_init() {
  OWNER_PW_DIR=$(mktemp -d); chmod 700 "$OWNER_PW_DIR"
  local p; read -rs -p "pm-owner keystore password: " p </dev/tty; echo >&2
  printf '%s' "$p" > "$OWNER_PW_DIR/o"; chmod 600 "$OWNER_PW_DIR/o"
}
owner() {
  local i out
  for i in 1 2 3 4; do
    out=$(cast send "$@" --account pm-owner --password-file "$OWNER_PW_DIR/o" --json 2>&1) &&
      { echo "   owner tx $(jq -r .transactionHash <<<"$out")"; return 0; }
    sleep 4
  done
  echo "$out" >&2; return 1
}

# Passwords for the unattended daily job (pm-agent, pm-seller; never pm-owner). On macOS they live in
# the login Keychain. Elsewhere they live in files only you can read, which is weaker: anyone who can
# read your home directory can read them. Testnet keys only. Stored by script/keychain-setup.sh.
PASS_DIR=${PM_PASS_DIR:-$HOME/.config/pocket-money}
is_mac() { [[ $(uname) == Darwin ]]; }
keypass() { if is_mac; then security find-generic-password -s pocket-money -a "$1" -w 2>/dev/null; else cat "$PASS_DIR/$1.pass" 2>/dev/null; fi; }
opens()   { local k; k=$(keypass "$1") && CAST_UNSAFE_PASSWORD="$k" cast wallet decrypt-keystore "$1" >/dev/null 2>&1; }

# wait_log <rpc> <from-block> <address> <event sig> [seconds] -> "tx block" of the newest match
wait_log() {
  local i out
  for ((i = 0; i < ${5:-120}; i++)); do
    out=$(cast logs --from-block $2 --address $3 "$4" --rpc-url $1 --json 2>/dev/null || echo '[]')
    [[ $(jq length <<<"$out") -gt 0 ]] && { jq -r '.[-1] | "\(.transactionHash) \(.blockNumber)"' <<<"$out"; return; }
    sleep 1
  done
  echo "none -"
}

# left <chain>: what the vault's budget mirror says the agent may still spend
left() { cast call $(eval echo \$VAULT_$1) "canSpend(address,uint256)(bool,uint256,bytes32)" $AGENT 1 --rpc-url $(rpc $1) | sed -n 2p | cut -d' ' -f1; }
