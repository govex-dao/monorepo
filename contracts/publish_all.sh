#!/bin/bash

echo "Publishing all futarchy packages to devnet in dependency order..."
echo ""

# Navigate to contracts directory
cd /Users/admin/monorepo/contracts

# Packages in dependency order
packages=(
    "futarchy_one_shot_utils"
    "futarchy_core"
    "futarchy_markets"
    "futarchy_vault"
)

# Publish each package
for package in "${packages[@]}"; do
    echo "========================================="
    echo "Publishing $package to devnet..."
    echo "========================================="
    
    cd "/Users/admin/monorepo/contracts/$package"
    
    # Publish to devnet
    if sui client publish --gas-budget 500000000 --skip-dependency-verification 2>&1 | tee publish.log; then
        echo "✅ $package published successfully!"
        
        # Extract the published address
        PACKAGE_ID=$(grep "Published Objects" -A 10 publish.log | grep "PackageID:" | awk '{print $3}')
        if [ -n "$PACKAGE_ID" ]; then
            echo "Package ID: $PACKAGE_ID"
            echo "$package=$PACKAGE_ID" >> ../published_addresses.txt
        fi
    else
        echo "❌ Failed to publish $package"
        exit 1
    fi
    
    echo ""
done

echo "========================================="
echo "All packages published successfully!"
echo "========================================="
echo ""
echo "Published addresses saved in: /Users/admin/monorepo/contracts/published_addresses.txt"
cat ../published_addresses.txt