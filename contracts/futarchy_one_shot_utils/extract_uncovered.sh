#!/bin/bash
# Extract uncovered lines from Move test coverage
# Usage: ./extract_uncovered.sh <module_name>

MODULE=${1:-math}

echo "Extracting coverage for module: $MODULE"

# Save coverage with colors preserved
script -q /dev/null sui move coverage source --module "$MODULE" 2>&1 | cat > /tmp/coverage_${MODULE}.txt

# Extract uncovered (red) lines
python3 - "$MODULE" << 'PYEOF'
import sys
import re

module = sys.argv[1] if len(sys.argv) > 1 else 'unknown'

with open(f'/tmp/coverage_{module}.txt', 'rb') as f:
    data = f.read().decode('utf-8', errors='ignore')

print("="*70)
print(f"UNCOVERED LINES IN MODULE: {module}")
print("="*70)
print()

uncovered = []
for line in data.split('\n'):
    # Check for red color code (uncovered) - look for bold red: 1;31m or standard red: 31m/91m
    if '\x1b[1;31m' in line or '\x1b[31m' in line or '\x1b[91m' in line:
        # Remove ANSI codes for display
        clean = re.sub(r'\x1b\[[0-9;]*m', '', line)
        uncovered.append(clean)
        print(clean)

# Now find line numbers by matching against source file
print("\n" + "="*70)
print("LINE NUMBERS:")
print("="*70)

import subprocess
source_file = f'sources/{module}.move'
try:
    for unc_line in uncovered:
        # Extract a unique part of the line to search for
        search_text = unc_line.strip()[:50]  # First 50 chars
        if search_text:
            # Search for this text in the source file
            result = subprocess.run(
                ['grep', '-n', '-F', search_text, source_file],
                capture_output=True, text=True
            )
            if result.stdout:
                line_info = result.stdout.strip().split(':')[0]
                print(f"Line {line_info}: {unc_line.strip()[:80]}")
except Exception as e:
    print(f"Could not find source file: {source_file}")

print()
print("="*70)
print(f"Total uncovered lines: {len(uncovered)}")
print("="*70)

if uncovered:
    # Save to file
    output_file = f'/Users/admin/monorepo/contracts/futarchy_one_shot_utils/uncovered_{module}.txt'
    with open(output_file, 'w') as f:
        f.write('\n'.join(uncovered))
    print(f"\nSaved to: uncovered_{module}.txt")
else:
    print(f"\n✓ 100% coverage - no uncovered lines!")
PYEOF
