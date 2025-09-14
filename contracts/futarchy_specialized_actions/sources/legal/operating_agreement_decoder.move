/// Decoder for operating agreement actions in futarchy DAOs
module futarchy_specialized_actions::operating_agreement_decoder;

// === Imports ===

use std::{string::String, type_name};
use sui::{object::{Self, UID}, dynamic_object_field, bcs};
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_specialized_actions::operating_agreement_actions::{
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
use futarchy_one_shot_utils::action_data_structs::CreateOperatingAgreementAction;

// === Constants ===
const ACTION_UPDATE: u8 = 0;
const ACTION_INSERT_AFTER: u8 = 1;
const ACTION_INSERT_AT_BEGINNING: u8 = 2;
const ACTION_REMOVE: u8 = 3;

// === Decoder Objects ===

/// Decoder for CreateOperatingAgreementAction
public struct CreateOperatingAgreementActionDecoder has key, store {
    id: UID,
}

/// Decoder for OperatingAgreementAction
public struct OperatingAgreementActionDecoder has key, store {
    id: UID,
}

/// Decoder for UpdateLineAction
public struct UpdateLineActionDecoder has key, store {
    id: UID,
}

/// Decoder for InsertLineAfterAction
public struct InsertLineAfterActionDecoder has key, store {
    id: UID,
}

/// Decoder for InsertLineAtBeginningAction
public struct InsertLineAtBeginningActionDecoder has key, store {
    id: UID,
}

/// Decoder for RemoveLineAction
public struct RemoveLineActionDecoder has key, store {
    id: UID,
}

/// Decoder for SetLineImmutableAction
public struct SetLineImmutableActionDecoder has key, store {
    id: UID,
}

/// Decoder for SetInsertAllowedAction
public struct SetInsertAllowedActionDecoder has key, store {
    id: UID,
}

/// Decoder for SetRemoveAllowedAction
public struct SetRemoveAllowedActionDecoder has key, store {
    id: UID,
}

/// Decoder for SetGlobalImmutableAction
public struct SetGlobalImmutableActionDecoder has key, store {
    id: UID,
}

/// Decoder for BatchOperatingAgreementAction
public struct BatchOperatingAgreementActionDecoder has key, store {
    id: UID,
}

// === Helper Functions ===

fun decode_option_id(bcs_data: &mut BCS): Option<ID> {
    let is_some = bcs::peel_bool(bcs_data);
    if (is_some) {
        option::some(object::id_from_address(bcs::peel_address(bcs_data)))
    } else {
        option::none()
    }
}

fun decode_option_string(bcs_data: &mut BCS): Option<String> {
    let is_some = bcs::peel_bool(bcs_data);
    if (is_some) {
        option::some(bcs::peel_vec_u8(bcs_data).to_string())
    } else {
        option::none()
    }
}

fun decode_option_u64(bcs_data: &mut BCS): Option<u64> {
    let is_some = bcs::peel_bool(bcs_data);
    if (is_some) {
        option::some(bcs::peel_u64(bcs_data))
    } else {
        option::none()
    }
}

// === Decoder Functions ===

/// Decode a CreateOperatingAgreementAction
public fun decode_create_operating_agreement_action(
    _decoder: &CreateOperatingAgreementActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    // Read lines vector
    let lines_count = bcs::peel_vec_length(&mut bcs_data);
    let mut i = 0;
    while (i < lines_count) {
        bcs::peel_vec_u8(&mut bcs_data); // text
        bcs::peel_u64(&mut bcs_data); // difficulty
        i = i + 1;
    };

    let immutable = bcs::peel_bool(&mut bcs_data);
    let insert_allowed = bcs::peel_bool(&mut bcs_data);
    let remove_allowed = bcs::peel_bool(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"lines_count".to_string(),
            lines_count.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"immutable".to_string(),
            if (immutable) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
        schema::new_field(
            b"insert_allowed".to_string(),
            if (insert_allowed) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
        schema::new_field(
            b"remove_allowed".to_string(),
            if (remove_allowed) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
    ]
}

/// Decode an OperatingAgreementAction
public fun decode_operating_agreement_action(
    _decoder: &OperatingAgreementActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let action_type = bcs::peel_u8(&mut bcs_data);
    let line_id = decode_option_id(&mut bcs_data);
    let text = decode_option_string(&mut bcs_data);
    let difficulty = decode_option_u64(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let action_type_str = if (action_type == ACTION_UPDATE) {
        b"Update"
    } else if (action_type == ACTION_INSERT_AFTER) {
        b"InsertAfter"
    } else if (action_type == ACTION_INSERT_AT_BEGINNING) {
        b"InsertAtBeginning"
    } else {
        b"Remove"
    };

    let mut fields = vector[
        schema::new_field(
            b"action_type".to_string(),
            action_type_str.to_string(),
            b"String".to_string(),
        ),
    ];

    if (line_id.is_some()) {
        fields.push_back(schema::new_field(
            b"line_id".to_string(),
            line_id.destroy_some().to_string(),
            b"ID".to_string(),
        ));
    } else {
        line_id.destroy_none();
    };

    if (text.is_some()) {
        fields.push_back(schema::new_field(
            b"text".to_string(),
            text.destroy_some(),
            b"String".to_string(),
        ));
    } else {
        text.destroy_none();
    };

    if (difficulty.is_some()) {
        fields.push_back(schema::new_field(
            b"difficulty".to_string(),
            difficulty.destroy_some().to_string(),
            b"u64".to_string(),
        ));
    } else {
        difficulty.destroy_none();
    };

    fields
}

/// Decode an UpdateLineAction
public fun decode_update_line_action(
    _decoder: &UpdateLineActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let line_id = bcs::peel_address(&mut bcs_data);
    let new_text = bcs::peel_vec_u8(&mut bcs_data).to_string();

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"line_id".to_string(),
            line_id.to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"new_text".to_string(),
            new_text,
            b"String".to_string(),
        ),
    ]
}

/// Decode an InsertLineAfterAction
public fun decode_insert_line_after_action(
    _decoder: &InsertLineAfterActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let prev_line_id = bcs::peel_address(&mut bcs_data);
    let text = bcs::peel_vec_u8(&mut bcs_data).to_string();
    let difficulty = bcs::peel_u64(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"prev_line_id".to_string(),
            prev_line_id.to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"text".to_string(),
            text,
            b"String".to_string(),
        ),
        schema::new_field(
            b"difficulty".to_string(),
            difficulty.to_string(),
            b"u64".to_string(),
        ),
    ]
}

/// Decode an InsertLineAtBeginningAction
public fun decode_insert_line_at_beginning_action(
    _decoder: &InsertLineAtBeginningActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let text = bcs::peel_vec_u8(&mut bcs_data).to_string();
    let difficulty = bcs::peel_u64(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"text".to_string(),
            text,
            b"String".to_string(),
        ),
        schema::new_field(
            b"difficulty".to_string(),
            difficulty.to_string(),
            b"u64".to_string(),
        ),
    ]
}

/// Decode a RemoveLineAction
public fun decode_remove_line_action(
    _decoder: &RemoveLineActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let line_id = bcs::peel_address(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"line_id".to_string(),
            line_id.to_string(),
            b"ID".to_string(),
        ),
    ]
}

/// Decode a SetLineImmutableAction
public fun decode_set_line_immutable_action(
    _decoder: &SetLineImmutableActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let line_id = bcs::peel_address(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"line_id".to_string(),
            line_id.to_string(),
            b"ID".to_string(),
        ),
    ]
}

/// Decode a SetInsertAllowedAction
public fun decode_set_insert_allowed_action(
    _decoder: &SetInsertAllowedActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let allowed = bcs::peel_bool(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"allowed".to_string(),
            if (allowed) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
    ]
}

/// Decode a SetRemoveAllowedAction
public fun decode_set_remove_allowed_action(
    _decoder: &SetRemoveAllowedActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let allowed = bcs::peel_bool(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"allowed".to_string(),
            if (allowed) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
    ]
}

/// Decode a SetGlobalImmutableAction
public fun decode_set_global_immutable_action(
    _decoder: &SetGlobalImmutableActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let bcs_data = bcs::new(action_data);

    // No fields to decode
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"action".to_string(),
            b"SetGlobalImmutable".to_string(),
            b"String".to_string(),
        ),
    ]
}

/// Decode a BatchOperatingAgreementAction
public fun decode_batch_operating_agreement_action(
    _decoder: &BatchOperatingAgreementActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let batch_id = bcs::peel_address(&mut bcs_data);

    // Read actions vector
    let actions_count = bcs::peel_vec_length(&mut bcs_data);
    let mut i = 0;
    while (i < actions_count) {
        // Decode each OperatingAgreementAction
        bcs::peel_u8(&mut bcs_data); // action_type
        decode_option_id(&mut bcs_data); // line_id
        decode_option_string(&mut bcs_data); // text
        decode_option_u64(&mut bcs_data); // difficulty
        i = i + 1;
    };

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"batch_id".to_string(),
            batch_id.to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"actions_count".to_string(),
            actions_count.to_string(),
            b"u64".to_string(),
        ),
    ]
}

// === Registration Functions ===

/// Register all operating agreement decoders
public fun register_decoders(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    register_create_operating_agreement_decoder(registry, ctx);
    register_operating_agreement_action_decoder(registry, ctx);
    register_update_line_decoder(registry, ctx);
    register_insert_line_after_decoder(registry, ctx);
    register_insert_line_at_beginning_decoder(registry, ctx);
    register_remove_line_decoder(registry, ctx);
    register_set_line_immutable_decoder(registry, ctx);
    register_set_insert_allowed_decoder(registry, ctx);
    register_set_remove_allowed_decoder(registry, ctx);
    register_set_global_immutable_decoder(registry, ctx);
    register_batch_operating_agreement_decoder(registry, ctx);
}

fun register_create_operating_agreement_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CreateOperatingAgreementActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CreateOperatingAgreementAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_operating_agreement_action_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = OperatingAgreementActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<OperatingAgreementAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_update_line_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = UpdateLineActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<UpdateLineAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_insert_line_after_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = InsertLineAfterActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<InsertLineAfterAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_insert_line_at_beginning_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = InsertLineAtBeginningActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<InsertLineAtBeginningAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_remove_line_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = RemoveLineActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<RemoveLineAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_set_line_immutable_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = SetLineImmutableActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<SetLineImmutableAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_set_insert_allowed_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = SetInsertAllowedActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<SetInsertAllowedAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_set_remove_allowed_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = SetRemoveAllowedActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<SetRemoveAllowedAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_set_global_immutable_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = SetGlobalImmutableActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<SetGlobalImmutableAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_batch_operating_agreement_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = BatchOperatingAgreementActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<BatchOperatingAgreementAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}