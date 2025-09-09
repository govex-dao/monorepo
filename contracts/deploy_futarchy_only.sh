#!/bin/bash

# Simple deployment script for the 9 futarchy packages only
# Assumes Account Protocol packages are already deployed

set -e  # Exit on error

echo "=== Deploying Futarchy Packages ==="
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Futarchy packages in dependency order
PACKAGES=(
    "futarchy_one_shot_utils"
    "futarchy_core"
    "futarchy_markets"
    "futarchy_vault"
    "futarchy_multisig"
    "futarchy_lifecycle"
    "futarchy_specialized_actions"
    "futarchy_actions"
    "futarchy_dao"
)

echo -e "${BLUE}Will deploy ${#PACKAGES[@]} packages${NC}"

# Function to deploy a package
deploy_package() {
    local package=$1
    echo -e "\n${BLUE}Deploying $package...${NC}"
    
    cd "/Users/admin/monorepo/contracts/$package"
    
    # Set package address to 0x0 for deployment
    echo "Setting $package address to 0x0 in Move.toml..."
    sed -i '' "s/^$package = \"0x[a-f0-9]*\"/$package = \"0x0\"/" Move.toml
    
    # Build first to verify
    echo "Building $package..."
    if ! sui move build --skip-fetch-latest-git-deps 2>/dev/null; then
        echo -e "${RED}Failed to build $package${NC}"
        exit 1
    fi
    
    # Deploy the package
    echo "Publishing $package..."
    DEPLOY_OUTPUT=$(sui client publish --gas-budget 5000000000 --skip-fetch-latest-git-deps --json 2>/dev/null)
    
    # Extract the package ID
    PACKAGE_ID=$(echo "$DEPLOY_OUTPUT" | jq -r '.effects.created[] | select(.owner == "Immutable") | .reference.objectId' | head -1)
    
    if [ -z "$PACKAGE_ID" ] || [ "$PACKAGE_ID" == "null" ]; then
        echo -e "${RED}Failed to get package ID for $package${NC}"
        echo "Deploy output: $DEPLOY_OUTPUT"
        exit 1
    fi
    
    echo -e "${GREEN}$package deployed at: $PACKAGE_ID${NC}"
    
    # Update all Move.toml files with the new address
    echo "Updating all Move.toml files with new address..."
    find /Users/admin/monorepo/contracts -name "Move.toml" -type f -exec \
        sed -i '' "s/$package = \"0x[a-f0-9]*\"/$package = \"$PACKAGE_ID\"/" {} \;
    
    echo -e "${GREEN}✓ $package deployed successfully${NC}"
}

# Main deployment loop
for package in "${PACKAGES[@]}"; do
    deploy_package "$package"
done

echo -e "\n${GREEN}=== All Futarchy Packages Deployed Successfully ===${NC}"
echo ""
echo "Deployed packages:"
for package in "${PACKAGES[@]}"; do
    cd "/Users/admin/monorepo/contracts/$package"
    ADDR=$(grep "^$package = " Move.toml | cut -d'"' -f2)
    echo "$package: $ADDR"
done