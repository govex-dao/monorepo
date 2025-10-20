#!/bin/bash

# Script to update remaining action files from framework_action_types to local action_types

set -e

echo "Refactoring move-framework action types..."

# Function to update a file
update_file() {
    local file=$1
    local old_import=$2
    local new_import=$3
    local old_prefix=$4
    local new_prefix=$5

    if [ -f "$file" ]; then
        echo "Updating $file..."

        # Update import statement
        sed -i.bak "s|$old_import|$new_import|g" "$file"

        # Update all type references
        sed -i.bak "s|$old_prefix|$new_prefix|g" "$file"

        # Remove backup
        rm -f "${file}.bak"

        echo "  ✓ Done"
    else
        echo "  ✗ File not found: $file"
    fi
}

BASE="/Users/admin/monorepo/contracts/move-framework/packages"

# Vesting
update_file \
    "$BASE/actions/sources/lib/vesting.move" \
    "use account_extensions::framework_action_types::\{Self, VestingCreate, VestingCancel\}" \
    "use account_actions::vesting_action_types" \
    "framework_action_types::" \
    "vesting_action_types::"

# Transfer
update_file \
    "$BASE/actions/sources/lib/transfer.move" \
    "use account_extensions::framework_action_types::\{Self, TransferObject\}" \
    "use account_actions::transfer_action_types" \
    "framework_action_types::" \
    "transfer_action_types::"

# Package Upgrade
update_file \
    "$BASE/actions/sources/lib/package_upgrade.move" \
    "use account_extensions::framework_action_types::\{Self, PackageUpgrade, PackageCommit, PackageRestrict, PackageCreateCommitCap\}" \
    "use account_actions::package_upgrade_action_types" \
    "framework_action_types::" \
    "package_upgrade_action_types::"

# Access Control
update_file \
    "$BASE/actions/sources/lib/access_control.move" \
    "use account_extensions::framework_action_types" \
    "use account_actions::access_control_action_types" \
    "framework_action_types::" \
    "access_control_action_types::"

# Memo
update_file \
    "$BASE/actions/sources/lib/memo.move" \
    "use account_extensions::framework_action_types::\{Self, Memo\}" \
    "use account_actions::memo_action_types" \
    "framework_action_types::" \
    "memo_action_types::"

# Config (protocol package)
update_file \
    "$BASE/protocol/sources/actions/config.move" \
    "use account_extensions::framework_action_types::\{Self, ConfigUpdateDeps, ConfigUpdateMetadata\}" \
    "use account_protocol::config_action_types" \
    "framework_action_types::" \
    "config_action_types::"

# Owned (protocol package)
update_file \
    "$BASE/protocol/sources/actions/owned.move" \
    "use account_extensions::framework_action_types" \
    "use account_protocol::owned_action_types" \
    "framework_action_types::" \
    "owned_action_types::"

echo ""
echo "✓ All action files updated!"
echo ""
echo "Next steps:"
echo "1. Update test files (if any reference framework_action_types)"
echo "2. Run: cd $BASE && sui move test"
echo "3. If tests pass, delete framework_action_types.move"
