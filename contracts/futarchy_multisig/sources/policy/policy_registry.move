/// Manages on-chain policies that require external account approval for critical actions.
/// This registry uses type-based policies (via TypeName) and object-specific policies (via ID)
/// to determine which actions require security council approval.
module futarchy_multisig::policy_registry;

use std::option::{Self, Option};
use std::string::String;
use std::vector;
use std::type_name::{Self, TypeName};
use sui::object::{ID, UID};
use sui::package::UpgradeCap;
use sui::table::{Self, Table};
use sui::event;
use sui::tx_context::TxContext;
use account_protocol::account::{Self, Account};
use account_protocol::version_witness::VersionWitness;

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

/// The registry object for type-based and object-specific policies
public struct PolicyRegistry has store {
    /// Type-based policies for actions
    /// Maps TypeName to PolicyRule (council ID + mode)
    type_policies: Table<TypeName, PolicyRule>,
    
    /// Object-specific policies (e.g., specific UpgradeCap)
    /// Maps object ID to PolicyRule (council ID + mode)
    object_policies: Table<ID, PolicyRule>,
    
    /// Registered security councils for this DAO
    registered_councils: vector<ID>,
}

/// NEW: Simplified policy rule for descriptor-based policies
public struct PolicyRule has store, copy, drop {
    /// The security council ID (if any)
    council_id: Option<ID>,
    /// Mode: 0=DAO_ONLY, 1=COUNCIL_ONLY, 2=DAO_OR_COUNCIL, 3=DAO_AND_COUNCIL
    mode: u8,
}


// === Events ===
public struct TypePolicySet has copy, drop {
    dao_id: ID,
    action_type: TypeName,
    council_id: Option<ID>,
    mode: u8,
}

public struct ObjectPolicySet has copy, drop {
    dao_id: ID,
    object_id: ID,
    council_id: Option<ID>,
    mode: u8,
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

// === Convenience Functions for Common Policy Patterns ===





// REMOVED: All string-based critical policy functions
// Use type-based policies instead via set_type_policy()

// === New Functions for Descriptor-Based Policies ===

/// Check if a type needs council approval
public fun type_needs_council(registry: &PolicyRegistry, action_type: TypeName): bool {
    if (table::contains(&registry.type_policies, action_type)) {
        let rule = table::borrow(&registry.type_policies, action_type);
        // Needs council if mode is not DAO_ONLY (0)
        rule.mode != 0
    } else {
        false
    }
}

/// Get the council ID for a type
public fun get_type_council(registry: &PolicyRegistry, action_type: TypeName): Option<ID> {
    if (table::contains(&registry.type_policies, action_type)) {
        let rule = table::borrow(&registry.type_policies, action_type);
        rule.council_id
    } else {
        option::none()
    }
}

/// Get the approval mode for a type
public fun get_type_mode(registry: &PolicyRegistry, action_type: TypeName): u8 {
    if (table::contains(&registry.type_policies, action_type)) {
        let rule = table::borrow(&registry.type_policies, action_type);
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

/// Set a type-based policy with mode
public fun set_type_policy<T: drop>(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    council_id: Option<ID>,
    mode: u8,
) {
    let action_type = type_name::get<T>();
    let rule = PolicyRule { council_id, mode };
    if (table::contains(&registry.type_policies, action_type)) {
        let existing = table::borrow_mut(&mut registry.type_policies, action_type);
        *existing = rule;
    } else {
        table::add(&mut registry.type_policies, action_type, rule);
    };
    
    event::emit(TypePolicySet {
        dao_id,
        action_type,
        council_id,
        mode,
    });
}

/// Set a type-based policy using TypeName directly
public fun set_type_policy_by_name(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    action_type: TypeName,
    council_id: Option<ID>,
    mode: u8,
) {
    let rule = PolicyRule { council_id, mode };
    if (table::contains(&registry.type_policies, action_type)) {
        let existing = table::borrow_mut(&mut registry.type_policies, action_type);
        *existing = rule;
    } else {
        table::add(&mut registry.type_policies, action_type, rule);
    };
    
    event::emit(TypePolicySet {
        dao_id,
        action_type,
        council_id,
        mode,
    });
}

/// Set an object-specific policy with mode
public fun set_object_policy(
    registry: &mut PolicyRegistry,
    dao_id: ID,
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
    };
    
    event::emit(ObjectPolicySet {
        dao_id,
        object_id,
        council_id,
        mode,
    });
}

/// Register a security council with the DAO
public fun register_council(
    registry: &mut PolicyRegistry,
    dao_id: ID,
    council_id: ID,
) {
    if (!vector::contains(&registry.registered_councils, &council_id)) {
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
public fun has_type_policy<T>(registry: &PolicyRegistry): bool {
    let type_name = type_name::get<T>();
    table::contains(&registry.type_policies, type_name)
}