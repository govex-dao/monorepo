#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}==================================================================="
echo "BUILDING ALL MOVE PACKAGES"
echo "===================================================================${NC}"
echo ""

# Array of packages to build
packages=(
  "move-framework/packages/extensions"
  "move-framework/packages/protocol"
  "move-framework/packages/actions"
  "futarchy_types"
  "futarchy_one_shot_utils"
  "futarchy_seal_utils"
  "futarchy_core"
  "futarchy_markets_primitives"
  "futarchy_markets_core"
  "futarchy_markets_operations"
  "futarchy_vault"
  "futarchy_multisig"
  "futarchy_oracle"
  "futarchy_payments"
  "futarchy_streams"
  "futarchy_lifecycle"
  "futarchy_factory"
  "futarchy_governance_actions"
  "futarchy_legal_actions"
  "futarchy_actions"
  "futarchy_dao"
)

success_count=0
fail_count=0
failed_packages=()

for pkg in "${packages[@]}"; do
  pkg_name=$(basename "$pkg")
  if [ "$pkg" = "move-framework/packages/extensions" ]; then
    pkg_name="AccountExtensions"
  elif [ "$pkg" = "move-framework/packages/protocol" ]; then
    pkg_name="AccountProtocol"
  elif [ "$pkg" = "move-framework/packages/actions" ]; then
    pkg_name="AccountActions"
  fi
  
  printf "%-45s " "$pkg_name"
  
  if [ ! -d "$pkg" ]; then
    echo -e "${RED}✗ Directory not found${NC}"
    fail_count=$((fail_count + 1))
    failed_packages+=("$pkg_name (not found)")
    continue
  fi
  
  cd "$pkg"
  
  # Build and capture output
  build_output=$(sui move build --silence-warnings 2>&1)
  build_status=$?
  
  if [ $build_status -eq 0 ]; then
    # Check for actual errors even if exit code is 0
    if echo "$build_output" | grep -q "error\[E"; then
      echo -e "${RED}✗ FAILED (has errors)${NC}"
      fail_count=$((fail_count + 1))
      failed_packages+=("$pkg_name")
      echo "$build_output" | grep -A 3 "error\[E" | head -20
    else
      echo -e "${GREEN}✓ SUCCESS${NC}"
      success_count=$((success_count + 1))
    fi
  else
    echo -e "${RED}✗ FAILED${NC}"
    fail_count=$((fail_count + 1))
    failed_packages+=("$pkg_name")
    # Show first error
    echo "$build_output" | grep -A 3 "error\[E" | head -20
  fi
  
  cd - > /dev/null
done

echo ""
echo -e "${BLUE}==================================================================="
echo "BUILD SUMMARY"
echo "===================================================================${NC}"
echo -e "${GREEN}Successful builds: $success_count${NC}"
echo -e "${RED}Failed builds:     $fail_count${NC}"

if [ $fail_count -gt 0 ]; then
  echo ""
  echo -e "${RED}Failed packages:${NC}"
  for failed in "${failed_packages[@]}"; do
    echo "  - $failed"
  done
  exit 1
else
  echo ""
  echo -e "${GREEN}✓ All packages built successfully!${NC}"
  exit 0
fi
