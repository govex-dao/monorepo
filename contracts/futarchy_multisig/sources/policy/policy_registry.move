/// Manages on-chain policies that require external account approval for critical actions.
/// This registry links a protected resource (identified by a key) to a policy-enforcing Account.
/// 
/// Uses standardized resource keys from futarchy::resources for consistency.
module futarchy_multisig::policy_registry;

use std::string::{Self, String};
use std::option::{Self, Option};
use std::vector;
use sui::object::{ID, UID};
use sui::table::{Self, Table};
use sui::event;
use sui::tx_context::TxContext;
use account_protocol::account::{Self, Account};
use account_protocol::version_witness::VersionWitness;
use futarchy_multisig::resources;

// === Errors ===
const EPolicyNotFound: u64 = 1;

// === Constants for Approval Modes ===
public fun MODE_DAO_ONLY(): u8 { 0 }           // Just DAO vote
public fun MODE_COUNCIL_ONLY(): u8 { 1 }       // Just council (no DAO)
public fun MODE_DAO_OR_COUNCIL(): u8 { 2 }     // Either DAO or council
public fun MODE_DAO_AND_COUNCIL(): u8 { 3 }    // Both DAO and council

// === Structs ===

/// Key for storing the registry in the Account's managed data.
public struct PolicyRegistryKey has copy, drop, store {}

/// The registry object. Maps a resource key (e.g., "UpgradeCap:futarchy") to a Policy.
public struct PolicyRegistry has store {
    policies: Table<String, Policy>,
    /// Resource keys that require 2-of-2 approval (DAO + Council)
    /// These can be exact matches or patterns with wildcards
    critical_policies: vector<String>,
    
    /// NEW: Pattern-based policies for action descriptors (e.g., b"treasury/mint")
    /// Maps pattern to PolicyRule (council ID + mode)
    pattern_policies: Table<vector<u8>, PolicyRule>,
    
    /// NEW: Object-specific policies (e.g., specific UpgradeCap)
    /// Maps object ID to PolicyRule (council ID + mode)
    object_policies: Table<ID, PolicyRule>,
    
    /// NEW: Registered security councils for this DAO
    registered_councils: vector<ID>,
}

/// NEW: Simplified policy rule for descriptor-based policies
public struct PolicyRule has store, copy, drop {
    /// The security council ID (if any)
    council_id: Option<ID>,
    /// Mode: 0=DAO_ONLY, 1=COUNCIL_ONLY, 2=DAO_OR_COUNCIL, 3=DAO_AND_COUNCIL
    mode: u8,
}

/// Defines the policy for a given resource.
public struct Policy has store, copy, drop {
    /// The ID of the Account (e.g., a Security Council multisig) that enforces this policy.
    policy_account_id: ID,
    /// A unique prefix for intents sent to this policy account, to prevent key collisions.
    intent_key_prefix: String,
    /// Gating mode: 0=DAO_ONLY, 1=COUNCIL_ONLY, 2=AND (both required), 3=OR (either)
    gating_mode: u8,
    /// Optional time delay in milliseconds (0 = no delay)
    time_delay_ms: u64,
    /// Optional approval threshold (e.g., 3 for "3 of 5")
    approval_threshold: u64,
}

// === Events ===
public struct PolicySet has copy, drop {
    dao_id: ID,
    resource_key: String,
    policy_account_id: ID,
}

public struct PolicyRemoved has copy, drop {
    dao_id: ID,
    resource_key: String,
}

public struct CriticalPolicyAdded has copy, drop {
    dao_id: ID,
    resource_pattern: String,
}

public struct CriticalPolicyRemoved has copy, drop {
    dao_id: ID,
    resource_pattern: String,
}

// === Public Functions ===

/// Initializes the policy registry for an Account with optional critical policies.
public fun initialize<Config>(
    account: &mut Account<Config>, 
    version_witness: VersionWitness,
    initial_critical_policies: vector<String>,
    ctx: &mut TxContext
) {
    if (!account::has_managed_data(account, PolicyRegistryKey {})) {
        account::add_managed_data(
            account,
            PolicyRegistryKey {},
            PolicyRegistry { 
                policies: table::new(ctx),
                critical_policies: initial_critical_policies,
                pattern_policies: table::new(ctx),
                object_policies: table::new(ctx),
                registered_councils: vector::empty(),
            },
            version_witness
        );
    }
}

/// Sets or updates a policy for a specific resource.
/// Resource keys should be generated using futarchy::resources functions.
public fun set_policy(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    resource_key: String,
    policy_account_id: ID,
    intent_key_prefix: String,
) {
    // Default gating_mode to 0 (DAO_ONLY) with no delay or threshold
    let policy = Policy { 
        policy_account_id, 
        intent_key_prefix, 
        gating_mode: 0,
        time_delay_ms: 0,
        approval_threshold: 0
    };
    
    // Use atomic update pattern - if exists, borrow_mut and update, otherwise add
    if (table::contains(&registry.policies, resource_key)) {
        // Update existing policy in place
        let existing = table::borrow_mut(&mut registry.policies, resource_key);
        *existing = policy;
    } else {
        // Add new policy
        table::add(&mut registry.policies, resource_key, policy);
    };

    event::emit(PolicySet {
        dao_id,
        resource_key,
        policy_account_id,
    });
}

/// Removes a policy for a resource.
public fun remove_policy(registry: &mut PolicyRegistry, dao_id: ID, resource_key: String) {
    assert!(table::contains(&registry.policies, resource_key), EPolicyNotFound);
    table::remove(&mut registry.policies, resource_key);

    event::emit(PolicyRemoved {
        dao_id,
        resource_key,
    });
}

/// Gets the policy for a resource.
public fun get_policy(registry: &PolicyRegistry, resource_key: String): &Policy {
    assert!(table::contains(&registry.policies, resource_key), EPolicyNotFound);
    table::borrow(&registry.policies, resource_key)
}

/// Checks if a policy exists for a resource.
public fun has_policy(registry: &PolicyRegistry, resource_key: String): bool {
    table::contains(&registry.policies, resource_key)
}

/// Getter for policy_account_id.
public fun policy_account_id(policy: &Policy): ID {
    policy.policy_account_id
}

/// Getter for intent_key_prefix.
public fun intent_key_prefix(policy: &Policy): &String {
    &policy.intent_key_prefix
}

/// Getter for gating_mode.
public fun gating_mode(policy: &Policy): u8 {
    policy.gating_mode
}

/// Getter for time_delay_ms.
public fun time_delay_ms(policy: &Policy): u64 {
    policy.time_delay_ms
}

/// Getter for approval_threshold.
public fun approval_threshold(policy: &Policy): u64 {
    policy.approval_threshold
}

/// Gating mode constants
public fun gating_mode_dao_only(): u8 { 0 }
public fun gating_mode_council_only(): u8 { 1 }
public fun gating_mode_and(): u8 { 2 }
public fun gating_mode_or(): u8 { 3 }

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

// === Convenience Functions for Common Policy Patterns ===

/// Set a policy with time delay (e.g., for package upgrades)
public fun set_policy_with_timelock(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    resource_key: String,
    policy_account_id: ID,
    intent_key_prefix: String,
    delay_ms: u64,
) {
    let policy = Policy { 
        policy_account_id, 
        intent_key_prefix, 
        gating_mode: gating_mode_and(), // Both DAO and council must approve
        time_delay_ms: delay_ms,
        approval_threshold: 0
    };
    
    if (table::contains(&registry.policies, resource_key)) {
        // Update existing policy in place
        let existing = table::borrow_mut(&mut registry.policies, resource_key);
        *existing = policy;
    } else {
        // Add new policy
        table::add(&mut registry.policies, resource_key, policy);
    };

    event::emit(PolicySet {
        dao_id,
        resource_key,
        policy_account_id,
    });
}

/// Set a policy requiring threshold approvals
public fun set_policy_with_threshold(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    resource_key: String,
    policy_account_id: ID,
    intent_key_prefix: String,
    threshold: u64,
) {
    let policy = Policy { 
        policy_account_id, 
        intent_key_prefix, 
        gating_mode: gating_mode_council_only(), // Council handles threshold
        time_delay_ms: 0,
        approval_threshold: threshold
    };
    
    if (table::contains(&registry.policies, resource_key)) {
        // Update existing policy in place
        let existing = table::borrow_mut(&mut registry.policies, resource_key);
        *existing = policy;
    } else {
        // Add new policy
        table::add(&mut registry.policies, resource_key, policy);
    };

    event::emit(PolicySet {
        dao_id,
        resource_key,
        policy_account_id,
    });
}

/// Set an emergency policy (council only, no delay)
public fun set_emergency_policy(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    resource_key: String,
    policy_account_id: ID,
    intent_key_prefix: String,
) {
    let policy = Policy { 
        policy_account_id, 
        intent_key_prefix, 
        gating_mode: gating_mode_council_only(),
        time_delay_ms: 0,
        approval_threshold: 0
    };
    
    if (table::contains(&registry.policies, resource_key)) {
        // Update existing policy in place
        let existing = table::borrow_mut(&mut registry.policies, resource_key);
        *existing = policy;
    } else {
        // Add new policy
        table::add(&mut registry.policies, resource_key, policy);
    };

    event::emit(PolicySet {
        dao_id,
        resource_key,
        policy_account_id,
    });
}

/// Check if a resource requires policy approval based on the registry
public fun requires_policy_approval<Config>(
    account: &Account<Config>,
    resource_key: String,
    version_witness: VersionWitness,
): bool {
    if (!account::has_managed_data(account, PolicyRegistryKey {})) {
        return false
    };
    
    let registry = borrow_registry(account, version_witness);
    has_policy(registry, resource_key)
}

// === Critical Policy Management ===

/// Add a resource pattern to the critical policies list
/// Critical policies require 2-of-2 approval (DAO + Council)
public fun add_critical_policy(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    resource_pattern: String,
) {
    // Check if already exists to avoid duplicates
    if (!vector::contains(&registry.critical_policies, &resource_pattern)) {
        vector::push_back(&mut registry.critical_policies, resource_pattern);
        
        event::emit(CriticalPolicyAdded {
            dao_id,
            resource_pattern,
        });
    }
}

/// Remove a resource pattern from the critical policies list
public fun remove_critical_policy(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    resource_pattern: String,
) {
    let (exists, index) = vector::index_of(&registry.critical_policies, &resource_pattern);
    if (exists) {
        vector::remove(&mut registry.critical_policies, index);
        
        event::emit(CriticalPolicyRemoved {
            dao_id,
            resource_pattern,
        });
    }
}

/// Check if a resource key matches any critical policy pattern
public fun is_critical_policy(
    registry: &PolicyRegistry,
    resource_key: &String,
): bool {
    let mut i = 0;
    let len = registry.critical_policies.length();
    
    while (i < len) {
        let pattern = vector::borrow(&registry.critical_policies, i);
        
        // Check for wildcard matching (e.g., "UpgradeCap:*" matches "UpgradeCap:futarchy")
        if (resources::matches(pattern, resource_key)) {
            return true
        };
        
        i = i + 1;
    };
    
    false
}

/// Get all critical policy patterns
public fun get_critical_policies(registry: &PolicyRegistry): &vector<String> {
    &registry.critical_policies
}

/// Get default critical policies for a new DAO
/// These are sensible defaults that can be modified later
public fun default_critical_policies(): vector<String> {
    vector[
        // Package upgrades should always be critical
        b"resource:/package/upgrade/*".to_string(),
        b"resource:/package/restrict/*".to_string(),
        
        // Policy registry admin itself
        b"resource:/governance/policy_admin".to_string(),
        
        // Treasury minting capabilities
        b"resource:/vault/mint/*".to_string(),
        
        // Security council membership changes
        b"resource:/security/membership".to_string(),
        
        // Emergency actions
        b"resource:/security/emergency".to_string(),
    ]
}

// === New Functions for Descriptor-Based Policies ===

/// Check if a pattern needs council approval
public fun pattern_needs_council(registry: &PolicyRegistry, pattern: vector<u8>): bool {
    if (table::contains(&registry.pattern_policies, pattern)) {
        let rule = table::borrow(&registry.pattern_policies, pattern);
        // Needs council if mode is not DAO_ONLY (0)
        rule.mode != 0
    } else {
        false
    }
}

/// Get the council ID for a pattern
public fun get_pattern_council(registry: &PolicyRegistry, pattern: vector<u8>): Option<ID> {
    if (table::contains(&registry.pattern_policies, pattern)) {
        let rule = table::borrow(&registry.pattern_policies, pattern);
        rule.council_id
    } else {
        option::none()
    }
}

/// Get the approval mode for a pattern
public fun get_pattern_mode(registry: &PolicyRegistry, pattern: vector<u8>): u8 {
    if (table::contains(&registry.pattern_policies, pattern)) {
        let rule = table::borrow(&registry.pattern_policies, pattern);
        rule.mode
    } else {
        0 // Default to DAO_ONLY
    }
}

/// Check if an object needs council approval
public fun object_needs_council(registry: &PolicyRegistry, object_id: ID): bool {
    if (table::contains(&registry.object_policies, object_id)) {
        let rule = table::borrow(&registry.object_policies, object_id);
        // Needs council if mode is not DAO_ONLY (0)
        rule.mode != 0
    } else {
        false
    }
}

/// Get the council ID for an object
public fun get_object_council(registry: &PolicyRegistry, object_id: ID): Option<ID> {
    if (table::contains(&registry.object_policies, object_id)) {
        let rule = table::borrow(&registry.object_policies, object_id);
        rule.council_id
    } else {
        option::none()
    }
}

/// Get the approval mode for an object
public fun get_object_mode(registry: &PolicyRegistry, object_id: ID): u8 {
    if (table::contains(&registry.object_policies, object_id)) {
        let rule = table::borrow(&registry.object_policies, object_id);
        rule.mode
    } else {
        0 // Default to DAO_ONLY
    }
}

/// Set a pattern-based policy with mode
public fun set_pattern_policy(
    registry: &mut PolicyRegistry,
    pattern: vector<u8>,
    council_id: Option<ID>,
    mode: u8,
) {
    let rule = PolicyRule { council_id, mode };
    if (table::contains(&registry.pattern_policies, pattern)) {
        let existing = table::borrow_mut(&mut registry.pattern_policies, pattern);
        *existing = rule;
    } else {
        table::add(&mut registry.pattern_policies, pattern, rule);
    }
}

/// Set an object-specific policy with mode
public fun set_object_policy(
    registry: &mut PolicyRegistry,
    object_id: ID,
    council_id: Option<ID>,
    mode: u8,
) {
    let rule = PolicyRule { council_id, mode };
    if (table::contains(&registry.object_policies, object_id)) {
        let existing = table::borrow_mut(&mut registry.object_policies, object_id);
        *existing = rule;
    } else {
        table::add(&mut registry.object_policies, object_id, rule);
    }
}

/// Register a security council with the DAO
public fun register_council(
    registry: &mut PolicyRegistry,
    council_id: ID,
) {
    if (!vector::contains(&registry.registered_councils, &council_id)) {
        vector::push_back(&mut registry.registered_councils, council_id);
    }
}

/// Check if a council is registered
public fun is_council_registered(registry: &PolicyRegistry, council_id: ID): bool {
    vector::contains(&registry.registered_councils, &council_id)
}

/// Get all registered councils
public fun get_registered_councils(registry: &PolicyRegistry): &vector<ID> {
    &registry.registered_councils
}