/// Memo emission actions for futarchy DAOs
/// Provides text memos and accept/reject decision memos
module futarchy_actions::memo_actions;

// === Imports ===
use std::string::String;
use sui::{
    object::ID,
    clock::{Self, Clock},
    tx_context::{Self, TxContext},
    event,
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    version_witness::VersionWitness,
};
use futarchy_core::futarchy_config::FutarchyConfig;

// === Errors ===
const EEmptyMemo: u64 = 1;
const EMemoTooLong: u64 = 2;

// === Constants ===
const MAX_MEMO_LENGTH: u64 = 10000; // Maximum memo length in bytes
const DECISION_ACCEPT: u8 = 1;
const DECISION_REJECT: u8 = 2;

// === Action Structs ===

/// Action to emit a text memo
public struct EmitMemoAction has store {
    /// The message to emit
    memo: String,
}

/// Action to emit an accept/reject decision
public struct EmitDecisionAction has store {
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
public fun do_emit_memo<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action: &EmitMemoAction = executable::next_action(executable, intent_witness);

    // Validate memo
    assert!(action.memo.length() > 0, EEmptyMemo);
    assert!(action.memo.length() <= MAX_MEMO_LENGTH, EMemoTooLong);

    // Emit the event
    event::emit(MemoEmitted {
        dao_id: object::id(account),
        memo: action.memo,
        timestamp: clock.timestamp_ms(),
        emitter: tx_context::sender(ctx),
    });
}

/// Execute an emit decision action
public fun do_emit_decision<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action: &EmitDecisionAction = executable::next_action(executable, intent_witness);

    // Emit the event
    event::emit(DecisionEmitted {
        dao_id: object::id(account),
        accept: action.accept,
        reference_id: action.reference_id,
        timestamp: clock.timestamp_ms(),
        emitter: tx_context::sender(ctx),
    });
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