#!/bin/bash
# Extract uncovered lines from Move test coverage
# Usage: ./extract_uncovered.sh <module_name>

MODULE=${1:-math}

echo "Extracting coverage for module: $MODULE"

# Save coverage with colors preserved
script -q /dev/null ~/sui-tracing/target/release/sui move coverage source --module "$MODULE" 2>&1 | cat > /tmp/coverage_${MODULE}.txt

# Extract uncovered (red) lines
python3 << 'PYEOF'
import sys
import re

module = sys.argv[1] if len(sys.argv) > 1 else 'math'

with open(f'/tmp/coverage_{module}.txt', 'rb') as f:
    data = f.read().decode('utf-8', errors='ignore')

print("="*70)
print(f"UNCOVERED LINES IN MODULE: {module}")
print("="*70)
print()

uncovered = []
for line in data.split('\n'):
    # Check for red color code (uncovered)
    if '\x1b[1;31m' in line:
        # Remove ANSI codes for display
        clean = re.sub(r'\x1b\[[0-9;]*m', '', line)
        uncovered.append(clean)
        print(clean)

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
PYEOF "$MODULE"
