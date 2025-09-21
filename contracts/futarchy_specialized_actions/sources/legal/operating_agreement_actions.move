/// Operating agreement actions for futarchy DAOs with composable hot potato support
/// This module defines action structs and execution logic for operating agreement changes
/// Uses hot potato pattern for passing IDs between actions in atomic transactions
module futarchy_specialized_actions::operating_agreement_actions;

// === Imports ===
use std::{
    string::String,
    option::{Self, Option},
    vector,
    type_name,
};
use sui::{
    object::{Self, ID},
    clock::Clock,
    tx_context::TxContext,
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents::{Self as protocol_intents, Intent, Expired, ActionSpec},
    version_witness::VersionWitness,
    bcs_validation,
    action_validation,
};
use sui::bcs::{Self, BCS};
use futarchy_core::{
    futarchy_config::FutarchyConfig,
    version,
};
use futarchy_specialized_actions::operating_agreement::{Self, OperatingAgreement, AgreementKey,
    CreateOperatingAgreementAction,
    OperatingAgreementAction,
    UpdateLineAction,
    InsertLineAfterAction,
    InsertLineAtBeginningAction,
    RemoveLineAction,
    SetLineImmutableAction,
    SetInsertAllowedAction,
    SetRemoveAllowedAction,
    SetGlobalImmutableAction,
    BatchOperatingAgreementAction,
};

// === Errors ===
const EInvalidLineId: u64 = 1;
const EEmptyText: u64 = 2;
const EInvalidDifficulty: u64 = 3;
const EInvalidActionType: u64 = 4;
const EUnsupportedActionVersion: u64 = 5;

// === Constants ===
const ACTION_UPDATE: u8 = 0;
const ACTION_INSERT_AFTER: u8 = 1;
const ACTION_INSERT_AT_BEGINNING: u8 = 2;
const ACTION_REMOVE: u8 = 3;

// === Action Structs are now in operating_agreement module ===

// === Witness Types ===

/// Witness type for CreateOperatingAgreement action
public struct CreateOperatingAgreementWitness has drop {}

// === Execution Functions (PTB Pattern) ===

/// Execute create operating agreement action
public fun do_create_operating_agreement<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // CRITICAL: Assert action type before deserialization
    // Using a witness type for CreateOperatingAgreement
    action_validation::assert_action_type<CreateOperatingAgreementWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);

    // Check version
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);
    let allow_insert = bcs::peel_bool(&mut reader);
    let allow_remove = bcs::peel_bool(&mut reader);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(reader);

    // Initialize operating agreement if needed
    if (!account::has_managed_data(account, operating_agreement::new_agreement_key())) {
        let agreement = operating_agreement::new(
            allow_insert,
            allow_remove,
            ctx
        );
        account::add_managed_data(
            account,
            operating_agreement::new_agreement_key(),
            agreement,
            version::current()
        );
    };

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute update line action
public fun do_update_line<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // CRITICAL: Assert action type before deserialization
    // Using a witness type for UpdateLine
    action_validation::assert_action_type<UpdateLineWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);

    // Check version
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);
    let line_id = object::id_from_address(bcs::peel_address(&mut reader));
    let new_text = bcs::peel_vec_u8(&mut reader).to_string();

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(reader);

    // Validate
    assert!(new_text.length() > 0, EEmptyText);

    let agreement: &mut OperatingAgreement = account::borrow_managed_data_mut(
        account,
        operating_agreement::new_agreement_key(),
        version::current()
    );

    operating_agreement::update_line(agreement, line_id, new_text);

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute insert line after action
public fun do_insert_line_after<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // CRITICAL: Assert action type before deserialization
    // Using a witness type for InsertLineAfter
    action_validation::assert_action_type<InsertLineAfterWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);

    // Check version
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);
    let prev_line_id = object::id_from_address(bcs::peel_address(&mut reader));
    let text = bcs::peel_vec_u8(&mut reader).to_string();
    let difficulty = bcs::peel_u64(&mut reader);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(reader);

    // Validate
    assert!(text.length() > 0, EEmptyText);

    let agreement: &mut OperatingAgreement = account::borrow_managed_data_mut(
        account,
        operating_agreement::new_agreement_key(),
        version::current()
    );

    operating_agreement::insert_line_after(
        agreement,
        prev_line_id,
        text,
        difficulty,
        ctx
    );

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute insert line at beginning action
public fun do_insert_line_at_beginning<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // CRITICAL: Assert action type before deserialization
    action_validation::assert_action_type<InsertLineAtBeginningWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);

    // Check version
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);
    let text = bcs::peel_vec_u8(&mut reader).to_string();
    let difficulty = bcs::peel_u64(&mut reader);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(reader);

    // Validate
    assert!(text.length() > 0, EEmptyText);

    let agreement: &mut OperatingAgreement = account::borrow_managed_data_mut(
        account,
        operating_agreement::new_agreement_key(),
        version::current()
    );

    operating_agreement::insert_line_at_beginning(
        agreement,
        text,
        difficulty,
        ctx
    );

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute remove line action
public fun do_remove_line<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // CRITICAL: Assert action type before deserialization
    action_validation::assert_action_type<RemoveLineWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);

    // Check version
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);
    let line_id = object::id_from_address(bcs::peel_address(&mut reader));

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(reader);

    let agreement: &mut OperatingAgreement = account::borrow_managed_data_mut(
        account,
        operating_agreement::new_agreement_key(),
        version::current()
    );

    operating_agreement::remove_line(agreement, line_id);

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute set line immutable action
public fun do_set_line_immutable<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // CRITICAL: Assert action type before deserialization
    action_validation::assert_action_type<SetLineImmutableWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);

    // Check version
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);
    let line_id = object::id_from_address(bcs::peel_address(&mut reader));

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(reader);

    let agreement: &mut OperatingAgreement = account::borrow_managed_data_mut(
        account,
        operating_agreement::new_agreement_key(),
        version::current()
    );

    operating_agreement::set_line_immutable(agreement, line_id, _clock);

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute set insert allowed action
public fun do_set_insert_allowed<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // CRITICAL: Assert action type before deserialization
    action_validation::assert_action_type<SetInsertAllowedWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);

    // Check version
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);
    let allowed = bcs::peel_bool(&mut reader);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(reader);

    let agreement: &mut OperatingAgreement = account::borrow_managed_data_mut(
        account,
        operating_agreement::new_agreement_key(),
        version::current()
    );

    operating_agreement::set_insert_allowed(agreement, allowed, _clock);

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute set remove allowed action
public fun do_set_remove_allowed<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // CRITICAL: Assert action type before deserialization
    action_validation::assert_action_type<SetRemoveAllowedWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);

    // Check version
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);
    let allowed = bcs::peel_bool(&mut reader);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(reader);

    let agreement: &mut OperatingAgreement = account::borrow_managed_data_mut(
        account,
        operating_agreement::new_agreement_key(),
        version::current()
    );

    operating_agreement::set_remove_allowed(agreement, allowed, _clock);

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute set global immutable action
public fun do_set_global_immutable<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // CRITICAL: Assert action type before deserialization
    action_validation::assert_action_type<SetGlobalImmutableWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);

    // Check version
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // No parameters to deserialize for this action
    let reader = bcs::new(*action_data);

    // Security: ensure no unexpected data
    bcs_validation::validate_all_bytes_consumed(reader);

    let agreement: &mut OperatingAgreement = account::borrow_managed_data_mut(
        account,
        operating_agreement::new_agreement_key(),
        version::current()
    );

    operating_agreement::set_global_immutable(agreement, _clock);

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute batch operating agreement action
public fun do_batch_operating_agreement<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // CRITICAL: Assert action type before deserialization
    action_validation::assert_action_type<BatchOperatingAgreementWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);

    // Check version
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);
    let batch_id = object::id_from_address(bcs::peel_address(&mut reader));
    let actions_count = bcs::peel_vec_length(&mut reader);

    let agreement: &mut OperatingAgreement = account::borrow_managed_data_mut(
        account,
        operating_agreement::new_agreement_key(),
        version::current()
    );

    // Process each action in the batch
    let mut i = 0;
    while (i < actions_count) {
        // Deserialize each OperatingAgreementAction
        let action_type = bcs::peel_u8(&mut reader);

        // Read option for line_id
        let has_line_id = bcs::peel_bool(&mut reader);
        let line_id = if (has_line_id) {
            option::some(object::id_from_address(bcs::peel_address(&mut reader)))
        } else {
            option::none()
        };

        // Read option for text
        let has_text = bcs::peel_bool(&mut reader);
        let text_str = if (has_text) {
            option::some(bcs::peel_vec_u8(&mut reader).to_string())
        } else {
            option::none()
        };

        // Read option for difficulty
        let has_difficulty = bcs::peel_bool(&mut reader);
        let difficulty = if (has_difficulty) {
            option::some(bcs::peel_u64(&mut reader))
        } else {
            option::none()
        };

        if (action_type == ACTION_UPDATE) {
            operating_agreement::update_line(
                agreement,
                *line_id.borrow(),
                *text_str.borrow()
            );
        } else if (action_type == ACTION_INSERT_AFTER) {
            operating_agreement::insert_line_after(
                agreement,
                *line_id.borrow(),
                *text_str.borrow(),
                *difficulty.borrow(),
                ctx
            );
        } else if (action_type == ACTION_INSERT_AT_BEGINNING) {
            operating_agreement::insert_line_at_beginning(
                agreement,
                *text_str.borrow(),
                *difficulty.borrow(),
                ctx
            );
        } else if (action_type == ACTION_REMOVE) {
            operating_agreement::remove_line(agreement, *line_id.borrow());
        };

        i = i + 1;
    };

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(reader);

    // Increment action index
    executable::increment_action_idx(executable);
}

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

/// Delete a set global immutable action from an expired intent
public fun delete_set_global_immutable(expired: &mut Expired) {
    let SetGlobalImmutableAction { } = expired.remove_action();
}

/// Delete a batch operating agreement action from an expired intent
public fun delete_batch_operating_agreement(expired: &mut Expired) {
    let BatchOperatingAgreementAction { batch_id: _, actions: _ } = expired.remove_action();
}

/// Delete an operating agreement action from an expired intent
public fun delete_operating_agreement_action(expired: &mut Expired) {
    let OperatingAgreementAction { action_type: _, line_id: _, text: _, difficulty: _ } = expired.remove_action();
}

// === Destruction Functions ===

/// Destroy a CreateOperatingAgreementAction
public fun destroy_create_operating_agreement(action: CreateOperatingAgreementAction) {
    let CreateOperatingAgreementAction { allow_insert: _, allow_remove: _ } = action;
}

/// Destroy an UpdateLineAction
public fun destroy_update_line(action: UpdateLineAction) {
    let UpdateLineAction { line_id: _, new_text: _ } = action;
}

/// Destroy an InsertLineAfterAction
public fun destroy_insert_line_after(action: InsertLineAfterAction) {
    let InsertLineAfterAction { prev_line_id: _, text: _, difficulty: _ } = action;
}

/// Destroy an InsertLineAtBeginningAction
public fun destroy_insert_line_at_beginning(action: InsertLineAtBeginningAction) {
    let InsertLineAtBeginningAction { text: _, difficulty: _ } = action;
}

/// Destroy a RemoveLineAction
public fun destroy_remove_line(action: RemoveLineAction) {
    let RemoveLineAction { line_id: _ } = action;
}

/// Destroy a SetLineImmutableAction
public fun destroy_set_line_immutable(action: SetLineImmutableAction) {
    let SetLineImmutableAction { line_id: _ } = action;
}

/// Destroy a SetInsertAllowedAction
public fun destroy_set_insert_allowed(action: SetInsertAllowedAction) {
    let SetInsertAllowedAction { allowed: _ } = action;
}

/// Destroy a SetRemoveAllowedAction
public fun destroy_set_remove_allowed(action: SetRemoveAllowedAction) {
    let SetRemoveAllowedAction { allowed: _ } = action;
}

/// Destroy a SetGlobalImmutableAction
public fun destroy_set_global_immutable(action: SetGlobalImmutableAction) {
    let SetGlobalImmutableAction {} = action;
}

/// Destroy a BatchOperatingAgreementAction
public fun destroy_batch_operating_agreement(action: BatchOperatingAgreementAction) {
    let BatchOperatingAgreementAction { batch_id: _, actions } = action;
    // Destroy each action in the batch
    let mut i = 0;
    while (i < actions.length()) {
        let act = actions.pop_back();
        destroy_operating_agreement_action(act);
        i = i + 1;
    };
    actions.destroy_empty();
}

/// Destroy an OperatingAgreementAction
public fun destroy_operating_agreement_action(action: OperatingAgreementAction) {
    let OperatingAgreementAction { action_type: _, line_id: _, text: _, difficulty: _ } = action;
}

// === Intent Helper Functions ===
// NOTE: Helper functions to create action specs and add them to intents

// === Helper Functions ===

/// Get the batch ID from a BatchOperatingAgreementAction
public fun get_batch_id(batch: &BatchOperatingAgreementAction): ID {
    batch.batch_id
}

// === Construction Functions with Serialize-Then-Destroy Pattern ===

/// Create and add a CreateOperatingAgreement action to an intent
public fun new_create_operating_agreement<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    allow_insert: bool,
    allow_remove: bool,
    intent_witness: IW,
) {
    // Serialize action data
    let mut data = vector[];
    data.append(bcs::to_bytes(&allow_insert));
    data.append(bcs::to_bytes(&allow_remove));

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        CreateOperatingAgreementWitness {},
        data,
        intent_witness,
    );
}

/// Create and add an UpdateLine action to an intent
public fun new_update_line<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    line_id: ID,
    new_text: String,
    intent_witness: IW,
) {
    assert!(new_text.length() > 0, EEmptyText);

    // Serialize action data
    let mut data = vector[];
    data.append(bcs::to_bytes(&object::id_to_address(&line_id)));
    data.append(bcs::to_bytes(&new_text.as_bytes()));

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        UpdateLineWitness {},
        data,
        intent_witness,
    );
}

/// Create and add an InsertLineAfter action to an intent
public fun new_insert_line_after<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    prev_line_id: ID,
    text: String,
    difficulty: u64,
    intent_witness: IW,
) {
    assert!(text.length() > 0, EEmptyText);

    // Serialize action data
    let mut data = vector[];
    data.append(bcs::to_bytes(&object::id_to_address(&prev_line_id)));
    data.append(bcs::to_bytes(&text.as_bytes()));
    data.append(bcs::to_bytes(&difficulty));

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        InsertLineAfterWitness {},
        data,
        intent_witness,
    );
}

/// Create and add an InsertLineAtBeginning action to an intent
public fun new_insert_line_at_beginning<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    text: String,
    difficulty: u64,
    intent_witness: IW,
) {
    assert!(text.length() > 0, EEmptyText);

    // Serialize action data
    let mut data = vector[];
    data.append(bcs::to_bytes(&text.as_bytes()));
    data.append(bcs::to_bytes(&difficulty));

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        InsertLineAtBeginningWitness {},
        data,
        intent_witness,
    );
}

/// Create and add a RemoveLine action to an intent
public fun new_remove_line<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    line_id: ID,
    intent_witness: IW,
) {
    // Serialize action data
    let data = bcs::to_bytes(&object::id_to_address(&line_id));

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        RemoveLineWitness {},
        data,
        intent_witness,
    );
}

/// Create and add a SetLineImmutable action to an intent
public fun new_set_line_immutable<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    line_id: ID,
    intent_witness: IW,
) {
    // Serialize action data
    let data = bcs::to_bytes(&object::id_to_address(&line_id));

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        SetLineImmutableWitness {},
        data,
        intent_witness,
    );
}

/// Create and add a SetInsertAllowed action to an intent
public fun new_set_insert_allowed<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    allowed: bool,
    intent_witness: IW,
) {
    // Serialize action data
    let data = bcs::to_bytes(&allowed);

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        SetInsertAllowedWitness {},
        data,
        intent_witness,
    );
}

/// Create and add a SetRemoveAllowed action to an intent
public fun new_set_remove_allowed<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    allowed: bool,
    intent_witness: IW,
) {
    // Serialize action data
    let data = bcs::to_bytes(&allowed);

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        SetRemoveAllowedWitness {},
        data,
        intent_witness,
    );
}

/// Create and add a SetGlobalImmutable action to an intent
public fun new_set_global_immutable<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    intent_witness: IW,
) {
    // Serialize action data (empty)
    let data = vector[];

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        SetGlobalImmutableWitness {},
        data,
        intent_witness,
    );
}

// Note: Old direct constructor functions have been removed.
// Use the new_* functions above that follow the serialize-then-destroy pattern.

/// Create and add a BatchOperatingAgreement action to an intent
public fun new_batch_operating_agreement(
    intent: &mut Intent,
    batch_id: ID,
    actions: vector<OperatingAgreementAction>,
) {
    let action = BatchOperatingAgreementAction { batch_id, actions };

    // Serialize action data
    let mut data = vector[];
    data.append(bcs::to_bytes(&object::id_to_address(&batch_id)));

    // Serialize the vector of actions
    data.append(bcs::to_bytes(&actions.length()));
    let mut i = 0;
    while (i < actions.length()) {
        let act = actions.borrow(i);
        data.append(bcs::to_bytes(&act.action_type));

        // Serialize option fields
        if (act.line_id.is_some()) {
            data.append(bcs::to_bytes(&true));
            data.append(bcs::to_bytes(&object::id_to_address(act.line_id.borrow())));
        } else {
            data.append(bcs::to_bytes(&false));
        };

        if (act.text.is_some()) {
            data.append(bcs::to_bytes(&true));
            data.append(bcs::to_bytes(&act.text.borrow().as_bytes()));
        } else {
            data.append(bcs::to_bytes(&false));
        };

        if (act.difficulty.is_some()) {
            data.append(bcs::to_bytes(&true));
            data.append(bcs::to_bytes(act.difficulty.borrow()));
        } else {
            data.append(bcs::to_bytes(&false));
        };

        i = i + 1;
    };

    // Add to intent spec
    protocol_intents::add_action(
        spec,
        type_name::with_defining_ids<action_types::BatchOperatingAgreement>(),
        data,
    );

    // Destroy the action struct
    destroy_batch_operating_agreement(action);
}

/// Helper to create an OperatingAgreementAction for batch operations
public fun create_operating_agreement_action(
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
        // Difficulty of 0 is valid for unanimous decisions
        assert!(difficulty.is_some(), EInvalidDifficulty);
    } else if (action_type == ACTION_INSERT_AT_BEGINNING) {
        assert!(text.is_some() && text.borrow().length() > 0, EEmptyText);
        // Difficulty of 0 is valid for unanimous decisions
        assert!(difficulty.is_some(), EInvalidDifficulty);
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
        // Difficulty of 0 is valid for unanimous decisions
        assert!(action.difficulty.is_some(), EInvalidDifficulty);
    } else if (action.action_type == ACTION_INSERT_AT_BEGINNING) {
        assert!(action.text.is_some() && action.text.borrow().length() > 0, EEmptyText);
        // Difficulty of 0 is valid for unanimous decisions
        assert!(action.difficulty.is_some(), EInvalidDifficulty);
    } else if (action.action_type == ACTION_REMOVE) {
        assert!(action.line_id.is_some(), EInvalidLineId);
    };
}