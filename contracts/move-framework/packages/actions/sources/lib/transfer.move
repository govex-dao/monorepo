// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// This module defines apis to transfer assets owned or managed by the account.
/// The intents can implement transfers for any action type (e.g. see owned or vault).

module account_actions::transfer;

// === Imports ===


use sui::bcs;
use account_protocol::{
    action_validation,
    intents::{Self, Expired, Intent},
    executable::{Self, Executable},
    bcs_validation,
};

// === Use Fun Aliases ===
// Removed - add_typed_action is now called directly

// === Errors ===

const EUnsupportedActionVersion: u64 = 0;

// === Action Type Markers ===

/// Transfer object ownership
public struct TransferObject has drop {}
/// Transfer object to transaction sender
public struct TransferToSender has drop {}

// === Structs ===

/// Action used in combination with other actions (like WithdrawAction) to transfer objects to a recipient.
public struct TransferAction has store {
    // address to transfer to
    recipient: address,
}

/// Action to transfer to the transaction sender (perfect for crank fees)
public struct TransferToSenderAction has store {
    // No recipient field needed - uses tx_context::sender()
}

// === Destruction Functions ===

/// Destroy a TransferAction after serialization
public fun destroy_transfer_action(action: TransferAction) {
    let TransferAction { recipient: _ } = action;
}

/// Destroy a TransferToSenderAction after serialization
public fun destroy_transfer_to_sender_action(action: TransferToSenderAction) {
    let TransferToSenderAction {} = action;
}

// === Public functions ===

/// Creates a TransferAction and adds it to an intent with descriptor.
public fun new_transfer<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    recipient: address,
    intent_witness: IW,
) {
    // Create the action struct (no drop)
    let action = TransferAction { recipient };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with pre-serialized bytes
    intent.add_typed_action(
        TransferObject {},
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_transfer_action(action);
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

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<TransferObject>(spec);


    let action_data = intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let recipient = bcs::peel_address(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    transfer::public_transfer(object, recipient);
    executable::increment_action_idx(executable);
}

/// Transfer object during initialization - works on unshared Accounts
/// Directly transfers an object to a recipient during DAO creation.
/// SAFETY: This function can be called during initialization to transfer
/// objects that were created as part of the DAO setup.
public fun do_transfer_unshared<T: key + store>(
    object: T,
    recipient: address,
) {
    transfer::public_transfer(object, recipient);
}

/// Deletes a TransferAction from an expired intent.
public fun delete_transfer(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, automatically cleaned up
}

/// Creates a TransferToSenderAction and adds it to an intent
public fun new_transfer_to_sender<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    intent_witness: IW,
) {
    // Create the action struct with no fields
    let action = TransferToSenderAction {};

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with type marker for TransferObject (reusing existing type)
    intent.add_typed_action(
        TransferObject {},
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_transfer_to_sender_action(action);
}

/// Processes a TransferToSenderAction and transfers an object to the transaction sender
public fun do_transfer_to_sender<Outcome: store, T: key + store, IW: drop>(
    executable: &mut Executable<Outcome>,
    object: T,
    _intent_witness: IW,
    ctx: &mut TxContext,
) {
    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect (using TransferObject)
    action_validation::assert_action_type<TransferObject>(spec);

    let _action_data = intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // TransferToSenderAction is an empty struct with no fields to deserialize
    // We acknowledge the action_data exists but don't process it

    // Transfer to the transaction sender (the cranker!)
    transfer::public_transfer(object, tx_context::sender(ctx));
    executable::increment_action_idx(executable);
}

/// Deletes a TransferToSenderAction from an expired intent.
public fun delete_transfer_to_sender(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, automatically cleaned up
}
