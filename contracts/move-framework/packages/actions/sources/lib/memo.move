// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Generic memo emission actions for Account Protocol
/// Works with any Account type
/// Provides text memos with optional references to objects
///
/// Can be used for:
/// - Simple text memos: "This is important"
/// - Accept decisions: "Accept" + Some(proposal_id)
/// - Reject decisions: "Reject" + Some(proposal_id)
/// - Comments on objects: "Looks good!" + Some(object_id)

module account_actions::memo;

// === Imports ===

use std::{
    string::{Self, String},
    option::{Option},
};
use sui::{
    object::{Self, ID},
    clock::{Clock},
    tx_context::{Self, TxContext},
    event,
    bcs,
};
use account_protocol::{
    account::{Account},
    executable::{Self, Executable},
    intents::{Self, Expired, Intent},
    bcs_validation,
    action_validation,
};

// === Errors ===

const EEmptyMemo: u64 = 0;
const EMemoTooLong: u64 = 1;
const EUnsupportedActionVersion: u64 = 2;

// === Constants ===

const MAX_MEMO_LENGTH: u64 = 10000; // Maximum memo length in bytes

// === Action Type Markers ===

/// Emit a text memo with optional object reference
public struct Memo has drop {}

public fun memo(): Memo { Memo {} }

// === Structs ===

/// Action to emit a text memo with optional reference to an object
public struct EmitMemoAction has store {
    /// The message to emit
    memo: String,
    /// Optional reference to what this memo is about
    reference_id: Option<ID>,
}

// === Events ===

public struct MemoEmitted has copy, drop {
    /// DAO that emitted the memo
    dao_id: ID,
    /// The memo content
    memo: String,
    /// Optional reference to what this memo is about
    reference_id: Option<ID>,
    /// When it was emitted
    timestamp: u64,
    /// Who triggered the emission
    emitter: address,
}

// === Destruction Functions ===

/// Destroy an EmitMemoAction after serialization
public fun destroy_emit_memo_action(action: EmitMemoAction) {
    let EmitMemoAction { memo: _, reference_id: _ } = action;
}

// === Public Functions ===

/// Creates an EmitMemoAction and adds it to an intent
public fun new_emit_memo<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    memo: String,
    reference_id: Option<ID>,
    intent_witness: IW,
) {
    assert!(memo.length() > 0, EEmptyMemo);
    assert!(memo.length() <= MAX_MEMO_LENGTH, EMemoTooLong);

    // Create the action struct
    let action = EmitMemoAction { memo, reference_id };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with pre-serialized bytes
    intent.add_typed_action(
        memo(),
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_emit_memo_action(action);
}

/// Execute an emit memo action
public fun do_emit_memo<Config: store, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    _intent_witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<Memo>(spec);

    let action_data = intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    // BCS format: String (memo) followed by Option<ID> (reference_id)
    let mut reader = bcs::new(*action_data);
    let memo_bytes = reader.peel_vec_u8();
    let memo = string::utf8(memo_bytes);

    // Deserialize Option<ID>
    // BCS encodes Option as: 0x00 for None, 0x01 followed by value for Some
    let option_byte = bcs::peel_u8(&mut reader);
    let reference_id = if (option_byte == 1) {
        let id_bytes = bcs::peel_vec_u8(&mut reader);
        option::some(object::id_from_bytes(id_bytes))
    } else {
        option::none()
    };

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Validate memo
    assert!(memo.length() > 0, EEmptyMemo);
    assert!(memo.length() <= MAX_MEMO_LENGTH, EMemoTooLong);

    // Emit the event
    event::emit(MemoEmitted {
        dao_id: object::id(account),
        memo,
        reference_id,
        timestamp: clock.timestamp_ms(),
        emitter: tx_context::sender(ctx),
    });

    executable::increment_action_idx(executable);
}

/// Deletes a memo action from an expired intent
public fun delete_memo(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, automatically cleaned up
}
