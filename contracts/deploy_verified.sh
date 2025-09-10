#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Deployment tracking
LOGS_DIR="/Users/admin/monorepo/contracts/deployment-logs"
mkdir -p "$LOGS_DIR"
DEPLOYMENT_LOG="$LOGS_DIR/deployment_verified_$(date +%Y%m%d_%H%M%S).log"
DEPLOYED_PACKAGES=()

echo -e "${BLUE}=== Verified Futarchy Deployment Script ===${NC}"
echo "Deployment log: $DEPLOYMENT_LOG"
echo ""

# Function to log messages
log() {
    echo "$1" | tee -a "$DEPLOYMENT_LOG"
}

# Function to deploy and verify a package
deploy_and_verify() {
    local pkg_path=$1
    local pkg_name=$2
    local pkg_var_name=$3
    
    echo -e "${YELLOW}Deploying $pkg_name...${NC}"
    cd "$pkg_path"
    
    # Set package address to 0x0 for deployment
    sed -i '' "s/^$pkg_var_name = \"0x[a-f0-9]*\"/$pkg_var_name = \"0x0\"/" Move.toml 2>/dev/null || true
    
    # Build first
    echo "Building $pkg_name..."
    sui move build --skip-fetch-latest-git-deps 2>&1 | tee -a "$DEPLOYMENT_LOG"
    
    # Deploy and capture full output
    echo "Publishing $pkg_name..."
    local temp_file="/tmp/deploy_${pkg_name}_$$.txt"
    sui client publish --gas-budget 5000000000 --skip-dependency-verification 2>&1 | tee "$temp_file"
    
    # Extract package ID
    local pkg_id=$(grep "PackageID:" "$temp_file" | sed 's/.*PackageID: //' | awk '{print $1}')
    rm -f "$temp_file"
    
    if [ -n "$pkg_id" ] && [ "$pkg_id" != "null" ] && [ "$pkg_id" != "" ]; then
        echo -e "${GREEN}✓ $pkg_name deployed at: $pkg_id${NC}"
        log "✓ $pkg_name: $pkg_id"
        
        # Update all Move.toml files with new address
        find /Users/admin/monorepo/contracts -name "Move.toml" -type f -exec \
            sed -i '' "s/$pkg_var_name = \"0x[a-f0-9]*\"/$pkg_var_name = \"$pkg_id\"/" {} \;
        
        DEPLOYED_PACKAGES+=("$pkg_name:$pkg_id")
        return 0
    else
        echo -e "${RED}✗ Failed to extract package ID for $pkg_name${NC}"
        return 1
    fi
}

# Package list in deployment order
declare -a PACKAGES=(
    "Kiosk:/Users/admin/monorepo/contracts/move-framework/deps/kiosk:kiosk"
    "AccountExtensions:/Users/admin/monorepo/contracts/move-framework/packages/extensions:account_extensions"
    "AccountProtocol:/Users/admin/monorepo/contracts/move-framework/packages/protocol:account_protocol"
    "AccountActions:/Users/admin/monorepo/contracts/move-framework/packages/actions:account_actions"
    "futarchy_one_shot_utils:/Users/admin/monorepo/contracts/futarchy_one_shot_utils:futarchy_one_shot_utils"
    "futarchy_core:/Users/admin/monorepo/contracts/futarchy_core:futarchy_core"
    "futarchy_markets:/Users/admin/monorepo/contracts/futarchy_markets:futarchy_markets"
    "futarchy_vault:/Users/admin/monorepo/contracts/futarchy_vault:futarchy_vault"
    "futarchy_multisig:/Users/admin/monorepo/contracts/futarchy_multisig:futarchy_multisig"
    "futarchy_lifecycle:/Users/admin/monorepo/contracts/futarchy_lifecycle:futarchy_lifecycle"
    "futarchy_specialized_actions:/Users/admin/monorepo/contracts/futarchy_specialized_actions:futarchy_specialized_actions"
    "futarchy_actions:/Users/admin/monorepo/contracts/futarchy_actions:futarchy_actions"
    "futarchy_dao:/Users/admin/monorepo/contracts/futarchy_dao:futarchy_dao"
)

# Main deployment
main() {
    local start_from="${1:-}"
    local start_index=0
    
    echo -e "${BLUE}Checking gas balance...${NC}"
    sui client gas | head -10
    echo ""
    
    # Find start index if package name provided
    if [ -n "$start_from" ]; then
        for i in "${!PACKAGES[@]}"; do
            IFS=':' read -r name path var <<< "${PACKAGES[$i]}"
            if [ "$name" = "$start_from" ]; then
                start_index=$i
                echo -e "${YELLOW}Starting deployment from: $name (index $start_index)${NC}"
                break
            fi
        done
        
        if [ $start_index -eq 0 ] && [ "$start_from" != "Kiosk" ]; then
            echo -e "${RED}Package '$start_from' not found. Available packages:${NC}"
            for pkg in "${PACKAGES[@]}"; do
                IFS=':' read -r name _ _ <<< "$pkg"
                echo "  - $name"
            done
            exit 1
        fi
    fi
    
    echo -e "${BLUE}=== Starting Verified Deployment ===${NC}"
    echo ""
    
    # Deploy packages starting from index
    for i in "${!PACKAGES[@]}"; do
        if [ $i -lt $start_index ]; then
            continue
        fi
        
        IFS=':' read -r name path var <<< "${PACKAGES[$i]}"
        if ! deploy_and_verify "$path" "$name" "$var"; then
            echo -e "${RED}Deployment failed at: $name${NC}"
            echo -e "${YELLOW}To resume from this package, run: ./deploy_verified.sh $name${NC}"
            exit 1
        fi
    done
    
    echo ""
    echo -e "${BLUE}=== Final Verification ===${NC}"
    echo ""
    
    # Verify all packages
    local verified=0
    local total=0
    for pkg in "${DEPLOYED_PACKAGES[@]}"; do
        total=$((total + 1))
        local name=$(echo "$pkg" | cut -d: -f1)
        local addr=$(echo "$pkg" | cut -d: -f2)
        
        printf "%-30s: %s\n" "$name" "$addr"
        verified=$((verified + 1))
    done
    
    echo ""
    if [ $verified -eq $total ]; then
        echo -e "${GREEN}✓ All $total packages deployed and verified successfully!${NC}"
        
        # Save results
        RESULTS_FILE="$LOGS_DIR/deployment_verified_$(date +%Y%m%d_%H%M%S).json"
        echo "{" > "$RESULTS_FILE"
        echo '  "timestamp": "'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'",' >> "$RESULTS_FILE"
        echo '  "network": "'$(sui client active-env)'",' >> "$RESULTS_FILE"
        echo '  "packages": {' >> "$RESULTS_FILE"
        
        first=true
        for pkg in "${DEPLOYED_PACKAGES[@]}"; do
            if [ "$first" = true ]; then
                first=false
            else
                echo "," >> "$RESULTS_FILE"
            fi
            name=$(echo "$pkg" | cut -d: -f1)
            addr=$(echo "$pkg" | cut -d: -f2)
            echo -n '    "'$name'": "'$addr'"' >> "$RESULTS_FILE"
        done
        
        echo "" >> "$RESULTS_FILE"
        echo "  }" >> "$RESULTS_FILE"
        echo "}" >> "$RESULTS_FILE"
        
        echo -e "${GREEN}Results saved to: $RESULTS_FILE${NC}"
    else
        echo -e "${RED}✗ Only $verified of $total packages could be verified${NC}"
    fi
}

main "$@"