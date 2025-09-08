#!/bin/bash

# Prepare packages for deployment by setting all addresses to 0x0
echo "Preparing packages for deployment..."

# List of all futarchy packages
packages=(
    "futarchy_one_shot_utils"
    "futarchy_core"
    "futarchy_markets"
    "futarchy_vault"
    "futarchy_multisig"
    "futarchy_actions"
    "futarchy_specialized_actions"
    "futarchy_lifecycle"
    "futarchy_dao"
)

# Update each package's Move.toml to set published-at to 0x0
for package in "${packages[@]}"; do
    if [ -d "$package" ]; then
        echo "Updating $package/Move.toml..."
        # Update the published-at field
        sed -i '' 's/published-at = "0x[a-fA-F0-9]*"/published-at = "0x0"/' "$package/Move.toml"
        
        # Update the package address in [addresses] section
        sed -i '' "s/^$package = \"0x[a-fA-F0-9]*\"/$package = \"0x0\"/" "$package/Move.toml"
    fi
done

echo "All packages prepared for deployment!"