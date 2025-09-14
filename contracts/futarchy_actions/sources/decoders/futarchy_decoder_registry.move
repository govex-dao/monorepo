/// Main decoder registry initialization module for Futarchy protocol
/// Creates and shares the global ActionDecoderRegistry for all futarchy actions
module futarchy_actions::futarchy_decoder_registry;

// === Imports ===

use sui::{transfer, object};
use account_protocol::schema::{Self, ActionDecoderRegistry};
use futarchy_actions::{
    config_decoder,
    liquidity_decoder,
    governance_decoder,
    memo_decoder,
    platform_fee_decoder,
    protocol_admin_decoder,
    founder_lock_decoder,
};
use futarchy_lifecycle::{
    dissolution_decoder,
    oracle_decoder,
    stream_decoder,
};
use futarchy_specialized_actions::{
    operating_agreement_decoder,
    governance_specialized_decoder,
};
use futarchy_vault::custody_decoder;
use futarchy_multisig::{
    security_council_decoder,
    policy_decoder,
};

// === Structs ===

/// Admin capability for futarchy decoder management
public struct FutarchyDecoderAdminCap has key, store {
    id: UID,
}

// === Init Function ===

/// Initialize the futarchy decoder registry with all action decoders
/// This is called once during protocol deployment
fun init(ctx: &mut TxContext) {
    // Create the decoder registry
    let mut registry = schema::init_registry(ctx);

    // Register all futarchy decoders
    register_all_futarchy_decoders(&mut registry, ctx);

    // Share the registry for public access
    transfer::public_share_object(registry);

    // Create admin capability
    let admin_cap = FutarchyDecoderAdminCap {
        id: object::new(ctx),
    };
    transfer::transfer(admin_cap, ctx.sender());
}

// === Public Functions ===

/// Register all decoders from all futarchy action modules
public fun register_all_futarchy_decoders(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    // === Futarchy Actions Package ===

    // Register config action decoders
    config_decoder::register_decoders(registry, ctx);

    // Register liquidity action decoders
    liquidity_decoder::register_decoders(registry, ctx);

    // Register governance action decoders
    governance_decoder::register_decoders(registry, ctx);

    // Register memo action decoders
    memo_decoder::register_decoders(registry, ctx);

    // Register platform fee action decoders
    platform_fee_decoder::register_decoders(registry, ctx);

    // Register protocol admin action decoders
    protocol_admin_decoder::register_decoders(registry, ctx);

    // Register founder lock action decoders
    founder_lock_decoder::register_decoders(registry, ctx);

    // === Futarchy Lifecycle Package ===

    // Register dissolution action decoders
    dissolution_decoder::register_decoders(registry, ctx);

    // Register oracle action decoders
    oracle_decoder::register_decoders(registry, ctx);

    // Register stream action decoders
    stream_decoder::register_decoders(registry, ctx);

    // === Futarchy Specialized Actions Package ===

    // Register operating agreement action decoders
    operating_agreement_decoder::register_decoders(registry, ctx);

    // Register specialized governance action decoders
    governance_specialized_decoder::register_decoders(registry, ctx);

    // === Futarchy Vault Package ===

    // Register custody action decoders
    custody_decoder::register_decoders(registry, ctx);

    // === Futarchy Multisig Package ===

    // Register security council action decoders
    security_council_decoder::register_decoders(registry, ctx);

    // Register policy action decoders
    policy_decoder::register_decoders(registry, ctx);
}

/// Get the ID of a decoder registry (for storing references)
public fun get_registry_id(registry: &ActionDecoderRegistry): ID {
    object::id(registry)
}

/// Update decoders (requires admin capability)
public fun update_decoders(
    registry: &mut ActionDecoderRegistry,
    _admin_cap: &FutarchyDecoderAdminCap,
    ctx: &mut TxContext,
) {
    // This allows re-registration of decoders after updates
    register_all_futarchy_decoders(registry, ctx);
}