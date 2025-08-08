/// Operating agreement module for futarchy DAOs
/// This module manages the on-chain operating agreement with amendment capabilities
module futarchy::operating_agreement;

// === Imports ===
use std::{
    string::String,
    option::{Self, Option},
};
use sui::{
    clock::{Self, Clock},
    event,
    dynamic_field as df,
    object::{Self, ID, UID},
    tx_context::TxContext,
};
use account_protocol::{
    account::{Self, Account},
    executable::Executable,
    version_witness::VersionWitness,
};
use futarchy::{
    futarchy_config::FutarchyOutcome,
};
use futarchy::operating_agreement_actions::{
    UpdateLineAction,
    InsertLineAfterAction,
    InsertLineAtBeginningAction,
    RemoveLineAction,
    BatchOperatingAgreementAction,
    OperatingAgreementAction,
    get_update_line_params,
    get_insert_line_after_params,
    get_insert_line_at_beginning_params,
    get_remove_line_id,
    get_batch_actions,
    get_operating_agreement_action_params,
    action_update,
    action_insert_after,
    action_insert_at_beginning,
    action_remove,
};

// === Type Keys for Dynamic Fields ===
/// Type key for storing the operating agreement in the Account
public struct AgreementKey has copy, drop, store {}

/// Type key for individual lines in the agreement
public struct LineKey has copy, drop, store {
    id: ID,
}

// === Errors ===
const ELineNotFound: u64 = 0;
const EIncorrectLengths: u64 = 1;
const ETooManyLines: u64 = 2;
const EInvalidActionType: u64 = 3;
const EAgreementNotFound: u64 = 4;
const EAgreementAlreadyExists: u64 = 5;

// === Constants ===
const MAX_LINES_PER_AGREEMENT: u64 = 1000;
const MAX_TRAVERSAL_LIMIT: u64 = 1000;

// === Structs ===

/// Individual line in the operating agreement
public struct AgreementLine has store, drop {
    text: String,
    /// Difficulty required to change this line (in basis points)
    difficulty: u64,
    /// Previous line in the linked list
    prev: Option<ID>,
    /// Next line in the linked list
    next: Option<ID>,
}

/// The main operating agreement object - a shared object on chain
public struct OperatingAgreement has key, store {
    id: UID,
    /// DAO/Account ID this agreement belongs to
    dao_id: ID,
    /// Head of the linked list
    head: Option<ID>,
    /// Tail of the linked list  
    tail: Option<ID>,
}

// === Creation and Management Functions ===

/// Store the operating agreement in the Account using managed assets
public fun store_in_account<Config>(
    account: &mut Account<Config>,
    agreement: OperatingAgreement,
    version_witness: account_protocol::version_witness::VersionWitness,
) {
    account::add_managed_asset(account, AgreementKey {}, agreement, version_witness);
}

/// Get a mutable reference to the operating agreement from the Account
public fun get_agreement_mut<Config>(
    account: &mut Account<Config>,
    version_witness: account_protocol::version_witness::VersionWitness,
): &mut OperatingAgreement {
    account::borrow_managed_asset_mut(account, AgreementKey {}, version_witness)
}

/// Get a reference to the operating agreement from the Account
public fun get_agreement<Config>(
    account: &Account<Config>,
    version_witness: VersionWitness,
): &OperatingAgreement {
    account::borrow_managed_asset<Config, AgreementKey, OperatingAgreement>(account, AgreementKey {}, version_witness)
}

/// Check if an account has an operating agreement
public fun has_agreement<Config>(
    account: &Account<Config>,
): bool {
    account::has_managed_asset<Config, AgreementKey>(account, AgreementKey {})
}

// === Events ===

/// Emitted when the agreement is read or modified
public struct AgreementRead has copy, drop {
    dao_id: ID,
    line_ids: vector<ID>,
    texts: vector<String>,
    difficulties: vector<u64>,
    timestamp_ms: u64,
}

/// Emitted when a line is updated
public struct LineUpdated has copy, drop {
    dao_id: ID,
    line_id: ID,
    new_text: String,
    timestamp_ms: u64,
}

/// Emitted when a line is inserted
public struct LineInserted has copy, drop {
    dao_id: ID,
    line_id: ID,
    text: String,
    difficulty: u64,
    position_after: Option<ID>,
    timestamp_ms: u64,
}

/// Emitted when a line is removed
public struct LineRemoved has copy, drop {
    dao_id: ID,
    line_id: ID,
    timestamp_ms: u64,
}

// === Witness ===
/// Witness for accessing the operating agreement
public struct OperatingAgreementWitness has drop {}

// === Initialization Functions ===

/// Create a new operating agreement for a DAO
/// Returns the created agreement (to be stored in Account)
public fun new(
    dao_id: ID,
    initial_lines: vector<String>,
    initial_difficulties: vector<u64>,
    ctx: &mut TxContext
): OperatingAgreement {
    assert!(initial_lines.length() == initial_difficulties.length(), EIncorrectLengths);
    
    let mut agreement = OperatingAgreement {
        id: object::new(ctx),
        dao_id,
        head: option::none(),
        tail: option::none(),
    };
    
    // Initialize with the provided lines
    let mut i = 0;
    let mut prev_id: Option<ID> = option::none();
    
    assert!(initial_lines.length() <= MAX_LINES_PER_AGREEMENT, ETooManyLines);
    
    while (i < initial_lines.length()) {
        let text = *initial_lines.borrow(i);
        let difficulty = *initial_difficulties.borrow(i);
        let line_uid = object::new(ctx);
        let line_id = object::uid_to_inner(&line_uid);
        
        let line = AgreementLine {
            text,
            difficulty,
            prev: prev_id,
            next: option::none(),
        };
        
        // Store line as dynamic field on the agreement
        df::add(&mut agreement.id, LineKey { id: line_id }, line);
        
        // Update previous line's next pointer
        if (prev_id.is_some()) {
            let prev_line = df::borrow_mut<LineKey, AgreementLine>(
                &mut agreement.id, 
                LineKey { id: *prev_id.borrow() }
            );
            prev_line.next = option::some(line_id);
        } else {
            // This is the first line
            agreement.head = option::some(line_id);
        };
        
        prev_id = option::some(line_id);
        object::delete(line_uid);
        i = i + 1;
    };
    
    // Set tail to the last line
    if (prev_id.is_some()) {
        agreement.tail = prev_id;
    };
    
    agreement
}

// === Execution Functions (Called by action_dispatcher) ===

/// Execute an update line action
public fun execute_update_line<IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
    agreement: &mut OperatingAgreement,
    witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let action: &UpdateLineAction = executable.next_action(witness);
    let (line_id, new_text) = get_update_line_params(action);
    
    update_line_internal(agreement, line_id, new_text, clock);
}

/// Execute an insert line after action
public fun execute_insert_line_after<IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
    agreement: &mut OperatingAgreement,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action: &InsertLineAfterAction = executable.next_action(witness);
    let (prev_line_id, text, difficulty) = get_insert_line_after_params(action);
    
    insert_line_after_internal(agreement, prev_line_id, text, difficulty, clock, ctx);
}

/// Execute an insert line at beginning action
public fun execute_insert_line_at_beginning<IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
    agreement: &mut OperatingAgreement,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action: &InsertLineAtBeginningAction = executable.next_action(witness);
    let (text, difficulty) = get_insert_line_at_beginning_params(action);
    
    insert_line_at_beginning_internal(agreement, text, difficulty, clock, ctx);
}

/// Execute a remove line action
public fun execute_remove_line<IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
    agreement: &mut OperatingAgreement,
    witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let action: &RemoveLineAction = executable.next_action(witness);
    let line_id = get_remove_line_id(action);
    
    remove_line_internal(agreement, line_id, clock);
}

/// Execute a batch operating agreement action
public fun execute_batch_operating_agreement<IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
    agreement: &mut OperatingAgreement,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action: &BatchOperatingAgreementAction = executable.next_action(witness);
    let actions = get_batch_actions(action);
    
    // Process each action in the batch
    let mut i = 0;
    while (i < actions.length()) {
        let act = actions.borrow(i);
        let (action_type, line_id_opt, text_opt, difficulty_opt) = get_operating_agreement_action_params(act);
        
        if (action_type == action_update()) {
            assert!(line_id_opt.is_some() && text_opt.is_some(), EInvalidActionType);
            update_line_internal(agreement, *line_id_opt.borrow(), *text_opt.borrow(), clock);
        } else if (action_type == action_insert_after()) {
            assert!(line_id_opt.is_some() && text_opt.is_some() && difficulty_opt.is_some(), EInvalidActionType);
            insert_line_after_internal(
                agreement, 
                *line_id_opt.borrow(), 
                *text_opt.borrow(), 
                *difficulty_opt.borrow(), 
                clock, 
                ctx
            );
        } else if (action_type == action_insert_at_beginning()) {
            assert!(text_opt.is_some() && difficulty_opt.is_some(), EInvalidActionType);
            insert_line_at_beginning_internal(
                agreement, 
                *text_opt.borrow(), 
                *difficulty_opt.borrow(), 
                clock, 
                ctx
            );
        } else if (action_type == action_remove()) {
            assert!(line_id_opt.is_some(), EInvalidActionType);
            remove_line_internal(agreement, *line_id_opt.borrow(), clock);
        } else {
            abort EInvalidActionType
        };
        
        i = i + 1;
    };
    
    // Emit the full state after batch update
    emit_current_state_event(agreement, clock);
}

// === Internal Functions ===

fun update_line_internal(
    agreement: &mut OperatingAgreement,
    line_id: ID,
    new_text: String,
    clock: &Clock,
) {
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: line_id }), ELineNotFound);
    let line = df::borrow_mut<LineKey, AgreementLine>(&mut agreement.id, LineKey { id: line_id });
    line.text = new_text;
    
    event::emit(LineUpdated {
        dao_id: agreement.dao_id,
        line_id,
        new_text,
        timestamp_ms: clock::timestamp_ms(clock),
    });
}

fun insert_line_after_internal(
    agreement: &mut OperatingAgreement,
    prev_line_id: ID,
    new_text: String,
    new_difficulty: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: prev_line_id }), ELineNotFound);
    
    let current_line_count = get_all_line_ids_ordered(agreement).length();
    assert!(current_line_count < MAX_LINES_PER_AGREEMENT, ETooManyLines);
    
    let line_uid = object::new(ctx);
    let new_line_id = object::uid_to_inner(&line_uid);
    
    // Get the next pointer from the previous line
    let prev_line_next;
    {
        let prev_line = df::borrow<LineKey, AgreementLine>(&agreement.id, LineKey { id: prev_line_id });
        prev_line_next = prev_line.next;
    };
    
    let new_line = AgreementLine {
        text: new_text,
        difficulty: new_difficulty,
        prev: option::some(prev_line_id),
        next: prev_line_next,
    };
    
    // Update the next line's prev pointer if it exists
    if (prev_line_next.is_some()) {
        let next_line_id = *prev_line_next.borrow();
        let next_line = df::borrow_mut<LineKey, AgreementLine>(&mut agreement.id, LineKey { id: next_line_id });
        next_line.prev = option::some(new_line_id);
    };
    
    // Update the previous line's next pointer
    let prev_line = df::borrow_mut<LineKey, AgreementLine>(&mut agreement.id, LineKey { id: prev_line_id });
    prev_line.next = option::some(new_line_id);
    
    // If we inserted after the tail, update tail
    if (agreement.tail.is_some() && *agreement.tail.borrow() == prev_line_id) {
        agreement.tail = option::some(new_line_id);
    };
    
    df::add(&mut agreement.id, LineKey { id: new_line_id }, new_line);
    object::delete(line_uid);
    
    event::emit(LineInserted {
        dao_id: agreement.dao_id,
        line_id: new_line_id,
        text: new_text,
        difficulty: new_difficulty,
        position_after: option::some(prev_line_id),
        timestamp_ms: clock::timestamp_ms(clock),
    });
    
    new_line_id
}

fun insert_line_at_beginning_internal(
    agreement: &mut OperatingAgreement,
    new_text: String,
    new_difficulty: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let current_line_count = get_all_line_ids_ordered(agreement).length();
    assert!(current_line_count < MAX_LINES_PER_AGREEMENT, ETooManyLines);
    
    let line_uid = object::new(ctx);
    let new_line_id = object::uid_to_inner(&line_uid);
    
    let new_line = AgreementLine {
        text: new_text,
        difficulty: new_difficulty,
        prev: option::none(),
        next: agreement.head,
    };
    
    // Update the current head's prev pointer if it exists
    if (agreement.head.is_some()) {
        let current_head_id = *agreement.head.borrow();
        let current_head = df::borrow_mut<LineKey, AgreementLine>(&mut agreement.id, LineKey { id: current_head_id });
        current_head.prev = option::some(new_line_id);
    } else {
        // This is the first line, so it's also the tail
        agreement.tail = option::some(new_line_id);
    };
    
    agreement.head = option::some(new_line_id);
    df::add(&mut agreement.id, LineKey { id: new_line_id }, new_line);
    object::delete(line_uid);
    
    event::emit(LineInserted {
        dao_id: agreement.dao_id,
        line_id: new_line_id,
        text: new_text,
        difficulty: new_difficulty,
        position_after: option::none(),
        timestamp_ms: clock::timestamp_ms(clock),
    });
    
    new_line_id
}

fun remove_line_internal(
    agreement: &mut OperatingAgreement,
    line_id: ID,
    clock: &Clock,
) {
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: line_id }), ELineNotFound);
    let line_to_remove = df::remove<LineKey, AgreementLine>(&mut agreement.id, LineKey { id: line_id });
    
    // Update the previous line's next pointer
    if (line_to_remove.prev.is_some()) {
        let prev_id = *line_to_remove.prev.borrow();
        let prev_line = df::borrow_mut<LineKey, AgreementLine>(&mut agreement.id, LineKey { id: prev_id });
        prev_line.next = line_to_remove.next;
    } else {
        // This was the head
        agreement.head = line_to_remove.next;
    };
    
    // Update the next line's prev pointer
    if (line_to_remove.next.is_some()) {
        let next_id = *line_to_remove.next.borrow();
        let next_line = df::borrow_mut<LineKey, AgreementLine>(&mut agreement.id, LineKey { id: next_id });
        next_line.prev = line_to_remove.prev;
    } else {
        // This was the tail
        agreement.tail = line_to_remove.prev;
    };
    
    let AgreementLine { text: _, difficulty: _, prev: _, next: _ } = line_to_remove;
    
    event::emit(LineRemoved {
        dao_id: agreement.dao_id,
        line_id,
        timestamp_ms: clock::timestamp_ms(clock),
    });
}

// === View Functions ===

/// Get the difficulty for a specific line
public fun get_difficulty(agreement: &OperatingAgreement, line_id: ID): u64 {
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: line_id }), ELineNotFound);
    df::borrow<LineKey, AgreementLine>(&agreement.id, LineKey { id: line_id }).difficulty
}

/// Get the text for a specific line
public fun get_line_text(agreement: &OperatingAgreement, line_id: ID): String {
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: line_id }), ELineNotFound);
    df::borrow<LineKey, AgreementLine>(&agreement.id, LineKey { id: line_id }).text
}

/// Get all line IDs in order
public fun get_all_line_ids_ordered(agreement: &OperatingAgreement): vector<ID> {
    let mut lines = vector[];
    let mut current_id_opt = agreement.head;
    let mut iterations = 0;
    
    while (current_id_opt.is_some() && iterations < MAX_TRAVERSAL_LIMIT) {
        let current_id = *current_id_opt.borrow();
        lines.push_back(current_id);
        let current_line = df::borrow<LineKey, AgreementLine>(&agreement.id, LineKey { id: current_id });
        current_id_opt = current_line.next;
        iterations = iterations + 1;
    };
    
    assert!(iterations < MAX_TRAVERSAL_LIMIT, ETooManyLines);
    lines
}

/// Read and emit the full operating agreement
public entry fun read_agreement(agreement: &OperatingAgreement, clock: &Clock) {
    emit_current_state_event(agreement, clock);
}

/// Emit the current state of the agreement
public(package) fun emit_current_state_event(agreement: &OperatingAgreement, clock: &Clock) {
    let ordered_ids = get_all_line_ids_ordered(agreement);
    
    let mut texts = vector[];
    let mut difficulties = vector[];
    
    let mut i = 0;
    while (i < ordered_ids.length()) {
        let line_id = *ordered_ids.borrow(i);
        let line = df::borrow<LineKey, AgreementLine>(&agreement.id, LineKey { id: line_id });
        texts.push_back(line.text);
        difficulties.push_back(line.difficulty);
        i = i + 1;
    };
    
    event::emit(AgreementRead {
        dao_id: agreement.dao_id,
        line_ids: ordered_ids,
        texts,
        difficulties,
        timestamp_ms: clock::timestamp_ms(clock),
    });
}