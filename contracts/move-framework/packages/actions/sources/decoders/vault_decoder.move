// ============================================================================
// FORK ADDITION - Vault Action Decoder
// ============================================================================
// NEW FILE added to the fork for on-chain action decoding.
//
// PURPOSE:
// Provides human-readable decoding of vault actions (treasury operations)
// for transparency. Part of the mandatory decoder system that ensures all
// actions can be decoded and displayed to users before execution.
//
// IMPLEMENTATION:
// - Handles SpendAction and DepositAction for treasury management
// - Uses BCS deserialization with peel_* functions
// - Security validation via validate_all_bytes_consumed()
// - Returns vector<HumanReadableField> for universal display
// ============================================================================

/// Decoder for vault actions - tightly coupled with vault action definitions
/// This module knows exactly how to decode SpendAction and DepositAction
module account_actions::vault_decoder;

use account_actions::vault::{
    SpendAction,
    DepositAction,
    ToggleStreamPauseAction,
    ToggleStreamFreezeAction
};
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::dynamic_object_field;
use sui::object::{Self, UID};

// === Imports ===

// === Decoder Objects ===

/// Decoder that knows how to decode SpendAction<CoinType>
public struct SpendActionDecoder has key, store {
    id: UID,
}

/// Decoder that knows how to decode DepositAction<CoinType>
public struct DepositActionDecoder has key, store {
    id: UID,
}

/// Decoder for ToggleStreamPauseAction
public struct ToggleStreamPauseActionDecoder has key, store {
    id: UID,
}

/// Decoder for ToggleStreamFreezeAction
public struct ToggleStreamFreezeActionDecoder has key, store {
    id: UID,
}

// === Placeholder for Generic Registration ===

/// Placeholder type for registering generic decoders
public struct CoinPlaceholder has drop, store {}

// === Decoder Functions ===

/// Decode a SpendAction from BCS bytes to human-readable fields
public fun decode_spend_action<CoinType>(
    _decoder: &SpendActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    // Deserialize the fields directly - DO NOT reconstruct the Action struct
    let mut bcs_data = bcs::new(action_data);
    let name = bcs::peel_vec_u8(&mut bcs_data).to_string();
    let amount = bcs::peel_u64(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector::empty();

    // Extract and convert each field
    fields.push_back(
        schema::new_field(
            b"name".to_string(),
            name,
            b"String".to_string(),
        ),
    );

    fields.push_back(
        schema::new_field(
            b"amount".to_string(),
            amount.to_string(),
            b"u64".to_string(),
        ),
    );

    fields
}

/// Decode a DepositAction from BCS bytes to human-readable fields
public fun decode_deposit_action<CoinType>(
    _decoder: &DepositActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    // Deserialize the fields directly - DO NOT reconstruct the Action struct
    let mut bcs_data = bcs::new(action_data);
    let name = bcs::peel_vec_u8(&mut bcs_data).to_string();
    let amount = bcs::peel_u64(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector::empty();

    fields.push_back(
        schema::new_field(
            b"name".to_string(),
            name,
            b"String".to_string(),
        ),
    );

    fields.push_back(
        schema::new_field(
            b"amount".to_string(),
            amount.to_string(),
            b"u64".to_string(),
        ),
    );

    fields
}

/// Decode a ToggleStreamPauseAction
public fun decode_toggle_stream_pause_action(
    _decoder: &ToggleStreamPauseActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let vault_name = bcs::peel_vec_u8(&mut bcs_data).to_string();
    let stream_id_address = bcs::peel_address(&mut bcs_data);
    let stream_id = object::id_from_address(stream_id_address);
    let pause_duration_ms = bcs::peel_u64(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"vault_name".to_string(),
            vault_name,
            b"String".to_string(),
        ),
        schema::new_field(
            b"stream_id".to_string(),
            stream_id.id_to_address().to_string(),
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

/// Decode a ToggleStreamFreezeAction
public fun decode_toggle_stream_freeze_action(
    _decoder: &ToggleStreamFreezeActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let vault_name = bcs::peel_vec_u8(&mut bcs_data).to_string();
    let stream_id_address = bcs::peel_address(&mut bcs_data);
    let stream_id = object::id_from_address(stream_id_address);
    let freeze = bcs::peel_bool(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"vault_name".to_string(),
            vault_name,
            b"String".to_string(),
        ),
        schema::new_field(
            b"stream_id".to_string(),
            stream_id.id_to_address().to_string(),
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

/// Register all vault decoders in the registry
/// Called once during protocol initialization
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    register_spend_decoder(registry, ctx);
    register_deposit_decoder(registry, ctx);
    register_toggle_stream_pause_decoder(registry, ctx);
    register_toggle_stream_freeze_decoder(registry, ctx);
}

/// Register the SpendAction decoder
fun register_spend_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = SpendActionDecoder {
        id: object::new(ctx),
    };

    // Use placeholder for generic registration
    let type_key = type_name::with_defining_ids<SpendAction<CoinPlaceholder>>();

    // Attach decoder as dynamic object field
    dynamic_object_field::add(
        schema::registry_id_mut(registry),
        type_key,
        decoder,
    );
}

/// Register the DepositAction decoder
fun register_deposit_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = DepositActionDecoder {
        id: object::new(ctx),
    };

    let type_key = type_name::with_defining_ids<DepositAction<CoinPlaceholder>>();

    dynamic_object_field::add(
        schema::registry_id_mut(registry),
        type_key,
        decoder,
    );
}

/// Register the ToggleStreamPauseAction decoder
fun register_toggle_stream_pause_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ToggleStreamPauseActionDecoder {
        id: object::new(ctx),
    };

    let type_key = type_name::with_defining_ids<ToggleStreamPauseAction>();

    dynamic_object_field::add(
        schema::registry_id_mut(registry),
        type_key,
        decoder,
    );
}

/// Register the ToggleStreamFreezeAction decoder
fun register_toggle_stream_freeze_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ToggleStreamFreezeActionDecoder {
        id: object::new(ctx),
    };

    let type_key = type_name::with_defining_ids<ToggleStreamFreezeAction>();

    dynamic_object_field::add(
        schema::registry_id_mut(registry),
        type_key,
        decoder,
    );
}

// === Verification Functions ===

/// Check if a SpendAction decoder is registered
public fun has_spend_decoder(registry: &ActionDecoderRegistry): bool {
    let type_key = type_name::with_defining_ids<SpendAction<CoinPlaceholder>>();
    dynamic_object_field::exists_(schema::registry_id(registry), type_key)
}

/// Check if a DepositAction decoder is registered
public fun has_deposit_decoder(registry: &ActionDecoderRegistry): bool {
    let type_key = type_name::with_defining_ids<DepositAction<CoinPlaceholder>>();
    dynamic_object_field::exists_(schema::registry_id(registry), type_key)
}
