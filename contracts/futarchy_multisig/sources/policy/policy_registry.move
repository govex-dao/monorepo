/// Manages on-chain policies that require external account approval for critical actions.
/// This registry uses type-based policies (via TypeName) and object-specific policies (via ID)
/// to determine which actions require security council approval.
module futarchy_multisig::policy_registry;

use std::option::{Self, Option};
use std::ascii::{Self, String};
use std::vector;
use std::type_name::{Self, TypeName};
use sui::object::{ID, UID};
use sui::package::UpgradeCap;
use sui::table::{Self, Table};
use sui::event;
use sui::clock::Clock;
use sui::tx_context::TxContext;
use account_protocol::account::{Self, Account};
use account_protocol::version_witness::VersionWitness;

// === Errors ===
const EPolicyNotFound: u64 = 1;
const ETooManyTypePolicies: u64 = 2;
const ETooManyObjectPolicies: u64 = 3;
const ETooManyFilePolicies: u64 = 4;
const ETooManyCouncils: u64 = 5;
const EPendingChangeNotFound: u64 = 6;
const EDelayNotElapsed: u64 = 7;

// === Constants for Approval Modes ===
public fun MODE_DAO_ONLY(): u8 { 0 }           // Just DAO vote
public fun MODE_COUNCIL_ONLY(): u8 { 1 }       // Just council (no DAO)
public fun MODE_DAO_OR_COUNCIL(): u8 { 2 }     // Either DAO or council
public fun MODE_DAO_AND_COUNCIL(): u8 { 3 }    // Both DAO and council

// === Storage Limits (DOS Protection) ===
// These limits prevent unbounded storage growth that could DOS the DAO with costs
// Note: On Sui, storage rebates mean DAOs pay for their own bloat, but limits
// still prevent accidental/malicious spam and keep governance manageable

/// Maximum number of type-based policies (actions that can have specific governance)
/// Rationale: Most DAOs need <50 action types with custom policies
public fun MAX_TYPE_POLICIES(): u64 { 200 }

/// Maximum number of object-specific policies (e.g., different UpgradeCaps)
/// Rationale: DAOs typically have 5-20 critical objects needing special governance
public fun MAX_OBJECT_POLICIES(): u64 { 100 }

/// Maximum number of file-specific policies (e.g., different legal documents)
/// Rationale: DAOs typically have 10-50 documents
public fun MAX_FILE_POLICIES(): u64 { 100 }

/// Maximum number of security councils
/// Rationale: Even large DAOs rarely need more than 5-10 councils
/// (Treasury, Technical, Legal, Emergency, Community, etc.)
public fun MAX_COUNCILS(): u64 { 20 }

/// Maximum age for pending changes before they can be cleaned up (30 days in milliseconds)
/// Rationale: If a pending change hasn't been finalized after 30 days, it's likely abandoned
public fun MAX_PENDING_CHANGE_AGE_MS(): u64 { 2592000000 } // 30 days

// === Structs ===

/// Key for storing the registry in the Account's managed data.
public struct PolicyRegistryKey has copy, drop, store {}

/// The registry object for type-based and object-specific policies
public struct PolicyRegistry has store {
    /// Type-based policies for actions
    /// Maps type name string to PolicyRule (council ID + mode)
    /// Using String instead of TypeName to enable on-chain change permission enforcement
    type_policies: Table<String, PolicyRule>,

    /// Object-specific policies (e.g., specific UpgradeCap)
    /// Maps object ID to PolicyRule (council ID + mode)
    object_policies: Table<ID, PolicyRule>,

    /// File-level policies (e.g., "bylaws" requires Legal Council)
    /// Maps file name to PolicyRule (council ID + mode)
    file_policies: Table<String, PolicyRule>,

    /// Default file policy (fallback when specific file has no policy)
    /// Separate from file_policies to avoid key collision
    default_file_policy: Option<PolicyRule>,

    /// Pending type policy changes awaiting delay expiration
    pending_type_changes: Table<String, PendingChange>,

    /// Pending object policy changes awaiting delay expiration
    pending_object_changes: Table<ID, PendingChange>,

    /// Pending file policy changes awaiting delay expiration
    pending_file_changes: Table<String, PendingChange>,

    /// Registered security councils for this DAO
    registered_councils: vector<ID>,
}

/// Policy rule for descriptor-based policies with metacontrol and time delays
public struct PolicyRule has store, copy, drop {
    /// The security council ID for action execution (None = DAO only)
    execution_council_id: Option<ID>,
    /// Execution mode: 0=DAO_ONLY, 1=COUNCIL_ONLY, 2=DAO_OR_COUNCIL, 3=DAO_AND_COUNCIL
    execution_mode: u8,

    /// The security council ID for changing this policy (None = DAO only)
    change_council_id: Option<ID>,
    /// Change mode: 0=DAO_ONLY, 1=COUNCIL_ONLY, 2=DAO_OR_COUNCIL, 3=DAO_AND_COUNCIL
    change_mode: u8,

    /// Minimum delay before policy changes take effect (milliseconds)
    /// 0 = immediate, 86400000 = 24 hours, 172800000 = 48 hours
    /// This delay protects against malicious policy changes by giving DAO time to react
    change_delay_ms: u64,
}

/// Pending policy change awaiting delay expiration
public struct PendingChange has store, drop {
    new_rule: PolicyRule,
    effective_at_ms: u64,  // Timestamp when change becomes active
    proposer_id: ID,       // Who proposed the change (for accountability)
    proposed_at_ms: u64,   // Timestamp when change was proposed (for cleanup)
}

// === Helper Functions ===

const CHAR_LESS_THAN: u8 = 60; // '<' ASCII character

/// Extract generic type from parameterized type for fallback policy lookup
///
/// # Purpose
/// Enables generic fallback: e.g., if `SpendAction<0x2::sui::SUI>` has no policy,
/// fall back to `SpendAction` policy (applies to all coin types).
///
/// # Examples
/// - `"SpendAction<0x2::sui::SUI>"` → `"SpendAction"`
/// - `"SpendAction"` → `"SpendAction"` (no change if not parameterized)
/// - `"Table<vector<u8>>"` → `"Table"` (stops at first '<')
///
/// # Assumptions about Sui TypeName Format
/// 1. Type parameters are enclosed in angle brackets `<>`
/// 2. The first `<` character marks the start of type parameters
/// 3. Fully qualified names: `"0xaddr::module::Type<0xaddr2::mod::Inner>"`
/// 4. For nested generics like `Table<Table<u64>>`, extracts outermost type only
///
/// # Important Notes
/// - This function does NOT parse nested generics correctly for the inner types
/// - It only extracts the leftmost type name before the first `<`
/// - This is intentional and sufficient for our fallback use case
/// - Sui's TypeName serialization is deterministic and controlled by the Move VM
///
/// # Security
/// - No risk of injection: TypeName is generated by Move VM, not user input
/// - String parsing is simple and deterministic
///
/// # CRITICAL: Generic Fallback Precedence Rules
///
/// When looking up policies, the system uses a TWO-TIER fallback mechanism:
///
/// ## Tier 1: Exact Match (Highest Priority)
/// - Looks for an exact match of the fully qualified type name
/// - Example: `"0x123::vault::SpendAction<0x2::sui::SUI>"` matches exactly
/// - If found, this policy is used IMMEDIATELY - no fallback occurs
///
/// ## Tier 2: Generic Fallback (Lower Priority)
/// - If no exact match, extracts the generic type (strips `<...>`)
/// - Example: `"0x123::vault::SpendAction<0x2::sui::SUI>"` → `"0x123::vault::SpendAction"`
/// - Searches for a policy on the generic type
/// - If found, this policy applies to ALL parameterizations
///
/// ## Tier 3: Default (Lowest Priority)
/// - If neither exact nor generic match exists, returns default value
/// - For execution: `false` (no council needed, DAO-only)
/// - For council lookup: `option::none()` (no council)
/// - For mode: `0` (MODE_DAO_ONLY)
///
/// ## Important Implications:
///
/// 1. **Specific Overrides Generic**:
///    If both `SpendAction<SUI>` and `SpendAction` policies exist,
///    the specific one takes precedence for SUI spending.
///
/// 2. **Generic Applies to All**:
///    Setting a policy on `SpendAction` (no params) applies to ALL coin types
///    that don't have their own specific policy.
///
/// 3. **Policy Change Strategy**:
///    - To change policy for ONE coin type: Set specific policy (e.g., `SpendAction<SUI>`)
///    - To change policy for ALL coin types: Set generic policy (e.g., `SpendAction`)
///    - To remove specific override: Delete the specific policy (falls back to generic)
///
/// 4. **Performance**:
///    - Exact match is O(1) table lookup
///    - Generic fallback is O(1) string parsing + O(1) table lookup
///    - Total worst case: O(1) - extremely efficient
///
/// 5. **Gas Optimization**:
///    Using generic policies reduces DAO governance overhead:
///    - One vote for "all spending requires council" instead of per-coin votes
///    - Smaller storage footprint (1 entry vs N entries for N coin types)
///    - Simpler mental model for DAO members
///
/// ## Example Policy Hierarchy:
///
/// ```
/// Generic: SpendAction → MODE_COUNCIL_ONLY (Treasury Council)
/// Specific: SpendAction<SUI> → MODE_DAO_ONLY (DAO can spend SUI directly)
/// Specific: SpendAction<USDC> → MODE_DAO_AND_COUNCIL (Both needed for USDC)
/// (No policy): SpendAction<CUSTOM_TOKEN> → Falls back to generic (Council only)
/// ```
///
/// In this example:
/// - Spending SUI requires only DAO approval (specific override)
/// - Spending USDC requires both DAO and Council (specific override)
/// - Spending any other token requires only Council (generic fallback)
///
fun extract_generic_type(type_str: String): String {
    let bytes = type_str.into_bytes();
    let len = bytes.length();
    let mut i = 0;

    // Find the first '<' character
    while (i < len) {
        if (*bytes.borrow(i) == CHAR_LESS_THAN) {
            // Return everything before the '<'
            let mut result = vector::empty();
            let mut j = 0;
            while (j < i) {
                result.push_back(*bytes.borrow(j));
                j = j + 1;
            };
            return ascii::string(result)
        };
        i = i + 1;
    };

    // No '<' found, return original (non-parameterized type)
    type_str
}

// === PolicyRule Getter Functions ===

/// Get all fields from a PolicyRule
public fun get_policy_rule_fields(rule: &PolicyRule): (Option<ID>, u8, Option<ID>, u8) {
    (rule.execution_council_id, rule.execution_mode, rule.change_council_id, rule.change_mode)
}

/// Get execution council ID from a PolicyRule
public fun policy_rule_execution_council_id(rule: &PolicyRule): Option<ID> {
    rule.execution_council_id
}

/// Get execution mode from a PolicyRule
public fun policy_rule_execution_mode(rule: &PolicyRule): u8 {
    rule.execution_mode
}

/// Get change council ID from a PolicyRule
public fun policy_rule_change_council_id(rule: &PolicyRule): Option<ID> {
    rule.change_council_id
}

/// Get change mode from a PolicyRule
public fun policy_rule_change_mode(rule: &PolicyRule): u8 {
    rule.change_mode
}


// === Events ===
public struct TypePolicySet has copy, drop {
    dao_id: ID,
    action_type: TypeName,
    execution_council_id: Option<ID>,
    execution_mode: u8,
    change_council_id: Option<ID>,
    change_mode: u8,
}

public struct ObjectPolicySet has copy, drop {
    dao_id: ID,
    object_id: ID,
    execution_council_id: Option<ID>,
    execution_mode: u8,
    change_council_id: Option<ID>,
    change_mode: u8,
}

public struct CouncilRegistered has copy, drop {
    dao_id: ID,
    council_id: ID,
}


// === Public Functions ===

/// Initializes the policy registry for an Account.
public fun initialize<Config>(
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    ctx: &mut TxContext
) {
    if (!account::has_managed_data(account, PolicyRegistryKey {})) {
        account::add_managed_data(
            account,
            PolicyRegistryKey {},
            PolicyRegistry {
                type_policies: table::new(ctx),
                object_policies: table::new(ctx),
                file_policies: table::new(ctx),
                default_file_policy: option::none(),
                pending_type_changes: table::new(ctx),
                pending_object_changes: table::new(ctx),
                pending_file_changes: table::new(ctx),
                registered_councils: vector::empty(),
            },
            version_witness
        );
    }
}






/// Helper function to get a mutable reference to the PolicyRegistry from an Account
public fun borrow_registry_mut<Config>(
    account: &mut Account<Config>,
    version_witness: VersionWitness
): &mut PolicyRegistry {
    account::borrow_managed_data_mut(account, PolicyRegistryKey {}, version_witness)
}

/// Helper function to get an immutable reference to the PolicyRegistry from an Account
public fun borrow_registry<Config>(
    account: &Account<Config>,
    version_witness: VersionWitness
): &PolicyRegistry {
    account::borrow_managed_data(account, PolicyRegistryKey {}, version_witness)
}

// === Type-Based Policy Functions ===

/// Check if a type needs council approval for execution
/// Uses fallback: specific type -> generic type -> default (false)
public fun type_needs_council(registry: &PolicyRegistry, action_type: TypeName): bool {
    let type_str = type_name::into_string(action_type);

    // 1. Try exact match (e.g., "SpendAction<0x2::sui::SUI>")
    if (table::contains(&registry.type_policies, type_str)) {
        let rule = table::borrow(&registry.type_policies, type_str);
        return rule.execution_mode != 0
    };

    // 2. Try generic fallback (e.g., "SpendAction")
    let generic_type = extract_generic_type(type_str);
    if (generic_type != type_str && table::contains(&registry.type_policies, generic_type)) {
        let rule = table::borrow(&registry.type_policies, generic_type);
        return rule.execution_mode != 0
    };

    // 3. Default to DAO_ONLY (no council needed)
    false
}

/// Get the council ID for a type's execution
/// Uses fallback: specific type -> generic type -> default (None)
public fun get_type_council(registry: &PolicyRegistry, action_type: TypeName): Option<ID> {
    let type_str = type_name::into_string(action_type);

    // 1. Try exact match
    if (table::contains(&registry.type_policies, type_str)) {
        let rule = table::borrow(&registry.type_policies, type_str);
        return rule.execution_council_id
    };

    // 2. Try generic fallback
    let generic_type = extract_generic_type(type_str);
    if (generic_type != type_str && table::contains(&registry.type_policies, generic_type)) {
        let rule = table::borrow(&registry.type_policies, generic_type);
        return rule.execution_council_id
    };

    // 3. Default to no council
    option::none()
}

/// Get the approval mode for a type's execution
/// Uses fallback: specific type -> generic type -> default (0)
public fun get_type_mode(registry: &PolicyRegistry, action_type: TypeName): u8 {
    let type_str = type_name::into_string(action_type);

    // 1. Try exact match
    if (table::contains(&registry.type_policies, type_str)) {
        let rule = table::borrow(&registry.type_policies, type_str);
        return rule.execution_mode
    };

    // 2. Try generic fallback
    let generic_type = extract_generic_type(type_str);
    if (generic_type != type_str && table::contains(&registry.type_policies, generic_type)) {
        let rule = table::borrow(&registry.type_policies, generic_type);
        return rule.execution_mode
    };

    // 3. Default to DAO_ONLY
    0
}

/// Get the complete policy rule for a type (for checking change permissions)
/// Uses fallback: specific type -> generic type -> aborts if neither exist
public fun get_type_policy_rule(registry: &PolicyRegistry, action_type: TypeName): &PolicyRule {
    let type_str = type_name::into_string(action_type);

    // 1. Try exact match
    if (table::contains(&registry.type_policies, type_str)) {
        return table::borrow(&registry.type_policies, type_str)
    };

    // 2. Try generic fallback
    let generic_type = extract_generic_type(type_str);
    if (generic_type != type_str && table::contains(&registry.type_policies, generic_type)) {
        return table::borrow(&registry.type_policies, generic_type)
    };

    // 3. Abort - this function requires a policy to exist
    abort EPolicyNotFound
}

/// Get the complete policy rule for a type by string (for change permission validation)
/// Uses fallback: specific type -> generic type -> aborts if neither exist
public fun get_type_policy_rule_by_string(registry: &PolicyRegistry, type_str: String): &PolicyRule {
    // 1. Try exact match
    if (table::contains(&registry.type_policies, type_str)) {
        return table::borrow(&registry.type_policies, type_str)
    };

    // 2. Try generic fallback
    let generic_type = extract_generic_type(type_str);
    if (generic_type != type_str && table::contains(&registry.type_policies, generic_type)) {
        return table::borrow(&registry.type_policies, generic_type)
    };

    // 3. Abort - this function requires a policy to exist
    abort EPolicyNotFound
}

/// Check if an object needs council approval for execution
public fun object_needs_council(registry: &PolicyRegistry, object_id: ID): bool {
    if (table::contains(&registry.object_policies, object_id)) {
        let rule = table::borrow(&registry.object_policies, object_id);
        // Needs council if execution_mode is not DAO_ONLY (0)
        rule.execution_mode != 0
    } else {
        false
    }
}

/// Get the council ID for an object's execution
public fun get_object_council(registry: &PolicyRegistry, object_id: ID): Option<ID> {
    if (table::contains(&registry.object_policies, object_id)) {
        let rule = table::borrow(&registry.object_policies, object_id);
        rule.execution_council_id
    } else {
        option::none()
    }
}

/// Get the approval mode for an object's execution
public fun get_object_mode(registry: &PolicyRegistry, object_id: ID): u8 {
    if (table::contains(&registry.object_policies, object_id)) {
        let rule = table::borrow(&registry.object_policies, object_id);
        rule.execution_mode
    } else {
        0 // Default to DAO_ONLY
    }
}

/// Get the complete policy rule for an object (for checking change permissions)
public fun get_object_policy_rule(registry: &PolicyRegistry, object_id: ID): &PolicyRule {
    table::borrow(&registry.object_policies, object_id)
}

/// Set a type-based policy with execution and change control
public fun set_type_policy<T: drop>(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    execution_council_id: Option<ID>,
    execution_mode: u8,
    change_council_id: Option<ID>,
    change_mode: u8,
    change_delay_ms: u64,
) {
    let action_type = type_name::get<T>();
    let type_str = type_name::into_string(action_type);
    let rule = PolicyRule {
        execution_council_id,
        execution_mode,
        change_council_id,
        change_mode,
        change_delay_ms,
    };
    if (table::contains(&registry.type_policies, type_str)) {
        let existing = table::borrow_mut(&mut registry.type_policies, type_str);
        *existing = rule;
    } else {
        assert!(table::length(&registry.type_policies) < MAX_TYPE_POLICIES(), ETooManyTypePolicies);
        table::add(&mut registry.type_policies, type_str, rule);
    };

    event::emit(TypePolicySet {
        dao_id,
        action_type,
        execution_council_id,
        execution_mode,
        change_council_id,
        change_mode,
    });
}

/// Set a type-based policy using TypeName directly
public fun set_type_policy_by_name(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    action_type: TypeName,
    execution_council_id: Option<ID>,
    execution_mode: u8,
    change_council_id: Option<ID>,
    change_mode: u8,
    change_delay_ms: u64,
) {
    let type_str = type_name::into_string(action_type);
    let rule = PolicyRule {
        execution_council_id,
        execution_mode,
        change_council_id,
        change_mode,
        change_delay_ms,
    };
    if (table::contains(&registry.type_policies, type_str)) {
        let existing = table::borrow_mut(&mut registry.type_policies, type_str);
        *existing = rule;
    } else {
        assert!(table::length(&registry.type_policies) < MAX_TYPE_POLICIES(), ETooManyTypePolicies);
        table::add(&mut registry.type_policies, type_str, rule);
    };

    event::emit(TypePolicySet {
        dao_id,
        action_type,
        execution_council_id,
        execution_mode,
        change_council_id,
        change_mode,
    });
}

/// Set a type-based policy using string representation
/// This is used when deserializing from BCS since TypeName can't be reconstructed from string
public fun set_type_policy_by_string(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    type_name_str: String,
    execution_council_id: Option<ID>,
    execution_mode: u8,
    change_council_id: Option<ID>,
    change_mode: u8,
    change_delay_ms: u64,
    proposer_id: ID,
    clock: &Clock,
) {
    let rule = PolicyRule {
        execution_council_id,
        execution_mode,
        change_council_id,
        change_mode,
        change_delay_ms,
    };

    // Check if existing policy has delay
    if (table::contains(&registry.type_policies, type_name_str)) {
        let existing = table::borrow(&registry.type_policies, type_name_str);

        // If existing policy has delay, create pending change instead of applying immediately
        if (existing.change_delay_ms > 0) {
            let current_time = sui::clock::timestamp_ms(clock);
            let effective_at_ms = current_time + existing.change_delay_ms;
            let pending = PendingChange {
                new_rule: rule,
                effective_at_ms,
                proposer_id,
                proposed_at_ms: current_time,
            };

            // Replace existing pending change if any
            if (table::contains(&registry.pending_type_changes, type_name_str)) {
                table::remove(&mut registry.pending_type_changes, type_name_str);
            };
            table::add(&mut registry.pending_type_changes, type_name_str, pending);
            return
        };

        // No delay - apply immediately
        let existing_mut = table::borrow_mut(&mut registry.type_policies, type_name_str);
        *existing_mut = rule;
    } else {
        // New policy - apply immediately (no existing delay to respect)
        assert!(table::length(&registry.type_policies) < MAX_TYPE_POLICIES(), ETooManyTypePolicies);
        table::add(&mut registry.type_policies, type_name_str, rule);
    };

    // Emit event with placeholder TypeName since we only have string
    event::emit(TypePolicySet {
        dao_id,
        action_type: type_name::get<PolicyRegistry>(), // Placeholder TypeName
        execution_council_id,
        execution_mode,
        change_council_id,
        change_mode,
    });
}

/// Set an object-specific policy with execution and change control
public fun set_object_policy(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    object_id: ID,
    execution_council_id: Option<ID>,
    execution_mode: u8,
    change_council_id: Option<ID>,
    change_mode: u8,
    change_delay_ms: u64,
    proposer_id: ID,
    clock: &Clock,
) {
    let rule = PolicyRule {
        execution_council_id,
        execution_mode,
        change_council_id,
        change_mode,
        change_delay_ms,
    };

    // Check if existing policy has delay
    if (table::contains(&registry.object_policies, object_id)) {
        let existing = table::borrow(&registry.object_policies, object_id);

        // If existing policy has delay, create pending change instead of applying immediately
        if (existing.change_delay_ms > 0) {
            let current_time = sui::clock::timestamp_ms(clock);
            let effective_at_ms = current_time + existing.change_delay_ms;
            let pending = PendingChange {
                new_rule: rule,
                effective_at_ms,
                proposer_id,
                proposed_at_ms: current_time,
            };

            // Replace existing pending change if any
            if (table::contains(&registry.pending_object_changes, object_id)) {
                table::remove(&mut registry.pending_object_changes, object_id);
            };
            table::add(&mut registry.pending_object_changes, object_id, pending);
            return
        };

        // No delay - apply immediately
        let existing_mut = table::borrow_mut(&mut registry.object_policies, object_id);
        *existing_mut = rule;
    } else {
        // New policy - apply immediately (no existing delay to respect)
        assert!(table::length(&registry.object_policies) < MAX_OBJECT_POLICIES(), ETooManyObjectPolicies);
        table::add(&mut registry.object_policies, object_id, rule);
    };

    event::emit(ObjectPolicySet {
        dao_id,
        object_id,
        execution_council_id,
        execution_mode,
        change_council_id,
        change_mode,
    });
}

/// Register a security council with the DAO
public fun register_council(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    council_id: ID,
) {
    if (!vector::contains(&registry.registered_councils, &council_id)) {
        assert!(vector::length(&registry.registered_councils) < MAX_COUNCILS(), ETooManyCouncils);
        vector::push_back(&mut registry.registered_councils, council_id);
    };

    event::emit(CouncilRegistered {
        dao_id,
        council_id,
    });
}

/// Check if a council is registered
public fun is_council_registered(registry: &PolicyRegistry, council_id: ID): bool {
    vector::contains(&registry.registered_councils, &council_id)
}

/// Get all registered councils
public fun get_registered_councils(registry: &PolicyRegistry): &vector<ID> {
    &registry.registered_councils
}

/// Check if a type-based policy exists
/// Uses fallback: specific type -> generic type
public fun has_type_policy<T>(registry: &PolicyRegistry): bool {
    let type_name = type_name::get<T>();
    let type_str = type_name::into_string(type_name);

    // 1. Check exact match
    if (table::contains(&registry.type_policies, type_str)) {
        return true
    };

    // 2. Check generic fallback
    let generic_type = extract_generic_type(type_str);
    if (generic_type != type_str && table::contains(&registry.type_policies, generic_type)) {
        return true
    };

    false
}

/// Check if a type-based policy exists by string
/// Uses fallback: specific type -> generic type
public fun has_type_policy_by_string(registry: &PolicyRegistry, type_str: String): bool {
    // 1. Check exact match
    if (table::contains(&registry.type_policies, type_str)) {
        return true
    };

    // 2. Check generic fallback
    let generic_type = extract_generic_type(type_str);
    if (generic_type != type_str && table::contains(&registry.type_policies, generic_type)) {
        return true
    };

    false
}

/// Check if an object-specific policy exists
public fun has_object_policy(registry: &PolicyRegistry, object_id: ID): bool {
    table::contains(&registry.object_policies, object_id)
}

// === File-Level Policy Functions ===

/// Check if a file needs council approval for execution
/// Uses fallback: specific file -> default_file_policy -> default (false)
public fun file_needs_council(registry: &PolicyRegistry, file_name: String): bool {
    // 1. Try specific file policy
    if (table::contains(&registry.file_policies, file_name)) {
        let rule = table::borrow(&registry.file_policies, file_name);
        return rule.execution_mode != 0
    };

    // 2. Try default file policy
    if (option::is_some(&registry.default_file_policy)) {
        let rule = option::borrow(&registry.default_file_policy);
        return rule.execution_mode != 0
    };

    // 3. Default to DAO_ONLY (no council needed)
    false
}

/// Get the council ID for a file's execution
/// Uses fallback: specific file -> default_file_policy -> default (None)
public fun get_file_council(registry: &PolicyRegistry, file_name: String): Option<ID> {
    // 1. Try specific file policy
    if (table::contains(&registry.file_policies, file_name)) {
        let rule = table::borrow(&registry.file_policies, file_name);
        return rule.execution_council_id
    };

    // 2. Try default file policy
    if (option::is_some(&registry.default_file_policy)) {
        let rule = option::borrow(&registry.default_file_policy);
        return rule.execution_council_id
    };

    // 3. Default to no council
    option::none()
}

/// Get the approval mode for a file's execution
/// Uses fallback: specific file -> default_file_policy -> default (0)
public fun get_file_mode(registry: &PolicyRegistry, file_name: String): u8 {
    // 1. Try specific file policy
    if (table::contains(&registry.file_policies, file_name)) {
        let rule = table::borrow(&registry.file_policies, file_name);
        return rule.execution_mode
    };

    // 2. Try default file policy
    if (option::is_some(&registry.default_file_policy)) {
        let rule = option::borrow(&registry.default_file_policy);
        return rule.execution_mode
    };

    // 3. Default to DAO_ONLY
    0
}

/// Get the complete policy rule for a file (for checking change permissions)
/// Uses fallback: specific file -> default_file_policy -> aborts if neither exist
public fun get_file_policy_rule(registry: &PolicyRegistry, file_name: String): &PolicyRule {
    // 1. Try specific file policy
    if (table::contains(&registry.file_policies, file_name)) {
        return table::borrow(&registry.file_policies, file_name)
    };

    // 2. Try default file policy
    if (option::is_some(&registry.default_file_policy)) {
        return option::borrow(&registry.default_file_policy)
    };

    // 3. Abort - this function requires a policy to exist
    abort EPolicyNotFound
}

/// Set a file-level policy with execution and change control
public fun set_file_policy(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    file_name: String,
    execution_council_id: Option<ID>,
    execution_mode: u8,
    change_council_id: Option<ID>,
    change_mode: u8,
    change_delay_ms: u64,
    proposer_id: ID,
    clock: &Clock,
) {
    let rule = PolicyRule {
        execution_council_id,
        execution_mode,
        change_council_id,
        change_mode,
        change_delay_ms,
    };

    // Check if existing policy has delay
    if (table::contains(&registry.file_policies, file_name)) {
        let existing = table::borrow(&registry.file_policies, file_name);

        // If existing policy has delay, create pending change instead of applying immediately
        if (existing.change_delay_ms > 0) {
            let current_time = sui::clock::timestamp_ms(clock);
            let effective_at_ms = current_time + existing.change_delay_ms;
            let pending = PendingChange {
                new_rule: rule,
                effective_at_ms,
                proposer_id,
                proposed_at_ms: current_time,
            };

            // Replace existing pending change if any
            if (table::contains(&registry.pending_file_changes, file_name)) {
                table::remove(&mut registry.pending_file_changes, file_name);
            };
            table::add(&mut registry.pending_file_changes, file_name, pending);
            return
        };

        // No delay - apply immediately
        let existing_mut = table::borrow_mut(&mut registry.file_policies, file_name);
        *existing_mut = rule;
    } else {
        // New policy - apply immediately (no existing delay to respect)
        assert!(table::length(&registry.file_policies) < MAX_FILE_POLICIES(), ETooManyFilePolicies);
        table::add(&mut registry.file_policies, file_name, rule);
    };

    event::emit(FilePolicySet {
        dao_id,
        file_name,
        execution_council_id,
        execution_mode,
        change_council_id,
        change_mode,
    });
}

/// Set the default file policy (fallback for all files without specific policies)
public fun set_default_file_policy(
    registry: &mut PolicyRegistry,
    execution_council_id: Option<ID>,
    execution_mode: u8,
    change_council_id: Option<ID>,
    change_mode: u8,
    change_delay_ms: u64,
) {
    let rule = PolicyRule {
        execution_council_id,
        execution_mode,
        change_council_id,
        change_mode,
        change_delay_ms,
    };
    registry.default_file_policy = option::some(rule);
}

/// Remove the default file policy
public fun remove_default_file_policy(registry: &mut PolicyRegistry) {
    registry.default_file_policy = option::none();
}

// === Pending Policy Change Functions ===

/// Finalize a pending type policy change after delay has elapsed
public fun finalize_pending_type_policy(
    registry: &mut PolicyRegistry,
    type_name_str: String,
    clock: &Clock,
) {
    assert!(table::contains(&registry.pending_type_changes, type_name_str), EPendingChangeNotFound);
    let pending = table::remove(&mut registry.pending_type_changes, type_name_str);

    // Ensure delay has elapsed
    assert!(sui::clock::timestamp_ms(clock) >= pending.effective_at_ms, EDelayNotElapsed);

    // Apply the policy change
    if (table::contains(&registry.type_policies, type_name_str)) {
        let existing = table::borrow_mut(&mut registry.type_policies, type_name_str);
        *existing = pending.new_rule;
    } else {
        assert!(table::length(&registry.type_policies) < MAX_TYPE_POLICIES(), ETooManyTypePolicies);
        table::add(&mut registry.type_policies, type_name_str, pending.new_rule);
    };
}

/// Finalize a pending object policy change after delay has elapsed
public fun finalize_pending_object_policy(
    registry: &mut PolicyRegistry,
    object_id: ID,
    clock: &Clock,
) {
    assert!(table::contains(&registry.pending_object_changes, object_id), EPendingChangeNotFound);
    let pending = table::remove(&mut registry.pending_object_changes, object_id);

    // Ensure delay has elapsed
    assert!(sui::clock::timestamp_ms(clock) >= pending.effective_at_ms, EDelayNotElapsed);

    // Apply the policy change
    if (table::contains(&registry.object_policies, object_id)) {
        let existing = table::borrow_mut(&mut registry.object_policies, object_id);
        *existing = pending.new_rule;
    } else {
        assert!(table::length(&registry.object_policies) < MAX_OBJECT_POLICIES(), ETooManyObjectPolicies);
        table::add(&mut registry.object_policies, object_id, pending.new_rule);
    };
}

/// Finalize a pending file policy change after delay has elapsed
public fun finalize_pending_file_policy(
    registry: &mut PolicyRegistry,
    file_name: String,
    clock: &Clock,
) {
    assert!(table::contains(&registry.pending_file_changes, file_name), EPendingChangeNotFound);
    let pending = table::remove(&mut registry.pending_file_changes, file_name);

    // Ensure delay has elapsed
    assert!(sui::clock::timestamp_ms(clock) >= pending.effective_at_ms, EDelayNotElapsed);

    // Apply the policy change
    if (table::contains(&registry.file_policies, file_name)) {
        let existing = table::borrow_mut(&mut registry.file_policies, file_name);
        *existing = pending.new_rule;
    } else {
        assert!(table::length(&registry.file_policies) < MAX_FILE_POLICIES(), ETooManyFilePolicies);
        table::add(&mut registry.file_policies, file_name, pending.new_rule);
    };
}

/// Cancel a pending type policy change
/// Only the DAO or authorized council can cancel
public fun cancel_pending_type_policy(
    registry: &mut PolicyRegistry,
    type_name_str: String,
) {
    assert!(table::contains(&registry.pending_type_changes, type_name_str), EPendingChangeNotFound);
    table::remove(&mut registry.pending_type_changes, type_name_str);
}

/// Cancel a pending object policy change
/// Only the DAO or authorized council can cancel
public fun cancel_pending_object_policy(
    registry: &mut PolicyRegistry,
    object_id: ID,
) {
    assert!(table::contains(&registry.pending_object_changes, object_id), EPendingChangeNotFound);
    table::remove(&mut registry.pending_object_changes, object_id);
}

/// Cancel a pending file policy change
/// Only the DAO or authorized council can cancel
public fun cancel_pending_file_policy(
    registry: &mut PolicyRegistry,
    file_name: String,
) {
    assert!(table::contains(&registry.pending_file_changes, file_name), EPendingChangeNotFound);
    table::remove(&mut registry.pending_file_changes, file_name);
}

// === Pending Change Cleanup Functions ===

/// Clean up abandoned pending type policy changes older than MAX_PENDING_CHANGE_AGE_MS
/// This prevents DoS via pending change accumulation
/// Returns the number of cleaned up entries
public fun cleanup_abandoned_type_policies(
    registry: &mut PolicyRegistry,
    type_names: vector<String>,
    clock: &Clock,
): u64 {
    let current_time = sui::clock::timestamp_ms(clock);
    let cutoff_time = if (current_time > MAX_PENDING_CHANGE_AGE_MS()) {
        current_time - MAX_PENDING_CHANGE_AGE_MS()
    } else {
        0
    };

    let mut cleaned = 0;
    let mut i = 0;
    while (i < vector::length(&type_names)) {
        let type_name = vector::borrow(&type_names, i);
        if (table::contains(&registry.pending_type_changes, *type_name)) {
            let pending = table::borrow(&registry.pending_type_changes, *type_name);
            if (pending.proposed_at_ms < cutoff_time) {
                table::remove(&mut registry.pending_type_changes, *type_name);
                cleaned = cleaned + 1;
            };
        };
        i = i + 1;
    };

    cleaned
}

/// Clean up abandoned pending object policy changes older than MAX_PENDING_CHANGE_AGE_MS
/// Returns the number of cleaned up entries
public fun cleanup_abandoned_object_policies(
    registry: &mut PolicyRegistry,
    object_ids: vector<ID>,
    clock: &Clock,
): u64 {
    let current_time = sui::clock::timestamp_ms(clock);
    let cutoff_time = if (current_time > MAX_PENDING_CHANGE_AGE_MS()) {
        current_time - MAX_PENDING_CHANGE_AGE_MS()
    } else {
        0
    };

    let mut cleaned = 0;
    let mut i = 0;
    while (i < vector::length(&object_ids)) {
        let object_id = *vector::borrow(&object_ids, i);
        if (table::contains(&registry.pending_object_changes, object_id)) {
            let pending = table::borrow(&registry.pending_object_changes, object_id);
            if (pending.proposed_at_ms < cutoff_time) {
                table::remove(&mut registry.pending_object_changes, object_id);
                cleaned = cleaned + 1;
            };
        };
        i = i + 1;
    };

    cleaned
}

/// Clean up abandoned pending file policy changes older than MAX_PENDING_CHANGE_AGE_MS
/// Returns the number of cleaned up entries
public fun cleanup_abandoned_file_policies(
    registry: &mut PolicyRegistry,
    file_names: vector<String>,
    clock: &Clock,
): u64 {
    let current_time = sui::clock::timestamp_ms(clock);
    let cutoff_time = if (current_time > MAX_PENDING_CHANGE_AGE_MS()) {
        current_time - MAX_PENDING_CHANGE_AGE_MS()
    } else {
        0
    };

    let mut cleaned = 0;
    let mut i = 0;
    while (i < vector::length(&file_names)) {
        let file_name = vector::borrow(&file_names, i);
        if (table::contains(&registry.pending_file_changes, *file_name)) {
            let pending = table::borrow(&registry.pending_file_changes, *file_name);
            if (pending.proposed_at_ms < cutoff_time) {
                table::remove(&mut registry.pending_file_changes, *file_name);
                cleaned = cleaned + 1;
            };
        };
        i = i + 1;
    };

    cleaned
}

/// Check if a pending change is eligible for cleanup (older than MAX_PENDING_CHANGE_AGE_MS)
public fun is_pending_change_abandonded(
    pending_proposed_at_ms: u64,
    clock: &Clock,
): bool {
    let current_time = sui::clock::timestamp_ms(clock);
    let cutoff_time = if (current_time > MAX_PENDING_CHANGE_AGE_MS()) {
        current_time - MAX_PENDING_CHANGE_AGE_MS()
    } else {
        0
    };

    pending_proposed_at_ms < cutoff_time
}

/// Check if a file policy exists
/// Uses fallback: specific file -> default_file_policy
public fun has_file_policy(registry: &PolicyRegistry, file_name: String): bool {
    // 1. Check specific file
    if (table::contains(&registry.file_policies, file_name)) {
        return true
    };

    // 2. Check default file policy
    if (option::is_some(&registry.default_file_policy)) {
        return true
    };

    false
}

// === Query Functions ===

/// Get count of type policies
public fun get_type_policy_count(registry: &PolicyRegistry): u64 {
    table::length(&registry.type_policies)
}

/// Get count of object policies
public fun get_object_policy_count(registry: &PolicyRegistry): u64 {
    table::length(&registry.object_policies)
}

/// Get count of file policies
public fun get_file_policy_count(registry: &PolicyRegistry): u64 {
    table::length(&registry.file_policies)
}

/// Get count of registered councils
public fun get_council_count(registry: &PolicyRegistry): u64 {
    vector::length(&registry.registered_councils)
}

/// Get the default file policy (if set)
public fun get_default_file_policy(registry: &PolicyRegistry): &Option<PolicyRule> {
    &registry.default_file_policy
}

// === File Policy Event ===
public struct FilePolicySet has copy, drop {
    dao_id: ID,
    file_name: String,
    execution_council_id: Option<ID>,
    execution_mode: u8,
    change_council_id: Option<ID>,
    change_mode: u8,
}

// === Policy Migration Notes ===
//
// Policy migrations are handled via standard DAO governance:
// 1. Create an intent with batch_set_*_policies() to update all policies
// 2. DAO approves the migration intent via normal voting
// 3. Execution applies all policy changes atomically
//
// For complex migrations:
// - Use multiple intents if hitting batch size limits
// - Document migration plan in operating agreement
// - Consider creating a "migration council" with temporary elevated permissions
//
// Upgrade path for PolicyRegistry struct changes:
// - PolicyRegistry is stored in Account's managed data
// - Use Account Protocol's managed data migration system
// - Add migration action type to policy_actions.move if needed
// - See account_protocol::account::migrate_managed_data() for pattern