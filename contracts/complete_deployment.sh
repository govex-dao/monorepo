#!/bin/bash
set -e

echo "========================================"
echo "Complete deployment of all packages"
echo "========================================"
echo ""

# Function to deploy and update addresses
deploy_package() {
    local pkg_name=$1
    local pkg_path=$2
    local addr_name=${3:-$pkg_name}
    
    echo "Deploying $pkg_name from $pkg_path..."
    cd "$pkg_path"
    
    # Reset own address to 0x0
    sed -i '' "s/^${addr_name} = \"0x[^\"]*\"/${addr_name} = \"0x0\"/" Move.toml
    
    # Build
    sui move build --skip-fetch-latest-git-deps
    
    # Deploy
    OUTPUT=$(sui client publish --gas-budget 5000000000 2>&1)
    PKG_ID=$(echo "$OUTPUT" | grep -oE "PackageID: 0x[a-f0-9]{64}" | head -1 | cut -d' ' -f2)
    
    if [ -z "$PKG_ID" ]; then
        PKG_ID=$(echo "$OUTPUT" | grep -A5 "Published Objects" | grep -oE "0x[a-f0-9]{64}" | head -1)
    fi
    
    if [ -z "$PKG_ID" ]; then
        echo "❌ Failed to deploy $pkg_name"
        echo "$OUTPUT" | tail -30
        return 1
    fi
    
    echo "✅ $pkg_name deployed: $PKG_ID"
    
    # Update address everywhere
    cd /Users/admin/monorepo/contracts
    find . -name "Move.toml" -exec sed -i '' "s/${addr_name} = \"0x[^\"]*\"/${addr_name} = \"${PKG_ID}\"/" {} \;
    
    echo ""
    return 0
}

# Check current addresses
echo "Current deployment status:"
echo "=========================="
echo "Kiosk: $(grep 'kiosk = ' move-framework/packages/actions/Move.toml | cut -d'"' -f2)"
echo "AccountExtensions: $(grep 'account_extensions = ' futarchy_vault/Move.toml | cut -d'"' -f2)"
echo "AccountProtocol: $(grep 'account_protocol = ' futarchy_vault/Move.toml | cut -d'"' -f2)"
echo "AccountActions: $(grep 'account_actions = ' futarchy_vault/Move.toml | cut -d'"' -f2)"
echo ""

# Deploy remaining futarchy packages
packages=(
    "futarchy_vault|/Users/admin/monorepo/contracts/futarchy_vault|futarchy_vault"
    "futarchy_multisig|/Users/admin/monorepo/contracts/futarchy_multisig|futarchy_multisig"
    "futarchy_lifecycle|/Users/admin/monorepo/contracts/futarchy_lifecycle|futarchy_lifecycle"
    "futarchy_actions|/Users/admin/monorepo/contracts/futarchy_actions|futarchy_actions"
    "futarchy_specialized_actions|/Users/admin/monorepo/contracts/futarchy_specialized_actions|futarchy_specialized_actions"
    "futarchy_dao|/Users/admin/monorepo/contracts/futarchy_dao|futarchy_dao"
)

for pkg_info in "${packages[@]}"; do
    IFS='|' read -r name path addr <<< "$pkg_info"
    if deploy_package "$name" "$path" "$addr"; then
        echo "✅ $name deployed successfully"
    else
        echo "❌ $name deployment failed"
        echo "Stopping deployment process..."
        exit 1
    fi
done

echo "========================================"
echo "All packages deployed successfully!"
echo "========================================"
echo ""

# Show final addresses
echo "Final deployment addresses:"
echo "==========================="
cd /Users/admin/monorepo/contracts
echo "Kiosk: $(grep 'kiosk = ' move-framework/packages/actions/Move.toml | cut -d'"' -f2)"
echo "AccountExtensions: $(grep 'account_extensions = ' futarchy_vault/Move.toml | cut -d'"' -f2)"
echo "AccountProtocol: $(grep 'account_protocol = ' futarchy_vault/Move.toml | cut -d'"' -f2)"
echo "AccountActions: $(grep 'account_actions = ' futarchy_vault/Move.toml | cut -d'"' -f2)"
echo ""
for pkg in futarchy_one_shot_utils futarchy_core futarchy_markets futarchy_vault futarchy_multisig futarchy_lifecycle futarchy_actions futarchy_specialized_actions futarchy_dao; do
    if [ -f "$pkg/Move.toml" ]; then
        address=$(grep "^$pkg = " "$pkg/Move.toml" | head -1 | cut -d'"' -f2)
        echo "$pkg: $address"
    fi
done