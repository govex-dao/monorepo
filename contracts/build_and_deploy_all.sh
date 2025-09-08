#!/bin/bash

# Build and deploy all futarchy packages to devnet
set -e

echo "Starting build and deployment of all futarchy packages to devnet..."

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to build a package
build_package() {
    local package_name=$1
    echo -e "${YELLOW}Building $package_name...${NC}"
    cd /Users/admin/monorepo/contracts/$package_name
    if sui move build --skip-fetch-latest-git-deps; then
        echo -e "${GREEN}✓ $package_name built successfully${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to build $package_name${NC}"
        return 1
    fi
}

# Function to deploy a package
deploy_package() {
    local package_name=$1
    echo -e "${YELLOW}Deploying $package_name to devnet...${NC}"
    cd /Users/admin/monorepo/contracts/$package_name
    if sui client publish --gas-budget 500000000 --skip-dependency-verification; then
        echo -e "${GREEN}✓ $package_name deployed successfully${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to deploy $package_name${NC}"
        return 1
    fi
}

# Build packages in dependency order
echo -e "\n${YELLOW}Phase 1: Building base packages...${NC}"
build_package "futarchy_one_shot_utils"
build_package "futarchy_core"

echo -e "\n${YELLOW}Phase 2: Building market packages...${NC}"
build_package "futarchy_markets"

echo -e "\n${YELLOW}Phase 3: Building vault and multisig packages...${NC}"
build_package "futarchy_vault"
build_package "futarchy_multisig"

echo -e "\n${YELLOW}Phase 4: Building action packages...${NC}"
# Note: These packages have circular dependencies that need to be resolved
# For now, we'll try to build them in the best order possible
build_package "futarchy_actions" || true
build_package "futarchy_specialized_actions" || true
build_package "futarchy_lifecycle" || true

echo -e "\n${YELLOW}Phase 5: Building DAO package...${NC}"
build_package "futarchy_dao" || true

# Deploy packages to devnet
echo -e "\n${YELLOW}Starting deployment to devnet...${NC}"
echo "Note: Make sure you have switched to devnet with: sui client switch --env devnet"

# Deploy in dependency order
echo -e "\n${YELLOW}Deploying base packages...${NC}"
deploy_package "futarchy_one_shot_utils"
deploy_package "futarchy_core"

echo -e "\n${YELLOW}Deploying market packages...${NC}"
deploy_package "futarchy_markets"

echo -e "\n${YELLOW}Deploying vault and multisig packages...${NC}"
deploy_package "futarchy_vault"
deploy_package "futarchy_multisig"

echo -e "\n${YELLOW}Deploying action packages...${NC}"
deploy_package "futarchy_actions" || true
deploy_package "futarchy_specialized_actions" || true
deploy_package "futarchy_lifecycle" || true

echo -e "\n${YELLOW}Deploying DAO package...${NC}"
deploy_package "futarchy_dao" || true

echo -e "\n${GREEN}Build and deployment process completed!${NC}"
echo "Check above for any packages that failed to build or deploy."