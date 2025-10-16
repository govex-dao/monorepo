// ============================================================================
// FORK ADDITION - Vesting Action Decoder
// ============================================================================
// NEW FILE added to the fork for on-chain action decoding.
//
// PURPOSE:
// Provides human-readable decoding of vesting actions for transparency.
// Part of the mandatory decoder system that ensures all actions can be
// decoded and displayed to users before execution.
//
// IMPLEMENTATION:
// - Uses BCS deserialization with peel_* functions
// - Security validation via validate_all_bytes_consumed()
// - Returns vector<HumanReadableField> for universal display
// - Handles CreateVestingAction and CancelVestingAction
// ============================================================================

/// Decoder for vesting actions - tightly coupled with vesting action definitions
module account_actions::vesting_decoder;

use account_actions::vesting::{
    CreateVestingAction,
    CancelVestingAction,
    ToggleVestingPauseAction,
    ToggleVestingFreezeAction
};
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::dynamic_object_field;
use sui::object::{Self, UID, ID};

// === Imports ===

// === Decoder Objects ===

/// Decoder for CreateVestingAction<CoinType>
public struct CreateVestingActionDecoder has key, store {
    id: UID,
}

/// Decoder for CancelVestingAction
public struct CancelVestingActionDecoder has key, store {
    id: UID,
}

/// Decoder for ToggleVestingPauseAction
public struct ToggleVestingPauseActionDecoder has key, store {
    id: UID,
}

/// Decoder for ToggleVestingFreezeAction
public struct ToggleVestingFreezeActionDecoder has key, store {
    id: UID,
}

// === Placeholder for Generic Registration ===

/// Placeholder type for registering generic decoders
public struct CoinPlaceholder has drop, store {}

// === Decoder Functions ===

/// Decode a CreateVestingAction
public fun decode_create_vesting_action<CoinType>(
    _decoder: &CreateVestingActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    // Deserialize the fields directly - DO NOT reconstruct the Action struct
    let mut bcs_data = bcs::new(action_data);
    let amount = bcs::peel_u64(&mut bcs_data);
    let start_timestamp = bcs::peel_u64(&mut bcs_data);
    let end_timestamp = bcs::peel_u64(&mut bcs_data);
    let mut cliff_time = bcs_data.peel_option!(|bcs| bcs.peel_u64());
    let recipient = bcs::peel_address(&mut bcs_data);
    let max_beneficiaries = bcs::peel_u64(&mut bcs_data);
    let max_per_withdrawal = bcs::peel_u64(&mut bcs_data);
    let min_interval_ms = bcs::peel_u64(&mut bcs_data);
    let is_transferable = bcs::peel_bool(&mut bcs_data);
    let is_cancelable = bcs::peel_bool(&mut bcs_data);
    let mut metadata = bcs_data.peel_option!(|bcs| bcs.peel_vec_u8());

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector::empty();

    fields.push_back(
        schema::new_field(
            b"amount".to_string(),
            amount.to_string(),
            b"u64".to_string(),
        ),
    );

    fields.push_back(
        schema::new_field(
            b"start_timestamp".to_string(),
            start_timestamp.to_string(),
            b"u64".to_string(),
        ),
    );

    fields.push_back(
        schema::new_field(
            b"end_timestamp".to_string(),
            end_timestamp.to_string(),
            b"u64".to_string(),
        ),
    );

    fields.push_back(
        schema::new_field(
            b"cliff_time".to_string(),
            if (cliff_time.is_some()) {
                cliff_time.destroy_some().to_string()
            } else {
                cliff_time.destroy_none();
                b"None".to_string()
            },
            b"Option<u64>".to_string(),
        ),
    );

    fields.push_back(
        schema::new_field(
            b"recipient".to_string(),
            recipient.to_string(),
            b"address".to_string(),
        ),
    );

    fields.push_back(
        schema::new_field(
            b"max_beneficiaries".to_string(),
            max_beneficiaries.to_string(),
            b"u64".to_string(),
        ),
    );

    fields.push_back(
        schema::new_field(
            b"max_per_withdrawal".to_string(),
            max_per_withdrawal.to_string(),
            b"u64".to_string(),
        ),
    );

    fields.push_back(
        schema::new_field(
            b"min_interval_ms".to_string(),
            min_interval_ms.to_string(),
            b"u64".to_string(),
        ),
    );

    fields.push_back(
        schema::new_field(
            b"is_transferable".to_string(),
            if (is_transferable) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
    );

    fields.push_back(
        schema::new_field(
            b"is_cancelable".to_string(),
            if (is_cancelable) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
    );

    fields.push_back(
        schema::new_field(
            b"metadata".to_string(),
            if (metadata.is_some()) {
                metadata.destroy_some().to_string()
            } else {
                metadata.destroy_none();
                b"None".to_string()
            },
            b"Option<String>".to_string(),
        ),
    );

    fields
}

/// Decode a CancelVestingAction
public fun decode_cancel_vesting_action(
    _decoder: &CancelVestingActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    // Deserialize the fields directly - DO NOT reconstruct the Action struct
    let mut bcs_data = bcs::new(action_data);
    let vesting_id = object::id_from_bytes(bcs::peel_vec_u8(&mut bcs_data));

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"vesting_id".to_string(),
            vesting_id.id_to_address().to_string(),
            b"ID".to_string(),
        ),
    ]
}

/// Decode a ToggleVestingPauseAction
public fun decode_toggle_vesting_pause_action(
    _decoder: &ToggleVestingPauseActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let vesting_id = object::id_from_bytes(bcs::peel_vec_u8(&mut bcs_data));
    let pause_duration_ms = bcs::peel_u64(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"vesting_id".to_string(),
            vesting_id.id_to_address().to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"pause_duration_ms".to_string(),
            pause_duration_ms.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"action".to_string(),
            if (pause_duration_ms == 0) { b"unpause" } else { b"pause" }.to_string(),
            b"string".to_string(),
        ),
    ]
}

/// Decode a ToggleVestingFreezeAction
public fun decode_toggle_vesting_freeze_action(
    _decoder: &ToggleVestingFreezeActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let vesting_id = object::id_from_bytes(bcs::peel_vec_u8(&mut bcs_data));
    let freeze = bcs::peel_bool(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"vesting_id".to_string(),
            vesting_id.id_to_address().to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"freeze".to_string(),
            if (freeze) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
        schema::new_field(
            b"action".to_string(),
            if (freeze) { b"emergency_freeze" } else { b"unfreeze" }.to_string(),
            b"string".to_string(),
        ),
    ]
}

// === Registration Functions ===

/// Register all vesting decoders
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    register_create_vesting_decoder(registry, ctx);
    register_cancel_vesting_decoder(registry, ctx);
    register_toggle_vesting_pause_decoder(registry, ctx);
    register_toggle_vesting_freeze_decoder(registry, ctx);
}

fun register_create_vesting_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = CreateVestingActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CreateVestingAction<CoinPlaceholder>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_cancel_vesting_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = CancelVestingActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CancelVestingAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_toggle_vesting_pause_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ToggleVestingPauseActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<ToggleVestingPauseAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_toggle_vesting_freeze_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ToggleVestingFreezeActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<ToggleVestingFreezeAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
