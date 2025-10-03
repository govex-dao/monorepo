/// Decoder for policy actions in futarchy DAOs
module futarchy_multisig::policy_decoder;

// === Imports ===

use std::{string::String, type_name::{Self, TypeName}, option::{Self, Option}};
use sui::{object::{Self, UID}, dynamic_object_field, bcs, tx_context::TxContext};
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_multisig::policy_actions::{
    SetTypePolicyAction,
    SetObjectPolicyAction,
    RegisterCouncilAction,
    RemoveTypePolicyAction,
    RemoveObjectPolicyAction,
};

// === Helper Functions ===

/// Convert mode constant to human-readable string
fun mode_to_string(mode: u8): vector<u8> {
    if (mode == 0) {
        b"DaoOnly"
    } else if (mode == 1) {
        b"CouncilOnly"
    } else if (mode == 2) {
        b"DaoOrCouncil"
    } else if (mode == 3) {
        b"DaoAndCouncil"
    } else {
        b"Unknown"
    }
}

// === Decoder Objects ===

/// Decoder for SetTypePolicyAction
public struct SetTypePolicyActionDecoder has key, store {
    id: UID,
}

/// Decoder for SetObjectPolicyAction
public struct SetObjectPolicyActionDecoder has key, store {
    id: UID,
}

/// Decoder for RegisterCouncilAction
public struct RegisterCouncilActionDecoder has key, store {
    id: UID,
}

/// Decoder for RemoveTypePolicyAction
public struct RemoveTypePolicyActionDecoder has key, store {
    id: UID,
}

/// Decoder for RemoveObjectPolicyAction
public struct RemoveObjectPolicyActionDecoder has key, store {
    id: UID,
}

// === Decoder Functions ===

/// Decode a SetTypePolicyAction
public fun decode_set_type_policy_action(
    _decoder: &SetTypePolicyActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    // TypeName was serialized as string bytes
    let type_name_bytes = bcs::peel_vec_u8(&mut bcs_data);

    // Execution Option<ID>
    let execution_council_id = if (bcs::peel_bool(&mut bcs_data)) {
        option::some(bcs::peel_address(&mut bcs_data))
    } else {
        option::none()
    };
    let execution_mode = bcs::peel_u8(&mut bcs_data);

    // Change Option<ID>
    let change_council_id = if (bcs::peel_bool(&mut bcs_data)) {
        option::some(bcs::peel_address(&mut bcs_data))
    } else {
        option::none()
    };
    let change_mode = bcs::peel_u8(&mut bcs_data);
    let change_delay_ms = bcs::peel_u64(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let execution_mode_str = mode_to_string(execution_mode);
    let change_mode_str = mode_to_string(change_mode);

    let mut fields = vector[
        schema::new_field(
            b"type_name".to_string(),
            type_name_bytes.to_string(),
            b"TypeName".to_string(),
        ),
        schema::new_field(
            b"execution_mode".to_string(),
            execution_mode_str.to_string(),
            b"String".to_string(),
        ),
        schema::new_field(
            b"change_mode".to_string(),
            change_mode_str.to_string(),
            b"String".to_string(),
        ),
        schema::new_field(
            b"change_delay_ms".to_string(),
            change_delay_ms.to_string(),
            b"u64".to_string(),
        ),
    ];

    if (execution_council_id.is_some()) {
        fields.push_back(schema::new_field(
            b"execution_council_id".to_string(),
            (*execution_council_id.borrow()).to_string(),
            b"ID".to_string(),
        ));
    };

    if (change_council_id.is_some()) {
        fields.push_back(schema::new_field(
            b"change_council_id".to_string(),
            (*change_council_id.borrow()).to_string(),
            b"ID".to_string(),
        ));
    };

    fields
}

/// Decode a SetObjectPolicyAction
public fun decode_set_object_policy_action(
    _decoder: &SetObjectPolicyActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let object_id = bcs::peel_address(&mut bcs_data);

    // Execution Option<ID>
    let execution_council_id = if (bcs::peel_bool(&mut bcs_data)) {
        option::some(bcs::peel_address(&mut bcs_data))
    } else {
        option::none()
    };
    let execution_mode = bcs::peel_u8(&mut bcs_data);

    // Change Option<ID>
    let change_council_id = if (bcs::peel_bool(&mut bcs_data)) {
        option::some(bcs::peel_address(&mut bcs_data))
    } else {
        option::none()
    };
    let change_mode = bcs::peel_u8(&mut bcs_data);
    let change_delay_ms = bcs::peel_u64(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let execution_mode_str = mode_to_string(execution_mode);
    let change_mode_str = mode_to_string(change_mode);

    let mut fields = vector[
        schema::new_field(
            b"object_id".to_string(),
            object_id.to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"execution_mode".to_string(),
            execution_mode_str.to_string(),
            b"String".to_string(),
        ),
        schema::new_field(
            b"change_mode".to_string(),
            change_mode_str.to_string(),
            b"String".to_string(),
        ),
        schema::new_field(
            b"change_delay_ms".to_string(),
            change_delay_ms.to_string(),
            b"u64".to_string(),
        ),
    ];

    if (execution_council_id.is_some()) {
        fields.push_back(schema::new_field(
            b"execution_council_id".to_string(),
            (*execution_council_id.borrow()).to_string(),
            b"ID".to_string(),
        ));
    };

    if (change_council_id.is_some()) {
        fields.push_back(schema::new_field(
            b"change_council_id".to_string(),
            (*change_council_id.borrow()).to_string(),
            b"ID".to_string(),
        ));
    };

    fields
}

/// Decode a RegisterCouncilAction
public fun decode_register_council_action(
    _decoder: &RegisterCouncilActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let council_id = bcs::peel_address(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"council_id".to_string(),
            council_id.to_string(),
            b"ID".to_string(),
        ),
    ]
}

/// Decode a RemoveTypePolicyAction
public fun decode_remove_type_policy_action(
    _decoder: &RemoveTypePolicyActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    // TypeName is a struct with a name field (ASCII string)
    let type_name_bytes = bcs::peel_vec_u8(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"type_name".to_string(),
            type_name_bytes.to_string(),
            b"TypeName".to_string(),
        ),
    ]
}

/// Decode a RemoveObjectPolicyAction
public fun decode_remove_object_policy_action(
    _decoder: &RemoveObjectPolicyActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let object_id = bcs::peel_address(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"object_id".to_string(),
            object_id.to_string(),
            b"ID".to_string(),
        ),
    ]
}

// === Registration Functions ===

/// Register all policy decoders
public fun register_decoders(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    register_set_type_policy_decoder(registry, ctx);
    register_set_object_policy_decoder(registry, ctx);
    register_register_council_decoder(registry, ctx);
    register_remove_type_policy_decoder(registry, ctx);
    register_remove_object_policy_decoder(registry, ctx);
}

fun register_set_type_policy_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = SetTypePolicyActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<SetTypePolicyAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_set_object_policy_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = SetObjectPolicyActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<SetObjectPolicyAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_register_council_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = RegisterCouncilActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<RegisterCouncilAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_remove_type_policy_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = RemoveTypePolicyActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<RemoveTypePolicyAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_remove_object_policy_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = RemoveObjectPolicyActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<RemoveObjectPolicyAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}