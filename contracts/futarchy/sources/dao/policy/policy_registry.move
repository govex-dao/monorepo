/// Manages on-chain policies that require external account approval for critical actions.
/// This registry links a protected resource (identified by a key) to a policy-enforcing Account.
module futarchy::policy_registry;

use std::string::{Self, String};
use sui::object::{ID, UID};
use sui::table::{Self, Table};
use sui::event;
use sui::tx_context::TxContext;
use account_protocol::account::{Self, Account};
use account_protocol::version_witness::VersionWitness;

// === Errors ===
const EPolicyNotFound: u64 = 1;
const ECannotRemoveOACustodian: u64 = 2;  // DAO can never remove OA:Custodian

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
public fun set_policy(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    resource_key: String,
    policy_account_id: ID,
    intent_key_prefix: String,
) {
    let policy = Policy { policy_account_id, intent_key_prefix };
    
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
    
    // CRITICAL: DAO can NEVER remove OA:Custodian
    // Only the security council can give up control through the coexec path
    // This ensures the DAO always has an operating agreement
    if (resource_key == b"OA:Custodian".to_string()) {
        abort ECannotRemoveOACustodian
    };
    
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