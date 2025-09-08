#!/bin/bash
set -e

echo "========================================"
echo "FRESH REDEPLOYMENT OF ALL PACKAGES"
echo "========================================"
echo ""

# Function to deploy and properly extract package ID
deploy_package() {
    local pkg_name=$1
    local pkg_path=$2
    local addr_name=${3:-$pkg_name}
    
    echo "----------------------------------------"
    echo "Deploying $pkg_name from $pkg_path..."
    cd "$pkg_path"
    
    # Reset own address to 0x0
    sed -i '' "s/^${addr_name} = \"0x[^\"]*\"/${addr_name} = \"0x0\"/" Move.toml
    
    # Build
    echo "Building..."
    sui move build --skip-fetch-latest-git-deps
    
    # Deploy and save full output
    echo "Publishing..."
    OUTPUT=$(sui client publish --gas-budget 5000000000 2>&1)
    
    # Try multiple patterns to extract the actual package ID
    # Look for the package ID in the transaction effects
    PKG_ID=$(echo "$OUTPUT" | grep -A 100 "Transaction Effects" | grep -B 5 "Owner: Immutable" | grep "Object ID:" | head -1 | awk '{print $3}')
    
    if [ -z "$PKG_ID" ]; then
        # Try alternative: look for Published Objects section
        PKG_ID=$(echo "$OUTPUT" | sed -n '/Published Objects/,/╰/p' | grep "PackageID:" | head -1 | awk '{print $2}')
    fi
    
    if [ -z "$PKG_ID" ]; then
        # Try another pattern
        PKG_ID=$(echo "$OUTPUT" | grep -E "│ Object ID:.*│ Version:.*│$" | head -1 | sed 's/.*Object ID: *//' | sed 's/ *│.*//')
    fi
    
    if [ -z "$PKG_ID" ] || [ "$PKG_ID" = "null" ]; then
        echo "❌ Failed to deploy $pkg_name"
        echo "Full output:"
        echo "$OUTPUT"
        return 1
    fi
    
    echo "✅ $pkg_name deployed: $PKG_ID"
    
    # Update address everywhere
    cd /Users/admin/monorepo/contracts
    find . -name "Move.toml" -exec sed -i '' "s/${addr_name} = \"0x[^\"]*\"/${addr_name} = \"${PKG_ID}\"/" {} \;
    
    echo ""
    return 0
}

echo "Starting fresh deployment..."
echo ""

# Deploy in dependency order
deploy_package "Kiosk" "/Users/admin/monorepo/contracts/move-framework/deps/kiosk" "kiosk" || exit 1
deploy_package "AccountExtensions" "/Users/admin/monorepo/contracts/move-framework/packages/extensions" "account_extensions" || exit 1
deploy_package "AccountProtocol" "/Users/admin/monorepo/contracts/move-framework/packages/protocol" "account_protocol" || exit 1
deploy_package "AccountActions" "/Users/admin/monorepo/contracts/move-framework/packages/actions" "account_actions" || exit 1

deploy_package "futarchy_one_shot_utils" "/Users/admin/monorepo/contracts/futarchy_one_shot_utils" || exit 1
deploy_package "futarchy_core" "/Users/admin/monorepo/contracts/futarchy_core" || exit 1
deploy_package "futarchy_markets" "/Users/admin/monorepo/contracts/futarchy_markets" || exit 1
deploy_package "futarchy_vault" "/Users/admin/monorepo/contracts/futarchy_vault" || exit 1
deploy_package "futarchy_multisig" "/Users/admin/monorepo/contracts/futarchy_multisig" || exit 1
deploy_package "futarchy_lifecycle" "/Users/admin/monorepo/contracts/futarchy_lifecycle" || exit 1
deploy_package "futarchy_actions" "/Users/admin/monorepo/contracts/futarchy_actions" || exit 1
deploy_package "futarchy_specialized_actions" "/Users/admin/monorepo/contracts/futarchy_specialized_actions" || exit 1
deploy_package "futarchy_dao" "/Users/admin/monorepo/contracts/futarchy_dao" || exit 1

echo "========================================"
echo "ALL PACKAGES DEPLOYED SUCCESSFULLY!"
echo "========================================"
echo ""

# Show final addresses
echo "Final deployment addresses:"
echo "==========================="
cd /Users/admin/monorepo/contracts
echo "Kiosk: $(grep 'kiosk = ' move-framework/deps/kiosk/Move.toml | cut -d'"' -f2)"
echo "AccountExtensions: $(grep 'account_extensions = ' move-framework/packages/extensions/Move.toml | cut -d'"' -f2)"
echo "AccountProtocol: $(grep 'account_protocol = ' move-framework/packages/protocol/Move.toml | cut -d'"' -f2)"
echo "AccountActions: $(grep 'account_actions = ' move-framework/packages/actions/Move.toml | cut -d'"' -f2)"
echo ""
for pkg in futarchy_one_shot_utils futarchy_core futarchy_markets futarchy_vault futarchy_multisig futarchy_lifecycle futarchy_actions futarchy_specialized_actions futarchy_dao; do
    if [ -f "$pkg/Move.toml" ]; then
        address=$(grep "^$pkg = " "$pkg/Move.toml" | head -1 | cut -d'"' -f2)
        echo "$pkg: $address"
    fi
done