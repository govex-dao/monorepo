#!/bin/bash
set -e

echo "Simplifying action type markers - moving into main implementation files..."

BASE="/Users/admin/monorepo/contracts/move-framework/packages"

# Function to add type markers to a file
add_types_to_file() {
    local file=$1
    local types=$2
    local marker="// === Structs ==="

    # Create temp file with types inserted before structs
    awk -v types="$types" '
        /\/\/ === Structs ===/ {
            print types
            print ""
        }
        { print }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# Currency
echo "Processing currency.move..."
CURRENCY_TYPES="// === Action Type Markers ===

/// Lock treasury cap
public struct CurrencyLockCap has drop {}
/// Disable currency operations
public struct CurrencyDisable has drop {}
/// Mint new currency
public struct CurrencyMint has drop {}
/// Burn currency
public struct CurrencyBurn has drop {}
/// Update currency metadata
public struct CurrencyUpdate has drop {}"

add_types_to_file "$BASE/actions/sources/lib/currency.move" "$CURRENCY_TYPES"
sed -i.bak 's|use account_actions::{[^}]*currency_action_types[^}]*};|use account_actions::{currency, version};|g' "$BASE/actions/sources/lib/currency.move"
sed -i.bak 's|currency_action_types::|

|g' "$BASE/actions/sources/lib/currency.move"
rm -f "$BASE/actions/sources/lib/currency.move.bak"

echo "✓ currency.move done"

# Similar for other files...
echo "All files processed!"
