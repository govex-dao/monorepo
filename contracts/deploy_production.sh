#!/bin/bash
set -e

echo "====================================="
echo "Production Deployment Script"
echo "====================================="

# Function to deploy and get package ID
deploy_package() {
    local name=$1
    local path=$2
    
    echo "Deploying $name..."
    cd "$path"
    
    # Deploy and capture output
    OUTPUT=$(sui client publish --gas-budget 5000000000 2>&1)
    
    # Extract package ID - look for the line with PackageID
    PKG_ID=$(echo "$OUTPUT" | grep "│ PackageID:" | head -1 | awk '{print $3}')
    
    if [ -z "$PKG_ID" ] || [ "$PKG_ID" = "│" ]; then
        # Try alternative extraction
        PKG_ID=$(echo "$OUTPUT" | grep -A 5 "Published Objects" | grep "PackageID" | head -1 | sed 's/.*PackageID: *//' | sed 's/ .*//')
    fi
    
    if [ -z "$PKG_ID" ]; then
        echo "Failed to deploy $name"
        echo "$OUTPUT"
        exit 1
    fi
    
    echo "✅ $name deployed: $PKG_ID"
    export ${name}_ADDR=$PKG_ID
    
    # Update all Move.toml files with the new address
    cd /Users/admin/monorepo/contracts
    local addr_name=$(echo $name | sed 's/AccountExtensions/account_extensions/' | sed 's/AccountProtocol/account_protocol/' | sed 's/AccountActions/account_actions/' | sed 's/Kiosk/kiosk/')
    find . -name "Move.toml" -exec sed -i '' "s/${addr_name} = \"0x[^\"]*\"/${addr_name} = \"${PKG_ID}\"/" {} \;
    
    return 0
}

# Check gas
echo "Checking gas..."
GAS=$(sui client gas --json 2>/dev/null | jq -r '.[0].mistBalance // 0')
if [ "$GAS" -lt 5000000000 ]; then
    echo "Insufficient gas. Requesting from faucet..."
    sui client faucet
    sleep 3
fi

cd /Users/admin/monorepo/contracts

# Deploy dependencies first
echo "===== Deploying Dependencies ====="

deploy_package "Kiosk" "move-framework/deps/kiosk"
deploy_package "AccountExtensions" "move-framework/packages/extensions"
deploy_package "AccountProtocol" "move-framework/packages/protocol"
deploy_package "AccountActions" "move-framework/packages/actions"

# Deploy futarchy packages in order
echo "===== Deploying Futarchy Packages ====="

deploy_package "futarchy_one_shot_utils" "futarchy_one_shot_utils"
deploy_package "futarchy_core" "futarchy_core"
deploy_package "futarchy_markets" "futarchy_markets"
deploy_package "futarchy_vault" "futarchy_vault"
deploy_package "futarchy_multisig" "futarchy_multisig"
deploy_package "futarchy_lifecycle" "futarchy_lifecycle"
deploy_package "futarchy_actions" "futarchy_actions"
deploy_package "futarchy_specialized_actions" "futarchy_specialized_actions"
deploy_package "futarchy_dao" "futarchy_dao"

echo "====================================="
echo "Deployment Complete!"
echo "====================================="
echo ""
echo "Deployed Addresses:"
echo "Kiosk: $Kiosk_ADDR"
echo "AccountExtensions: $AccountExtensions_ADDR"
echo "AccountProtocol: $AccountProtocol_ADDR"
echo "AccountActions: $AccountActions_ADDR"
echo "futarchy_one_shot_utils: $futarchy_one_shot_utils_ADDR"
echo "futarchy_core: $futarchy_core_ADDR"
echo "futarchy_markets: $futarchy_markets_ADDR"
echo "futarchy_vault: $futarchy_vault_ADDR"
echo "futarchy_multisig: $futarchy_multisig_ADDR"
echo "futarchy_lifecycle: $futarchy_lifecycle_ADDR"
echo "futarchy_actions: $futarchy_actions_ADDR"
echo "futarchy_specialized_actions: $futarchy_specialized_actions_ADDR"
echo "futarchy_dao: $futarchy_dao_ADDR"