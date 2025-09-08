#!/bin/bash
set -e

echo "Redeploying fixed packages..."

# First redeploy futarchy_actions since it was modified
echo "1. Redeploying futarchy_actions..."
cd /Users/admin/monorepo/contracts/futarchy_actions
sui client publish --gas-budget 3000000000 --skip-dependency-verification > deploy_result.txt 2>&1
if grep -q "Success" deploy_result.txt; then
    NEW_ADDR=$(grep -oE '0x[a-f0-9]{64}' deploy_result.txt | head -1)
    echo "   Deployed at: $NEW_ADDR"
    # Update the address in Move.toml
    sed -i '' "s/futarchy_actions = \"0x0\"/futarchy_actions = \"$NEW_ADDR\"/" Move.toml
else
    echo "   Failed to deploy futarchy_actions"
    cat deploy_result.txt
    exit 1
fi

# Then redeploy futarchy_dao which depends on the updated futarchy_actions
echo "2. Updating futarchy_dao with new futarchy_actions address..."
cd /Users/admin/monorepo/contracts/futarchy_dao
sed -i '' "s/futarchy_actions = \"0x[a-f0-9]*\"/futarchy_actions = \"$NEW_ADDR\"/" Move.toml

echo "3. Rebuilding futarchy_dao..."
sui move build

echo "Done! All packages updated with fixes."
