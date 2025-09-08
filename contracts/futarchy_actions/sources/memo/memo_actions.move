/// Memo/Message emission actions for futarchy DAOs
/// This module defines action structs and execution logic for emitting messages
/// Following the same pattern as liquidity_actions, config_actions, etc.
module futarchy_actions::memo_actions;

// === Imports ===
use std::string::String;
use std::vector;
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
const EInvalidMetadata: u64 = 2;
const EMemoTooLong: u64 = 3;

// === Constants ===
const MAX_MEMO_LENGTH: u64 = 10000; // Maximum memo length in bytes

// === Action Structs ===

/// Action to emit a simple text memo
public struct EmitMemoAction has store {
    /// The message to emit
    memo: String,
    /// Optional category for filtering/organizing memos
    category: String,
    /// Optional reference to related entity (proposal, DAO, etc.)
    reference_id: Option<ID>,
}

/// Action to emit structured data as a memo
public struct EmitStructuredMemoAction has store {
    /// Title of the memo
    title: String,
    /// Key-value pairs of structured data
    fields: vector<MemoField>,
    /// Optional metadata
    metadata: vector<u8>,
}

/// A field in a structured memo
public struct MemoField has store, copy, drop {
    key: String,
    value: String,
}

/// Action to emit a commitment or agreement
public struct EmitCommitmentAction has store {
    /// Type of commitment (e.g., "partnership", "investment", "governance")
    commitment_type: String,
    /// The commitment message
    commitment: String,
    /// Counterparty ID if applicable
    counterparty: Option<ID>,
    /// Expiry timestamp if applicable
    expires_at: Option<u64>,
}

/// Action to emit a vote or signal
public struct EmitSignalAction has store {
    /// What is being signaled about
    signal_type: String,
    /// The signal value (e.g., "support", "oppose", "abstain")
    signal_value: String,
    /// Optional context
    context: vector<u8>,
}

// === Events ===

public struct MemoEmitted has copy, drop {
    /// DAO that emitted the memo
    dao_id: ID,
    /// The memo content
    memo: String,
    /// Category of the memo
    category: String,
    /// Optional reference
    reference_id: Option<ID>,
    /// When it was emitted
    timestamp: u64,
    /// Who triggered the emission
    emitter: address,
}

public struct StructuredMemoEmitted has copy, drop {
    dao_id: ID,
    title: String,
    fields: vector<MemoField>,
    timestamp: u64,
    emitter: address,
}

public struct CommitmentEmitted has copy, drop {
    dao_id: ID,
    commitment_type: String,
    commitment: String,
    counterparty: Option<ID>,
    expires_at: Option<u64>,
    timestamp: u64,
    emitter: address,
}

public struct SignalEmitted has copy, drop {
    dao_id: ID,
    signal_type: String,
    signal_value: String,
    timestamp: u64,
    emitter: address,
}

// === Intent Witness ===

/// Witness for memo intents
public struct MemoIntent has drop {}

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
        category: action.category,
        reference_id: action.reference_id,
        timestamp: clock::timestamp_ms(clock),
        emitter: tx_context::sender(ctx),
    });
}

/// Execute an emit structured memo action
public fun do_emit_structured_memo<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action: &EmitStructuredMemoAction = executable::next_action(executable, intent_witness);
    
    // Validate
    assert!(action.title.length() > 0, EEmptyMemo);
    assert!(!vector::is_empty(&action.fields), EInvalidMetadata);
    
    // Emit the event
    event::emit(StructuredMemoEmitted {
        dao_id: object::id(account),
        title: action.title,
        fields: action.fields,
        timestamp: clock::timestamp_ms(clock),
        emitter: tx_context::sender(ctx),
    });
}

/// Execute an emit commitment action
public fun do_emit_commitment<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action: &EmitCommitmentAction = executable::next_action(executable, intent_witness);
    
    // Validate
    assert!(action.commitment.length() > 0, EEmptyMemo);
    assert!(action.commitment.length() <= MAX_MEMO_LENGTH, EMemoTooLong);
    
    // Check expiry if provided
    if (action.expires_at.is_some()) {
        let expiry = *action.expires_at.borrow();
        assert!(expiry > clock::timestamp_ms(clock), EInvalidMetadata);
    };
    
    // Emit the event
    event::emit(CommitmentEmitted {
        dao_id: object::id(account),
        commitment_type: action.commitment_type,
        commitment: action.commitment,
        counterparty: action.counterparty,
        expires_at: action.expires_at,
        timestamp: clock::timestamp_ms(clock),
        emitter: tx_context::sender(ctx),
    });
}

/// Execute an emit signal action
public fun do_emit_signal<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action: &EmitSignalAction = executable::next_action(executable, intent_witness);
    
    // Validate
    assert!(action.signal_type.length() > 0, EEmptyMemo);
    assert!(action.signal_value.length() > 0, EEmptyMemo);
    
    // Emit the event
    event::emit(SignalEmitted {
        dao_id: object::id(account),
        signal_type: action.signal_type,
        signal_value: action.signal_value,
        timestamp: clock::timestamp_ms(clock),
        emitter: tx_context::sender(ctx),
    });
}

// === Constructor Functions ===

/// Create an emit memo action
public fun new_emit_memo_action(
    memo: String,
    category: String,
    reference_id: Option<ID>,
): EmitMemoAction {
    EmitMemoAction {
        memo,
        category,
        reference_id,
    }
}

/// Create an emit structured memo action
public fun new_emit_structured_memo_action(
    title: String,
    fields: vector<MemoField>,
    metadata: vector<u8>,
): EmitStructuredMemoAction {
    EmitStructuredMemoAction {
        title,
        fields,
        metadata,
    }
}

/// Create an emit commitment action
public fun new_emit_commitment_action(
    commitment_type: String,
    commitment: String,
    counterparty: Option<ID>,
    expires_at: Option<u64>,
): EmitCommitmentAction {
    EmitCommitmentAction {
        commitment_type,
        commitment,
        counterparty,
        expires_at,
    }
}

/// Create an emit signal action
public fun new_emit_signal_action(
    signal_type: String,
    signal_value: String,
    context: vector<u8>,
): EmitSignalAction {
    EmitSignalAction {
        signal_type,
        signal_value,
        context,
    }
}

/// Create a memo field
public fun new_memo_field(key: String, value: String): MemoField {
    MemoField { key, value }
}

// === Getter Functions ===

public fun get_memo(action: &EmitMemoAction): &String {
    &action.memo
}

public fun get_category(action: &EmitMemoAction): &String {
    &action.category
}

public fun get_reference_id(action: &EmitMemoAction): &Option<ID> {
    &action.reference_id
}

public fun get_title(action: &EmitStructuredMemoAction): &String {
    &action.title
}

public fun get_fields(action: &EmitStructuredMemoAction): &vector<MemoField> {
    &action.fields
}

public fun get_commitment_type(action: &EmitCommitmentAction): &String {
    &action.commitment_type
}

public fun get_commitment(action: &EmitCommitmentAction): &String {
    &action.commitment
}

public fun get_counterparty(action: &EmitCommitmentAction): &Option<ID> {
    &action.counterparty
}

public fun get_signal_type(action: &EmitSignalAction): &String {
    &action.signal_type
}

public fun get_signal_value(action: &EmitSignalAction): &String {
    &action.signal_value
}

// === Delete Functions for Expired Intents ===

/// Delete an emit memo action from an expired intent
public fun delete_memo(expired: &mut account_protocol::intents::Expired) {
    let EmitMemoAction {
        memo: _,
        category: _,
        reference_id: _,
    } = expired.remove_action();
}

/// Delete an emit structured memo action from an expired intent
public fun delete_structured_memo(expired: &mut account_protocol::intents::Expired) {
    let EmitStructuredMemoAction {
        title: _,
        fields: _,
        metadata: _,
    } = expired.remove_action();
}

/// Delete an emit commitment action from an expired intent
public fun delete_commitment(expired: &mut account_protocol::intents::Expired) {
    let EmitCommitmentAction {
        commitment_type: _,
        commitment: _,
        counterparty: _,
        expires_at: _,
    } = expired.remove_action();
}

/// Delete an emit signal action from an expired intent
public fun delete_signal(expired: &mut account_protocol::intents::Expired) {
    let EmitSignalAction {
        signal_type: _,
        signal_value: _,
        context: _,
    } = expired.remove_action();
}