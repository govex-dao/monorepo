#!/usr/bin/env python3
import os
import re
import glob

def fix_malformed_imports(file_path):
    """Fix malformed imports in a Move file"""
    with open(file_path, 'r') as f:
        content = f.read()
    
    original_content = content
    
    # Pattern: Find malformed nested use statements
    # Example: use futarchy_markets:{\nuse futarchy_core::futarchy_config::FutarchyConfig,\n...}
    
    # Look for use package::{...use other_package...}
    pattern = re.compile(
        r'use\s+(futarchy_markets|futarchy_core|futarchy_utils)\s*:\s*\{\s*\n?\s*(use\s+futarchy_[^:]+::[^,}\n]*[,}]?[^}]*?)\s*\n?\s*([^}]*)\};',
        re.MULTILINE | re.DOTALL
    )
    
    def fix_nested_use(match):
        outer_pkg = match.group(1)
        nested_use_line = match.group(2).strip()
        remaining_content = match.group(3).strip()
        
        # Extract the nested use statement
        nested_parts = re.match(r'use\s+(futarchy_[^:]+)::(.*?)([,}]?)', nested_use_line.strip())
        if nested_parts:
            nested_pkg = nested_parts.group(1)
            nested_import = nested_parts.group(2).strip()
            
            # Clean up the nested import to remove trailing commas
            if nested_import.endswith(','):
                nested_import = nested_import[:-1]
            
            # Create the fixed import statement
            fixed_nested = f'use {nested_pkg}::{nested_import};'
            
            # Handle remaining content
            if remaining_content and remaining_content.strip() and remaining_content.strip() != ',':
                # Clean up remaining content
                remaining_content = remaining_content.strip()
                if remaining_content.startswith(','):
                    remaining_content = remaining_content[1:].strip()
                if remaining_content:
                    fixed_outer = f'use {outer_pkg}::{{\n    {remaining_content}\n}};'
                    return f'{fixed_nested}\n{fixed_outer}'
                else:
                    return fixed_nested
            else:
                return fixed_nested
        
        return match.group(0)  # Return original if couldn't parse
    
    content = pattern.sub(fix_nested_use, content)
    
    # Additional cleanup patterns
    # Remove empty use blocks
    content = re.sub(r'use\s+\w+\s*:\s*\{\s*\n?\s*\};', '', content)
    
    # Fix double newlines
    content = re.sub(r'\n\n+', '\n\n', content)
    
    # Only write if content changed
    if content != original_content:
        with open(file_path, 'w') as f:
            f.write(content)
        print(f"Fixed imports in: {file_path}")
        return True
    return False

# Find all Move files in the futarchy package
move_files = glob.glob('/Users/admin/monorepo/contracts/futarchy/sources/**/*.move', recursive=True)

fixed_count = 0
for file_path in move_files:
    if fix_malformed_imports(file_path):
        fixed_count += 1

print(f"Total files fixed: {fixed_count}")

# List files that might still have issues
print("\nChecking for remaining issues...")
for file_path in move_files:
    with open(file_path, 'r') as f:
        content = f.read()
        if re.search(r'use\s+futarchy_[^:]*\s*:\s*\{[^}]*use\s+futarchy_', content):
            print(f"Still has nested use pattern: {file_path}")