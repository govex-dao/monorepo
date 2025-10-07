#!/bin/bash

echo "Building all futarchy packages in dependency order..."
echo ""

# Navigate to contracts directory
cd /Users/admin/monorepo/contracts

# Build packages in dependency order
packages=(
    "futarchy_one_shot_utils"
    "futarchy_core"
    "futarchy_markets"
    "futarchy_vault"
    "futarchy_multisig"
    "futarchy_lifecycle"
    "futarchy_actions"
    "futarchy_legal_actions"
    "futarchy_governance_actions"
    "futarchy_dao"
)

success_count=0
failed_packages=""

for package in "${packages[@]}"; do
    echo "========================================="
    echo "Building $package..."
    echo "========================================="
    
    cd "/Users/admin/monorepo/contracts/$package"
    
    # Try to build
    if sui move build --silence-warnings 2>&1 | tail -5 | grep -q "Failed to build"; then
        echo "❌ Failed to build $package"
        failed_packages="$failed_packages $package"
    else
        echo "✅ $package built successfully!"
        ((success_count++))
    fi
    
    echo ""
done

echo "========================================="
echo "Build Summary:"
echo "========================================="
echo "Successfully built: $success_count / ${#packages[@]} packages"
if [ -n "$failed_packages" ]; then
    echo "Failed packages:$failed_packages"
else
    echo "All packages built successfully!"
fi