#!/bin/bash
set -e

echo "==============================================="
echo "FINAL DEPLOYMENT SCRIPT"
echo "==============================================="
echo ""

# Function to deploy and update addresses
deploy() {
    local pkg=$1
    echo "----------------------------------------"
    echo "Deploying $pkg..."
    cd "/Users/admin/monorepo/contracts/$pkg"
    
    # Build first
    echo "Building $pkg..."
    sui move build --skip-fetch-latest-git-deps
    
    # Deploy
    echo "Publishing $pkg..."
    OUTPUT=$(sui client publish --gas-budget 500000000 --skip-dependency-verification 2>&1)
    PKG_ID=$(echo "$OUTPUT" | grep "PackageID" | head -1 | awk '{print $3}')
    
    if [ -z "$PKG_ID" ]; then
        echo "❌ Failed to deploy $pkg"
        return 1
    fi
    
    echo "✅ $pkg deployed: $PKG_ID"
    
    # Update in all packages
    cd /Users/admin/monorepo/contracts
    for toml in */Move.toml; do
        sed -i '' "s/${pkg} = \"0x[^\"]*\"/${pkg} = \"${PKG_ID}\"/" "$toml"
    done
    
    return 0
}

# Packages already deployed
echo "Already deployed:"
echo "✅ futarchy_one_shot_utils: 0xa8371475984de44132d23773a571385695be80226bd944ad9cc598359fed1749"
echo "✅ futarchy_core: 0x28c40499699f98000b805f86714ecbd2f2cd548e26ae7f0525f4964ae39dfa8e"
echo "✅ futarchy_markets: 0x48e04b8974fb65f67bd9853154010b21eb3757f2271059b123b39ae73f39de2f"
echo "✅ futarchy_vault: 0xcbcc984a31011e78ba4db7eee897ba0179c771b17de42fea5f058971dc87e7f8"
echo "✅ futarchy_multisig: 0x712bd791034894a9fe6b72c69aa740a840ecf1621a43a40020cfcb744191ccbb"
echo ""

# Deploy remaining packages
# First, futarchy_lifecycle (no remaining dependencies)
deploy "futarchy_lifecycle"

# Then futarchy_actions (depends on lifecycle)
deploy "futarchy_actions"

# Then futarchy_specialized_actions (depends on actions)
deploy "futarchy_specialized_actions"

# Finally futarchy_dao (depends on all others)
deploy "futarchy_dao"

echo ""
echo "==============================================="
echo "DEPLOYMENT COMPLETE!"
echo "==============================================="