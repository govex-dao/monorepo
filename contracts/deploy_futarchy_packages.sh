#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Deployment tracking
DEPLOYMENT_LOG="deployment_$(date +%Y%m%d_%H%M%S).log"
DEPLOYED_PACKAGES=()

echo -e "${BLUE}=== Futarchy Packages Deployment Script ===${NC}"
echo "Deployment log: $DEPLOYMENT_LOG"
echo ""

# Function to log messages
log() {
    echo "$1" | tee -a "$DEPLOYMENT_LOG"
}

# Function to check if package exists on chain
check_package_exists() {
    local address=$1
    if [ "$address" = "0x0" ] || [ -z "$address" ]; then
        return 1
    fi
    
    if sui client object "$address" --json 2>/dev/null | jq -e '.data.type' > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to update package address in all Move.toml files
update_package_address() {
    local package_name=$1
    local address=$2
    
    log "Updating $package_name to $address in all Move.toml files..."
    find /Users/admin/monorepo/contracts -name "Move.toml" -type f -exec \
        sed -i '' "s/$package_name = \"0x[a-f0-9]*\"/$package_name = \"$address\"/" {} \;
}

# Function to add missing address to Move.toml if not present
ensure_package_address() {
    local toml_file=$1
    local package_name=$2
    local address=$3
    
    # Check if package address exists in the file
    if ! grep -q "^$package_name = " "$toml_file"; then
        # Add after [addresses] section
        sed -i '' "/\[addresses\]/a\\
$package_name = \"$address\"" "$toml_file"
    else
        # Update existing
        sed -i '' "s/^$package_name = \"0x[a-f0-9]*\"/$package_name = \"$address\"/" "$toml_file"
    fi
}

# Function to deploy a package
deploy_package() {
    local pkg_path=$1
    local pkg_name=$2
    local pkg_var_name=$3
    
    echo -e "${YELLOW}Deploying $pkg_name...${NC}"
    cd "$pkg_path"
    
    # Ensure the package has its own address set to 0x0 before deployment
    ensure_package_address "Move.toml" "$pkg_var_name" "0x0"
    
    # Build first to check for errors
    if ! sui move build --skip-fetch-latest-git-deps 2>&1 | tee -a "$DEPLOYMENT_LOG"; then
        echo -e "${RED}Build failed for $pkg_name${NC}"
        return 1
    fi
    
    # Deploy and extract package ID
    local deploy_output=$(sui client publish --gas-budget 5000000000 --skip-fetch-latest-git-deps --json 2>/dev/null)
    local pkg_id=$(echo "$deploy_output" | jq -r '.effects.created[] | select(.owner == "Immutable") | .reference.objectId' | head -1)
    
    if [ -n "$pkg_id" ] && [ "$pkg_id" != "null" ]; then
        echo -e "${GREEN}✓ $pkg_name deployed at: $pkg_id${NC}"
        log "✓ $pkg_name: $pkg_id"
        
        # Update package address everywhere
        update_package_address "$pkg_var_name" "$pkg_id"
        
        # Add to deployed packages list
        DEPLOYED_PACKAGES+=("$pkg_name:$pkg_id")
        
        return 0
    else
        echo -e "${RED}✗ Failed to deploy $pkg_name${NC}"
        echo "Deploy output:" >> "$DEPLOYMENT_LOG"
        echo "$deploy_output" >> "$DEPLOYMENT_LOG"
        return 1
    fi
}

# Function to check gas balance
check_gas() {
    echo -e "${BLUE}Checking gas balance...${NC}"
    local gas_output=$(sui client gas --json 2>/dev/null)
    local total_gas=$(echo "$gas_output" | jq '[.[] | .gasBalance | tonumber] | add')
    
    if [ "$total_gas" -lt 10000000000 ]; then
        echo -e "${YELLOW}Low gas balance. Requesting from faucet...${NC}"
        sui client faucet
        sleep 5
    else
        echo -e "${GREEN}Gas balance sufficient${NC}"
    fi
}

# Function to clean duplicate entries in Move.toml files
clean_move_toml_duplicates() {
    echo -e "${BLUE}Cleaning duplicate entries in Move.toml files...${NC}"
    find /Users/admin/monorepo/contracts -name "Move.toml" -type f | while read file; do
        # Remove duplicate lines while preserving order
        awk '!seen[$0]++' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    done
}

# Main deployment process
main() {
    # Check prerequisites
    check_gas
    
    # Clean any duplicate entries first
    clean_move_toml_duplicates
    
    echo -e "${BLUE}=== Starting Deployment ===${NC}"
    echo ""
    
    # Track if packages are already deployed
    declare -A PACKAGE_ADDRESSES
    
    # Check and store existing deployments
    echo -e "${BLUE}Checking existing deployments...${NC}"
    
    # Framework packages (may already be deployed)
    KIOSK_ADDR=$(grep '^kiosk = ' /Users/admin/monorepo/contracts/futarchy_dao/Move.toml 2>/dev/null | cut -d'"' -f2 || echo "0x0")
    ACCOUNT_EXTENSIONS_ADDR=$(grep '^account_extensions = ' /Users/admin/monorepo/contracts/futarchy_dao/Move.toml 2>/dev/null | cut -d'"' -f2 || echo "0x0")
    ACCOUNT_PROTOCOL_ADDR=$(grep '^account_protocol = ' /Users/admin/monorepo/contracts/futarchy_dao/Move.toml 2>/dev/null | cut -d'"' -f2 || echo "0x0")
    ACCOUNT_ACTIONS_ADDR=$(grep '^account_actions = ' /Users/admin/monorepo/contracts/futarchy_dao/Move.toml 2>/dev/null | cut -d'"' -f2 || echo "0x0")
    
    # Futarchy packages
    FUTARCHY_ONE_SHOT_UTILS_ADDR=$(grep '^futarchy_one_shot_utils = ' /Users/admin/monorepo/contracts/futarchy_dao/Move.toml 2>/dev/null | cut -d'"' -f2 || echo "0x0")
    
    # Deploy Kiosk if not deployed
    if ! check_package_exists "$KIOSK_ADDR"; then
        deploy_package "/Users/admin/monorepo/contracts/move-framework/deps/kiosk" "Kiosk" "kiosk"
    else
        echo -e "${GREEN}Kiosk already deployed at: $KIOSK_ADDR${NC}"
        update_package_address "kiosk" "$KIOSK_ADDR"
    fi
    
    # Deploy AccountExtensions if not deployed
    if ! check_package_exists "$ACCOUNT_EXTENSIONS_ADDR"; then
        deploy_package "/Users/admin/monorepo/contracts/move-framework/packages/extensions" "AccountExtensions" "account_extensions"
    else
        echo -e "${GREEN}AccountExtensions already deployed at: $ACCOUNT_EXTENSIONS_ADDR${NC}"
        update_package_address "account_extensions" "$ACCOUNT_EXTENSIONS_ADDR"
    fi
    
    # Deploy AccountProtocol if not deployed
    if ! check_package_exists "$ACCOUNT_PROTOCOL_ADDR"; then
        deploy_package "/Users/admin/monorepo/contracts/move-framework/packages/protocol" "AccountProtocol" "account_protocol"
    else
        echo -e "${GREEN}AccountProtocol already deployed at: $ACCOUNT_PROTOCOL_ADDR${NC}"
        update_package_address "account_protocol" "$ACCOUNT_PROTOCOL_ADDR"
    fi
    
    # Deploy AccountActions if not deployed
    if ! check_package_exists "$ACCOUNT_ACTIONS_ADDR"; then
        deploy_package "/Users/admin/monorepo/contracts/move-framework/packages/actions" "AccountActions" "account_actions"
    else
        echo -e "${GREEN}AccountActions already deployed at: $ACCOUNT_ACTIONS_ADDR${NC}"
        update_package_address "account_actions" "$ACCOUNT_ACTIONS_ADDR"
    fi
    
    # Deploy futarchy_one_shot_utils if not deployed (reused from previous deployment)
    if ! check_package_exists "$FUTARCHY_ONE_SHOT_UTILS_ADDR"; then
        deploy_package "/Users/admin/monorepo/contracts/futarchy_one_shot_utils" "futarchy_one_shot_utils" "futarchy_one_shot_utils"
    else
        echo -e "${GREEN}futarchy_one_shot_utils already deployed at: $FUTARCHY_ONE_SHOT_UTILS_ADDR${NC}"
        update_package_address "futarchy_one_shot_utils" "$FUTARCHY_ONE_SHOT_UTILS_ADDR"
    fi
    
    # Deploy remaining futarchy packages in dependency order
    deploy_package "/Users/admin/monorepo/contracts/futarchy_core" "futarchy_core" "futarchy_core"
    deploy_package "/Users/admin/monorepo/contracts/futarchy_markets" "futarchy_markets" "futarchy_markets"
    deploy_package "/Users/admin/monorepo/contracts/futarchy_vault" "futarchy_vault" "futarchy_vault"
    deploy_package "/Users/admin/monorepo/contracts/futarchy_multisig" "futarchy_multisig" "futarchy_multisig"
    deploy_package "/Users/admin/monorepo/contracts/futarchy_lifecycle" "futarchy_lifecycle" "futarchy_lifecycle"
    deploy_package "/Users/admin/monorepo/contracts/futarchy_specialized_actions" "futarchy_specialized_actions" "futarchy_specialized_actions"
    deploy_package "/Users/admin/monorepo/contracts/futarchy_actions" "futarchy_actions" "futarchy_actions"
    deploy_package "/Users/admin/monorepo/contracts/futarchy_dao" "futarchy_dao" "futarchy_dao"
    
    echo ""
    echo -e "${BLUE}=== Deployment Summary ===${NC}"
    echo ""
    
    # Display all deployed packages
    for pkg in "${DEPLOYED_PACKAGES[@]}"; do
        echo -e "${GREEN}$pkg${NC}"
    done
    
    # Save deployment addresses to JSON
    DEPLOYMENT_JSON="deployment_addresses_$(date +%Y%m%d_%H%M%S).json"
    echo "{" > "$DEPLOYMENT_JSON"
    echo '  "timestamp": "'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'",' >> "$DEPLOYMENT_JSON"
    echo '  "network": "'$(sui client active-env)'",' >> "$DEPLOYMENT_JSON"
    echo '  "packages": {' >> "$DEPLOYMENT_JSON"
    
    # Add all package addresses to JSON
    first=true
    for pkg in "${DEPLOYED_PACKAGES[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            echo "," >> "$DEPLOYMENT_JSON"
        fi
        pkg_name=$(echo "$pkg" | cut -d: -f1)
        pkg_addr=$(echo "$pkg" | cut -d: -f2)
        echo -n '    "'$pkg_name'": "'$pkg_addr'"' >> "$DEPLOYMENT_JSON"
    done
    
    echo "" >> "$DEPLOYMENT_JSON"
    echo "  }" >> "$DEPLOYMENT_JSON"
    echo "}" >> "$DEPLOYMENT_JSON"
    
    echo ""
    echo -e "${GREEN}Deployment addresses saved to: $DEPLOYMENT_JSON${NC}"
    echo -e "${GREEN}Deployment log saved to: $DEPLOYMENT_LOG${NC}"
    echo ""
    echo -e "${GREEN}✓ All packages deployed successfully!${NC}"
}

# Run main deployment
main "$@"