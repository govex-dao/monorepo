/// Operating agreement module for futarchy DAOs
/// This module manages the on-chain operating agreement with amendment capabilities
module futarchy_specialized_actions::operating_agreement;

// === Imports ===
use std::{
    string::String,
    option::{Self, Option},
    vector,
};
use sui::{
    clock::{Self, Clock},
    event,
    dynamic_field as df,
    object::{Self, ID, UID},
    tx_context::{Self, TxContext},
};
use account_protocol::{
    account::{Self, Account},
    executable::Executable,
    version_witness::VersionWitness,
};
use futarchy_core::version;
use futarchy_multisig::policy_registry;

// === Type Keys for Dynamic Fields ===
/// Type key for storing the operating agreement in the Account
public struct AgreementKey has copy, drop, store {}

/// Constructor for AgreementKey
public fun new_agreement_key(): AgreementKey {
    AgreementKey {}
}

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
const ELineIsImmutable: u64 = 6;
const EInsertNotAllowed: u64 = 7;
const ERemoveNotAllowed: u64 = 8;
const ECannotReEnableInsert: u64 = 9;
const ECannotReEnableRemove: u64 = 10;
const EAlreadyImmutable: u64 = 11;
const EUnauthorizedCustodian: u64 = 12;
const ELineHasNoExpiry: u64 = 13;
const ELineNotExpired: u64 = 14;
const EInvalidTimeOrder: u64 = 15;
const EAgreementIsImmutable: u64 = 16;
const EAlreadyGloballyImmutable: u64 = 17;
const EInsertNotAllowedForTemporaryLine: u64 = 18;
const EExpiryTooFarInFuture: u64 = 19;
const EDuplicateLineText: u64 = 20;

// === Constants ===
const MAX_LINES_PER_AGREEMENT: u64 = 1000;
const MAX_TRAVERSAL_LIMIT: u64 = 1000;
// Maximum expiry time: 100 years in milliseconds
const MAX_EXPIRY_TIME_MS: u64 = 100 * 365 * 24 * 60 * 60 * 1000;

// Line type constants
const LINE_TYPE_PERMANENT: u8 = 0;
const LINE_TYPE_SUNSET: u8 = 1;     // Auto-deactivates after expiry
const LINE_TYPE_SUNRISE: u8 = 2;    // Activates after effective_from
const LINE_TYPE_TEMPORARY: u8 = 3;  // Active only between effective_from and expires_at

// === Structs ===

/// Individual line in the operating agreement
public struct AgreementLine has store, drop {
    text: String,
    /// Difficulty required to change this line (in basis points)
    difficulty: u64,
    /// Whether this line is immutable (one-way lock: false -> true only)
    immutable: bool,
    /// Previous line in the linked list
    prev: Option<ID>,
    /// Next line in the linked list
    next: Option<ID>,
    /// Type of time-based provision
    line_type: u8,
    /// Timestamp when line becomes inactive (milliseconds)
    expires_at: Option<u64>,
    /// Timestamp when line becomes active (milliseconds)
    effective_from: Option<u64>,
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
    /// Whether new lines can be inserted (one-way lock: true -> false only)
    allow_insert: bool,
    /// Whether lines can be removed (one-way lock: true -> false only)
    allow_remove: bool,
    /// Number of lines in the agreement for O(1) counting
    line_count: u64,
    /// Global immutable flag - when true, entire agreement is frozen (one-way lock: false -> true only)
    immutable: bool,
}

// === Action Structs (moved from operating_agreement_actions to break circular dependency) ===

/// Create a new operating agreement for the DAO
public struct CreateOperatingAgreementAction has store, drop, copy {
    allow_insert: bool,
    allow_remove: bool,
}

/// Represents a single atomic change to the operating agreement
/// NOTE: This is used as part of BatchOperatingAgreementAction for batch operations.
/// Individual actions (UpdateLineAction, InsertLineAfterAction, etc.) are handled
/// directly by PTB calls. This wrapper is only used within batch operations.
public struct OperatingAgreementAction has store, drop, copy {
    action_type: u8, // 0 for Update, 1 for Insert After, 2 for Insert At Beginning, 3 for Remove
    // Only fields relevant to the action_type will be populated
    line_id: Option<ID>, // Used for Update, Remove, and as the *previous* line for Insert After
    text: Option<String>, // Used for Update and Insert operations
    difficulty: Option<u64>, // Used for Insert operations
}

/// Action to update a line in the operating agreement
public struct UpdateLineAction has store, drop, copy {
    line_id: ID,
    new_text: String,
}

/// Action to insert a line after another line
public struct InsertLineAfterAction has store, drop, copy {
    prev_line_id: ID,
    text: String,
    difficulty: u64,
}

/// Action to insert a line at the beginning
public struct InsertLineAtBeginningAction has store, drop, copy {
    text: String,
    difficulty: u64,
}

/// Action to remove a line
public struct RemoveLineAction has store, drop, copy {
    line_id: ID,
}

/// Action to set a line as immutable (one-way lock)
public struct SetLineImmutableAction has store, drop, copy {
    line_id: ID,
}

/// Action to control whether insertions are allowed (one-way lock)
public struct SetInsertAllowedAction has store, drop, copy {
    allowed: bool,
}

/// Action to control whether removals are allowed (one-way lock)
public struct SetRemoveAllowedAction has store, drop, copy {
    allowed: bool,
}

/// Action to set the entire operating agreement as globally immutable (one-way lock)
/// This is the ultimate lock - once set, NO changes can be made to the agreement
public struct SetGlobalImmutableAction has store, drop, copy {
    // No fields needed - this is a one-way operation to true
}

/// Batch action for multiple operating agreement changes
public struct BatchOperatingAgreementAction has store, drop, copy {
    batch_id: ID,  // Unique ID for this batch
    actions: vector<OperatingAgreementAction>,
}

// === Action Type Constants (moved from operating_agreement_actions) ===
const ACTION_UPDATE: u8 = 0;
const ACTION_INSERT_AFTER: u8 = 1;
const ACTION_INSERT_AT_BEGINNING: u8 = 2;
const ACTION_REMOVE: u8 = 3;

// === Getter Functions for Action Structs (moved from operating_agreement_actions) ===

/// Get line ID and new text from UpdateLineAction
public fun get_update_line_params(action: &UpdateLineAction): (ID, String) {
    (action.line_id, action.new_text)
}

/// Get parameters from InsertLineAfterAction
public fun get_insert_line_after_params(action: &InsertLineAfterAction): (ID, String, u64) {
    (action.prev_line_id, action.text, action.difficulty)
}

/// Get parameters from InsertLineAtBeginningAction
public fun get_insert_line_at_beginning_params(action: &InsertLineAtBeginningAction): (String, u64) {
    (action.text, action.difficulty)
}

/// Get line ID from RemoveLineAction
public fun get_remove_line_id(action: &RemoveLineAction): ID {
    action.line_id
}

/// Get line ID from SetLineImmutableAction
public fun get_set_line_immutable_id(action: &SetLineImmutableAction): ID {
    action.line_id
}

/// Get allowed flag from SetInsertAllowedAction
public fun get_set_insert_allowed(action: &SetInsertAllowedAction): bool {
    action.allowed
}

/// Get allowed flag from SetRemoveAllowedAction
public fun get_set_remove_allowed(action: &SetRemoveAllowedAction): bool {
    action.allowed
}

/// Get confirmation that SetGlobalImmutableAction exists (no params to return)
public fun confirm_set_global_immutable(_action: &SetGlobalImmutableAction): bool {
    true
}

/// Get actions from BatchOperatingAgreementAction
public fun get_batch_actions(action: &BatchOperatingAgreementAction): &vector<OperatingAgreementAction> {
    &action.actions
}

/// Get parameters from OperatingAgreementAction
public fun get_operating_agreement_action_params(action: &OperatingAgreementAction): (
    u8,
    &Option<ID>,
    &Option<String>,
    &Option<u64>,
) {
    (action.action_type, &action.line_id, &action.text, &action.difficulty)
}

/// Get parameters from CreateOperatingAgreementAction
public fun get_create_operating_agreement_params(action: &CreateOperatingAgreementAction): (bool, bool) {
    (action.allow_insert, action.allow_remove)
}

/// Get action type constants for external use
public fun action_update(): u8 { ACTION_UPDATE }
public fun action_insert_after(): u8 { ACTION_INSERT_AFTER }
public fun action_insert_at_beginning(): u8 { ACTION_INSERT_AT_BEGINNING }
public fun action_remove(): u8 { ACTION_REMOVE }

// === Creation and Management Functions ===

/// Store the operating agreement in the Account using managed assets
public fun store_in_account<Config: store>(
    account: &mut Account<Config>,
    agreement: OperatingAgreement,
    version_witness: account_protocol::version_witness::VersionWitness,
) {
    account::add_managed_asset(account, AgreementKey {}, agreement, version_witness);
}

/// Get a mutable reference to the operating agreement from the Account
public fun get_agreement_mut<Config: store>(
    account: &mut Account<Config>,
    version_witness: account_protocol::version_witness::VersionWitness,
): &mut OperatingAgreement {
    account::borrow_managed_asset_mut(account, AgreementKey {}, version_witness)
}

/// Get a reference to the operating agreement from the Account
public fun get_agreement<Config: store>(
    account: &Account<Config>,
    version_witness: VersionWitness,
): &OperatingAgreement {
    account::borrow_managed_asset<Config, AgreementKey, OperatingAgreement>(account, AgreementKey {}, version_witness)
}

/// Check if an account has an operating agreement
public fun has_agreement<Config: store>(
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
    immutables: vector<bool>,
    allow_insert: bool,
    allow_remove: bool,
    global_immutable: bool,
    timestamp_ms: u64,
}

/// Enhanced event with time-based status
public struct AgreementReadWithStatus has copy, drop {
    dao_id: ID,
    line_ids: vector<ID>,
    texts: vector<String>,
    difficulties: vector<u64>,
    immutables: vector<bool>,
    active_statuses: vector<bool>,      // Whether each line is currently active
    line_types: vector<u8>,             // Type of each line
    expires_at: vector<Option<u64>>,    // Expiry times
    effective_from: vector<Option<u64>>, // Effective times
    allow_insert: bool,
    allow_remove: bool,
    global_immutable: bool,
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
    line_type: u8,
    expires_at: Option<u64>,
    effective_from: Option<u64>,
}

/// Emitted when a line is removed
public struct LineRemoved has copy, drop {
    dao_id: ID,
    line_id: ID,
    timestamp_ms: u64,
}

/// Emitted when a line's immutability status changes (one-way: false -> true only)
public struct LineImmutabilityChanged has copy, drop {
    dao_id: ID,
    line_id: ID,
    immutable: bool,
    timestamp_ms: u64,
}

/// Emitted when OA's insert permission changes (one-way: true -> false only)
public struct OAInsertAllowedChanged has copy, drop {
    dao_id: ID,
    allow_insert: bool,
    timestamp_ms: u64,
}

/// Emitted when OA's remove permission changes (one-way: true -> false only)  
public struct OARemoveAllowedChanged has copy, drop {
    dao_id: ID,
    allow_remove: bool,
    timestamp_ms: u64,
}

/// Emitted when OA becomes globally immutable (one-way: false -> true only)
public struct OAGlobalImmutabilityChanged has copy, drop {
    dao_id: ID,
    immutable: bool,
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
        allow_insert: true,  // Initially allow insertions
        allow_remove: true,  // Initially allow removals
        line_count: 0,
        immutable: false,  // Initially mutable
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
            immutable: false,  // Lines start as mutable
            prev: prev_id,
            next: option::none(),
            line_type: LINE_TYPE_PERMANENT,  // Default to permanent
            expires_at: option::none(),
            effective_from: option::none(),
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
        agreement.line_count = agreement.line_count + 1;
        i = i + 1;
    };
    
    // Set tail to the last line
    if (prev_id.is_some()) {
        agreement.tail = prev_id;
    };
    
    agreement
}

// === Execution Functions (Called by PTB) ===

/// Execute creation of a fresh OperatingAgreement and store it in the Account
/// This creates an empty OA (no lines), with the allow_insert/remove flags set as requested.
/// Abort if an agreement already exists.
public(package) fun execute_create_agreement<IW: drop, Config: store, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    if (has_agreement(account)) {
        abort EAgreementAlreadyExists
    };

    let action: &CreateOperatingAgreementAction = executable.next_action(witness);
    let (allow_insert, allow_remove) = get_create_operating_agreement_params(action);

    // Create an empty OA for this DAO ID
    let dao_id = object::id(account);
    let initial_lines: vector<String> = vector[];
    let initial_difficulties: vector<u64> = vector[];
    let mut agreement = new(dao_id, initial_lines, initial_difficulties, ctx);

    // Apply policy flags as requested
    set_insert_allowed(&mut agreement, allow_insert, clock);
    set_remove_allowed(&mut agreement, allow_remove, clock);

    // Store in account managed assets
    store_in_account(account, agreement, version::current());
}

/// Execute an update line action
public(package) fun execute_update_line<IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
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
public(package) fun execute_insert_line_after<IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
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
public(package) fun execute_insert_line_at_beginning<IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
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
public(package) fun execute_remove_line<IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
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
public(package) fun execute_batch_operating_agreement<IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
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

/// Execute a set line immutable action
public(package) fun execute_set_line_immutable<IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    agreement: &mut OperatingAgreement,
    witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let action: &SetLineImmutableAction = executable.next_action(witness);
    let line_id = get_set_line_immutable_id(action);
    set_line_immutable(agreement, line_id, clock);
}

/// Execute a set insert allowed action
public(package) fun execute_set_insert_allowed<IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    agreement: &mut OperatingAgreement,
    witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let action: &SetInsertAllowedAction = executable.next_action(witness);
    let allowed = get_set_insert_allowed(action);
    set_insert_allowed(agreement, allowed, clock);
}

/// Execute a set remove allowed action
public(package) fun execute_set_remove_allowed<IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    agreement: &mut OperatingAgreement,
    witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let action: &SetRemoveAllowedAction = executable.next_action(witness);
    let allowed = get_set_remove_allowed(action);
    set_remove_allowed(agreement, allowed, clock);
}

/// Execute a set global immutable action
/// WARNING: This is a permanent one-way operation that locks the entire agreement
public(package) fun execute_set_global_immutable<IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    agreement: &mut OperatingAgreement,
    witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let action: &SetGlobalImmutableAction = executable.next_action(witness);
    // Confirm the action exists (no params to extract)
    let _ = confirm_set_global_immutable(action);
    set_global_immutable(agreement, clock);
}

// === Internal Functions ===

fun update_line_internal(
    agreement: &mut OperatingAgreement,
    line_id: ID,
    new_text: String,
    clock: &Clock,
) {
    // Check if agreement is globally immutable
    assert!(!agreement.immutable, EAgreementIsImmutable);
    
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: line_id }), ELineNotFound);
    let line = df::borrow_mut<LineKey, AgreementLine>(&mut agreement.id, LineKey { id: line_id });
    
    // Check if line is immutable
    assert!(!line.immutable, ELineIsImmutable);
    
    line.text = new_text;
    
    event::emit(LineUpdated {
        dao_id: agreement.dao_id,
        line_id,
        new_text,
        timestamp_ms: clock.timestamp_ms(),
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
    // Check if agreement is globally immutable
    assert!(!agreement.immutable, EAgreementIsImmutable);
    
    // Check if insertions are allowed
    assert!(agreement.allow_insert, EInsertNotAllowed);
    
    // Check for duplicate text
    assert!(!has_duplicate_text(agreement, &new_text), EDuplicateLineText);
    
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: prev_line_id }), ELineNotFound);
    
    assert!(agreement.line_count < MAX_LINES_PER_AGREEMENT, ETooManyLines);
    
    // Get the next pointer from the previous line first (before creating UID)
    let prev_line_next = {
        let prev_line = df::borrow<LineKey, AgreementLine>(&agreement.id, LineKey { id: prev_line_id });
        prev_line.next
    };
    
    // Now create the UID after all validations
    let line_uid = object::new(ctx);
    let new_line_id = object::uid_to_inner(&line_uid);
    
    let new_line = AgreementLine {
        text: new_text,
        difficulty: new_difficulty,
        immutable: false,  // New lines start as mutable
        prev: option::some(prev_line_id),
        next: prev_line_next,
        line_type: LINE_TYPE_PERMANENT,  // Default to permanent
        expires_at: option::none(),
        effective_from: option::none(),
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
    agreement.line_count = agreement.line_count + 1;
    
    event::emit(LineInserted {
        dao_id: agreement.dao_id,
        line_id: new_line_id,
        text: new_text,
        difficulty: new_difficulty,
        position_after: option::some(prev_line_id),
        timestamp_ms: clock.timestamp_ms(),
        line_type: LINE_TYPE_PERMANENT,
        expires_at: option::none(),
        effective_from: option::none(),
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
    // Check if agreement is globally immutable
    assert!(!agreement.immutable, EAgreementIsImmutable);
    
    // Check if insertions are allowed
    assert!(agreement.allow_insert, EInsertNotAllowed);
    
    // Check for duplicate text
    assert!(!has_duplicate_text(agreement, &new_text), EDuplicateLineText);
    
    assert!(agreement.line_count < MAX_LINES_PER_AGREEMENT, ETooManyLines);
    
    // Create UID after all validations
    let line_uid = object::new(ctx);
    let new_line_id = object::uid_to_inner(&line_uid);
    
    let new_line = AgreementLine {
        text: new_text,
        difficulty: new_difficulty,
        immutable: false,  // New lines start as mutable
        prev: option::none(),
        next: agreement.head,
        line_type: LINE_TYPE_PERMANENT,  // Default to permanent
        expires_at: option::none(),
        effective_from: option::none(),
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
    agreement.line_count = agreement.line_count + 1;
    
    event::emit(LineInserted {
        dao_id: agreement.dao_id,
        line_id: new_line_id,
        text: new_text,
        difficulty: new_difficulty,
        position_after: option::none(),
        timestamp_ms: clock.timestamp_ms(),
        line_type: LINE_TYPE_PERMANENT,
        expires_at: option::none(),
        effective_from: option::none(),
    });
    
    new_line_id
}

/// Internal function to remove expired lines
/// NOTE: This function intentionally bypasses the immutability check because expired lines
/// must be removable for cleanup, regardless of their immutable status. This is by design:
/// - Expired lines are no longer active/valid parts of the agreement
/// - Allowing their removal prevents permanent storage bloat
/// - The expiry mechanism takes precedence over immutability for cleanup purposes
fun remove_expired_line_internal(
    agreement: &mut OperatingAgreement,
    line_id: ID,
    clock: &Clock,
) {
    // Note: allow_remove check is done by the caller
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: line_id }), ELineNotFound);
    
    // For expired lines, we don't check immutability - expiry overrides immutability
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
    
    let AgreementLine { 
        text: _, 
        difficulty: _, 
        immutable: _, 
        prev: _, 
        next: _,
        line_type: _,
        expires_at: _,
        effective_from: _,
    } = line_to_remove;
    agreement.line_count = agreement.line_count - 1;
    
    event::emit(LineRemoved {
        dao_id: agreement.dao_id,
        line_id,
        timestamp_ms: clock.timestamp_ms(),
    });
}

fun remove_line_internal(
    agreement: &mut OperatingAgreement,
    line_id: ID,
    clock: &Clock,
) {
    // Check if agreement is globally immutable
    assert!(!agreement.immutable, EAgreementIsImmutable);
    
    // Check if removals are allowed
    assert!(agreement.allow_remove, ERemoveNotAllowed);
    
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: line_id }), ELineNotFound);
    
    // Check if the line is immutable before removing
    let line_immutable = df::borrow<LineKey, AgreementLine>(&agreement.id, LineKey { id: line_id }).immutable;
    assert!(!line_immutable, ELineIsImmutable);
    
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
    
    let AgreementLine { 
        text: _, 
        difficulty: _, 
        immutable: _, 
        prev: _, 
        next: _,
        line_type: _,
        expires_at: _,
        effective_from: _,
    } = line_to_remove;
    agreement.line_count = agreement.line_count - 1;
    
    event::emit(LineRemoved {
        dao_id: agreement.dao_id,
        line_id,
        timestamp_ms: clock.timestamp_ms(),
    });
}

// === Immutability Control Functions ===

/// Set a line as immutable (one-way: can only go from false to true)
public fun set_line_immutable(
    agreement: &mut OperatingAgreement,
    line_id: ID,
    clock: &Clock,
) {
    // Check if agreement is globally immutable
    assert!(!agreement.immutable, EAgreementIsImmutable);
    
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: line_id }), ELineNotFound);
    
    let line = df::borrow_mut<LineKey, AgreementLine>(&mut agreement.id, LineKey { id: line_id });
    
    // One-way lock: can only go from false to true
    assert!(!line.immutable, EAlreadyImmutable);
    
    line.immutable = true;
    
    event::emit(LineImmutabilityChanged {
        dao_id: agreement.dao_id,
        line_id,
        immutable: true,
        timestamp_ms: clock.timestamp_ms(),
    });
}

/// Set whether insertions are allowed (one-way: can only go from true to false)
public fun set_insert_allowed(
    agreement: &mut OperatingAgreement,
    allowed: bool,
    clock: &Clock,
) {
    // Check if agreement is globally immutable
    assert!(!agreement.immutable, EAgreementIsImmutable);
    
    // One-way lock: can only go from true to false
    if (!allowed) {
        agreement.allow_insert = false;
    } else {
        assert!(agreement.allow_insert, ECannotReEnableInsert);
    };
    
    event::emit(OAInsertAllowedChanged {
        dao_id: agreement.dao_id,
        allow_insert: agreement.allow_insert,
        timestamp_ms: clock.timestamp_ms(),
    });
}

/// Set whether removals are allowed (one-way: can only go from true to false)
public fun set_remove_allowed(
    agreement: &mut OperatingAgreement,
    allowed: bool,
    clock: &Clock,
) {
    // Check if agreement is globally immutable
    assert!(!agreement.immutable, EAgreementIsImmutable);
    
    // One-way lock: can only go from true to false
    if (!allowed) {
        agreement.allow_remove = false;
    } else {
        assert!(agreement.allow_remove, ECannotReEnableRemove);
    };
    
    event::emit(OARemoveAllowedChanged {
        dao_id: agreement.dao_id,
        allow_remove: agreement.allow_remove,
        timestamp_ms: clock.timestamp_ms(),
    });
}

/// Set the entire agreement as globally immutable (one-way: can only go from false to true)
/// This is the ultimate lock - once set, NO changes can be made to the agreement
public fun set_global_immutable(
    agreement: &mut OperatingAgreement,
    clock: &Clock,
) {
    // One-way lock: can only go from false to true
    assert!(!agreement.immutable, EAlreadyGloballyImmutable);
    
    agreement.immutable = true;
    
    event::emit(OAGlobalImmutabilityChanged {
        dao_id: agreement.dao_id,
        immutable: true,
        timestamp_ms: clock.timestamp_ms(),
    });
}

// === Public Wrapper Functions ===

/// Public wrapper for updating a line
public fun update_line(
    agreement: &mut OperatingAgreement,
    line_id: ID,
    new_text: String,
    clock: &Clock,
) {
    update_line_internal(agreement, line_id, new_text, clock);
}

/// Public wrapper for inserting a line after another line, returns the new line ID
public fun insert_line_after(
    agreement: &mut OperatingAgreement,
    prev_line_id: ID,
    new_text: String,
    new_difficulty: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    insert_line_after_internal(agreement, prev_line_id, new_text, new_difficulty, clock, ctx)
}

/// Public wrapper for inserting a line at the beginning, returns the new line ID
public fun insert_line_at_beginning(
    agreement: &mut OperatingAgreement,
    new_text: String,
    new_difficulty: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    insert_line_at_beginning_internal(agreement, new_text, new_difficulty, clock, ctx)
}

/// Public wrapper for removing a line
public fun remove_line(
    agreement: &mut OperatingAgreement,
    line_id: ID,
    clock: &Clock,
) {
    remove_line_internal(agreement, line_id, clock);
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

/// Check if a specific line is immutable
public fun is_line_immutable(agreement: &OperatingAgreement, line_id: ID): bool {
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: line_id }), ELineNotFound);
    df::borrow<LineKey, AgreementLine>(&agreement.id, LineKey { id: line_id }).immutable
}

/// Check if insertions are allowed
public fun is_insert_allowed(agreement: &OperatingAgreement): bool {
    agreement.allow_insert
}

/// Check if removals are allowed
public fun is_remove_allowed(agreement: &OperatingAgreement): bool {
    agreement.allow_remove
}

/// Get OA policy flags in one call (allow_insert, allow_remove)
public fun get_oa_policy(agreement: &OperatingAgreement): (bool, bool) {
    (agreement.allow_insert, agreement.allow_remove)
}

/// Check if the agreement is globally immutable
public fun is_global_immutable(agreement: &OperatingAgreement): bool {
    agreement.immutable
}

/// Check if a line with the given text already exists in the agreement
fun has_duplicate_text(agreement: &OperatingAgreement, text: &String): bool {
    let mut current_id_opt = agreement.head;
    let mut iterations = 0;
    
    while (current_id_opt.is_some() && iterations < MAX_TRAVERSAL_LIMIT) {
        let current_id = *current_id_opt.borrow();
        let current_line = df::borrow<LineKey, AgreementLine>(&agreement.id, LineKey { id: current_id });
        if (&current_line.text == text) {
            return true
        };
        current_id_opt = current_line.next;
        iterations = iterations + 1;
    };
    
    false
}

/// Get all OA lock status in one call (allow_insert, allow_remove, global_immutable)
public fun get_oa_full_policy(agreement: &OperatingAgreement): (bool, bool, bool) {
    (agreement.allow_insert, agreement.allow_remove, agreement.immutable)
}

/// Get the number of lines in the agreement (O(1) operation)
public fun line_count(agreement: &OperatingAgreement): u64 {
    agreement.line_count
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
    emit_current_state_event_with_status(agreement, clock);
}

/// Apply a batch of OA actions directly (co-exec calls this after validation).
/// Note: caller must have already enforced any policy/authorization checks.
public(package) fun apply_actions(
    agreement: &mut OperatingAgreement,
    actions: &vector<OperatingAgreementAction>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut i = 0;
    while (i < actions.length()) {
        let act = actions.borrow(i);
        let (t, lid_opt, text_opt, diff_opt) = get_operating_agreement_action_params(act);
        if (t == action_update()) {
            assert!(lid_opt.is_some() && text_opt.is_some(), EInvalidActionType);
            update_line_internal(agreement, *lid_opt.borrow(), *text_opt.borrow(), clock);
        } else if (t == action_insert_after()) {
            assert!(lid_opt.is_some() && text_opt.is_some() && diff_opt.is_some(), EInvalidActionType);
            insert_line_after_internal(
                agreement,
                *lid_opt.borrow(),
                *text_opt.borrow(),
                *diff_opt.borrow(),
                clock,
                ctx
            );
        } else if (t == action_insert_at_beginning()) {
            assert!(text_opt.is_some() && diff_opt.is_some(), EInvalidActionType);
            insert_line_at_beginning_internal(
                agreement,
                *text_opt.borrow(),
                *diff_opt.borrow(),
                clock,
                ctx
            );
        } else if (t == action_remove()) {
            assert!(lid_opt.is_some(), EInvalidActionType);
            remove_line_internal(agreement, *lid_opt.borrow(), clock);
        } else {
            abort EInvalidActionType
        };
        i = i + 1;
    };
    emit_current_state_event(agreement, clock);
}

public(package) fun emit_current_state_event(agreement: &OperatingAgreement, clock: &Clock) {
    let ordered_ids = get_all_line_ids_ordered(agreement);
    
    let mut texts = vector[];
    let mut difficulties = vector[];
    let mut immutables = vector[];
    
    let mut i = 0;
    while (i < ordered_ids.length()) {
        let line_id = *ordered_ids.borrow(i);
        let line = df::borrow<LineKey, AgreementLine>(&agreement.id, LineKey { id: line_id });
        texts.push_back(line.text);
        difficulties.push_back(line.difficulty);
        immutables.push_back(line.immutable);
        i = i + 1;
    };
    
    event::emit(AgreementRead {
        dao_id: agreement.dao_id,
        line_ids: ordered_ids,
        texts,
        difficulties,
        immutables,
        allow_insert: agreement.allow_insert,
        allow_remove: agreement.allow_remove,
        global_immutable: agreement.immutable,
        timestamp_ms: clock.timestamp_ms(),
    });
}
// === Time-Based Line Functions ===

/// Check if a line is currently active based on time
/// NOTE: Immutability is separate from time-based activity. An immutable line
/// can still have a sunset date (becomes inactive but remains unchangeable)
public fun is_line_active(line: &AgreementLine, current_time_ms: u64): bool {
    // Check effective_from
    if (line.effective_from.is_some()) {
        if (current_time_ms < *line.effective_from.borrow()) {
            return false
        }
    };
    
    // Check expires_at
    if (line.expires_at.is_some()) {
        if (current_time_ms >= *line.expires_at.borrow()) {
            return false
        }
    };
    
    true
}

/// Public entry point for anyone to remove a specific expired line
/// This is a cleanup function that can be called by anyone to remove expired sunset lines
/// The line must actually be expired (expires_at < current_time) for this to succeed
/// 
/// IMPORTANT: While this function can remove "immutable" expired lines, this is intentional:
/// - Immutability prevents CHANGES to line content, not cleanup of expired lines
/// - Expired lines are no longer part of the active agreement
/// - This prevents permanent storage bloat from expired but immutable lines
/// 
/// Respects allow_remove: if removals are disabled globally, even expired lines cannot be removed
public entry fun remove_expired_line(
    agreement: &mut OperatingAgreement,
    line_id: ID,
    clock: &Clock,
) {
    // Check if removals are allowed - if not, even expired lines can't be removed
    assert!(agreement.allow_remove, ERemoveNotAllowed);
    
    // Check line exists
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: line_id }), ELineNotFound);
    
    // Get the line and check if it's expired
    let line = df::borrow<LineKey, AgreementLine>(&agreement.id, LineKey { id: line_id });
    let current_time = clock.timestamp_ms();
    
    // Line must have an expiry date and be past it
    assert!(line.expires_at.is_some(), ELineHasNoExpiry);
    assert!(current_time >= *line.expires_at.borrow(), ELineNotExpired);
    
    // For expired lines, we bypass the immutability check in remove_line_internal
    // by calling a special version that allows removing expired immutable lines
    remove_expired_line_internal(agreement, line_id, clock);
}

/// Insert a line with sunset provision (auto-deactivates after expiry)
/// The line can optionally be immutable - it will still sunset but cannot be changed before then
public fun insert_sunset_line_after(
    agreement: &mut OperatingAgreement,
    prev_line_id: ID,
    text: String,
    difficulty: u64,
    expires_at_ms: u64,
    immutable: bool,  // Can be immutable AND have sunset
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Check if agreement is globally immutable
    assert!(!agreement.immutable, EAgreementIsImmutable);
    assert!(agreement.allow_insert, EInsertNotAllowed);
    // Check for duplicate text
    assert!(!has_duplicate_text(agreement, &text), EDuplicateLineText);
    // Cannot add sunset lines if removals are disabled (since they can't be cleaned up)
    assert!(agreement.allow_remove, ERemoveNotAllowed);
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: prev_line_id }), ELineNotFound);
    assert!(agreement.line_count < MAX_LINES_PER_AGREEMENT, ETooManyLines);
    
    // Validate sunset time is in the future but not too far
    let now = clock.timestamp_ms();
    assert!(expires_at_ms > now, EInvalidTimeOrder);
    assert!(expires_at_ms <= now + MAX_EXPIRY_TIME_MS, EExpiryTooFarInFuture);
    
    // Get the next pointer from the previous line first (before creating UID)
    let prev_line_next = {
        let prev_line = df::borrow<LineKey, AgreementLine>(&agreement.id, LineKey { id: prev_line_id });
        prev_line.next
    };
    
    // Now create the UID after all validations
    let line_uid = object::new(ctx);
    let new_line_id = object::uid_to_inner(&line_uid);
    
    let new_line = AgreementLine {
        text,
        difficulty,
        immutable,  // Can be immutable with sunset
        prev: option::some(prev_line_id),
        next: prev_line_next,
        line_type: LINE_TYPE_SUNSET,
        expires_at: option::some(expires_at_ms),
        effective_from: option::none(),
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
    agreement.line_count = agreement.line_count + 1;
    
    event::emit(LineInserted {
        dao_id: agreement.dao_id,
        line_id: new_line_id,
        text,
        difficulty,
        position_after: option::some(prev_line_id),
        timestamp_ms: clock.timestamp_ms(),
        line_type: LINE_TYPE_SUNSET,
        expires_at: option::some(expires_at_ms),
        effective_from: option::none(),
    });
    
    new_line_id
}

/// Insert a line that becomes active only after `effective_from`
public fun insert_sunrise_line_after(
    agreement: &mut OperatingAgreement,
    prev_line_id: ID,
    text: String,
    difficulty: u64,
    effective_from_ms: u64,
    immutable: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Check if agreement is globally immutable
    assert!(!agreement.immutable, EAgreementIsImmutable);
    assert!(agreement.allow_insert, EInsertNotAllowed);
    // Check for duplicate text
    assert!(!has_duplicate_text(agreement, &text), EDuplicateLineText);
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: prev_line_id }), ELineNotFound);
    assert!(agreement.line_count < MAX_LINES_PER_AGREEMENT, ETooManyLines);

    // Get the next pointer from the previous line first (before creating UID)
    let prev_line_next = {
        let prev_line = df::borrow<LineKey, AgreementLine>(&agreement.id, LineKey { id: prev_line_id });
        prev_line.next
    };

    // Now create the UID after all validations
    let line_uid = object::new(ctx);
    let new_line_id = object::uid_to_inner(&line_uid);

    let new_line = AgreementLine {
        text,
        difficulty,
        immutable,
        prev: option::some(prev_line_id),
        next: prev_line_next,
        line_type: LINE_TYPE_SUNRISE,
        expires_at: option::none(),
        effective_from: option::some(effective_from_ms),
    };

    if (prev_line_next.is_some()) {
        let next_line_id = *prev_line_next.borrow();
        let next_line = df::borrow_mut<LineKey, AgreementLine>(&mut agreement.id, LineKey { id: next_line_id });
        next_line.prev = option::some(new_line_id);
    };
    
    let prev_line = df::borrow_mut<LineKey, AgreementLine>(&mut agreement.id, LineKey { id: prev_line_id });
    prev_line.next = option::some(new_line_id);
    
    if (agreement.tail.is_some() && *agreement.tail.borrow() == prev_line_id) {
        agreement.tail = option::some(new_line_id);
    };

    df::add(&mut agreement.id, LineKey { id: new_line_id }, new_line);
    object::delete(line_uid);
    agreement.line_count = agreement.line_count + 1;

    event::emit(LineInserted {
        dao_id: agreement.dao_id,
        line_id: new_line_id,
        text,
        difficulty,
        position_after: option::some(prev_line_id),
        timestamp_ms: clock.timestamp_ms(),
        line_type: LINE_TYPE_SUNRISE,
        expires_at: option::none(),
        effective_from: option::some(effective_from_ms),
    });

    new_line_id
}

/// Insert a line that is active only between [effective_from, expires_at)
public fun insert_temporary_line_after(
    agreement: &mut OperatingAgreement,
    prev_line_id: ID,
    text: String,
    difficulty: u64,
    effective_from_ms: u64,
    expires_at_ms: u64,
    immutable: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Check if agreement is globally immutable
    assert!(!agreement.immutable, EAgreementIsImmutable);
    assert!(agreement.allow_insert, EInsertNotAllowed);
    // Check for duplicate text
    assert!(!has_duplicate_text(agreement, &text), EDuplicateLineText);
    // Temporary lines need removal to be allowed for cleanup after expiry
    assert!(agreement.allow_remove, EInsertNotAllowedForTemporaryLine);
    assert!(df::exists_<LineKey>(&agreement.id, LineKey { id: prev_line_id }), ELineNotFound);
    assert!(agreement.line_count < MAX_LINES_PER_AGREEMENT, ETooManyLines);
    assert!(effective_from_ms < expires_at_ms, EInvalidTimeOrder);
    // Validate times are reasonable
    let now = clock.timestamp_ms();
    assert!(expires_at_ms <= now + MAX_EXPIRY_TIME_MS, EExpiryTooFarInFuture);

    // Get the next pointer from the previous line first (before creating UID)
    let prev_line_next = {
        let prev_line = df::borrow<LineKey, AgreementLine>(&agreement.id, LineKey { id: prev_line_id });
        prev_line.next
    };

    // Now create the UID after all validations
    let line_uid = object::new(ctx);
    let new_line_id = object::uid_to_inner(&line_uid);

    let new_line = AgreementLine {
        text,
        difficulty,
        immutable,
        prev: option::some(prev_line_id),
        next: prev_line_next,
        line_type: LINE_TYPE_TEMPORARY,
        expires_at: option::some(expires_at_ms),
        effective_from: option::some(effective_from_ms),
    };

    if (prev_line_next.is_some()) {
        let next_line_id = *prev_line_next.borrow();
        let next_line = df::borrow_mut<LineKey, AgreementLine>(&mut agreement.id, LineKey { id: next_line_id });
        next_line.prev = option::some(new_line_id);
    };
    
    let prev_line = df::borrow_mut<LineKey, AgreementLine>(&mut agreement.id, LineKey { id: prev_line_id });
    prev_line.next = option::some(new_line_id);
    
    if (agreement.tail.is_some() && *agreement.tail.borrow() == prev_line_id) {
        agreement.tail = option::some(new_line_id);
    };

    df::add(&mut agreement.id, LineKey { id: new_line_id }, new_line);
    object::delete(line_uid);
    agreement.line_count = agreement.line_count + 1;

    event::emit(LineInserted {
        dao_id: agreement.dao_id,
        line_id: new_line_id,
        text,
        difficulty,
        position_after: option::some(prev_line_id),
        timestamp_ms: clock.timestamp_ms(),
        line_type: LINE_TYPE_TEMPORARY,
        expires_at: option::some(expires_at_ms),
        effective_from: option::some(effective_from_ms),
    });

    new_line_id
}

/// Emit the full state including activity and schedule
public fun emit_current_state_event_with_status(agreement: &OperatingAgreement, clock: &Clock) {
    let ordered_ids = get_all_line_ids_ordered(agreement);
    let now = clock.timestamp_ms();

    let mut texts = vector[];
    let mut difficulties = vector[];
    let mut immutables = vector[];
    let mut active_statuses = vector[];
    let mut line_types = vector[];
    let mut expires_vec = vector[];
    let mut effective_vec = vector[];

    let mut i = 0;
    while (i < ordered_ids.length()) {
        let line_id = *ordered_ids.borrow(i);
        let line = df::borrow<LineKey, AgreementLine>(&agreement.id, LineKey { id: line_id });
        texts.push_back(line.text);
        difficulties.push_back(line.difficulty);
        immutables.push_back(line.immutable);
        active_statuses.push_back(is_line_active(line, now));
        line_types.push_back(line.line_type);
        expires_vec.push_back(line.expires_at);
        effective_vec.push_back(line.effective_from);
        i = i + 1;
    };

    event::emit(AgreementReadWithStatus {
        dao_id: agreement.dao_id,
        line_ids: ordered_ids,
        texts,
        difficulties,
        immutables,
        active_statuses,
        line_types,
        expires_at: expires_vec,
        effective_from: effective_vec,
        allow_insert: agreement.allow_insert,
        allow_remove: agreement.allow_remove,
        global_immutable: agreement.immutable,
        timestamp_ms: now,
    });
}

