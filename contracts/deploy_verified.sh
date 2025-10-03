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

# Function to resolve address conflicts by updating all Move.toml files with deployed addresses
resolve_address_conflicts() {
    echo -e "${BLUE}Resolving any remaining address conflicts...${NC}"

    # Update all deployed package addresses to ensure consistency
    for deployed_pkg in "${DEPLOYED_PACKAGES[@]}"; do
        local pkg_name=$(echo "$deployed_pkg" | cut -d: -f1)
        local pkg_addr=$(echo "$deployed_pkg" | cut -d: -f2)
        local pkg_var=""

        # Convert package name to variable name
        case "$pkg_name" in
            "AccountExtensions") pkg_var="account_extensions" ;;
            "AccountProtocol") pkg_var="account_protocol" ;;
            "AccountActions") pkg_var="account_actions" ;;
            *) pkg_var="$pkg_name" ;;
        esac

        # Update all Move.toml files with this package's address (only in [addresses] section)
        for toml_file in $(find /Users/admin/monorepo/contracts -name "Move.toml" -type f); do
            awk -v key="$pkg_var" -v addr="$pkg_addr" '
                BEGIN { in_addr=0 }
                /^\[addresses\]/ { in_addr=1; print; next }
                /^\[/ && !/^\[addresses\]/ { in_addr=0 }
                in_addr && $0 ~ "^"key" = " { print key " = \"" addr "\""; next }
                { print }
            ' "$toml_file" > "$toml_file.tmp" && mv "$toml_file.tmp" "$toml_file"
        done 2>/dev/null || true
    done
}

# Function to deploy and verify a package
deploy_and_verify() {
    local pkg_path=$1
    local pkg_name=$2
    local pkg_var_name=$3

    echo -e "${YELLOW}Deploying $pkg_name...${NC}"
    cd "$pkg_path"

    # Set package address to 0x0 for deployment in the current package
    # Use a more robust sed pattern to avoid escaping issues
    sed -i '' "s|^${pkg_var_name} = .*|${pkg_var_name} = \"0x0\"|" Move.toml 2>/dev/null || true

    # Also reset this package's address in ALL other Move.toml files (only in [addresses] section)
    for toml_file in $(find /Users/admin/monorepo/contracts -name "Move.toml" -type f); do
        awk -v key="$pkg_var_name" '
            BEGIN { in_addr=0 }
            /^\[addresses\]/ { in_addr=1; print; next }
            /^\[/ && !/^\[addresses\]/ { in_addr=0 }
            in_addr && $0 ~ "^"key" = " { print key " = \"0x0\""; next }
            { print }
        ' "$toml_file" > "$toml_file.tmp" && mv "$toml_file.tmp" "$toml_file"
    done 2>/dev/null || true
    
    # Build first and check for success
    echo "Building $pkg_name..."
    local build_log="/tmp/build_${pkg_name}_$$.log"
    if ! sui move build --skip-fetch-latest-git-deps 2>&1 | tee "$build_log" | tee -a "$DEPLOYMENT_LOG"; then
        # Build failed, check if it's due to address conflicts
        if grep -q "Conflicting assignments for address" "$build_log"; then
            echo -e "${YELLOW}Address conflict detected, attempting to resolve...${NC}"
            resolve_address_conflicts

            # Retry build after resolving conflicts
            echo "Retrying build for $pkg_name..."
            if ! sui move build --skip-fetch-latest-git-deps 2>&1 | tee -a "$DEPLOYMENT_LOG"; then
                echo -e "${RED}Build failed for $pkg_name even after conflict resolution${NC}"
                rm -f "$build_log"
                return 1
            fi
        else
            echo -e "${RED}Build failed for $pkg_name${NC}"
            rm -f "$build_log"
            return 1
        fi
    fi
    rm -f "$build_log"

    # Deploy and capture full output
    echo "Publishing $pkg_name..."
    local temp_file="/tmp/deploy_${pkg_name}_$$.txt"
    sui client publish --gas-budget 5000000000 --skip-dependency-verification 2>&1 | tee "$temp_file"
    
    # Extract package ID with better error handling
    local pkg_id=$(grep "PackageID:" "$temp_file" | sed 's/.*PackageID: //' | awk '{print $1}')

    # Check if deployment failed due to address conflicts
    if grep -q "Conflicting assignments for address" "$temp_file"; then
        echo -e "${YELLOW}Deployment failed due to address conflict, resolving and retrying...${NC}"
        rm -f "$temp_file"

        # Resolve conflicts and retry once
        resolve_address_conflicts

        echo "Retrying deployment for $pkg_name..."
        sui client publish --gas-budget 5000000000 --skip-dependency-verification 2>&1 | tee "$temp_file"
        pkg_id=$(grep "PackageID:" "$temp_file" | sed 's/.*PackageID: //' | awk '{print $1}')
    fi

    rm -f "$temp_file"

    if [ -n "$pkg_id" ] && [ "$pkg_id" != "null" ] && [ "$pkg_id" != "" ]; then
        echo -e "${GREEN}✓ $pkg_name deployed at: $pkg_id${NC}"
        log "✓ $pkg_name: $pkg_id"

        # Update all Move.toml files with new address (only in [addresses] section)
        for toml_file in $(find /Users/admin/monorepo/contracts -name "Move.toml" -type f); do
            awk -v key="$pkg_var_name" -v addr="$pkg_id" '
                BEGIN { in_addr=0 }
                /^\[addresses\]/ { in_addr=1; print; next }
                /^\[/ && !/^\[addresses\]/ { in_addr=0 }
                in_addr && $0 ~ "^"key" = " { print key " = \"" addr "\""; next }
                { print }
            ' "$toml_file" > "$toml_file.tmp" && mv "$toml_file.tmp" "$toml_file"
        done

        DEPLOYED_PACKAGES+=("$pkg_name:$pkg_id")
        return 0
    else
        echo -e "${RED}✗ Failed to extract package ID for $pkg_name${NC}"
        return 1
    fi
}

# Package list in deployment order (18 packages total)
declare -a PACKAGES=(
    # Move Framework packages (3)
    "AccountExtensions:/Users/admin/monorepo/contracts/move-framework/packages/extensions:account_extensions"
    "AccountProtocol:/Users/admin/monorepo/contracts/move-framework/packages/protocol:account_protocol"
    "AccountActions:/Users/admin/monorepo/contracts/move-framework/packages/actions:account_actions"

    # Futarchy packages (15)
    "futarchy_types:/Users/admin/monorepo/contracts/futarchy_types:futarchy_types"
    "futarchy_one_shot_utils:/Users/admin/monorepo/contracts/futarchy_one_shot_utils:futarchy_one_shot_utils"
    "futarchy_core:/Users/admin/monorepo/contracts/futarchy_core:futarchy_core"
    "futarchy_markets:/Users/admin/monorepo/contracts/futarchy_markets:futarchy_markets"
    "futarchy_vault:/Users/admin/monorepo/contracts/futarchy_vault:futarchy_vault"
    "futarchy_multisig:/Users/admin/monorepo/contracts/futarchy_multisig:futarchy_multisig"
    "futarchy_oracle:/Users/admin/monorepo/contracts/futarchy_oracle:futarchy_oracle"
    "futarchy_payments:/Users/admin/monorepo/contracts/futarchy_payments:futarchy_payments"
    "futarchy_streams:/Users/admin/monorepo/contracts/futarchy_streams:futarchy_streams"
    "futarchy_lifecycle:/Users/admin/monorepo/contracts/futarchy_lifecycle:futarchy_lifecycle"
    "futarchy_actions:/Users/admin/monorepo/contracts/futarchy_actions:futarchy_actions"
    "futarchy_governance_actions:/Users/admin/monorepo/contracts/futarchy_governance_actions:futarchy_governance_actions"
    "futarchy_legal_actions:/Users/admin/monorepo/contracts/futarchy_legal_actions:futarchy_legal_actions"
    "futarchy_factory:/Users/admin/monorepo/contracts/futarchy_factory:futarchy_factory"
    "futarchy_dao:/Users/admin/monorepo/contracts/futarchy_dao:futarchy_dao"
)

# Main deployment
main() {
    local start_from="${1:-}"
    local start_index=0

    # Clean up any leftover futarchy_utils and kiosk references before deployment
    echo -e "${BLUE}Cleaning up old package references...${NC}"
    find /Users/admin/monorepo/contracts -name "Move.toml" -type f -exec \
        sed -i '' -e '/^futarchy_utils = /d' -e '/^kiosk = /d' {} \; 2>/dev/null || true

    # Reset all package addresses to 0x0 for fresh deployment if starting from beginning
    if [ -z "$start_from" ] || [ "$start_from" = "AccountExtensions" ]; then
        echo -e "${BLUE}Resetting all package addresses to 0x0 for fresh deployment...${NC}"
        find /Users/admin/monorepo/contracts -name "Move.toml" -type f -exec \
            sed -i '' 's/= "0x[a-f0-9][a-f0-9]*"/= "0x0"/g' {} \; 2>/dev/null || true
    fi

    echo -e "${BLUE}Checking gas balance...${NC}"
    sui client gas | head -10
    echo ""

    # Request gas from faucet if on devnet/testnet
    local env=$(sui client active-env)
    if [[ "$env" == "devnet" || "$env" == "testnet" ]]; then
        echo -e "${YELLOW}Requesting gas from faucet...${NC}"
        sui client faucet
        echo ""
        echo "Updated gas balance:"
        sui client gas | head -10
        echo ""
    fi
    
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

        if [ $start_index -eq 0 ] && [ "$start_from" != "AccountExtensions" ]; then
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

    # Final address conflict resolution
    resolve_address_conflicts

    # Verify all packages build correctly
    echo -e "${BLUE}Verifying all packages build successfully...${NC}"
    local build_failed=false
    for pkg in "${DEPLOYED_PACKAGES[@]}"; do
        local name=$(echo "$pkg" | cut -d: -f1)
        local addr=$(echo "$pkg" | cut -d: -f2)

        # Find package path
        local pkg_path=""
        for package_entry in "${PACKAGES[@]}"; do
            IFS=':' read -r pkg_name pkg_path_temp pkg_var <<< "$package_entry"
            if [ "$pkg_name" = "$name" ]; then
                pkg_path="$pkg_path_temp"
                break
            fi
        done

        if [ -n "$pkg_path" ]; then
            echo -n "Building $name... "
            cd "$pkg_path"
            if sui move build --skip-fetch-latest-git-deps >/dev/null 2>&1; then
                echo -e "${GREEN}✓${NC}"
            else
                echo -e "${RED}✗${NC}"
                build_failed=true
            fi
        fi
    done

    if [ "$build_failed" = true ]; then
        echo -e "${YELLOW}Some packages failed to build. This may indicate configuration issues.${NC}"
    fi

    # Display deployment results
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