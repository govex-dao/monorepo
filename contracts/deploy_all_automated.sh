#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}    Automated Futarchy Package Deployment      ${NC}"
echo -e "${BLUE}================================================${NC}"

# Configuration
MIN_GAS_REQUIRED=5000000000  # 5 SUI minimum required
GAS_BUDGET=3000000000         # 3 SUI per deployment
CONTRACTS_DIR="/Users/admin/monorepo/contracts"

# Check if Account Protocol packages need deployment
check_and_deploy_account_packages() {
    echo -e "${YELLOW}Checking Account Protocol packages...${NC}"
    
    # Check if they're at 0x0 (not deployed)
    local account_packages=("AccountProtocol" "AccountExtensions" "AccountActions")
    local need_deployment=false
    
    for pkg in "${account_packages[@]}"; do
        local pkg_lower=$(echo "$pkg" | tr '[:upper:]' '[:lower:]' | tr -d '_')
        local pkg_path="/Users/admin/monorepo/contracts/move-framework/packages"
        
        if [ "$pkg" = "AccountProtocol" ]; then
            pkg_path="$pkg_path/protocol"
        elif [ "$pkg" = "AccountExtensions" ]; then
            pkg_path="$pkg_path/extensions"
        elif [ "$pkg" = "AccountActions" ]; then
            pkg_path="$pkg_path/actions"
        fi
        
        if [ -d "$pkg_path" ]; then
            echo "  Found $pkg at $pkg_path"
            cd "$pkg_path"
            
            # Check if it needs deployment
            local current_addr=$(grep "^account_" Move.toml 2>/dev/null | grep -v "0x0" | head -1 || echo "")
            if [ -z "$current_addr" ]; then
                echo -e "${YELLOW}  $pkg needs deployment${NC}"
                
                # Deploy it
                echo "  Deploying $pkg..."
                if sui client publish --gas-budget "$GAS_BUDGET" 2>&1 | tee "${pkg}_deploy.log"; then
                    local pkg_id=$(grep -oE "PackageID: 0x[a-f0-9]{64}" "${pkg}_deploy.log" | cut -d' ' -f2 | head -1)
                    if [ -n "$pkg_id" ]; then
                        echo -e "${GREEN}  $pkg deployed at: $pkg_id${NC}"
                    fi
                fi
            else
                echo -e "${GREEN}  $pkg already deployed${NC}"
            fi
        fi
    done
}

# Array of packages in dependency order
declare -a PACKAGES=(
    "futarchy_one_shot_utils"
    "futarchy_core"
    "futarchy_markets"
    "futarchy_vault"
    "futarchy_multisig"
    "futarchy_specialized_actions"
    "futarchy_lifecycle"
    "futarchy_actions"
    "futarchy_dao"
)

# Track deployed addresses (using regular arrays for compatibility)
DEPLOYED_PACKAGES=()
DEPLOYED_ADDRS=()

# Function to check gas balance
check_gas_balance() {
    echo -e "${YELLOW}Checking gas balance...${NC}"
    
    # Get current address
    CURRENT_ADDRESS=$(sui client active-address)
    echo "Current address: $CURRENT_ADDRESS"
    
    # Get gas balance (in MIST)
    GAS_BALANCE=$(sui client gas --json | jq -r '[.[] | select(.gasBalance != null) | .gasBalance | tonumber] | add // 0')
    
    echo "Current gas balance: $GAS_BALANCE MIST ($(echo "scale=2; $GAS_BALANCE / 1000000000" | bc) SUI)"
    
    if [ "$GAS_BALANCE" -lt "$MIN_GAS_REQUIRED" ]; then
        echo -e "${RED}Insufficient gas balance!${NC}"
        echo -e "${YELLOW}You need at least $(echo "scale=2; $MIN_GAS_REQUIRED / 1000000000" | bc) SUI${NC}"
        echo -e "${YELLOW}Please run: sui client faucet${NC}"
        echo "Attempting to request from faucet..."
        
        # Try to request from faucet
        if sui client faucet 2>&1 | grep -q "Request successful"; then
            echo -e "${GREEN}Successfully requested gas from faucet!${NC}"
            sleep 2
            # Recheck balance
            GAS_BALANCE=$(sui client gas --json | jq -r '[.[] | select(.gasBalance != null) | .gasBalance | tonumber] | add // 0')
            echo "New gas balance: $GAS_BALANCE MIST ($(echo "scale=2; $GAS_BALANCE / 1000000000" | bc) SUI)"
        else
            echo -e "${RED}Failed to get gas from faucet. Please manually add funds.${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}Sufficient gas balance available${NC}"
    fi
}

# Function to reset all addresses to 0x0 in a Move.toml
reset_addresses_to_zero() {
    local package=$1
    local move_toml="${CONTRACTS_DIR}/${package}/Move.toml"
    
    echo "  Resetting addresses to 0x0 in $package/Move.toml..."
    
    # Reset the package's own address to 0x0
    sed -i '' "s/^${package} = \"0x[a-f0-9]*\"/${package} = \"0x0\"/" "$move_toml"
}

# Function to update address in Move.toml files
update_address_in_move_toml() {
    local package=$1
    local new_address=$2
    
    echo "  Updating $package address to $new_address"
    
    # Update in the package's own Move.toml
    local move_toml="${CONTRACTS_DIR}/${package}/Move.toml"
    sed -i '' "s/^${package} = \"0x[a-f0-9]*\"/${package} = \"${new_address}\"/" "$move_toml"
    
    # Update in all other packages that depend on this one
    for other_package in "${PACKAGES[@]}"; do
        local other_toml="${CONTRACTS_DIR}/${other_package}/Move.toml"
        if [ -f "$other_toml" ] && grep -q "^${package} = " "$other_toml"; then
            echo "    Updating reference in $other_package/Move.toml"
            sed -i '' "s/^${package} = \"0x[a-f0-9]*\"/${package} = \"${new_address}\"/" "$other_toml"
        fi
    done
}

# Function to extract package ID from deployment output
extract_package_id() {
    local output_file=$1
    local package_id=""
    
    # Try multiple patterns to find the package ID
    # Pattern 1: Look for PackageID
    package_id=$(grep -oE "PackageID: 0x[a-f0-9]{64}" "$output_file" 2>/dev/null | head -1 | cut -d' ' -f2)
    
    # Pattern 2: Look for "Published Objects" section
    if [ -z "$package_id" ]; then
        package_id=$(grep -A5 "Published Objects" "$output_file" 2>/dev/null | grep -oE "0x[a-f0-9]{64}" | head -1)
    fi
    
    # Pattern 3: Look for package ID in transaction effects
    if [ -z "$package_id" ]; then
        package_id=$(grep -oE "package.*0x[a-f0-9]{64}" "$output_file" 2>/dev/null | grep -oE "0x[a-f0-9]{64}" | head -1)
    fi
    
    # Pattern 4: Just find the first object ID after "Success"
    if [ -z "$package_id" ]; then
        package_id=$(grep -A20 "Success" "$output_file" 2>/dev/null | grep -oE "0x[a-f0-9]{64}" | head -1)
    fi
    
    echo "$package_id"
}

# Function to check if a package is already deployed
check_package_deployed() {
    local package=$1
    local move_toml="${CONTRACTS_DIR}/${package}/Move.toml"
    
    if [ -f "$move_toml" ]; then
        local current_addr=$(grep "^${package} = " "$move_toml" | grep -oE '"0x[a-f0-9]{64}"' | tr -d '"')
        if [ -n "$current_addr" ] && [ "$current_addr" != "0x0" ]; then
            echo "$current_addr"
            return 0
        fi
    fi
    return 1
}

# Function to deploy a single package
deploy_package() {
    local package=$1
    local force_redeploy=${2:-false}
    local package_dir="${CONTRACTS_DIR}/${package}"
    
    echo -e "\n${BLUE}Deploying ${package}...${NC}"
    
    # Check if package directory exists
    if [ ! -d "$package_dir" ]; then
        echo -e "${RED}Error: Package directory not found: $package_dir${NC}"
        return 1
    fi
    
    # Check if already deployed
    local existing_addr=$(check_package_deployed "$package")
    if [ -n "$existing_addr" ] && [ "$force_redeploy" != "true" ]; then
        echo -e "${YELLOW}Package $package already deployed at: $existing_addr${NC}"
        echo -e "${YELLOW}Use force_redeploy=true to redeploy${NC}"
        DEPLOYED_PACKAGES+=("$package")
        DEPLOYED_ADDRS+=("$existing_addr")
        return 0
    fi
    
    cd "$package_dir"
    
    # Reset address to 0x0 for deployment
    reset_addresses_to_zero "$package"
    
    # Build the package first to check for errors
    echo "  Building package..."
    if ! sui move build 2>&1 | tee build_output.log | tail -5; then
        echo -e "${RED}Build failed for $package!${NC}"
        cat build_output.log
        return 1
    fi
    
    # Deploy the package
    echo "  Publishing package..."
    local deploy_output="${package}_deploy_output.log"
    
    if sui client publish --gas-budget "$GAS_BUDGET" --with-unpublished-dependencies 2>&1 | tee "$deploy_output"; then
        # Extract package ID
        local package_id=$(extract_package_id "$deploy_output")
        
        if [ -n "$package_id" ]; then
            echo -e "${GREEN}Successfully deployed $package at: $package_id${NC}"
            DEPLOYED_PACKAGES+=("$package")
            DEPLOYED_ADDRS+=("$package_id")
            
            # Update all Move.toml files with the new address
            update_address_in_move_toml "$package" "$package_id"
            
            return 0
        else
            echo -e "${RED}Failed to extract package ID for $package${NC}"
            echo "Deployment output:"
            cat "$deploy_output"
            return 1
        fi
    else
        echo -e "${RED}Deployment failed for $package!${NC}"
        return 1
    fi
}

# Function to save deployment results
save_deployment_results() {
    local results_file="${CONTRACTS_DIR}/deployment_results_$(date +%Y%m%d_%H%M%S).json"
    
    echo -e "\n${BLUE}Saving deployment results to: $results_file${NC}"
    
    echo "{" > "$results_file"
    echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"," >> "$results_file"
    echo "  \"network\": \"$(sui client active-env)\"," >> "$results_file"
    echo "  \"packages\": {" >> "$results_file"
    
    local first=true
    for i in "${!DEPLOYED_PACKAGES[@]}"; do
        if [ "$first" = false ]; then
            echo "," >> "$results_file"
        fi
        echo -n "    \"${DEPLOYED_PACKAGES[$i]}\": \"${DEPLOYED_ADDRS[$i]}\"" >> "$results_file"
        first=false
    done
    
    echo "" >> "$results_file"
    echo "  }" >> "$results_file"
    echo "}" >> "$results_file"
    
    echo -e "${GREEN}Results saved!${NC}"
}

# Function to handle special case deployments
handle_special_deployments() {
    # Check if futarchy_actions needs redeployment due to missing modules
    echo -e "${YELLOW}Checking futarchy_actions deployment status...${NC}"
    local actions_addr=$(check_package_deployed "futarchy_actions")
    
    if [ -n "$actions_addr" ]; then
        echo "  futarchy_actions found at: $actions_addr"
        echo "  Verifying modules are present..."
        
        # Check if key modules exist by trying to build dependent packages
        cd "${CONTRACTS_DIR}/futarchy_dao"
        if ! sui move build 2>&1 | grep -q "PublishUpgradeMissingDependency"; then
            echo -e "${GREEN}  futarchy_actions modules verified${NC}"
        else
            echo -e "${YELLOW}  futarchy_actions missing modules, forcing redeployment${NC}"
            # Force redeploy futarchy_actions
            if deploy_package "futarchy_actions" true; then
                echo -e "${GREEN}✓ futarchy_actions redeployed successfully${NC}"
            else
                echo -e "${RED}✗ futarchy_actions redeployment failed${NC}"
                return 1
            fi
        fi
    fi
    
    return 0
}

# Main deployment process
main() {
    echo "Starting deployment process..."
    echo "Network: $(sui client active-env)"
    echo ""
    
    # Parse command line arguments
    local force_redeploy=false
    if [ "$1" = "--force" ] || [ "$1" = "-f" ]; then
        force_redeploy=true
        echo -e "${YELLOW}Force redeploy mode enabled${NC}"
    fi
    
    # Check gas balance
    check_gas_balance
    
    # Check and deploy Account Protocol packages if needed
    check_and_deploy_account_packages
    
    # Handle special deployment cases
    handle_special_deployments
    
    # Deploy each package
    local failed_packages=()
    local deployed_count=0
    
    for package in "${PACKAGES[@]}"; do
        if deploy_package "$package" "$force_redeploy"; then
            ((deployed_count++))
            echo -e "${GREEN}✓ $package deployed successfully (${deployed_count}/${#PACKAGES[@]})${NC}"
        else
            echo -e "${RED}✗ $package deployment failed${NC}"
            failed_packages+=("$package")
            
            # In automated mode, continue with remaining packages
            echo -e "${YELLOW}Continuing with remaining packages...${NC}"
        fi
        
        # Small delay between deployments
        sleep 2
    done
    
    # Summary
    echo -e "\n${BLUE}================================================${NC}"
    echo -e "${BLUE}           Deployment Summary                  ${NC}"
    echo -e "${BLUE}================================================${NC}"
    
    echo -e "${GREEN}Successfully deployed: $deployed_count/${#PACKAGES[@]} packages${NC}"
    
    if [ ${#failed_packages[@]} -gt 0 ]; then
        echo -e "${RED}Failed packages:${NC}"
        for package in "${failed_packages[@]}"; do
            echo "  - $package"
        done
    fi
    
    if [ $deployed_count -gt 0 ]; then
        echo -e "\n${GREEN}Deployed addresses:${NC}"
        for i in "${!DEPLOYED_PACKAGES[@]}"; do
            echo "  ${DEPLOYED_PACKAGES[$i]}: ${DEPLOYED_ADDRS[$i]}"
        done
        
        # Save results to file
        save_deployment_results
    fi
    
    # Final gas check
    echo -e "\n${BLUE}Final gas balance check:${NC}"
    FINAL_GAS=$(sui client gas --json | jq -r '[.[] | select(.gasBalance != null) | .gasBalance | tonumber] | add // 0')
    echo "Remaining gas: $FINAL_GAS MIST ($(echo "scale=2; $FINAL_GAS / 1000000000" | bc) SUI)"
    
    if [ $deployed_count -eq ${#PACKAGES[@]} ]; then
        echo -e "\n${GREEN}🎉 All packages deployed successfully!${NC}"
        return 0
    else
        echo -e "\n${YELLOW}⚠️  Some packages failed to deploy${NC}"
        return 1
    fi
}

# Run main function with arguments
main "$@"