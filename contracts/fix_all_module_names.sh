#!/bin/bash

echo "Fixing all module declarations and imports..."

# Fix futarchy_dao modules
for file in $(find /Users/admin/monorepo/contracts/futarchy_dao/sources -name "*.move"); do
    sed -i '' 's/module futarchy::/module futarchy_dao::/g' "$file"
    sed -i '' 's/module futarchy_engine::/module futarchy_dao::/g' "$file"
done

# Fix futarchy_multisig modules
for file in $(find /Users/admin/monorepo/contracts/futarchy_multisig/sources -name "*.move"); do
    sed -i '' 's/module futarchy::/module futarchy_multisig::/g' "$file"
    sed -i '' 's/module futarchy_security::/module futarchy_multisig::/g' "$file"
done

# Fix futarchy_lifecycle modules
for file in $(find /Users/admin/monorepo/contracts/futarchy_lifecycle/sources -name "*.move"); do
    sed -i '' 's/module futarchy::/module futarchy_lifecycle::/g' "$file"
    sed -i '' 's/module futarchy_shared::/module futarchy_lifecycle::/g' "$file"
    sed -i '' 's/module futarchy_governance::/module futarchy_lifecycle::/g' "$file"
done

# Fix futarchy_actions modules
for file in $(find /Users/admin/monorepo/contracts/futarchy_actions/sources -name "*.move"); do
    sed -i '' 's/module futarchy_governance::/module futarchy_actions::/g' "$file"
done

# Fix futarchy_specialized_actions modules  
for file in $(find /Users/admin/monorepo/contracts/futarchy_specialized_actions/sources -name "*.move"); do
    sed -i '' 's/module futarchy_operations::/module futarchy_specialized_actions::/g' "$file"
    sed -i '' 's/module futarchy_streams::/module futarchy_specialized_actions::/g' "$file"
    sed -i '' 's/module futarchy_operating_agreement::/module futarchy_specialized_actions::/g' "$file"
done

# Fix futarchy_one_shot_utils modules
for file in $(find /Users/admin/monorepo/contracts/futarchy_one_shot_utils/sources -name "*.move"); do
    sed -i '' 's/module futarchy_utils::/module futarchy_one_shot_utils::/g' "$file"
done

echo "Module declarations fixed!"
echo ""
echo "Now fixing imports..."

# Update imports across all packages
for package in futarchy_dao futarchy_multisig futarchy_lifecycle futarchy_actions futarchy_specialized_actions futarchy_vault futarchy_markets futarchy_core; do
    for file in $(find /Users/admin/monorepo/contracts/$package/sources -name "*.move"); do
        # Update package renames
        sed -i '' 's/use futarchy::/use futarchy_dao::/g' "$file"
        sed -i '' 's/use futarchy_engine::/use futarchy_dao::/g' "$file"
        sed -i '' 's/use futarchy_utils::/use futarchy_one_shot_utils::/g' "$file"
        sed -i '' 's/use futarchy_security::/use futarchy_multisig::/g' "$file"
        sed -i '' 's/use futarchy_operations::/use futarchy_specialized_actions::/g' "$file"
        sed -i '' 's/use futarchy_streams::/use futarchy_specialized_actions::/g' "$file"
        sed -i '' 's/use futarchy_operating_agreement::/use futarchy_specialized_actions::/g' "$file"
        
        # Fix shared package references
        sed -i '' 's/use futarchy_shared::weighted_multisig/use futarchy_multisig::weighted_multisig/g' "$file"
        sed -i '' 's/use futarchy_shared::security_council/use futarchy_multisig::security_council/g' "$file"
        sed -i '' 's/use futarchy_shared::policy_/use futarchy_multisig::policy_/g' "$file"
        sed -i '' 's/use futarchy_shared::custody_actions/use futarchy_vault::custody_actions/g' "$file"
        sed -i '' 's/use futarchy_shared::futarchy_vault/use futarchy_vault::futarchy_vault/g' "$file"
        sed -i '' 's/use futarchy_shared::lp_token_custody/use futarchy_vault::lp_token_custody/g' "$file"
        sed -i '' 's/use futarchy_shared::factory/use futarchy_lifecycle::factory/g' "$file"
        sed -i '' 's/use futarchy_shared::launchpad/use futarchy_lifecycle::launchpad/g' "$file"
        
        # Fix governance references
        sed -i '' 's/use futarchy_governance::dissolution_/use futarchy_lifecycle::dissolution_/g' "$file"
        sed -i '' 's/use futarchy_governance::governance_actions/use futarchy_specialized_actions::governance_actions/g' "$file"
        sed -i '' 's/use futarchy_governance::governance_dispatcher/use futarchy_specialized_actions::governance_dispatcher/g' "$file"
        sed -i '' 's/use futarchy_governance::governance_intents/use futarchy_specialized_actions::governance_intents/g' "$file"
        
        # Fix version imports - all should use futarchy_core
        sed -i '' 's/use futarchy_[a-z_]*::version/use futarchy_core::version/g' "$file"
        # Special case for futarchy_core itself
        if [[ "$package" == "futarchy_core" ]]; then
            sed -i '' 's/use futarchy_core::version/use crate::version/g' "$file"
        fi
    done
done

echo "Imports fixed!"
echo ""
echo "Summary of changes:"
echo "- All module declarations updated to new package names"
echo "- All imports updated to reference correct packages"
echo "- All version imports now use futarchy_core::version"
echo "- Removed references to deleted futarchy_shared package"