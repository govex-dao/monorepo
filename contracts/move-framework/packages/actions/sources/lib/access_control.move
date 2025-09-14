// ============================================================================
// FORK MODIFICATION NOTICE - Access Control with Serialize-Then-Destroy Pattern
// ============================================================================
// This module manages capability-based access control for Account actions.
//
// CHANGES IN THIS FORK:
// - Actions use type markers: AccessControlBorrow, AccessControlReturn
// - Implemented serialize-then-destroy pattern for resource safety
// - Added destruction functions: destroy_borrow_action, destroy_return_action
// - Actions serialize to bytes before adding to intent via add_typed_action()
// - Enforces matching ReturnAction for every BorrowAction in intent
// - Type-safe action validation through compile-time TypeName comparison
// ============================================================================
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
use account_extensions::framework_action_types;

// === Use Fun Aliases ===
// Removed - add_typed_action is now called directly

// === Errors ===

/// BorrowAction requires a matching ReturnAction in the same intent to ensure capability is returned
const ENoReturn: u64 = 0;

// === Structs ===    

/// Dynamic Object Field key for the Cap.
public struct CapKey<phantom Cap>() has copy, drop, store;

/// Action giving access to the Cap.
public struct BorrowAction<phantom Cap> has drop, store {}
/// This hot potato is created upon approval to ensure the cap is returned.
public struct ReturnAction<phantom Cap> has drop, store {}

// === Public functions ===

/// Authenticated user can lock a Cap, the Cap must have at least store ability.
public fun lock_cap<Config, Cap: key + store>(
    auth: Auth,
    account: &mut Account<Config>,
    cap: Cap,
) {
    account.verify(auth);
    account.add_managed_asset(CapKey<Cap>(), cap, version::current());
}

/// Checks if there is a Cap locked for a given type.
public fun has_lock<Config, Cap>(
    account: &Account<Config>
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
        framework_action_types::access_control_borrow(),
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_borrow_action(action);
}

/// Processes a BorrowAction and returns a Borrowed hot potato and the Cap.
public fun do_borrow<Config, Outcome: store, Cap: key + store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    _intent_witness: IW,
): Cap {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec and verify it's a BorrowAction
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<framework_action_types::AccessControlBorrow>(spec);


    let _action_data = intents::action_spec_data(spec);

    // CRITICAL: Verify that a matching ReturnAction exists in the intent
    // This ensures the borrowed capability will be returned
    let current_idx = executable.action_idx();
    let mut return_found = false;
    let return_action_type = action_validation::get_action_type_name<framework_action_types::AccessControlReturn>();

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
        framework_action_types::access_control_return(),
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_return_action(action);
}

/// Returns a Cap to the Account and validates the ReturnAction.
public fun do_return<Config, Outcome: store, Cap: key + store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    cap: Cap,
    version_witness: VersionWitness,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec and verify it's a ReturnAction
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<framework_action_types::AccessControlReturn>(spec);


    let _action_data = intents::action_spec_data(spec);

    // For ReturnAction<Cap>, there's no data to deserialize (empty struct)
    // Just increment the action index
    executable::increment_action_idx(executable);

    account.add_managed_asset(CapKey<Cap>(), cap, version_witness);
}

/// Deletes a ReturnAction from an expired intent.
public fun delete_return<Cap>(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, automatically cleaned up
}
