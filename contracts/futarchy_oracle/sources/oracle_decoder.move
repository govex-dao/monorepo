/// Decoder for oracle mint grant actions
module futarchy_oracle::oracle_decoder;

use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_oracle::oracle_actions::{
    CreateOracleGrantAction,
    CancelGrantAction,
    PauseGrantAction,
    UnpauseGrantAction,
    EmergencyFreezeGrantAction,
    EmergencyUnfreezeGrantAction
};
use std::option::{Self, Option};
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::dynamic_object_field;
use sui::object::{Self, UID, ID};
use sui::tx_context::TxContext;

// === Imports ===

// === Decoder Objects ===

/// Decoder for unified CreateOracleGrantAction
public struct CreateOracleGrantActionDecoder has key, store {
    id: UID,
}

/// Decoder for CancelGrantAction
public struct CancelGrantActionDecoder has key, store {
    id: UID,
}

/// Decoder for PauseGrantAction
public struct PauseGrantActionDecoder has key, store {
    id: UID,
}

/// Decoder for UnpauseGrantAction
public struct UnpauseGrantActionDecoder has key, store {
    id: UID,
}

/// Decoder for EmergencyFreezeGrantAction
public struct EmergencyFreezeGrantActionDecoder has key, store {
    id: UID,
}

/// Decoder for EmergencyUnfreezeGrantAction
public struct EmergencyUnfreezeGrantActionDecoder has key, store {
    id: UID,
}

/// Placeholder for generic type registration
public struct AssetPlaceholder has drop, store {}
public struct StablePlaceholder has drop, store {}

// === Decoder Functions ===

/// Decode unified CreateOracleGrantAction (with multi-recipient support)
public fun decode_create_oracle_grant<AssetType, StableType>(
    _decoder: &CreateOracleGrantActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let recipients = bcs::peel_vec_address(&mut bcs_data);
    let amounts = bcs::peel_vec_u64(&mut bcs_data);
    let vesting_mode = bcs::peel_u8(&mut bcs_data);
    let vesting_cliff_months = bcs::peel_u64(&mut bcs_data);
    let vesting_duration_years = bcs::peel_u64(&mut bcs_data);
    let strike_mode = bcs::peel_u8(&mut bcs_data);
    let strike_price = bcs::peel_u64(&mut bcs_data);
    let launchpad_multiplier = bcs::peel_u64(&mut bcs_data);
    let cooldown_ms = bcs::peel_u64(&mut bcs_data);
    let max_executions = bcs::peel_u64(&mut bcs_data);
    let earliest_execution_offset_ms = bcs::peel_u64(&mut bcs_data);
    let expiry_years = bcs::peel_u64(&mut bcs_data);
    let price_condition_mode = bcs::peel_u8(&mut bcs_data);
    let price_threshold = bcs::peel_u128(&mut bcs_data);
    let price_is_above = bcs::peel_bool(&mut bcs_data);
    let cancelable = bcs::peel_bool(&mut bcs_data);
    let description_bytes = bcs::peel_vec_u8(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let description = std::string::utf8(description_bytes);
    let recipient_count = vector::length(&recipients);

    vector[
        schema::new_field(
            b"recipient_count".to_string(),
            recipient_count.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(b"vesting_mode".to_string(), vesting_mode.to_string(), b"u8".to_string()),
        schema::new_field(
            b"vesting_cliff_months".to_string(),
            vesting_cliff_months.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"vesting_duration_years".to_string(),
            vesting_duration_years.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(b"strike_mode".to_string(), strike_mode.to_string(), b"u8".to_string()),
        schema::new_field(
            b"strike_price".to_string(),
            strike_price.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"launchpad_multiplier".to_string(),
            launchpad_multiplier.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(b"cooldown_ms".to_string(), cooldown_ms.to_string(), b"u64".to_string()),
        schema::new_field(
            b"max_executions".to_string(),
            max_executions.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"earliest_execution_offset_ms".to_string(),
            earliest_execution_offset_ms.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"expiry_years".to_string(),
            expiry_years.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"price_condition_mode".to_string(),
            price_condition_mode.to_string(),
            b"u8".to_string(),
        ),
        schema::new_field(
            b"price_threshold".to_string(),
            price_threshold.to_string(),
            b"u128".to_string(),
        ),
        schema::new_field(
            b"price_is_above".to_string(),
            if (price_is_above) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
        schema::new_field(
            b"cancelable".to_string(),
            if (cancelable) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
        schema::new_field(b"description".to_string(), description, b"String".to_string()),
    ]
}

// Placeholder for tier data decoding (would need separate decoder for complex tier structures)
/// NOTE: Tier-specific data (price conditions, recipients, per-tier vesting/strikes)
/// would be passed separately via dynamic fields or additional action data
/// since BCS size limits make encoding N tiers in the action impractical

/// Decode CancelGrantAction
public fun decode_cancel_grant(
    _decoder: &CancelGrantActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let grant_id_address = bcs::peel_address(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(b"grant_id".to_string(), grant_id_address.to_string(), b"ID".to_string()),
    ]
}

/// Decode PauseGrantAction
public fun decode_pause_grant(
    _decoder: &PauseGrantActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let grant_id_address = bcs::peel_address(&mut bcs_data);
    let pause_duration_ms = bcs::peel_u64(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(b"grant_id".to_string(), grant_id_address.to_string(), b"ID".to_string()),
        schema::new_field(
            b"pause_duration_ms".to_string(),
            pause_duration_ms.to_string(),
            b"u64".to_string(),
        ),
    ]
}

/// Decode UnpauseGrantAction
public fun decode_unpause_grant(
    _decoder: &UnpauseGrantActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let grant_id_address = bcs::peel_address(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(b"grant_id".to_string(), grant_id_address.to_string(), b"ID".to_string()),
    ]
}

/// Decode EmergencyFreezeGrantAction
public fun decode_emergency_freeze_grant(
    _decoder: &EmergencyFreezeGrantActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let grant_id_address = bcs::peel_address(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(b"grant_id".to_string(), grant_id_address.to_string(), b"ID".to_string()),
    ]
}

/// Decode EmergencyUnfreezeGrantAction
public fun decode_emergency_unfreeze_grant(
    _decoder: &EmergencyUnfreezeGrantActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let grant_id_address = bcs::peel_address(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(b"grant_id".to_string(), grant_id_address.to_string(), b"ID".to_string()),
    ]
}

// === Registration Functions ===

/// Register all oracle decoders with the registry
public fun register_oracle_decoders<AssetType, StableType>(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    register_create_oracle_grant_decoder<AssetType, StableType>(registry, ctx);
    register_cancel_grant_decoder(registry, ctx);
    register_pause_grant_decoder(registry, ctx);
    register_unpause_grant_decoder(registry, ctx);
    register_emergency_freeze_grant_decoder(registry, ctx);
    register_emergency_unfreeze_grant_decoder(registry, ctx);
}

fun register_create_oracle_grant_decoder<AssetType, StableType>(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CreateOracleGrantActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CreateOracleGrantAction<AssetType, StableType>>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_cancel_grant_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = CancelGrantActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CancelGrantAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_pause_grant_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = PauseGrantActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<PauseGrantAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_unpause_grant_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = UnpauseGrantActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<UnpauseGrantAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_emergency_freeze_grant_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = EmergencyFreezeGrantActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<EmergencyFreezeGrantAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_emergency_unfreeze_grant_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = EmergencyUnfreezeGrantActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<EmergencyUnfreezeGrantAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
