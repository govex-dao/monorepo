// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Generic memo emission actions for Account Protocol
/// Works with any Account<Config> type
/// Provides text memos and accept/reject decision memos
module futarchy_actions::memo_actions;

// === Imports ===
use std::{
    string::{Self, String},
    option::{Self, Option},
};
use sui::{
    object::{Self, ID},
    clock::{Self, Clock},
    tx_context::{Self, TxContext},
    event,
    bcs::{Self, BCS},
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    version_witness::VersionWitness,
    intents::{Self, Expired, Intent},
    bcs_validation,
};
use futarchy_types::action_type_markers;
use futarchy_core::{
    action_validation,
    // action_types moved to futarchy_types
};

// === Aliases ===
use account_protocol::intents as protocol_intents;

// === Errors ===
const EEmptyMemo: u64 = 1;
const EMemoTooLong: u64 = 2;
const EWrongAction: u64 = 3;
const EUnsupportedActionVersion: u64 = 4;

// === Constants ===
const MAX_MEMO_LENGTH: u64 = 10000; // Maximum memo length in bytes
const DECISION_ACCEPT: u8 = 1;
const DECISION_REJECT: u8 = 2;

// === Action Structs ===

/// Action to emit a text memo
public struct EmitMemoAction has store, drop, copy {
    /// The message to emit
    memo: String,
}

/// Action to emit an accept/reject decision
public struct EmitDecisionAction has store, drop, copy {
    /// Decision: true for accept, false for reject
    accept: bool,
    /// Optional reference to what is being decided on
    reference_id: Option<ID>,
}

// === Events ===

public struct MemoEmitted has copy, drop {
    /// DAO that emitted the memo
    dao_id: ID,
    /// The memo content
    memo: String,
    /// When it was emitted
    timestamp: u64,
    /// Who triggered the emission
    emitter: address,
}

public struct DecisionEmitted has copy, drop {
    /// DAO that made the decision
    dao_id: ID,
    /// True for accept, false for reject
    accept: bool,
    /// Optional reference
    reference_id: Option<ID>,
    /// When it was emitted
    timestamp: u64,
    /// Who triggered the emission
    emitter: address,
}

// === Execution Functions ===

/// Execute an emit memo action
public fun do_emit_memo<Config: store, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version: VersionWitness,
    intent_witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // CRITICAL - Type check BEFORE deserialization
    action_validation::assert_action_type<action_type_markers::Memo>(spec);

    // Get action data
    let action_data = protocol_intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Safe deserialization with BCS reader
    let mut reader = bcs::new(*action_data);
    let memo = string::utf8(reader.peel_vec_u8());

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Validate memo
    assert!(memo.length() > 0, EEmptyMemo);
    assert!(memo.length() <= MAX_MEMO_LENGTH, EMemoTooLong);

    // Emit the event
    event::emit(MemoEmitted {
        dao_id: object::id(account),
        memo,
        timestamp: clock.timestamp_ms(),
        emitter: tx_context::sender(ctx),
    });

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute an emit decision action
public fun do_emit_decision<Config: store, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version: VersionWitness,
    intent_witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // CRITICAL - Type check BEFORE deserialization
    // Note: Using Memo type since EmitDecision is not in action_types
    action_validation::assert_action_type<action_type_markers::Memo>(spec);

    // Get action data
    let action_data = protocol_intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Safe deserialization with BCS reader
    let mut reader = bcs::new(*action_data);
    let accept = reader.peel_bool();
    let reference_id = if (reader.peel_bool()) {
        option::some(object::id_from_bytes(reader.peel_vec_u8()))
    } else {
        option::none()
    };

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Emit the event
    event::emit(DecisionEmitted {
        dao_id: object::id(account),
        accept,
        reference_id,
        timestamp: clock.timestamp_ms(),
        emitter: tx_context::sender(ctx),
    });

    // Increment action index
    executable::increment_action_idx(executable);
}

// === Destruction Functions ===

/// Destroy an EmitMemoAction
public fun destroy_emit_memo(action: EmitMemoAction) {
    let EmitMemoAction { memo: _ } = action;
}

/// Destroy an EmitDecisionAction
public fun destroy_emit_decision(action: EmitDecisionAction) {
    let EmitDecisionAction { accept: _, reference_id: _ } = action;
}

// === Cleanup Functions ===

/// Delete an emit memo action from an expired intent
public fun delete_emit_memo(expired: &mut Expired) {
    let action_spec = intents::remove_action_spec(expired);
    let action_data = intents::action_spec_action_data(action_spec);
    // Just consume the data without parsing
    let mut reader = bcs::new(action_data);
    let _memo = reader.peel_vec_u8();
    let _ = reader.into_remainder_bytes();
}

/// Delete an emit decision action from an expired intent
public fun delete_emit_decision(expired: &mut Expired) {
    let action_spec = intents::remove_action_spec(expired);
    let action_data = intents::action_spec_action_data(action_spec);
    // Just consume the data without parsing
    let mut reader = bcs::new(action_data);
    let _accept = reader.peel_bool();
    let _has_ref = reader.peel_bool();
    if (_has_ref) {
        let _ref_id = reader.peel_vec_u8();
    };
    let _ = reader.into_remainder_bytes();
}

/// Generic delete function for memo actions (tries both types)
/// This is called by the garbage collection registry
public fun delete_memo(expired: &mut Expired) {
    // Try to delete as emit_memo first, fall back to emit_decision
    // Both use the same action type, so we just need to consume the spec
    let action_spec = intents::remove_action_spec(expired);
    // Action spec has drop, so it's automatically cleaned up
    let _ = action_spec;
}

// === Constructor Functions ===

/// Create a new emit memo action
public fun new_emit_memo_action(
    memo: String,
): EmitMemoAction {
    EmitMemoAction {
        memo,
    }
}

/// Create a new emit decision action
public fun new_emit_decision_action(
    accept: bool,
    reference_id: Option<ID>,
): EmitDecisionAction {
    EmitDecisionAction {
        accept,
        reference_id,
    }
}

// === Intent Creation Functions (with serialize-then-destroy pattern) ===

/// Add an EmitMemo action to an intent
public fun new_emit_memo<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    memo: String,
    intent_witness: IW,
) {
    assert!(memo.length() > 0, EEmptyMemo);
    assert!(memo.length() <= MAX_MEMO_LENGTH, EMemoTooLong);

    let action = EmitMemoAction { memo };
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        action_type_markers::memo(),
        action_data,
        intent_witness
    );
    destroy_emit_memo(action);
}

/// Add an EmitDecision action to an intent
public fun new_emit_decision<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    accept: bool,
    reference_id: Option<ID>,
    intent_witness: IW,
) {
    let action = EmitDecisionAction { accept, reference_id };
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        action_type_markers::memo(), // Using memo type since EmitDecision not in action_types
        action_data,
        intent_witness
    );
    destroy_emit_decision(action);
}

// === Deserialization Functions ===

/// Deserialize EmitMemoAction from bytes
public(package) fun emit_memo_action_from_bytes(bytes: vector<u8>): EmitMemoAction {
    let mut bcs = bcs::new(bytes);
    EmitMemoAction {
        memo: string::utf8(bcs.peel_vec_u8()),
    }
}

/// Deserialize EmitDecisionAction from bytes
public(package) fun emit_decision_action_from_bytes(bytes: vector<u8>): EmitDecisionAction {
    let mut bcs = bcs::new(bytes);
    EmitDecisionAction {
        accept: bcs.peel_bool(),
        reference_id: if (bcs.peel_bool()) {
            option::some(object::id_from_bytes(bcs.peel_vec_u8()))
        } else {
            option::none()
        },
    }
}