/// Operating agreement actions for futarchy DAOs
/// This module defines action structs and execution logic for operating agreement changes
module futarchy_specialized_actions::operating_agreement_actions;

// === Imports ===
use std::{
    string::String,
    option::{Self, Option},
};
use sui::{
    object::ID,
    clock::Clock,
};
use account_protocol::{
    account::{Self, Account},
    executable::Executable,
    intents::{Intent, Expired},
    version_witness::VersionWitness,
};
use futarchy_core::futarchy_config::FutarchyConfig;

// === Errors ===
const EInvalidLineId: u64 = 1;
const EEmptyText: u64 = 2;
const EInvalidDifficulty: u64 = 3;
const EInvalidActionType: u64 = 4;

// === Constants ===
const ACTION_UPDATE: u8 = 0;
const ACTION_INSERT_AFTER: u8 = 1;
const ACTION_INSERT_AT_BEGINNING: u8 = 2;
const ACTION_REMOVE: u8 = 3;

// === Action Structs ===

/// Create a new (empty) Operating Agreement and store it in the Account
/// Lines can be inserted subsequently via Insert* actions.
public struct CreateOperatingAgreementAction has store {
    /// Optional policy flags to set immediately (defaults are true in OA::new)
    allow_insert: bool,
    allow_remove: bool,
}

/// Represents a single atomic change to the operating agreement
/// NOTE: This is used as part of BatchOperatingAgreementAction for batch operations.
/// Individual actions (UpdateLineAction, InsertLineAfterAction, etc.) are handled
/// directly in the dispatcher. This wrapper is only used within batch operations.
public struct OperatingAgreementAction has store, drop {
    action_type: u8, // 0 for Update, 1 for Insert After, 2 for Insert At Beginning, 3 for Remove
    // Only fields relevant to the action_type will be populated
    line_id: Option<ID>, // Used for Update, Remove, and as the *previous* line for Insert After
    text: Option<String>, // Used for Update and Insert operations
    difficulty: Option<u64>, // Used for Insert operations
}

/// Action to update a line in the operating agreement
public struct UpdateLineAction has store {
    line_id: ID,
    new_text: String,
}

/// Action to insert a line after another line
public struct InsertLineAfterAction has store {
    prev_line_id: ID,
    text: String,
    difficulty: u64,
}

/// Action to insert a line at the beginning
public struct InsertLineAtBeginningAction has store {
    text: String,
    difficulty: u64,
}

/// Action to remove a line
public struct RemoveLineAction has store {
    line_id: ID,
}

/// Action to set a line as immutable (one-way lock)
public struct SetLineImmutableAction has store {
    line_id: ID,
}

/// Action to control whether insertions are allowed (one-way lock)
public struct SetInsertAllowedAction has store {
    allowed: bool,
}

/// Action to control whether removals are allowed (one-way lock)
public struct SetRemoveAllowedAction has store {
    allowed: bool,
}

/// Batch action for multiple operating agreement changes
public struct BatchOperatingAgreementAction has store {
    batch_id: ID,  // Unique ID for this batch
    actions: vector<OperatingAgreementAction>,
}

// === Execution Functions ===
// Note: These do_* functions are not used. The action_dispatcher directly calls
// operating_agreement module functions. Keeping struct definitions only.

// === Cleanup Functions ===

/// Delete a create OA action from an expired intent
public fun delete_create_operating_agreement(expired: &mut Expired) {
    let CreateOperatingAgreementAction { allow_insert: _, allow_remove: _ } = expired.remove_action();
}

/// Delete an update line action from an expired intent
public fun delete_update_line(expired: &mut Expired) {
    let UpdateLineAction { line_id: _, new_text: _ } = expired.remove_action();
}

/// Delete an insert line after action from an expired intent
public fun delete_insert_line_after(expired: &mut Expired) {
    let InsertLineAfterAction { prev_line_id: _, text: _, difficulty: _ } = expired.remove_action();
}

/// Delete an insert line at beginning action from an expired intent
public fun delete_insert_line_at_beginning(expired: &mut Expired) {
    let InsertLineAtBeginningAction { text: _, difficulty: _ } = expired.remove_action();
}

/// Delete a remove line action from an expired intent
public fun delete_remove_line(expired: &mut Expired) {
    let RemoveLineAction { line_id: _ } = expired.remove_action();
}

/// Delete a set line immutable action from an expired intent
public fun delete_set_line_immutable(expired: &mut Expired) {
    let SetLineImmutableAction { line_id: _ } = expired.remove_action();
}

/// Delete a set insert allowed action from an expired intent
public fun delete_set_insert_allowed(expired: &mut Expired) {
    let SetInsertAllowedAction { allowed: _ } = expired.remove_action();
}

/// Delete a set remove allowed action from an expired intent
public fun delete_set_remove_allowed(expired: &mut Expired) {
    let SetRemoveAllowedAction { allowed: _ } = expired.remove_action();
}

/// Delete a batch operating agreement action from an expired intent
public fun delete_batch_operating_agreement(expired: &mut Expired) {
    let BatchOperatingAgreementAction { batch_id: _, actions: _ } = expired.remove_action();
}

/// Delete an operating agreement action from an expired intent
public fun delete_operating_agreement_action(expired: &mut Expired) {
    let OperatingAgreementAction { action_type: _, line_id: _, text: _, difficulty: _ } = expired.remove_action();
}

// === Intent Helper Functions ===

/// Create a new update line action for intents
public fun new_update_line<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    line_id: ID,
    new_text: String,
    intent_witness: IW,
) {
    let action = new_update_line_action(line_id, new_text);
    intent.add_action(action, intent_witness);
}

/// Create a new insert line after action for intents
public fun new_insert_line_after<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    prev_line_id: ID,
    text: String,
    difficulty: u64,
    intent_witness: IW,
) {
    let action = new_insert_line_after_action(prev_line_id, text, difficulty);
    intent.add_action(action, intent_witness);
}

/// Create a new insert line at beginning action for intents
public fun new_insert_line_at_beginning<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    text: String,
    difficulty: u64,
    intent_witness: IW,
) {
    let action = new_insert_line_at_beginning_action(text, difficulty);
    intent.add_action(action, intent_witness);
}

/// Create a new remove line action for intents
public fun new_remove_line<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    line_id: ID,
    intent_witness: IW,
) {
    let action = new_remove_line_action(line_id);
    intent.add_action(action, intent_witness);
}

/// Create a new batch operating agreement action for intents
public fun new_batch_operating_agreement<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    batch_id: ID,
    actions: vector<OperatingAgreementAction>,
    intent_witness: IW,
) {
    let action = new_batch_operating_agreement_action(batch_id, actions);
    intent.add_action(action, intent_witness);
}

// === Helper Functions ===

/// Get the batch ID from a BatchOperatingAgreementAction
public fun get_batch_id(batch: &BatchOperatingAgreementAction): ID {
    batch.batch_id
}

/// Create a new create OA action
public fun new_create_operating_agreement_action(
    allow_insert: bool,
    allow_remove: bool
): CreateOperatingAgreementAction {
    CreateOperatingAgreementAction { allow_insert, allow_remove }
}

/// Create a new update line action
public fun new_update_line_action(line_id: ID, new_text: String): UpdateLineAction {
    assert!(new_text.length() > 0, EEmptyText);
    UpdateLineAction { line_id, new_text }
}

/// Create a new insert line after action
public fun new_insert_line_after_action(
    prev_line_id: ID,
    text: String,
    difficulty: u64,
): InsertLineAfterAction {
    assert!(text.length() > 0, EEmptyText);
    assert!(difficulty > 0, EInvalidDifficulty);
    InsertLineAfterAction { prev_line_id, text, difficulty }
}

/// Create a new insert line at beginning action
public fun new_insert_line_at_beginning_action(
    text: String,
    difficulty: u64,
): InsertLineAtBeginningAction {
    assert!(text.length() > 0, EEmptyText);
    assert!(difficulty > 0, EInvalidDifficulty);
    InsertLineAtBeginningAction { text, difficulty }
}

/// Create a new remove line action
public fun new_remove_line_action(line_id: ID): RemoveLineAction {
    RemoveLineAction { line_id }
}

/// Create a new set line immutable action
public fun new_set_line_immutable_action(line_id: ID): SetLineImmutableAction {
    SetLineImmutableAction { line_id }
}

/// Create a new set insert allowed action
public fun new_set_insert_allowed_action(allowed: bool): SetInsertAllowedAction {
    SetInsertAllowedAction { allowed }
}

/// Create a new set remove allowed action
public fun new_set_remove_allowed_action(allowed: bool): SetRemoveAllowedAction {
    SetRemoveAllowedAction { allowed }
}

/// Create a new batch operating agreement action
public fun new_batch_operating_agreement_action(
    batch_id: ID,
    actions: vector<OperatingAgreementAction>
): BatchOperatingAgreementAction {
    BatchOperatingAgreementAction { batch_id, actions }
}

/// Create a new operating agreement action (flexible type)
public fun new_operating_agreement_action(
    action_type: u8,
    line_id: Option<ID>,
    text: Option<String>,
    difficulty: Option<u64>,
): OperatingAgreementAction {
    assert!(action_type <= ACTION_REMOVE, EInvalidActionType);
    
    // Validate based on action type
    if (action_type == ACTION_UPDATE) {
        assert!(line_id.is_some(), EInvalidLineId);
        assert!(text.is_some() && text.borrow().length() > 0, EEmptyText);
    } else if (action_type == ACTION_INSERT_AFTER) {
        assert!(line_id.is_some(), EInvalidLineId);
        assert!(text.is_some() && text.borrow().length() > 0, EEmptyText);
        assert!(difficulty.is_some() && *difficulty.borrow() > 0, EInvalidDifficulty);
    } else if (action_type == ACTION_INSERT_AT_BEGINNING) {
        assert!(text.is_some() && text.borrow().length() > 0, EEmptyText);
        assert!(difficulty.is_some() && *difficulty.borrow() > 0, EInvalidDifficulty);
    } else if (action_type == ACTION_REMOVE) {
        assert!(line_id.is_some(), EInvalidLineId);
    };
    
    OperatingAgreementAction {
        action_type,
        line_id,
        text,
        difficulty,
    }
}

/// Create a new update action using the flexible format
public fun new_update_action(line_id: ID, new_text: String): OperatingAgreementAction {
    new_operating_agreement_action(
        ACTION_UPDATE,
        option::some(line_id),
        option::some(new_text),
        option::none(),
    )
}

/// Create a new insert after action using the flexible format
public fun new_insert_after_action(prev_line_id: ID, text: String, difficulty: u64): OperatingAgreementAction {
    new_operating_agreement_action(
        ACTION_INSERT_AFTER,
        option::some(prev_line_id),
        option::some(text),
        option::some(difficulty),
    )
}

/// Create a new insert at beginning action using the flexible format
public fun new_insert_at_beginning_action(text: String, difficulty: u64): OperatingAgreementAction {
    new_operating_agreement_action(
        ACTION_INSERT_AT_BEGINNING,
        option::none(),
        option::some(text),
        option::some(difficulty),
    )
}

/// Create a new remove action using the flexible format
public fun new_remove_action(line_id: ID): OperatingAgreementAction {
    new_operating_agreement_action(
        ACTION_REMOVE,
        option::some(line_id),
        option::none(),
        option::none(),
    )
}

// === Getter Functions ===

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

// === Internal Functions ===

/// Validate an operating agreement action
fun validate_operating_agreement_action(action: &OperatingAgreementAction) {
    assert!(action.action_type <= ACTION_REMOVE, EInvalidActionType);
    
    if (action.action_type == ACTION_UPDATE) {
        assert!(action.line_id.is_some(), EInvalidLineId);
        assert!(action.text.is_some() && action.text.borrow().length() > 0, EEmptyText);
    } else if (action.action_type == ACTION_INSERT_AFTER) {
        assert!(action.line_id.is_some(), EInvalidLineId);
        assert!(action.text.is_some() && action.text.borrow().length() > 0, EEmptyText);
        assert!(action.difficulty.is_some() && *action.difficulty.borrow() > 0, EInvalidDifficulty);
    } else if (action.action_type == ACTION_INSERT_AT_BEGINNING) {
        assert!(action.text.is_some() && action.text.borrow().length() > 0, EEmptyText);
        assert!(action.difficulty.is_some() && *action.difficulty.borrow() > 0, EInvalidDifficulty);
    } else if (action.action_type == ACTION_REMOVE) {
        assert!(action.line_id.is_some(), EInvalidLineId);
    };
}