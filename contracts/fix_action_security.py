#!/usr/bin/env python3
"""
Fix security vulnerability in do_* functions by adding type assertions.
This script converts vulnerable next_action patterns to secure is_current_action patterns.
"""

import re
import sys
from pathlib import Path

def fix_do_function(content, function_match):
    """Fix a single do_ function by adding type assertion."""

    # Extract function content
    func_start = function_match.start()

    # Find the matching closing brace for the function
    brace_count = 0
    in_func = False
    func_end = func_start

    for i in range(func_start, len(content)):
        if content[i] == '{':
            brace_count += 1
            in_func = True
        elif content[i] == '}':
            brace_count -= 1
            if in_func and brace_count == 0:
                func_end = i + 1
                break

    func_content = content[func_start:func_end]

    # Find the next_action line
    next_action_pattern = r'let action.*?=.*?executable(?:::)?\.next_action.*?\);'
    next_action_match = re.search(next_action_pattern, func_content, re.DOTALL)

    if not next_action_match:
        return None

    # Extract the action type from the line
    action_type_pattern = r'let action:\s*&?(\w+)\s*='
    type_match = re.search(action_type_pattern, next_action_match.group())

    if not type_match:
        # Try to extract from generic parameters
        generic_pattern = r'next_action<[^,]+,\s*(\w+)'
        type_match = re.search(generic_pattern, next_action_match.group())
        if not type_match:
            print(f"Could not extract action type from: {next_action_match.group()}")
            return None

    action_type = type_match.group(1)

    # Build the replacement
    original_line = next_action_match.group()

    # Create the secure version
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
    let action: {action_type} = bcs::from_bytes(*action_data);'''

    # Replace the vulnerable line with the secure version
    new_func_content = func_content.replace(original_line, replacement)

    # Add increment_action_idx at the end if not present
    if 'executable::increment_action_idx' not in new_func_content:
        # Find the last closing brace
        last_brace = new_func_content.rfind('}')
        if last_brace > 0:
            new_func_content = (new_func_content[:last_brace] +
                               '\n    // Increment action index\n' +
                               '    executable::increment_action_idx(executable);\n' +
                               new_func_content[last_brace:])

    return content[:func_start] + new_func_content + content[func_end:]

def process_file(filepath):
    """Process a single Move file to fix vulnerable do_ functions."""

    print(f"Processing {filepath}...")

    with open(filepath, 'r') as f:
        content = f.read()

    # Check if file needs fixing
    if 'executable.next_action' not in content and 'executable::next_action' not in content:
        print(f"  No vulnerable patterns found.")
        return False

    # Find all do_ functions
    do_func_pattern = r'public fun do_\w+<[^>]+>\s*\([^)]+\)[^{]*\{'

    modified = False
    for match in re.finditer(do_func_pattern, content):
        # Check if this function uses next_action
        func_start = match.start()
        func_preview = content[func_start:func_start + 1000]

        if 'next_action' in func_preview:
            print(f"  Fixing function at position {func_start}...")
            new_content = fix_do_function(content, match)
            if new_content:
                content = new_content
                modified = True

    if modified:
        # Ensure required imports are present
        if 'use sui::bcs' not in content:
            # Add bcs import after other sui imports
            sui_import_pos = content.find('use sui::')
            if sui_import_pos >= 0:
                # Find the end of sui imports block
                next_use = content.find('\nuse ', sui_import_pos + 1)
                if next_use > 0:
                    content = content[:next_use] + '    bcs::{Self, BCS},\n' + content[next_use:]

        # Ensure error constant is defined
        if 'const EWrongAction' not in content:
            # Add after other error constants
            error_section = content.find('// === Errors ===')
            if error_section >= 0:
                next_section = content.find('// ===', error_section + 1)
                if next_section > 0:
                    content = (content[:next_section] +
                              'const EWrongAction: u64 = 9999;\n' +
                              'const EUnsupportedActionVersion: u64 = 9998;\n\n' +
                              content[next_section:])

        # Ensure protocol_intents alias exists
        if 'protocol_intents' not in content:
            # Add alias after imports
            use_section_end = content.rfind('use ')
            if use_section_end >= 0:
                next_line = content.find('\n', use_section_end)
                if next_line > 0:
                    content = (content[:next_line + 1] +
                              '\n// === Aliases ===\n' +
                              'use account_protocol::intents as protocol_intents;\n\n' +
                              content[next_line + 1:])

        # Write back the fixed content
        with open(filepath, 'w') as f:
            f.write(content)

        print(f"  Fixed and saved.")
        return True

    print(f"  No changes needed.")
    return False

def main():
    """Main function to process all vulnerable files."""

    vulnerable_files = [
        '/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/payments/stream_actions.move',
        '/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/dissolution/dissolution_actions.move',
        '/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/oracle/oracle_actions.move',
        '/Users/admin/monorepo/contracts/futarchy_specialized_actions/sources/legal/operating_agreement_actions.move',
        '/Users/admin/monorepo/contracts/futarchy_actions/sources/intent_lifecycle/founder_lock_actions.move',
        '/Users/admin/monorepo/contracts/futarchy_actions/sources/intent_lifecycle/protocol_admin_actions.move',
        '/Users/admin/monorepo/contracts/futarchy_actions/sources/memo/memo_actions.move',
        '/Users/admin/monorepo/contracts/futarchy_actions/sources/governance/platform_fee_actions.move',
        '/Users/admin/monorepo/contracts/futarchy_actions/sources/governance/governance_actions.move',
        '/Users/admin/monorepo/contracts/futarchy_actions/sources/liquidity/liquidity_actions.move',
        '/Users/admin/monorepo/contracts/futarchy_multisig/sources/policy/policy_actions.move',
    ]

    fixed_count = 0
    for filepath in vulnerable_files:
        if Path(filepath).exists():
            if process_file(filepath):
                fixed_count += 1
        else:
            print(f"File not found: {filepath}")

    print(f"\nFixed {fixed_count} files.")

if __name__ == '__main__':
    main()