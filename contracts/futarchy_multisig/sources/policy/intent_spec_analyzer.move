// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Analyzes InitActionSpecs to determine policy requirements before intent creation
/// Similar to descriptor_analyzer but works on action specs instead of live intents
///
/// COMPREHENSIVE POLICY CHECKING (TYPE + OBJECT + FILE):
/// This module checks ALL THREE policy types:
/// - Type policies (action types like mints, spends, etc.)
/// - Object policies (specific objects being withdrawn)
/// - File policies (specific documents being modified)
///
/// IDs are extracted directly from action specs by deserializing the BCS data!
/// No context structures needed - much simpler architecture.
module futarchy_multisig::intent_spec_analyzer;

use std::option::{Self, Option};
use std::string::String;
use std::type_name::TypeName;
use std::vector;
use sui::{object::{Self, ID}, bcs};
use futarchy_types::init_action_specs::{Self, InitActionSpecs};
use futarchy_multisig::policy_registry::{Self, PolicyRegistry};
use futarchy_core::action_type_markers;
use account_extensions::framework_action_types;

/// Approval requirement result (same as descriptor_analyzer)
public struct ApprovalRequirement has copy, drop, store {
    needs_dao: bool,
    needs_council: bool,
    council_id: Option<ID>,
    mode: u8, // 0=DAO_ONLY, 1=COUNCIL_ONLY, 2=DAO_OR_COUNCIL, 3=DAO_AND_COUNCIL
}

/// Analyze InitActionSpecs to determine approval requirements
/// This is the pre-intent version that works on action specs
public fun analyze_requirements(
    init_specs: &InitActionSpecs,
    registry: &PolicyRegistry,
): ApprovalRequirement {
    let specs = action_specs::actions(init_specs);

    let mut needs_dao = false;
    let mut needs_council = false;
    let mut council_id: Option<ID> = option::none();
    let mut mode = 0u8; // Default DAO_ONLY

    // Check each action spec
    let mut i = 0;
    while (i < vector::length(specs)) {
        let spec = vector::borrow(specs, i);
        let action_type = action_specs::action_type(spec);

        // Check if this type has a policy
        if (policy_registry::type_needs_council(registry, action_type)) {
            let type_mode = policy_registry::get_type_mode(registry, action_type);
            let type_council = policy_registry::get_type_council(registry, action_type);

            // Update requirements based on this type's policy
            // Use the MOST restrictive policy found
            if (type_mode > mode || (type_mode == mode && option::is_some(&type_council))) {
                mode = type_mode;
                if (option::is_some(&type_council)) {
                    council_id = type_council;
                };
            };
        };

        i = i + 1;
    };

    // Determine if council approval is needed
    // Mode 1 (COUNCIL_ONLY), 2 (DAO_OR), or 3 (DAO_AND) need council
    needs_council = (mode == 1 || mode == 2 || mode == 3);

    // Determine if DAO approval is needed based on mode
    // Mode 0 (DAO_ONLY) or 2 (DAO_OR) or 3 (DAO_AND) need DAO
    // Mode 1 (COUNCIL_ONLY) doesn't need DAO
    needs_dao = (mode == 0 || mode == 2 || mode == 3);

    ApprovalRequirement {
        needs_dao,
        needs_council,
        council_id,
        mode,
    }
}

/// Check if approvals are satisfied (same logic as descriptor_analyzer)
public fun check_approvals(
    requirement: &ApprovalRequirement,
    dao_approved: bool,
    council_approved: bool,
): bool {
    let mode = requirement.mode;

    if (mode == 0) { // DAO_ONLY
        dao_approved
    } else if (mode == 1) { // COUNCIL_ONLY
        council_approved
    } else if (mode == 2) { // DAO_OR_COUNCIL
        dao_approved || council_approved
    } else if (mode == 3) { // DAO_AND_COUNCIL
        dao_approved && council_approved
    } else {
        false
    }
}

// Getters
public fun needs_dao(req: &ApprovalRequirement): bool { req.needs_dao }
public fun needs_council(req: &ApprovalRequirement): bool { req.needs_council }
public fun council_id(req: &ApprovalRequirement): &Option<ID> { &req.council_id }
public fun mode(req: &ApprovalRequirement): u8 { req.mode }

// === COMPREHENSIVE POLICY ANALYSIS ===

/// Analyze ALL policies with OVERRIDE HIERARCHY: OBJECT > TYPE > ACTION
///
/// Extracts IDs directly from action specs by deserializing BCS data!
/// No context structures needed - IDs are already in the action_data bytes.
///
/// Policy hierarchy (OVERRIDE semantics - first match wins):
/// 1. OBJECT: "Can we use/withdraw this specific object?" (highest priority)
/// 2. TYPE: "Can we use this coin type?" (overrides action policy)
/// 3. ACTION: "Can we execute this action type?" (lowest priority, default)
///
/// Example: If specific vault has OBJECT policy, it overrides TYPE (SUI) and ACTION (VaultSpend) policies
///
/// Returns policy from first matching level in hierarchy (OVERRIDE, not merge)
public fun analyze_requirements_comprehensive(
    init_specs: &InitActionSpecs,
    registry: &PolicyRegistry,
): ApprovalRequirement {
    let specs = action_specs::actions(init_specs);

    let mut final_mode = 0u8;  // Default: DAO_ONLY
    let mut final_council: Option<ID> = option::none();

    // Check each action and apply override hierarchy
    let mut i = 0;
    while (i < vector::length(specs)) {
        let spec = vector::borrow(specs, i);
        let action_type = action_specs::action_type(spec);

        // === HIERARCHY LEVEL 1: OBJECT POLICY (highest priority) ===
        let object_id_opt = try_extract_object_id(spec);
        if (option::is_some(&object_id_opt)) {
            let object_id = *option::borrow(&object_id_opt);
            if (policy_registry::object_needs_council(registry, object_id)) {
                let mode = policy_registry::get_object_mode(registry, object_id);
                let council = policy_registry::get_object_council(registry, object_id);
                // OBJECT policy found - use it and skip TYPE/ACTION checks (override)
                (final_mode, final_council) = apply_most_restrictive(
                    final_mode,
                    final_council,
                    mode,
                    council
                );
                i = i + 1;
                continue
            };
        };

        // === HIERARCHY LEVEL 2: TYPE POLICY (coin type or cap type) ===
        let coin_type_opt = try_extract_coin_type(spec);
        if (option::is_some(&coin_type_opt)) {
            let coin_type = *option::borrow(&coin_type_opt);
            if (policy_registry::type_needs_council(registry, coin_type)) {
                let mode = policy_registry::get_type_mode(registry, coin_type);
                let council = policy_registry::get_type_council(registry, coin_type);
                // TYPE policy found - use it and skip ACTION check (override)
                (final_mode, final_council) = apply_most_restrictive(
                    final_mode,
                    final_council,
                    mode,
                    council
                );
                i = i + 1;
                continue
            };
        };

        // Also check cap type for access control actions
        let cap_type_opt = try_extract_cap_type(spec);
        if (option::is_some(&cap_type_opt)) {
            let cap_type = *option::borrow(&cap_type_opt);
            if (policy_registry::type_needs_council(registry, cap_type)) {
                let mode = policy_registry::get_type_mode(registry, cap_type);
                let council = policy_registry::get_type_council(registry, cap_type);
                // TYPE policy found - use it and skip ACTION check (override)
                (final_mode, final_council) = apply_most_restrictive(
                    final_mode,
                    final_council,
                    mode,
                    council
                );
                i = i + 1;
                continue
            };
        };

        // === HIERARCHY LEVEL 3: ACTION POLICY (lowest priority, default) ===
        let (action_mode, action_council) = check_type_policy(registry, action_type);
        (final_mode, final_council) = apply_most_restrictive(
            final_mode,
            final_council,
            action_mode,
            action_council
        );

        // === FILE POLICY (treated same as OBJECT - specific resource) ===
        // Files are objects with IDs, so we use object_policies table
        let file_id_opt = try_extract_file_id(spec);
        if (option::is_some(&file_id_opt)) {
            let file_id = *option::borrow(&file_id_opt);
            if (policy_registry::object_needs_council(registry, file_id)) {
                let mode = policy_registry::get_object_mode(registry, file_id);
                let council = policy_registry::get_object_council(registry, file_id);
                // FILE policy found - use it and skip lower levels (override)
                (final_mode, final_council) = apply_most_restrictive(
                    final_mode,
                    final_council,
                    mode,
                    council
                );
                i = i + 1;
                continue
            };
        };

        i = i + 1;
    };

    // Convert mode to needs_dao/needs_council
    let needs_council = (final_mode == 1 || final_mode == 2 || final_mode == 3);
    let needs_dao = (final_mode == 0 || final_mode == 2 || final_mode == 3);

    ApprovalRequirement {
        needs_dao,
        needs_council,
        council_id: final_council,
        mode: final_mode,
    }
}

/// Check TYPE policy for a single action type
/// Returns (mode, council_id)
fun check_type_policy(
    registry: &PolicyRegistry,
    action_type: TypeName,
): (u8, Option<ID>) {
    if (policy_registry::type_needs_council(registry, action_type)) {
        let mode = policy_registry::get_type_mode(registry, action_type);
        let council = policy_registry::get_type_council(registry, action_type);
        (mode, council)
    } else {
        (0, option::none()) // DAO_ONLY
    }
}

// Old helper functions removed - we now extract IDs directly from action specs!

/// Apply most restrictive policy when multiple actions in same spec
/// Policy strictness order: 0 (DAO_ONLY) < 2 (OR) < 1 (COUNCIL_ONLY) < 3 (AND)
///
/// Logic:
/// - Mode 3 (AND) is most restrictive - requires both approvals
/// - Mode 1 (COUNCIL_ONLY) is second - council required, DAO not needed
/// - Mode 2 (OR) is third - either approval works
/// - Mode 0 (DAO_ONLY) is least restrictive - just DAO
///
/// Note: This is used to combine policies from MULTIPLE actions in the same IntentSpec.
/// Within a single action, the hierarchy (OBJECT > TYPE > ACTION) uses first-match-wins.
fun apply_most_restrictive(
    current_mode: u8,
    current_council: Option<ID>,
    new_mode: u8,
    new_council: Option<ID>,
): (u8, Option<ID>) {
    // Define strictness order
    let current_strictness = if (current_mode == 3) { 3 }
                            else if (current_mode == 1) { 2 }
                            else if (current_mode == 2) { 1 }
                            else { 0 };

    let new_strictness = if (new_mode == 3) { 3 }
                        else if (new_mode == 1) { 2 }
                        else if (new_mode == 2) { 1 }
                        else { 0 };

    if (new_strictness > current_strictness) {
        (new_mode, new_council)
    } else {
        (current_mode, current_council)
    }
}

// === ID EXTRACTION HELPERS ===

/// Try to extract coin/asset type from action spec
///
/// # Returns
/// - `Some(TypeName)`: The action's full parameterized type (e.g., `SpendAction<SUI>`)
/// - `None`: Action is not parameterized (no type parameter)
///
/// # How It Works
/// Checks if the action TypeName contains type parameters by looking for '<' in the string.
/// If parameterized, returns the full action type for policy lookup.
///
/// # Policy Registration Model
/// Type-level policies can be registered on parameterized action types:
/// ```move
/// // Register policy for SUI spending specifically
/// set_type_policy<SpendAction<SUI>>(
///     account,
///     option::some(treasury_council_id),
///     MODE_DAO_ONLY
/// );
///
/// // Register policy for USDC spending specifically
/// set_type_policy<SpendAction<USDC>>(
///     account,
///     option::some(treasury_council_id),
///     MODE_COUNCIL_ONLY  // Different policy!
/// );
/// ```
///
/// # Requirements
/// Actions MUST be registered with parameterized TypeNames:
/// ```move
/// // ❌ OLD: Non-parameterized
/// intent.add_typed_action(
///     framework_action_types::vault_spend(),  // Returns VaultSpend {}
///     data,
///     witness
/// );
///
/// // ✅ NEW: Parameterized
/// intent.add_action_spec(
///     type_name::get<SpendAction<CoinType>>(),  // Includes CoinType parameter
///     data,
///     witness
/// );
/// ```
fun try_extract_coin_type(spec: &action_specs::ActionSpec): Option<TypeName> {
    let action_type = action_specs::action_type(spec);
    let type_str = std::type_name::into_string(action_type);
    let type_bytes = std::ascii::into_bytes(type_str);

    // Check if TypeName contains '<' (indicating type parameters)
    let mut i = 0;
    let len = type_bytes.length();
    let mut has_params = false;

    while (i < len) {
        if (*type_bytes.borrow(i) == 60) { // '<' ASCII code
            has_params = true;
            break
        };
        i = i + 1;
    };

    // If parameterized, return the full action type for policy lookup
    if (has_params) {
        option::some(action_type)
    } else {
        option::none()
    }
}

/// Try to extract object ID from action spec if it operates on a specific object
///
/// # Returns
/// - `Some(ID)`: This action operates on a specific object, returns the object ID
/// - `None`: This action does NOT operate on a specific object (intentional - skip object policy check)
///
/// # Aborts
/// - If action type matches but BCS data is malformed (security check)
/// - This prevents malicious actions with corrupted object references
///
/// # Supported Action Types
///
/// **Move Framework Actions**:
/// - `OwnedWithdrawObject`: Generic object withdrawal from account
///
/// **Stream Actions** (all have stream_id as first field):
/// - `CancelStream`, `WithdrawStream`, `UpdateStream`
/// - `PauseStream`, `ResumeStream`
///
/// **Liquidity Actions** (all have pool_id as first field):
/// - `UpdatePoolParams`, `SetPoolStatus`
///
/// # Important
/// If adding new action types that operate on specific objects, they MUST be
/// added to this function to ensure object-level policies are enforced.
fun try_extract_object_id(spec: &action_specs::ActionSpec): Option<ID> {
    let action_type = action_specs::action_type(spec);
    let action_data = action_specs::action_data(spec);
    let mut reader = bcs::new(*action_data);

    // === MOVE FRAMEWORK ACTIONS ===

    // OwnedWithdrawObject - first field is object_id (as address)
    if (action_type == std::type_name::get<framework_action_types::OwnedWithdrawObject>()) {
        let object_id = object::id_from_address(bcs::peel_address(&mut reader));
        return option::some(object_id)
    };

    // === STREAM ACTIONS (all have stream_id as first field) ===

    if (action_type == std::type_name::get<action_types::CancelStream>() ||
        action_type == std::type_name::get<action_types::WithdrawStream>() ||
        action_type == std::type_name::get<action_types::UpdateStream>() ||
        action_type == std::type_name::get<action_types::PauseStream>() ||
        action_type == std::type_name::get<action_types::ResumeStream>()) {
        // ID type is serialized as address in BCS
        let stream_id = object::id_from_address(bcs::peel_address(&mut reader));
        return option::some(stream_id)
    };

    // === LIQUIDITY ACTIONS (all have pool_id as first field) ===

    if (action_type == std::type_name::get<action_types::UpdatePoolParams>() ||
        action_type == std::type_name::get<action_types::SetPoolStatus>()) {
        // ID type is serialized as address in BCS
        let pool_id = object::id_from_address(bcs::peel_address(&mut reader));
        return option::some(pool_id)
    };

    // Not an object-specific action - return None (intentional, skip object policy check)
    option::none()
}

/// Try to extract file/document ID from action spec if it's a file action
///
/// # Returns
/// - `Some(ID)`: This is a file action, returns the document ID being modified
/// - `None`: This is NOT a file action (intentional - skip file policy check)
///
/// # Aborts
/// - If action type is a file action but BCS data is malformed (security check)
/// - This prevents malicious actions with corrupted document references
///
/// # Supported Action Types
/// - `AddChunk`: Add content to document
/// - `UpdateChunk`: Modify existing document content
/// - `RemoveChunk`: Delete document content
/// - `SetChunkImmutable`: Make document content immutable
/// - `SetFileImmutable`: Make entire document immutable
///
/// # Important
/// If adding new file action types to futarchy_core::action_type_markers, they MUST be
/// added to this function's type checks to ensure policies are enforced.
fun try_extract_file_id(spec: &action_specs::ActionSpec): Option<ID> {
    let action_type = action_specs::action_type(spec);

    // Check if this is a file modification action
    // IMPORTANT: All file action types must be listed here for policy enforcement
    if (action_type == std::type_name::get<action_types::AddChunk>() ||
        action_type == std::type_name::get<action_types::UpdateChunk>() ||
        action_type == std::type_name::get<action_types::RemoveChunk>() ||
        action_type == std::type_name::get<action_types::SetChunkImmutable>() ||
        action_type == std::type_name::get<action_types::SetFileImmutable>()) {

        // Deserialize the first field (doc_id) from BCS data
        // This will abort if data is malformed (security: prevent corrupted file operations)
        let action_data = action_specs::action_data(spec);
        let mut reader = bcs::new(*action_data);
        let doc_id = object::id_from_address(bcs::peel_address(&mut reader));
        return option::some(doc_id)
    };

    // Not a file action - return None (intentional, skip file policy check)
    option::none()
}

/// Try to extract capability type from custody action specs
///
/// # Returns
/// - `Some(TypeName)`: The action's full parameterized type (e.g., `ApproveCustodyAction<UpgradeCap>`)
/// - `None`: Action is not a custody action or not parameterized
///
/// # How It Works
/// Checks if the action TypeName is a custody action (ApproveCustodyAction or AcceptIntoCustodyAction)
/// with type parameters. If so, returns the full action type for policy lookup.
///
/// # Policy Registration Model
/// Type-level policies can be registered on parameterized custody actions:
/// ```move
/// // Register policy for UpgradeCap custody specifically
/// set_type_policy<ApproveCustodyAction<UpgradeCap>>(
///     account,
///     option::some(technical_council_id),
///     MODE_DAO_AND_COUNCIL
/// );
///
/// // Register policy for TreasuryCap<USDC> custody specifically
/// set_type_policy<ApproveCustodyAction<TreasuryCap<USDC>>>(
///     account,
///     option::some(treasury_council_id),
///     MODE_COUNCIL_ONLY  // Different policy!
/// );
/// ```
///
/// # Supported Actions
/// - `ApproveCustodyAction<R>`: DAO approves transferring object R to council custody
/// - `AcceptIntoCustodyAction<R>`: Council accepts object R into custody
///
/// Where R can be any capability type like:
/// - `sui::package::UpgradeCap`
/// - `sui::coin::TreasuryCap<CoinType>`
/// - Custom capability types
fun try_extract_cap_type(spec: &action_specs::ActionSpec): Option<TypeName> {
    // custody_actions removed

    let action_type = action_specs::action_type(spec);
    let type_str = std::type_name::into_string(action_type);
    let type_bytes = std::ascii::into_bytes(type_str);

    // Check if this is a custody action type
    // We look for "ApproveCustodyAction" or "AcceptIntoCustodyAction" in the type string
    let approve_custody_str = std::ascii::string(b"ApproveCustodyAction");
    let accept_custody_str = std::ascii::string(b"AcceptIntoCustodyAction");
    let type_str_copy = std::ascii::string(type_bytes);

    // Simple substring check: does the type name contain our custody action names?
    let is_custody_action = contains_substring(&type_str_copy, &approve_custody_str) ||
                           contains_substring(&type_str_copy, &accept_custody_str);

    if (!is_custody_action) {
        return option::none()
    };

    // Check if TypeName contains '<' (indicating type parameters)
    let mut i = 0;
    let len = type_bytes.length();
    let mut has_params = false;

    while (i < len) {
        if (*type_bytes.borrow(i) == 60) { // '<' ASCII code
            has_params = true;
            break
        };
        i = i + 1;
    };

    // If parameterized custody action, return the full action type for policy lookup
    if (has_params) {
        option::some(action_type)
    } else {
        option::none()
    }
}

/// Helper: Check if haystack contains needle substring
fun contains_substring(haystack: &std::ascii::String, needle: &std::ascii::String): bool {
    let haystack_bytes = std::ascii::into_bytes(*haystack);
    let needle_bytes = std::ascii::into_bytes(*needle);
    let haystack_len = haystack_bytes.length();
    let needle_len = needle_bytes.length();

    if (needle_len > haystack_len) {
        return false
    };

    let mut i = 0;
    while (i <= haystack_len - needle_len) {
        let mut j = 0;
        let mut matches = true;

        while (j < needle_len) {
            if (*haystack_bytes.borrow(i + j) != *needle_bytes.borrow(j)) {
                matches = false;
                break
            };
            j = j + 1;
        };

        if (matches) {
            return true
        };

        i = i + 1;
    };

    false
}
