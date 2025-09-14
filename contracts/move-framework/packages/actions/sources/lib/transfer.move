// ============================================================================
// FORK MODIFICATION NOTICE - Type-Based Transfer Operations
// ============================================================================
// This module defines APIs to transfer assets owned or managed by Account.
//
// CHANGES IN THIS FORK:
// - TransferAction uses TransferObject type marker from framework_action_types
// - Added 'drop' ability to TransferAction struct
// - Integrated BCS validation for action deserialization
// - Actions use typed Intent system with add_typed_action()
// - Enhanced imports for better modularity (bcs::Self, executable::Self, intents::Self)
// - Type-safe action validation through ActionSpec comparison
// - Compile-time type safety replaces string-based descriptors
// ============================================================================
/// This module defines apis to transfer assets owned or managed by the account.
/// The intents can implement transfers for any action type (e.g. see owned or vault).

module account_actions::transfer;

// === Imports ===

use sui::bcs::{Self, BCS};
use account_protocol::{
    intents::{Self, Expired, Intent},
    executable::{Self, Executable},
};
use account_extensions::framework_action_types;

// === Use Fun Aliases ===
use fun account_protocol::intents::add_typed_action as Intent.add_typed_action;

// === Structs ===

/// Action used in combination with other actions (like WithdrawAction) to transfer objects to a recipient.
public struct TransferAction has store, drop {
    // address to transfer to
    recipient: address,
}

// === Public functions ===

/// Creates a TransferAction and adds it to an intent with descriptor.
public fun new_transfer<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    recipient: address,
    intent_witness: IW,
) {
    intent.add_typed_action(
        TransferAction { recipient },
        framework_action_types::transfer_object(),
        intent_witness
    );
}

/// Processes a TransferAction and transfers an object to a recipient.
public fun do_transfer<Outcome: store, T: key + store, IW: drop>(
    executable: &mut Executable<Outcome>,
    object: T,
    _intent_witness: IW,
) {
    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());
    let action_data = intents::action_spec_data(spec);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let recipient = bcs::peel_address(&mut reader);

    transfer::public_transfer(object, recipient);
    executable::increment_action_idx(executable);
}

/// Deletes a TransferAction from an expired intent.
public fun delete_transfer(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, automatically cleaned up
}
