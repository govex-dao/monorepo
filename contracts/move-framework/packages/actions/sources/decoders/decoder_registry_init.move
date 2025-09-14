// ============================================================================
// FORK ADDITION - Decoder Registry Initialization
// ============================================================================
// NEW FILE added to the fork for decoder system initialization.
//
// PURPOSE:
// Central initialization point for all action decoders. Creates and shares
// the global ActionDecoderRegistry during protocol deployment.
//
// ARCHITECTURE:
// - Creates single, globally shared ActionDecoderRegistry
// - Registers all decoder modules in one place
// - Provides admin capability for future decoder updates
// - Ensures mandatory decoder availability for all actions
//
// DESIGN DECISION:
// Registry is a shared object with well-known address, NOT tied to
// individual accounts. This ensures universal decoder availability.
// ============================================================================

/// Main decoder registry initialization module
/// Registers all decoders during protocol deployment
module account_actions::decoder_registry_init;

// === Imports ===

use sui::{transfer, object};
use account_protocol::schema::{Self, ActionDecoderRegistry};
use account_actions::{
    vault_decoder,
    currency_decoder,
    package_upgrade_decoder,
    vesting_decoder,
    transfer_decoder,
    kiosk_decoder,
    access_control_decoder,
};

// === Structs ===

/// Admin capability for decoder management
public struct DecoderAdminCap has key, store {
    id: UID,
}

// === Init Function ===

/// Initialize the decoder registry with all action decoders
/// This is called once during protocol deployment
fun init(ctx: &mut TxContext) {
    // Create the decoder registry
    let mut registry = schema::init_registry(ctx);

    // Register all decoders
    register_all_decoders(&mut registry, ctx);

    // Share the registry for public access
    transfer::public_share_object(registry);

    // Create admin capability
    let admin_cap = DecoderAdminCap {
        id: object::new(ctx),
    };
    transfer::transfer(admin_cap, ctx.sender());
}

// === Public Functions ===

/// Register all decoders from all action modules
public fun register_all_decoders(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    // Register vault action decoders
    vault_decoder::register_decoders(registry, ctx);

    // Register currency action decoders
    currency_decoder::register_decoders(registry, ctx);

    // Register package upgrade decoders
    package_upgrade_decoder::register_decoders(registry, ctx);

    // Register vesting action decoders
    vesting_decoder::register_decoders(registry, ctx);

    // Register transfer action decoders
    transfer_decoder::register_decoders(registry, ctx);

    // Register kiosk action decoders
    kiosk_decoder::register_decoders(registry, ctx);

    // Register access control action decoders
    access_control_decoder::register_decoders(registry, ctx);
}

/// Get the ID of a decoder registry (for storing in Account)
public fun get_registry_id(registry: &ActionDecoderRegistry): ID {
    object::id(registry)
}

/// Update decoders (requires admin capability)
public fun update_decoders(
    registry: &mut ActionDecoderRegistry,
    _admin_cap: &DecoderAdminCap,
    ctx: &mut TxContext,
) {
    // This allows re-registration of decoders after updates
    register_all_decoders(registry, ctx);
}