#!/bin/bash

echo "Updating all imports to new package structure..."

# Function to update imports in a file
update_imports() {
    local file=$1
    
    # Update package names
    sed -i '' 's/use futarchy_shared::/use futarchy_vault::/g' "$file"
    sed -i '' 's/use futarchy_shared::weighted_multisig/use futarchy_security::weighted_multisig/g' "$file"
    sed -i '' 's/use futarchy_shared::security_council_actions/use futarchy_security::security_council_actions/g' "$file"
    sed -i '' 's/use futarchy_shared::policy_/use futarchy_security::policy_/g' "$file"
    sed -i '' 's/use futarchy_shared::resource/use futarchy_lifecycle::resource/g' "$file"
    sed -i '' 's/use futarchy_shared::oracle_actions/use futarchy_governance::oracle_actions/g' "$file"
    sed -i '' 's/use futarchy_shared::factory/use futarchy_lifecycle::factory/g' "$file"
    sed -i '' 's/use futarchy_shared::launchpad/use futarchy_lifecycle::launchpad/g' "$file"
    
    # Update futarchy to futarchy_engine
    sed -i '' 's/use futarchy::/use futarchy_engine::/g' "$file"
    
    # Update streams and operating agreement
    sed -i '' 's/use futarchy_streams::/use futarchy_operations::/g' "$file"
    sed -i '' 's/use futarchy_operating_agreement::/use futarchy_operations::/g' "$file"
    
    # Fix specific vault imports
    sed -i '' 's/use futarchy_vault::custody_actions/use futarchy_vault::custody_actions/g' "$file"
    sed -i '' 's/use futarchy_vault::futarchy_vault/use futarchy_vault::futarchy_vault/g' "$file"
    sed -i '' 's/use futarchy_vault::lp_token_custody/use futarchy_vault::lp_token_custody/g' "$file"
    
    # Fix lifecycle imports
    sed -i '' 's/futarchy_governance::dissolution_/futarchy_lifecycle::dissolution_/g' "$file"
}

# Update all Move files in all packages
for package in futarchy_engine futarchy_vault futarchy_security futarchy_lifecycle futarchy_operations futarchy_governance futarchy_markets futarchy_core; do
    if [ -d "/Users/admin/monorepo/contracts/$package" ]; then
        echo "Updating imports in $package..."
        find "/Users/admin/monorepo/contracts/$package/sources" -name "*.move" -type f | while read file; do
            update_imports "$file"
        done
    fi
done

echo "Import updates complete"