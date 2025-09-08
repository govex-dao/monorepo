#!/bin/bash

OUTPUT_FILE="/Users/admin/monorepo/contracts/futarchy_move_files.txt"

# Clear the output file
> "$OUTPUT_FILE"

echo "==================================================" >> "$OUTPUT_FILE"
echo "FUTARCHY PACKAGES - MOVE FILE INVENTORY" >> "$OUTPUT_FILE"
echo "==================================================" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# Array of packages in dependency order
packages=(
    "futarchy_utils"
    "futarchy_core" 
    "futarchy_markets"
    "futarchy_shared"
    "futarchy_streams"
    "futarchy_operating_agreement"
    "futarchy_governance"
    "futarchy"
)

total_files=0

for package in "${packages[@]}"; do
    package_dir="/Users/admin/monorepo/contracts/$package"
    
    if [ -d "$package_dir/sources" ]; then
        echo "==================================================" >> "$OUTPUT_FILE"
        echo "PACKAGE: $package" >> "$OUTPUT_FILE"
        echo "==================================================" >> "$OUTPUT_FILE"
        
        # Count files in this package
        file_count=$(find "$package_dir/sources" -name "*.move" -type f | grep -v test | wc -l | tr -d ' ')
        echo "Total files: $file_count" >> "$OUTPUT_FILE"
        echo "" >> "$OUTPUT_FILE"
        
        # List all .move files with their paths relative to sources
        find "$package_dir/sources" -name "*.move" -type f | grep -v test | sort | while read file; do
            # Get relative path from sources directory
            rel_path="${file#$package_dir/sources/}"
            echo "  - $rel_path" >> "$OUTPUT_FILE"
        done
        
        echo "" >> "$OUTPUT_FILE"
        total_files=$((total_files + file_count))
    fi
done

echo "==================================================" >> "$OUTPUT_FILE"
echo "SUMMARY" >> "$OUTPUT_FILE"
echo "==================================================" >> "$OUTPUT_FILE"
echo "Total packages: ${#packages[@]}" >> "$OUTPUT_FILE"

# Recount total files
total_files=0
for package in "${packages[@]}"; do
    package_dir="/Users/admin/monorepo/contracts/$package"
    if [ -d "$package_dir/sources" ]; then
        file_count=$(find "$package_dir/sources" -name "*.move" -type f | grep -v test | wc -l | tr -d ' ')
        total_files=$((total_files + file_count))
        echo "$package: $file_count files" >> "$OUTPUT_FILE"
    fi
done

echo "" >> "$OUTPUT_FILE"
echo "Total .move files: $total_files" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# Add timestamp
echo "Generated on: $(date)" >> "$OUTPUT_FILE"

echo "Report generated: $OUTPUT_FILE"
cat "$OUTPUT_FILE"