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

// === Imports ===

use std::{string::String, type_name};
use sui::{object::{Self, UID}, dynamic_object_field, bcs};
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use account_actions::vault::{SpendAction, DepositAction};

// === Decoder Objects ===

/// Decoder that knows how to decode SpendAction<CoinType>
public struct SpendActionDecoder has key, store {
    id: UID,
}

/// Decoder that knows how to decode DepositAction<CoinType>
public struct DepositActionDecoder has key, store {
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
    fields.push_back(schema::new_field(
        b"name".to_string(),
        name,
        b"String".to_string(),
    ));

    fields.push_back(schema::new_field(
        b"amount".to_string(),
        amount.to_string(),
        b"u64".to_string(),
    ));

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

    fields.push_back(schema::new_field(
        b"name".to_string(),
        name,
        b"String".to_string(),
    ));

    fields.push_back(schema::new_field(
        b"amount".to_string(),
        amount.to_string(),
        b"u64".to_string(),
    ));

    fields
}

// === Registration Functions ===

/// Register all vault decoders in the registry
/// Called once during protocol initialization
public fun register_decoders(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    register_spend_decoder(registry, ctx);
    register_deposit_decoder(registry, ctx);
}

/// Register the SpendAction decoder
fun register_spend_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
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
fun register_deposit_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
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