// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// Developers can restrict access to functions in their own package with a Cap that can be locked into an Account. 
/// The Cap can be borrowed upon approval and used in other move calls within the same ptb before being returned.
/// 
/// The Cap pattern uses the object type as a proof of access, the object ID is never checked.
/// Therefore, only one Cap of a given type can be locked into the Smart Account.
/// And any Cap of that type can be returned to the Smart Account after being borrowed.
/// 
/// A good practice to follow is to use a different Cap type for each function that needs to be restricted.
/// This way, the Cap borrowed can't be misused in another function, by the person executing the intent.
/// 
/// e.g.
/// 
/// public struct AdminCap has key, store {}
/// 
/// public fun foo(_: &AdminCap) { ... }

module account_actions::access_control;

// === Imports ===


use sui::bcs::{Self, BCS};
use account_protocol::{
    action_validation,
    account::{Account, Auth},
    intents::{Self, Expired, Intent},
    executable::{Self, Executable},
    version_witness::VersionWitness,
};
use account_actions::version;

// === Use Fun Aliases ===

// === Errors ===

/// BorrowAction requires a matching ReturnAction in the same intent to ensure capability is returned
const ENoReturn: u64 = 0;
/// Error when action version is not supported
const EUnsupportedActionVersion: u64 = 1;

// === Action Type Markers ===

/// Store/lock capability
public struct AccessControlStore has drop {}
/// Borrow capability
public struct AccessControlBorrow has drop {}
/// Return borrowed capability
public struct AccessControlReturn has drop {}

public fun access_control_store(): AccessControlStore { AccessControlStore {} }
public fun access_control_borrow(): AccessControlBorrow { AccessControlBorrow {} }
public fun access_control_return(): AccessControlReturn { AccessControlReturn {} }

// === Structs ===    

/// Dynamic Object Field key for the Cap.
public struct CapKey<phantom Cap>() has copy, drop, store;

/// Action giving access to the Cap.
public struct BorrowAction<phantom Cap> has drop, store {}
/// This hot potato is created upon approval to ensure the cap is returned.
public struct ReturnAction<phantom Cap> has drop, store {}

// === Public functions ===

/// Authenticated user can lock a Cap, the Cap must have at least store ability.
public fun lock_cap<Config: store, Cap: key + store>(
    auth: Auth,
    account: &mut Account,
    cap: Cap,
) {
    account.verify(auth);
    account.add_managed_asset(CapKey<Cap>(), cap, version::current());
}

/// Lock capability during initialization - works on unshared Accounts
/// Store any capability in the Account during creation
public(package) fun do_lock_cap_unshared< Cap: key + store>(
    account: &mut Account,
    cap: Cap,
) {
    account.add_managed_asset(CapKey<Cap>(), cap, version::current());
}

/// Checks if there is a Cap locked for a given type.
public fun has_lock<Config: store, Cap>(
    account: &Account
): bool {
    account.has_managed_asset(CapKey<Cap>())
}

// === Destruction Functions ===

/// Destroy a BorrowAction after serialization
public fun destroy_borrow_action<Cap>(action: BorrowAction<Cap>) {
    let BorrowAction {} = action;
}

/// Destroy a ReturnAction after serialization
public fun destroy_return_action<Cap>(action: ReturnAction<Cap>) {
    let ReturnAction {} = action;
}

// Intent functions

/// Creates and returns a BorrowAction.
public fun new_borrow<Outcome, Cap, IW: drop>(
    intent: &mut Intent<Outcome>,
    intent_witness: IW,
) {
    // Create the action struct
    let action = BorrowAction<Cap> {};

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with pre-serialized bytes
    intent.add_typed_action(
        access_control_borrow(),
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_borrow_action(action);
}

/// Processes a BorrowAction and returns a Borrowed hot potato and the Cap.
public fun do_borrow<Config: store, Outcome: store, Cap: key + store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    version_witness: VersionWitness,
    _intent_witness: IW,
): Cap {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec and verify it's a BorrowAction
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<AccessControlBorrow>(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let _action_data = intents::action_spec_data(spec);

    // BorrowAction is an empty struct with no fields to deserialize
    // We acknowledge the action_data exists but don't process it

    // CRITICAL: Verify that a matching ReturnAction exists in the intent
    // This ensures the borrowed capability will be returned
    let current_idx = executable.action_idx();
    let mut return_found = false;
    let return_action_type = action_validation::get_action_type_name<AccessControlReturn>();

    // Search from the next action onwards
    let mut i = current_idx + 1;
    while (i < specs.length()) {
        let future_spec = specs.borrow(i);
        if (intents::action_spec_type(future_spec) == return_action_type) {
            return_found = true;
            break
        };
        i = i + 1;
    };

    assert!(return_found, ENoReturn);

    // For BorrowAction<Cap>, there's no data to deserialize (empty struct)
    // Just increment the action index
    executable::increment_action_idx(executable);

    account.remove_managed_asset(CapKey<Cap>(), version_witness)
}

/// Deletes a BorrowAction from an expired intent.
public fun delete_borrow<Cap>(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, automatically cleaned up
}

/// Creates and returns a ReturnAction.
public fun new_return<Outcome, Cap, IW: drop>(
    intent: &mut Intent<Outcome>,
    intent_witness: IW,
) {
    // Create the action struct
    let action = ReturnAction<Cap> {};

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with pre-serialized bytes
    intent.add_typed_action(
        access_control_return(),
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_return_action(action);
}

/// Returns a Cap to the Account and validates the ReturnAction.
public fun do_return<Config: store, Outcome: store, Cap: key + store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    cap: Cap,
    version_witness: VersionWitness,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec and verify it's a ReturnAction
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<AccessControlReturn>(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let _action_data = intents::action_spec_data(spec);

    // ReturnAction is an empty struct with no fields to deserialize
    // We acknowledge the action_data exists but don't process it

    // Increment the action index
    executable::increment_action_idx(executable);

    account.add_managed_asset(CapKey<Cap>(), cap, version_witness);
}

/// Deletes a ReturnAction from an expired intent.
public fun delete_return<Cap>(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, automatically cleaned up
}
