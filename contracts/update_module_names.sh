#!/bin/bash

# Update module declarations in futarchy_vault
for file in /Users/admin/monorepo/contracts/futarchy_vault/sources/*.move; do
    if [ -f "$file" ]; then
        sed -i '' 's/module futarchy_shared::/module futarchy_vault::/g' "$file"
    fi
done

# Update module declarations in futarchy_security
for file in /Users/admin/monorepo/contracts/futarchy_security/sources/*.move; do
    if [ -f "$file" ]; then
        sed -i '' 's/module futarchy_shared::/module futarchy_security::/g' "$file"
        sed -i '' 's/module futarchy::/module futarchy_security::/g' "$file"
    fi
done

for file in /Users/admin/monorepo/contracts/futarchy_security/sources/coexec/*.move; do
    if [ -f "$file" ]; then
        sed -i '' 's/module futarchy::/module futarchy_security::/g' "$file"
    fi
done

# Update module declarations in futarchy_lifecycle
for file in /Users/admin/monorepo/contracts/futarchy_lifecycle/sources/factory/*.move; do
    if [ -f "$file" ]; then
        sed -i '' 's/module futarchy_shared::/module futarchy_lifecycle::/g' "$file"
        sed -i '' 's/module futarchy::/module futarchy_lifecycle::/g' "$file"
    fi
done

for file in /Users/admin/monorepo/contracts/futarchy_lifecycle/sources/dissolution/*.move; do
    if [ -f "$file" ]; then
        sed -i '' 's/module futarchy_governance::/module futarchy_lifecycle::/g' "$file"
    fi
done

for file in /Users/admin/monorepo/contracts/futarchy_lifecycle/sources/garbage-collection/*.move; do
    if [ -f "$file" ]; then
        sed -i '' 's/module futarchy::/module futarchy_lifecycle::/g' "$file"
    fi
done

# Update module declarations in futarchy_operations
for file in /Users/admin/monorepo/contracts/futarchy_operations/sources/payments/*.move; do
    if [ -f "$file" ]; then
        sed -i '' 's/module futarchy_streams::/module futarchy_operations::/g' "$file"
    fi
done

for file in /Users/admin/monorepo/contracts/futarchy_operations/sources/legal/*.move; do
    if [ -f "$file" ]; then
        sed -i '' 's/module futarchy_operating_agreement::/module futarchy_operations::/g' "$file"
    fi
done

# Update module declarations in futarchy_engine
for file in /Users/admin/monorepo/contracts/futarchy_engine/sources/**/*.move; do
    if [ -f "$file" ]; then
        sed -i '' 's/module futarchy::/module futarchy_engine::/g' "$file"
    fi
done

echo "Module declarations updated"