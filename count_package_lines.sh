#!/bin/bash

echo "==================================================================="
echo "MOVE PACKAGE LINE COUNTS (excluding test files)"
echo "==================================================================="
echo ""

# Array of package paths
packages=(
  "contracts/move-framework/packages/extensions/sources"
  "contracts/move-framework/packages/protocol/sources"
  "contracts/move-framework/packages/actions/sources"
  "contracts/futarchy_one_shot_utils/sources"
  "contracts/futarchy_types/sources"
  "contracts/futarchy_core/sources"
  "contracts/futarchy_markets_primitives/sources"
  "contracts/futarchy_markets_core/sources"
  "contracts/futarchy_markets_operations/sources"
  "contracts/futarchy_vault/sources"
  "contracts/futarchy_multisig/sources"
  "contracts/futarchy_payments/sources"
  "contracts/futarchy_streams/sources"
  "contracts/futarchy_oracle/sources"
  "contracts/futarchy_factory/sources"
  "contracts/futarchy_lifecycle/sources"
  "contracts/futarchy_legal_actions/sources"
  "contracts/futarchy_seal_utils/sources"
  "contracts/futarchy_governance_actions/sources"
  "contracts/futarchy_actions/sources"
  "contracts/futarchy_dao/sources"
)

grand_total=0
package_count=0

for pkg in "${packages[@]}"; do
  if [ -d "$pkg" ]; then
    # Count lines in all .move files excluding test files
    line_count=$(find "$pkg" -type f -name '*.move' ! -name "*test*" ! -name "*Test*" -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}')
    
    if [ -n "$line_count" ] && [ "$line_count" -gt 0 ]; then
      # Extract package name from path
      pkg_name=$(echo "$pkg" | sed 's|contracts/||' | sed 's|/sources||' | sed 's|move-framework/packages/||')
      
      printf "%-45s %8s lines\n" "$pkg_name" "$line_count"
      grand_total=$((grand_total + line_count))
      package_count=$((package_count + 1))
    fi
  fi
done

echo ""
echo "==================================================================="
printf "%-45s %8s lines\n" "TOTAL ($package_count packages)" "$grand_total"
echo "==================================================================="
