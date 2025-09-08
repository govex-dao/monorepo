#!/bin/bash
set -e

# Function to deploy a package
deploy_package() {
    local pkg=$1
    echo "========================================="
    echo "Deploying $pkg..."
    cd "/Users/admin/monorepo/contracts/$pkg"
    
    # Build first
    echo "Building $pkg..."
    if ! sui move build --skip-fetch-latest-git-deps; then
        echo "❌ Failed to build $pkg"
        return 1
    fi
    
    # Deploy and capture the package ID
    echo "Publishing $pkg..."
    OUTPUT=$(sui client publish --gas-budget 500000000 --skip-dependency-verification 2>&1)
    PACKAGE_ID=$(echo "$OUTPUT" | grep "PackageID:" | head -1 | awk '{print $2}')
    
    if [ -z "$PACKAGE_ID" ]; then
        echo "❌ Failed to deploy $pkg"
        echo "$OUTPUT" | tail -20
        return 1
    fi
    
    echo "✅ $pkg deployed: $PACKAGE_ID"
    
    # Update the package address in all Move.toml files
    cd /Users/admin/monorepo/contracts
    for toml in */Move.toml; do
        if [ -f "$toml" ]; then
            sed -i '' "s/${pkg} = \"0x[^\"]*\"/${pkg} = \"${PACKAGE_ID}\"/" "$toml"
        fi
    done
    
    echo "Updated $pkg address to $PACKAGE_ID in all packages"
    return 0
}

echo "Deployment Status:"
echo "=================="
echo "✅ futarchy_one_shot_utils: 0xa8371475984de44132d23773a571385695be80226bd944ad9cc598359fed1749"
echo "✅ futarchy_core: 0x28c40499699f98000b805f86714ecbd2f2cd548e26ae7f0525f4964ae39dfa8e"
echo "✅ futarchy_markets: 0x48e04b8974fb65f67bd9853154010b21eb3757f2271059b123b39ae73f39de2f"
echo ""
echo "Deploying remaining packages..."
echo ""

# Deploy the remaining packages in order
deploy_package "futarchy_vault"
deploy_package "futarchy_multisig"
deploy_package "futarchy_actions"
deploy_package "futarchy_specialized_actions"
deploy_package "futarchy_lifecycle"
deploy_package "futarchy_dao"

echo ""
echo "========================================="
echo "Deployment Summary:"
echo "========================================="
cd /Users/admin/monorepo/contracts
for pkg in futarchy_one_shot_utils futarchy_core futarchy_markets futarchy_vault futarchy_multisig futarchy_actions futarchy_specialized_actions futarchy_lifecycle futarchy_dao; do
    if [ -f "$pkg/Move.toml" ]; then
        address=$(grep "^$pkg = " "$pkg/Move.toml" | head -1 | cut -d'"' -f2)
        if [ "$address" = "0x0" ]; then
            echo "❌ $pkg: NOT DEPLOYED"
        else
            echo "✅ $pkg: $address"
        fi
    fi
done