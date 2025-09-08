#!/bin/bash
set -e

echo "========================================"
echo "Fresh deployment of all packages"
echo "========================================"
echo ""

# All packages in dependency order
packages=(
    "futarchy_one_shot_utils"
    "futarchy_core"
    "futarchy_markets"
    "futarchy_vault"
    "futarchy_multisig"
    "futarchy_lifecycle"
    "futarchy_actions"
    "futarchy_specialized_actions"
    "futarchy_dao"
)

# First, reset all package addresses to 0x0
echo "Resetting all package addresses to 0x0..."
cd /Users/admin/monorepo/contracts
for pkg in "${packages[@]}"; do
    if [ -d "$pkg" ]; then
        echo "  Resetting $pkg..."
        sed -i '' "s/^${pkg} = \"0x[^\"]*\"/${pkg} = \"0x0\"/" "$pkg/Move.toml"
    fi
done

echo ""
echo "Starting deployment..."
echo ""

# Deploy each package
for pkg in "${packages[@]}"; do
    echo "========================================="
    echo "Deploying $pkg..."
    echo "========================================="
    
    cd "/Users/admin/monorepo/contracts/$pkg"
    
    # Build
    echo "Building $pkg..."
    sui move build --skip-fetch-latest-git-deps
    
    # Deploy
    echo "Publishing $pkg..."
    OUTPUT=$(sui client publish --gas-budget 5000000000 2>&1)
    
    # Extract package ID (try multiple patterns)
    PACKAGE_ID=$(echo "$OUTPUT" | grep -oE "PackageID: 0x[a-f0-9]{64}" | head -1 | cut -d' ' -f2)
    
    if [ -z "$PACKAGE_ID" ]; then
        PACKAGE_ID=$(echo "$OUTPUT" | grep -A5 "Published Objects" | grep -oE "0x[a-f0-9]{64}" | head -1)
    fi
    
    if [ -z "$PACKAGE_ID" ]; then
        PACKAGE_ID=$(echo "$OUTPUT" | grep "Success" -A20 | grep -oE "0x[a-f0-9]{64}" | head -1)
    fi
    
    if [ -z "$PACKAGE_ID" ]; then
        echo "❌ Failed to deploy $pkg"
        echo "$OUTPUT" | tail -50
        exit 1
    fi
    
    echo "✅ $pkg deployed: $PACKAGE_ID"
    
    # Update this package's address in ALL Move.toml files
    cd /Users/admin/monorepo/contracts
    for toml in */Move.toml; do
        if [ -f "$toml" ]; then
            sed -i '' "s/${pkg} = \"0x[^\"]*\"/${pkg} = \"${PACKAGE_ID}\"/" "$toml"
        fi
    done
    
    echo "Updated $pkg address in all packages"
    echo ""
done

echo "========================================="
echo "Deployment Complete!"
echo "========================================="
echo ""
echo "Final addresses:"
for pkg in "${packages[@]}"; do
    if [ -f "$pkg/Move.toml" ]; then
        address=$(grep "^$pkg = " "$pkg/Move.toml" | head -1 | cut -d'"' -f2)
        echo "$pkg: $address"
    fi
done