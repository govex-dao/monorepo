#!/bin/bash
set -e

# Function to deploy a package
deploy_package() {
    local pkg=$1
    echo "Deploying $pkg..."
    cd "/Users/admin/monorepo/contracts/$pkg"
    
    # Deploy and capture the package ID
    OUTPUT=$(sui client publish --gas-budget 800000000 --skip-dependency-verification 2>&1)
    PACKAGE_ID=$(echo "$OUTPUT" | grep "PackageID:" | head -1 | awk '{print $2}')
    
    if [ -z "$PACKAGE_ID" ]; then
        echo "Failed to deploy $pkg"
        echo "$OUTPUT"
        exit 1
    fi
    
    echo "$pkg deployed: $PACKAGE_ID"
    
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

# Packages that have been deployed
echo "Already deployed:"
echo "futarchy_one_shot_utils: 0xa8371475984de44132d23773a571385695be80226bd944ad9cc598359fed1749"
echo "futarchy_core: 0x28c40499699f98000b805f86714ecbd2f2cd548e26ae7f0525f4964ae39dfa8e"
echo "futarchy_markets: 0x48e04b8974fb65f67bd9853154010b21eb3757f2271059b123b39ae73f39de2f"

# Deploy remaining packages in dependency order
echo ""
echo "Starting deployments..."

# Deploy futarchy_vault
deploy_package "futarchy_vault"

# Deploy futarchy_multisig
deploy_package "futarchy_multisig"

# Now try to build packages that depend on these
echo ""
echo "Building dependent packages..."

# Try to build futarchy_actions
cd /Users/admin/monorepo/contracts/futarchy_actions
echo "Building futarchy_actions..."
if sui move build --skip-fetch-latest-git-deps; then
    deploy_package "futarchy_actions"
else
    echo "futarchy_actions build failed, will retry after dependencies"
fi

# Try to build futarchy_specialized_actions
cd /Users/admin/monorepo/contracts/futarchy_specialized_actions
echo "Building futarchy_specialized_actions..."
if sui move build --skip-fetch-latest-git-deps; then
    deploy_package "futarchy_specialized_actions"
else
    echo "futarchy_specialized_actions build failed, will retry after dependencies"
fi

# Try to build futarchy_lifecycle
cd /Users/admin/monorepo/contracts/futarchy_lifecycle
echo "Building futarchy_lifecycle..."
if sui move build --skip-fetch-latest-git-deps; then
    deploy_package "futarchy_lifecycle"
else
    echo "futarchy_lifecycle build failed, will retry after dependencies"
fi

# Try to build futarchy_dao
cd /Users/admin/monorepo/contracts/futarchy_dao
echo "Building futarchy_dao..."
if sui move build --skip-fetch-latest-git-deps; then
    deploy_package "futarchy_dao"
else
    echo "futarchy_dao build failed"
fi

echo ""
echo "Deployment process completed!"
echo "Check above for any failures that need to be addressed."