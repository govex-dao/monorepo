#!/bin/bash

echo "Resetting all package addresses to 0x0..."

# Reset each package's Move.toml properly
for pkg_dir in /Users/admin/monorepo/contracts/*/; do
    if [ -f "$pkg_dir/Move.toml" ]; then
        pkg_name=$(basename "$pkg_dir")
        echo "Processing $pkg_name..."
        
        # Create a temporary file with corrected addresses
        awk '
        /^\[addresses\]/ { in_addresses = 1 }
        in_addresses && /^[a-zA-Z_]+ = / {
            # Extract the key name
            split($0, parts, " = ")
            key = parts[1]
            # Set all addresses to 0x0
            print key " = \"0x0\""
            next
        }
        { print }
        ' "$pkg_dir/Move.toml" > "$pkg_dir/Move.toml.tmp"
        
        # Replace the original file
        mv "$pkg_dir/Move.toml.tmp" "$pkg_dir/Move.toml"
    fi
done

# Also reset the move-framework packages
for framework_pkg in protocol extensions actions; do
    toml_file="/Users/admin/monorepo/contracts/move-framework/packages/$framework_pkg/Move.toml"
    if [ -f "$toml_file" ]; then
        echo "Processing move-framework/$framework_pkg..."
        awk '
        /^\[addresses\]/ { in_addresses = 1 }
        in_addresses && /^[a-zA-Z_]+ = / {
            split($0, parts, " = ")
            key = parts[1]
            print key " = \"0x0\""
            next
        }
        { print }
        ' "$toml_file" > "$toml_file.tmp"
        mv "$toml_file.tmp" "$toml_file"
    fi
done

# Reset kiosk
kiosk_toml="/Users/admin/monorepo/contracts/move-framework/deps/kiosk/Move.toml"
if [ -f "$kiosk_toml" ]; then
    echo "Processing kiosk..."
    awk '
    /^\[addresses\]/ { in_addresses = 1 }
    in_addresses && /^[a-zA-Z_]+ = / {
        split($0, parts, " = ")
        key = parts[1]
        print key " = \"0x0\""
        next
    }
    { print }
    ' "$kiosk_toml" > "$kiosk_toml.tmp"
    mv "$kiosk_toml.tmp" "$kiosk_toml"
fi

echo "Reset complete!"