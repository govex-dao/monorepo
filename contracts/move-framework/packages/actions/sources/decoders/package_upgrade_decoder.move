// ============================================================================
// FORK ADDITION - Package Upgrade Action Decoder
// ============================================================================
// NEW FILE added to the fork for on-chain action decoding.
//
// PURPOSE:
// Provides human-readable decoding of package upgrade actions for transparency.
// Critical for DAO governance to understand contract upgrade proposals.
//
// IMPLEMENTATION:
// - Handles UpgradeAction and RestrictAction for package management
// - Decodes digest (32 bytes) and policy fields
// - Uses BCS deserialization with security validation
// - Returns vector<HumanReadableField> for universal display
// ============================================================================

/// Decoder for package upgrade actions
module account_actions::package_upgrade_decoder;

// === Imports ===

use std::{string::String, type_name, vector};
use sui::{object::{Self, UID}, dynamic_object_field, bcs};
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use account_actions::package_upgrade::{UpgradeAction, CommitAction, RestrictAction};

// === Decoder Objects ===

/// Decoder for UpgradeAction
public struct UpgradeActionDecoder has key, store {
    id: UID,
}

/// Decoder for CommitAction
public struct CommitActionDecoder has key, store {
    id: UID,
}

/// Decoder for RestrictAction
public struct RestrictActionDecoder has key, store {
    id: UID,
}

// === Decoder Functions ===

/// Decode an UpgradeAction
public fun decode_upgrade_action(
    _decoder: &UpgradeActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let name = bcs::peel_vec_u8(&mut bcs_data).to_string();
    let digest = bcs::peel_vec_u8(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector::empty();

    fields.push_back(schema::new_field(
        b"name".to_string(),
        name,
        b"String".to_string(),
    ));

    // Convert digest bytes to hex string for readability
    fields.push_back(schema::new_field(
        b"digest".to_string(),
        bytes_to_hex_string(digest),
        b"vector<u8>".to_string(),
    ));

    fields
}

/// Decode a CommitAction
public fun decode_commit_action(
    _decoder: &CommitActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let name = bcs::peel_vec_u8(&mut bcs_data).to_string();

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"name".to_string(),
            name,
            b"String".to_string(),
        )
    ]
}

/// Decode a RestrictAction
public fun decode_restrict_action(
    _decoder: &RestrictActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let name = bcs::peel_vec_u8(&mut bcs_data).to_string();
    let policy = bcs::peel_u8(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector::empty();

    fields.push_back(schema::new_field(
        b"name".to_string(),
        name,
        b"String".to_string(),
    ));

    // Convert policy u8 to human-readable string
    let policy_str = if (policy == 0) {
        b"compatible"
    } else if (policy == 128) {
        b"additive"
    } else if (policy == 192) {
        b"dependency-only"
    } else if (policy == 255) {
        b"immutable"
    } else {
        b"unknown"
    };

    fields.push_back(schema::new_field(
        b"policy".to_string(),
        policy_str.to_string(),
        b"u8".to_string(),
    ));

    fields
}

// === Helper Functions ===

/// Convert bytes to hex string for display
fun bytes_to_hex_string(bytes: vector<u8>): String {
    let hex_chars = b"0123456789abcdef";
    let mut result = vector::empty<u8>();

    let mut i = 0;
    let len = bytes.length();
    while (i < len && i < 8) { // Show first 8 bytes for brevity
        let byte = bytes[i];
        result.push_back(hex_chars[(byte >> 4) as u64]);
        result.push_back(hex_chars[(byte & 0x0f) as u64]);
        i = i + 1;
    };

    if (len > 8) {
        result.append(b"...");
    };

    result.to_string()
}

// === Registration Functions ===

/// Register all package upgrade decoders
public fun register_decoders(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    register_upgrade_decoder(registry, ctx);
    register_commit_decoder(registry, ctx);
    register_restrict_decoder(registry, ctx);
}

fun register_upgrade_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = UpgradeActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<UpgradeAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_commit_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CommitActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<CommitAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_restrict_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = RestrictActionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<RestrictAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}