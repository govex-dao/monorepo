#!/usr/bin/env python3
"""
Batch fix security vulnerabilities in all futarchy action files.
Converts vulnerable next_action patterns to secure is_current_action patterns.
"""

import os
import re
import sys

def ensure_imports(content):
    """Ensure required imports are present."""

    # Check for BCS import
    if 'bcs::{Self' not in content and 'bcs::' not in content:
        # Add bcs to sui imports
        content = content.replace(
            'use sui::{',
            'use sui::{\n    bcs::{Self, BCS},'
        )

    # Check for object import (need object::id)
    if 'object::{Self' not in content and 'object::id' not in content:
        content = content.replace(
            'object::ID',
            'object::{Self, ID}'
        )
        content = content.replace(
            'object,',
            'object::{Self, ID},'
        )

    # Check for intents import
    if 'use account_protocol::intents as protocol_intents' not in content:
        # Add after other account_protocol imports
        account_import_pos = content.find('use account_protocol::')
        if account_import_pos >= 0:
            # Find the end of account_protocol imports
            next_use = content.find('\nuse ', account_import_pos)
            if next_use > 0:
                # Insert before next use statement
                content = content[:next_use] + '\n\n// === Aliases ===\nuse account_protocol::intents as protocol_intents;\n' + content[next_use:]
            else:
                # Add at end of imports
                import_end = content.rfind('};')
                if import_end > 0:
                    next_line = content.find('\n', import_end)
                    content = content[:next_line] + '\n\n// === Aliases ===\nuse account_protocol::intents as protocol_intents;\n' + content[next_line:]

    # Ensure intents is imported
    if ',\n    intents' not in content and '\n    intents,' not in content:
        content = content.replace(
            'version_witness::VersionWitness',
            'version_witness::VersionWitness,\n    intents'
        )

    return content

def ensure_error_constants(content):
    """Ensure required error constants are defined."""

    if 'const EWrongAction' not in content:
        # Find error section
        error_pos = content.find('// === Errors ===')
        if error_pos >= 0:
            # Find next section or next public declaration
            next_section = content.find('\n// ===', error_pos + 1)
            if next_section < 0:
                next_section = content.find('\npublic ', error_pos)

            if next_section > 0:
                # Add error constants before next section
                content = content[:next_section] + '\nconst EWrongAction: u64 = 9999;\nconst EUnsupportedActionVersion: u64 = 9998;\n' + content[next_section:]
        else:
            # No error section, add one
            module_end = content.find('module ')
            if module_end >= 0:
                next_line = content.find('\n', module_end)
                content = content[:next_line] + '\n\n// === Errors ===\nconst EWrongAction: u64 = 9999;\nconst EUnsupportedActionVersion: u64 = 9998;\n' + content[next_line:]

    return content

def fix_next_action_call(content):
    """Fix all next_action calls in the content."""

    # Pattern to find next_action calls
    patterns = [
        (r'let\s+(\w+):\s*&(\w+)\s*=\s*executable::next_action\([^)]+\);', True),  # Reference type
        (r'let\s+(\w+):\s*(\w+)\s*=\s*executable::next_action\([^)]+\);', False),  # Value type
        (r'let\s+(\w+)\s*=\s*executable::next_action<[^,]+,\s*(\w+)[^>]*>\([^)]+\);', False),  # Generic with type
        (r'let\s+(\w+):\s*&(\w+)\s*=\s*executable\.next_action\([^)]+\);', True),  # Method call reference
        (r'let\s+(\w+):\s*(\w+)\s*=\s*executable\.next_action\([^)]+\);', False),  # Method call value
    ]

    for pattern, is_ref in patterns:
        for match in re.finditer(pattern, content):
            var_name = match.group(1)
            action_type = match.group(2)
            original = match.group(0)

            # Build replacement
            if is_ref:
                replacement = f'''// Verify this is the current action
    assert!(executable::is_current_action<Outcome, {action_type}>(executable), EWrongAction);

    // Get BCS bytes from ActionSpec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    let action_data = protocol_intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize the action
    let {var_name}: {action_type} = bcs::from_bytes(*action_data);'''
            else:
                replacement = f'''// Verify this is the current action
    assert!(executable::is_current_action<Outcome, {action_type}>(executable), EWrongAction);

    // Get BCS bytes from ActionSpec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    let action_data = protocol_intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize the action
    let {var_name}: {action_type} = bcs::from_bytes(*action_data);'''

            content = content.replace(original, replacement)

    return content

def ensure_increment_action_idx(content):
    """Ensure each do_ function has increment_action_idx at the end."""

    # Find all do_ functions
    do_func_pattern = r'(public fun do_\w+<[^>]+>\s*\([^)]+\)[^{]*\{[^}]+\})'

    def add_increment(match):
        func_content = match.group(0)

        # Check if increment_action_idx is already present
        if 'executable::increment_action_idx' in func_content:
            return func_content

        # Find the last closing brace
        last_brace_pos = func_content.rfind('}')
        if last_brace_pos > 0:
            # Add increment before the last brace
            return (func_content[:last_brace_pos] +
                   '\n\n    // Increment action index\n' +
                   '    executable::increment_action_idx(executable);\n' +
                   func_content[last_brace_pos:])

        return func_content

    # Apply to all do_ functions
    content = re.sub(do_func_pattern, add_increment, content, flags=re.DOTALL)

    return content

def process_file(filepath):
    """Process a single file to fix vulnerabilities."""

    print(f"Processing {filepath}...")

    with open(filepath, 'r') as f:
        content = f.read()

    # Check if file needs fixing
    if 'next_action' not in content:
        print(f"  No vulnerable patterns found.")
        return False

    # Apply fixes
    original_content = content

    # 1. Ensure imports
    content = ensure_imports(content)

    # 2. Ensure error constants
    content = ensure_error_constants(content)

    # 3. Fix next_action calls
    content = fix_next_action_call(content)

    # 4. Ensure increment_action_idx
    content = ensure_increment_action_idx(content)

    # Check if content changed
    if content != original_content:
        with open(filepath, 'w') as f:
            f.write(content)
        print(f"  Fixed and saved.")
        return True
    else:
        print(f"  No changes needed.")
        return False

def main():
    """Main function to process all files."""

    files_to_fix = [
        'futarchy_lifecycle/sources/payments/stream_actions.move',
        'futarchy_lifecycle/sources/dissolution/dissolution_actions.move',
        'futarchy_lifecycle/sources/oracle/oracle_actions.move',
        'futarchy_specialized_actions/sources/legal/operating_agreement_actions.move',
        'futarchy_actions/sources/intent_lifecycle/founder_lock_actions.move',
        'futarchy_actions/sources/intent_lifecycle/protocol_admin_actions.move',
        'futarchy_actions/sources/governance/platform_fee_actions.move',
        'futarchy_actions/sources/governance/governance_actions.move',
        'futarchy_actions/sources/liquidity/liquidity_actions.move',
        'futarchy_multisig/sources/policy/policy_actions.move',
    ]

    # Change to contracts directory
    os.chdir('/Users/admin/monorepo/contracts')

    fixed_count = 0
    for filepath in files_to_fix:
        if os.path.exists(filepath):
            if process_file(filepath):
                fixed_count += 1
        else:
            print(f"File not found: {filepath}")

    print(f"\nFixed {fixed_count} files.")

if __name__ == '__main__':
    main()