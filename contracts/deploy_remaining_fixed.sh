#!/bin/bash
set -e

echo "Deploying remaining packages with updated addresses..."

# Packages to deploy in order
packages=(
    "futarchy_vault"
    "futarchy_multisig"
    "futarchy_lifecycle"
    "futarchy_actions"
    "futarchy_specialized_actions"
    "futarchy_dao"
)

# Function to deploy a package
deploy_package() {
    local pkg=$1
    echo "========================================="
    echo "Deploying $pkg..."
    cd "/Users/admin/monorepo/contracts/$pkg"
    
    # Reset own address to 0x0
    sed -i '' "s/^${pkg} = \"0x[^\"]*\"/${pkg} = \"0x0\"/" Move.toml
    
    # Build first
    echo "Building $pkg..."
    if ! sui move build --skip-fetch-latest-git-deps; then
        echo "❌ Failed to build $pkg"
        return 1
    fi
    
    # Deploy
    echo "Publishing $pkg..."
    OUTPUT=$(sui client publish --gas-budget 3000000000 2>&1)
    
    # Extract package ID
    PACKAGE_ID=$(echo "$OUTPUT" | grep -oE "PackageID: 0x[a-f0-9]{64}" | head -1 | cut -d' ' -f2)
    
    if [ -z "$PACKAGE_ID" ]; then
        # Try alternative pattern
        PACKAGE_ID=$(echo "$OUTPUT" | grep -A5 "Published Objects" | grep -oE "0x[a-f0-9]{64}" | head -1)
    fi
    
    if [ -z "$PACKAGE_ID" ]; then
        echo "❌ Failed to deploy $pkg"
        echo "$OUTPUT" | tail -30
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
    sleep 2
    return 0
}

# Deploy each package
for package in "${packages[@]}"; do
    if deploy_package "$package"; then
        echo "✅ $package deployed successfully"
    else
        echo "❌ $package deployment failed"
        exit 1
    fi
done

echo ""
echo "========================================="
echo "All packages deployed successfully!"
echo "========================================="

# Display final addresses
echo ""
echo "Final package addresses:"
cd /Users/admin/monorepo/contracts
for pkg in futarchy_one_shot_utils futarchy_core futarchy_markets "${packages[@]}"; do
    if [ -f "$pkg/Move.toml" ]; then
        address=$(grep "^$pkg = " "$pkg/Move.toml" | head -1 | cut -d'"' -f2)
        echo "$pkg: $address"
    fi
done