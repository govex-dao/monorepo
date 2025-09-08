#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}       Futarchy Package Deployment Status      ${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

PACKAGES=(
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

DEPLOYED_COUNT=0
NOT_DEPLOYED=()

for package in "${PACKAGES[@]}"; do
    move_toml="/Users/admin/monorepo/contracts/${package}/Move.toml"
    
    if [ ! -f "$move_toml" ]; then
        echo -e "${RED}✗ $package - Move.toml not found${NC}"
        continue
    fi
    
    # Get the package address
    address=$(grep "^${package} = " "$move_toml" | sed 's/.*"\(.*\)".*/\1/')
    
    if [ "$address" = "0x0" ] || [ -z "$address" ]; then
        echo -e "${YELLOW}○ $package - Not deployed${NC}"
        NOT_DEPLOYED+=("$package")
    else
        echo -e "${GREEN}✓ $package - Deployed at: ${address:0:16}...${NC}"
        ((DEPLOYED_COUNT++))
    fi
done

echo ""
echo -e "${BLUE}Summary:${NC}"
echo "  Deployed: $DEPLOYED_COUNT / ${#PACKAGES[@]}"

if [ ${#NOT_DEPLOYED[@]} -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Packages needing deployment:${NC}"
    for pkg in "${NOT_DEPLOYED[@]}"; do
        echo "  - $pkg"
    done
fi

# Check if all packages can build
echo ""
echo -e "${BLUE}Build Status:${NC}"

for package in "${NOT_DEPLOYED[@]}"; do
    echo -n "  Testing $package build... "
    cd "/Users/admin/monorepo/contracts/$package" 2>/dev/null
    if sui move build >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗ Build failed${NC}"
    fi
done