#!/bin/bash
set -e  # Exit on error

RPC_URL="http://127.0.0.1:8545"
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
CHAIN_ID=31337

echo "  Running DeployHook script..."
forge script script/DeployHook.s.sol \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast

# Path to the Foundry broadcast JSON
DEPLOY_JSON="broadcast/DeployHook.s.sol/$CHAIN_ID/run-latest.json"

# Extract the deployed address using jq (no head errors)
if command -v jq >/dev/null 2>&1; then
    CONTRACT_ADDRESS=$(jq -r '.transactions[0].contractAddress' "$DEPLOY_JSON")
else
    echo "⚠️  jq not installed — using grep/sed fallback"
    CONTRACT_ADDRESS=$(grep -m 1 '"contractAddress":' "$DEPLOY_JSON" | sed -E 's/.*"contractAddress": "([^"]+)".*/\1/')
fi

echo "  Hook deployed at: $CONTRACT_ADDRESS"

echo "  Running DemoSwap script..."
forge script script/DemoSwap.s.sol \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast

echo "🎉  Demo completed successfully!"
