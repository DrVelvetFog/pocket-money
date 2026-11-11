#!/usr/bin/env bash
# Deploy a SpendLimitRegistry on each chain and bind the agent to its vault there.
#   the owner deploys -> the agent signs Bind(agent, owner) for that registry (no transaction)
#   -> the owner submits bindWithSig(agent, vault, sig)
# After this any x402 facilitator can find the agent's limit with registry.mirrorOf(agent).
# The guard and the vaults are not touched. Asks for the pm-agent and pm-owner passwords once.
set -euo pipefail
cd "$(dirname "$0")/.."
source script/lib.sh
exec > >(tee -a "deployments/registry-deploy-$(date +%Y%m%d-%H%M%S).log") 2>&1
set -a; source deployments/testnet.env; source deployments/wallets.env; set +a
AGENT_PK=$(key pm-agent); export AGENT_PK
owner_init; trap 'rm -rf "$OWNER_PW_DIR"' EXIT

for c in "${CHAINS[@]}"; do
  V=$(eval echo \$VAULT_$c); R=$(eval echo \${REGISTRY_$c:-})
  echo; echo "================ chain $c ================"
  if [[ -z "$R" ]]; then
    R=$(forge create src/SpendLimitRegistry.sol:SpendLimitRegistry --rpc-url $(rpc $c) --account pm-owner \
      --password-file "$OWNER_PW_DIR/o" --broadcast --json | jq -r .deployedTo)
    echo "REGISTRY_$c=$R" >> deployments/testnet.env
  fi
  echo "registry  $R"
  if [[ $(cast call $R "controllerOf(address)(address)" $AGENT --rpc-url $(rpc $c)) == 0x0000000000000000000000000000000000000000 ]]; then
    sig=$(cd agent && npx tsx src/bind.ts $c $R $OWNER)
    echo "agent nonce before: $(cast nonce $AGENT --rpc-url $(rpc $c))"
    owner $R "bindWithSig(address,address,bytes)" $AGENT $V $sig --rpc-url $(rpc $c)
    echo "agent nonce after:  $(cast nonce $AGENT --rpc-url $(rpc $c))  (unchanged = the agent sent nothing)"
  fi
  echo "controllerOf(agent) = $(cast call $R "controllerOf(address)(address)" $AGENT --rpc-url $(rpc $c))  (owner $OWNER)"
  echo "mirrorOf(agent)     = $(cast call $R "mirrorOf(address)(address)" $AGENT --rpc-url $(rpc $c))  (vault $V)"
done
