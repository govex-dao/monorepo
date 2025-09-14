#!/usr/bin/env python3
"""
Fix all P0, P1, and P2 issues identified in the code review.
"""

import re
import os

def fix_p0_increment_action_idx():
    """P0: Add executable::increment_action_idx to ALL do_ functions."""

    files_to_fix = [
        "/Users/admin/monorepo/contracts/futarchy_actions/sources/liquidity/liquidity_actions.move",
        "/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/dissolution/dissolution_actions.move",
        "/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/payments/stream_actions.move",
        "/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/oracle/oracle_actions.move",
        "/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/payments/payment_actions.move",
    ]

    for file_path in files_to_fix:
        if not os.path.exists(file_path):
            print(f"⚠️  {file_path} not found")
            continue

        with open(file_path, 'r') as f:
            content = f.read()

        # Pattern to find do_ functions that don't already have increment_action_idx
        # Look for functions that have executable but might be missing the increment

        # For functions that validate and execute but don't increment
        pattern = r'(public fun do_\w+[^{]*\{[^}]*action_validation::assert_action_type[^}]*bcs_validation::validate_all_bytes_consumed[^}]*?)(\n\})'

        def add_increment_if_missing(match):
            func_body = match.group(1)
            closing = match.group(2)

            # Check if increment_action_idx already exists
            if 'executable::increment_action_idx' in func_body:
                return match.group(0)  # Already has it

            # Add increment before closing
            return func_body + '\n\n    // Execute and increment\n    executable::increment_action_idx(executable);' + closing

        content = re.sub(pattern, add_increment_if_missing, content, flags=re.DOTALL)

        # Also fix simple do_ functions that might not have validation but still need increment
        # Look for patterns where we have executable parameter but no increment
        pattern2 = r'(public fun do_\w+[^}]*executable: &mut Executable[^}]*\{[^}]*?)(\n\})'

        def check_and_add_increment(match):
            func_body = match.group(1)
            closing = match.group(2)

            # Skip if already has increment or if it returns something (hot potato)
            if 'executable::increment_action_idx' in func_body or '): Resource' in func_body:
                return match.group(0)

            # Skip if function returns a value (look for return or last expression)
            if re.search(r'\n\s+\w+\s*\n\}', func_body):
                return match.group(0)

            # Add increment
            return func_body + '\n\n    // Execute and increment\n    executable::increment_action_idx(executable);' + closing

        content = re.sub(pattern2, check_and_add_increment, content, flags=re.DOTALL)

        with open(file_path, 'w') as f:
            f.write(content)

        print(f"✅ Fixed increment_action_idx in {os.path.basename(file_path)}")

def fix_p1_create_missing_stream_actions():
    """P1: Create missing action structs in stream_actions.move."""

    file_path = "/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/payments/stream_actions.move"

    if not os.path.exists(file_path):
        print(f"⚠️  {file_path} not found")
        return

    with open(file_path, 'r') as f:
        content = f.read()

    # Add missing action structs after the existing ones
    missing_structs = '''
// === Missing Action Structs for Decoders ===

/// Action to create a stream payment
public struct CreateStreamAction<phantom CoinType> has store, drop, copy {
    recipient: address,
    amount_per_period: u64,
    period_duration_ms: u64,
    start_time: u64,
    end_time: Option<u64>,
    cliff_time: Option<u64>,
    cancellable: bool,
    description: String,
}

/// Action to cancel a stream
public struct CancelStreamAction has store, drop, copy {
    stream_id: ID,
    reason: String,
}

/// Action to withdraw from a stream
public struct WithdrawStreamAction has store, drop, copy {
    stream_id: ID,
    amount: u64,
}

/// Action to update stream parameters
public struct UpdateStreamAction has store, drop, copy {
    stream_id: ID,
    new_recipient: Option<address>,
    new_amount_per_period: Option<u64>,
}

/// Action to pause a stream
public struct PauseStreamAction has store, drop, copy {
    stream_id: ID,
    reason: String,
}

/// Action to resume a paused stream
public struct ResumeStreamAction has store, drop, copy {
    stream_id: ID,
}
'''

    # Insert after the module declaration and imports
    insert_position = content.find('// === Errors ===')
    if insert_position > 0:
        content = content[:insert_position] + missing_structs + '\n' + content[insert_position:]

        with open(file_path, 'w') as f:
            f.write(content)

        print("✅ Added missing stream action structs")
    else:
        print("⚠️  Could not find insertion point for stream actions")

def fix_p1_add_missing_action_type_markers():
    """P1: Ensure all action types have markers in action_types.move."""

    file_path = "/Users/admin/monorepo/contracts/futarchy_core/sources/action_types.move"

    with open(file_path, 'r') as f:
        content = f.read()

    # Check for missing types and add them
    missing_types = []

    # Check stream actions
    if 'public struct CreateStream has drop {}' not in content:
        missing_types.append('public struct CreateStream has drop {}')
    if 'public struct CancelStream has drop {}' not in content:
        missing_types.append('public struct CancelStream has drop {}')
    if 'public struct WithdrawStream has drop {}' not in content:
        missing_types.append('public struct WithdrawStream has drop {}')
    if 'public struct UpdateStream has drop {}' not in content:
        missing_types.append('public struct UpdateStream has drop {}')
    if 'public struct PauseStream has drop {}' not in content:
        missing_types.append('public struct PauseStream has drop {}')
    if 'public struct ResumeStream has drop {}' not in content:
        missing_types.append('public struct ResumeStream has drop {}')

    # Payment actions
    if 'public struct CreatePayment has drop {}' not in content:
        missing_types.append('public struct CreatePayment has drop {}')
    if 'public struct CancelPayment has drop {}' not in content:
        missing_types.append('public struct CancelPayment has drop {}')
    if 'public struct ProcessPayment has drop {}' not in content:
        missing_types.append('public struct ProcessPayment has drop {}')

    if missing_types:
        # Find insertion point (after Stream Action Types comment)
        insert_position = content.find('// === Oracle Action Types ===')
        if insert_position > 0:
            new_types = '\n'.join(missing_types) + '\n\n'
            content = content[:insert_position] + new_types + content[insert_position:]

        # Also add accessor functions
        accessor_funcs = []
        for type_def in missing_types:
            type_name = type_def.split(' ')[2]
            func_name = re.sub(r'([A-Z])', r'_\1', type_name).lower().lstrip('_')
            accessor_funcs.append(f'public fun {func_name}(): TypeName {{ type_name::with_defining_ids<{type_name}>() }}')

        if accessor_funcs:
            # Find insertion point for accessors
            insert_position = content.find('// Oracle actions')
            if insert_position > 0:
                new_accessors = '\n'.join(accessor_funcs) + '\n\n'
                content = content[:insert_position] + new_accessors + content[insert_position:]

        with open(file_path, 'w') as f:
            f.write(content)

        print(f"✅ Added {len(missing_types)} missing action type markers")
    else:
        print("✅ All action type markers already present")

def fix_p1_decoder_registrations():
    """P1: Fix decoder type registrations to use actual action types."""

    # Fix liquidity_decoder
    file_path = "/Users/admin/monorepo/contracts/futarchy_actions/sources/liquidity/liquidity_decoder.move"

    if os.path.exists(file_path):
        with open(file_path, 'r') as f:
            content = f.read()

        # Import the actual action types
        if '// Placeholder types' in content:
            content = content.replace(
                '// Placeholder types for registration\npublic struct AssetPlaceholder has drop, store {}\npublic struct StablePlaceholder has drop, store {}',
                '''use futarchy_actions::liquidity_actions::{
    CreatePoolAction,
    UpdatePoolParamsAction,
    RemoveLiquidityAction,
    SwapAction,
    CollectFeesAction,
    SetPoolEnabledAction,
    WithdrawFeesAction,
    SetPoolStatusAction,
};
use futarchy_one_shot_utils::action_data_structs::AddLiquidityAction;

// Placeholder types for generic parameters
public struct AssetPlaceholder has drop, store {}
public struct StablePlaceholder has drop, store {}'''
            )

        # Fix the type registrations to use actual action types
        replacements = [
            ('type_name::with_defining_ids<CreatePoolActionDecoder>()',
             'type_name::with_defining_ids<CreatePoolAction<AssetPlaceholder, StablePlaceholder>>()'),
            ('type_name::with_defining_ids<UpdatePoolParamsActionDecoder>()',
             'type_name::with_defining_ids<UpdatePoolParamsAction>()'),
            ('type_name::with_defining_ids<AddLiquidityActionDecoder>()',
             'type_name::with_defining_ids<AddLiquidityAction<AssetPlaceholder, StablePlaceholder>>()'),
            ('type_name::with_defining_ids<RemoveLiquidityActionDecoder>()',
             'type_name::with_defining_ids<RemoveLiquidityAction<AssetPlaceholder, StablePlaceholder>>()'),
            ('type_name::with_defining_ids<SwapActionDecoder>()',
             'type_name::with_defining_ids<SwapAction<AssetPlaceholder, StablePlaceholder>>()'),
            ('type_name::with_defining_ids<CollectFeesActionDecoder>()',
             'type_name::with_defining_ids<CollectFeesAction<AssetPlaceholder, StablePlaceholder>>()'),
            ('type_name::with_defining_ids<SetPoolEnabledActionDecoder>()',
             'type_name::with_defining_ids<SetPoolEnabledAction>()'),
            ('type_name::with_defining_ids<WithdrawFeesActionDecoder>()',
             'type_name::with_defining_ids<WithdrawFeesAction<AssetPlaceholder, StablePlaceholder>>()'),
        ]

        for old, new in replacements:
            content = content.replace(old, new)

        with open(file_path, 'w') as f:
            f.write(content)

        print("✅ Fixed liquidity_decoder type registrations")

    # Fix stream_decoder
    file_path = "/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/payments/stream_decoder.move"

    if os.path.exists(file_path):
        with open(file_path, 'r') as f:
            content = f.read()

        # Uncomment and fix the imports
        content = content.replace(
            '''// TODO: Fix these imports - action names don't match stream_actions module
// use futarchy_lifecycle::stream_actions::{
//     CreateStreamAction,
//     CancelStreamAction,
//     WithdrawStreamAction,
//     UpdateStreamAction,
//     PauseStreamAction,
//     ResumeStreamAction,
// };''',
            '''use futarchy_lifecycle::stream_actions::{
    CreateStreamAction,
    CancelStreamAction,
    WithdrawStreamAction,
    UpdateStreamAction,
    PauseStreamAction,
    ResumeStreamAction,
};'''
        )

        # Fix type registrations
        replacements = [
            ('type_name::with_defining_ids<CreateStreamActionDecoder>(); // TODO: Fix',
             'type_name::with_defining_ids<CreateStreamAction<CoinPlaceholder>>()'),
            ('type_name::with_defining_ids<CancelStreamActionDecoder>(); // TODO: Fix',
             'type_name::with_defining_ids<CancelStreamAction>()'),
            ('type_name::with_defining_ids<WithdrawStreamActionDecoder>(); // TODO: Fix',
             'type_name::with_defining_ids<WithdrawStreamAction>()'),
            ('type_name::with_defining_ids<UpdateStreamActionDecoder>(); // TODO: Fix',
             'type_name::with_defining_ids<UpdateStreamAction>()'),
            ('type_name::with_defining_ids<PauseStreamActionDecoder>(); // TODO: Fix',
             'type_name::with_defining_ids<PauseStreamAction>()'),
            ('type_name::with_defining_ids<ResumeStreamActionDecoder>(); // TODO: Fix',
             'type_name::with_defining_ids<ResumeStreamAction>()'),
        ]

        for old, new in replacements:
            content = content.replace(old, new)

        with open(file_path, 'w') as f:
            f.write(content)

        print("✅ Fixed stream_decoder type registrations")

def fix_p2_revert_new_functions():
    """P2: Revert new_ functions to return structs instead of bytes."""

    # Fix liquidity_actions.move
    file_path = "/Users/admin/monorepo/contracts/futarchy_actions/sources/liquidity/liquidity_actions.move"

    if os.path.exists(file_path):
        with open(file_path, 'r') as f:
            content = f.read()

        # Revert new_ functions to return structs
        pattern = r'public fun new_(\w+)_action([^)]*)\): vector<u8> \{([^}]*)\n    let bytes = bcs::to_bytes\(&action\);\n    // Destroy the action struct after serialization\n    let [^}]+ = action;\n    bytes\n\}'

        def revert_to_struct(match):
            func_name = match.group(1)
            params = match.group(2)
            body = match.group(3)

            # Extract the action creation part
            action_creation = re.search(r'(let action = [^;]+;)', body)
            if action_creation:
                # Return just the struct
                return f'public fun new_{func_name}_action{params}): {func_name.title().replace("_", "")}Action<AssetType, StableType> {{{body}\n    action\n}}'
            return match.group(0)

        # Manual replacements for better control
        replacements = [
            (r'public fun new_add_liquidity_action<AssetType, StableType>\(([^)]+)\): vector<u8>',
             r'public fun new_add_liquidity_action<AssetType, StableType>(\1): AddLiquidityAction<AssetType, StableType>'),
            (r'public fun new_remove_liquidity_action<AssetType, StableType>\(([^)]+)\): vector<u8>',
             r'public fun new_remove_liquidity_action<AssetType, StableType>(\1): RemoveLiquidityAction<AssetType, StableType>'),
            (r'public fun new_create_pool_action<AssetType, StableType>\(([^)]+)\): vector<u8>',
             r'public fun new_create_pool_action<AssetType, StableType>(\1): CreatePoolAction<AssetType, StableType>'),
            (r'public fun new_update_pool_params_action\(([^)]+)\): vector<u8>',
             r'public fun new_update_pool_params_action(\1): UpdatePoolParamsAction'),
            (r'public fun new_set_pool_status_action\(([^)]+)\): vector<u8>',
             r'public fun new_set_pool_status_action(\1): SetPoolStatusAction'),
            (r'public fun new_swap_action<AssetType, StableType>\(([^)]+)\): vector<u8>',
             r'public fun new_swap_action<AssetType, StableType>(\1): SwapAction<AssetType, StableType>'),
            (r'public fun new_collect_fees_action<AssetType, StableType>\(([^)]+)\): vector<u8>',
             r'public fun new_collect_fees_action<AssetType, StableType>(\1): CollectFeesAction<AssetType, StableType>'),
            (r'public fun new_set_pool_enabled_action\(([^)]+)\): vector<u8>',
             r'public fun new_set_pool_enabled_action(\1): SetPoolEnabledAction'),
            (r'public fun new_withdraw_fees_action<AssetType, StableType>\(([^)]+)\): vector<u8>',
             r'public fun new_withdraw_fees_action<AssetType, StableType>(\1): WithdrawFeesAction<AssetType, StableType>'),
        ]

        for pattern, replacement in replacements:
            content = re.sub(pattern, replacement, content)

        # Remove the serialization logic
        content = re.sub(
            r'    let bytes = bcs::to_bytes\(&action\);\n    // Destroy the action struct after serialization\n    let [^}]+ = action;\n    bytes',
            '    action',
            content
        )

        with open(file_path, 'w') as f:
            f.write(content)

        print("✅ Reverted new_ functions in liquidity_actions.move")

    # Similar fixes for dissolution_actions.move
    file_path = "/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/dissolution/dissolution_actions.move"

    if os.path.exists(file_path):
        with open(file_path, 'r') as f:
            content = f.read()

        # Fix the new_ functions
        replacements = [
            (r'public fun new_initiate_dissolution_action\(([^)]+)\): vector<u8>',
             r'public fun new_initiate_dissolution_action(\1): InitiateDissolutionAction'),
            (r'public fun new_batch_distribute_action\(([^)]+)\): vector<u8>',
             r'public fun new_batch_distribute_action(\1): BatchDistributeAction'),
            (r'public fun new_finalize_dissolution_action\(([^)]+)\): vector<u8>',
             r'public fun new_finalize_dissolution_action(\1): FinalizeDissolutionAction'),
            (r'public fun new_cancel_dissolution_action\(([^)]+)\): vector<u8>',
             r'public fun new_cancel_dissolution_action(\1): CancelDissolutionAction'),
        ]

        for pattern, replacement in replacements:
            content = re.sub(pattern, replacement, content)

        # Remove the serialization logic
        content = re.sub(
            r'    let bytes = bcs::to_bytes\(&action\);\n    // Destroy the action struct after serialization\n    let [^}]+ = action;\n    bytes',
            '    action',
            content
        )

        with open(file_path, 'w') as f:
            f.write(content)

        print("✅ Reverted new_ functions in dissolution_actions.move")

def main():
    print("🔧 Fixing all P0, P1, and P2 issues...")
    print("=" * 50)

    # P0 - Immediate fixes
    print("\n📍 P0: Immediate Fixes")
    fix_p0_increment_action_idx()

    # P1 - Critical fixes
    print("\n📍 P1: Critical Fixes")
    fix_p1_create_missing_stream_actions()
    fix_p1_add_missing_action_type_markers()
    fix_p1_decoder_registrations()

    # P2 - Important fixes
    print("\n📍 P2: Important Fixes")
    fix_p2_revert_new_functions()

    print("\n" + "=" * 50)
    print("✅ All fixes complete!")

if __name__ == "__main__":
    main()