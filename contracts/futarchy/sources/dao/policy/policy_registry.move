/// Manages on-chain policies that require external account approval for critical actions.
/// This registry links a protected resource (identified by a key) to a policy-enforcing Account.
/// 
/// Uses standardized resource keys from futarchy::resources for consistency.
module futarchy::policy_registry;

use std::string::{Self, String};
use sui::object::{ID, UID};
use sui::table::{Self, Table};
use sui::event;
use sui::tx_context::TxContext;
use account_protocol::account::{Self, Account};
use account_protocol::version_witness::VersionWitness;
use futarchy::resources;

// === Errors ===
const EPolicyNotFound: u64 = 1;

// === Structs ===

/// Key for storing the registry in the Account's managed data.
public struct PolicyRegistryKey has copy, drop, store {}

/// The registry object. Maps a resource key (e.g., "UpgradeCap:futarchy") to a Policy.
public struct PolicyRegistry has store {
    policies: Table<String, Policy>,
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

// === Public Functions ===

/// Initializes the policy registry for an Account.
public fun initialize<Config>(account: &mut Account<Config>, version_witness: VersionWitness, ctx: &mut TxContext) {
    if (!account::has_managed_data(account, PolicyRegistryKey {})) {
        account::add_managed_data(
            account,
            PolicyRegistryKey {},
            PolicyRegistry { policies: table::new(ctx) },
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
    
    // Check if policy exists and update or insert accordingly
    if (table::contains(&registry.policies, resource_key)) {
        table::remove(&mut registry.policies, resource_key);
    };
    table::add(&mut registry.policies, resource_key, policy);

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
        table::remove(&mut registry.policies, resource_key);
    };
    table::add(&mut registry.policies, resource_key, policy);

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
        table::remove(&mut registry.policies, resource_key);
    };
    table::add(&mut registry.policies, resource_key, policy);

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
        table::remove(&mut registry.policies, resource_key);
    };
    table::add(&mut registry.policies, resource_key, policy);

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