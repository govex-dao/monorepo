// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// - Deploy once, fully configured
// - No constants to update post-deployment
// - Registry ID discoverable through multiple methods
// - Clean, professional deployment process
// ============================================================================

/// Main decoder registry initialization module
/// Registers all decoders during protocol deployment
module account_actions::decoder_registry_init;

use account_actions::access_control_decoder;
use account_actions::currency_decoder;
use account_actions::package_upgrade_decoder;
use account_actions::transfer_decoder;
use account_actions::vault_decoder;
use account_actions::vesting_decoder;
use account_protocol::schema::{Self, ActionDecoderRegistry};
use sui::event;
use sui::object::{Self, ID, UID};
use sui::transfer;

// === Imports ===

// === Events ===

/// Emitted when the registry is created, containing its ID
public struct RegistryCreated has copy, drop {
    registry_id: ID,
}

// === Structs ===

/// One-time witness for initialization
public struct DECODER_REGISTRY_INIT has drop {}

/// Registry info object that stores the registry ID
/// This is a shared object that anyone can read to get the registry ID
public struct RegistryInfo has key, store {
    id: UID,
    registry_id: ID,
}

/// Admin capability for decoder management
public struct DecoderAdminCap has key, store {
    id: UID,
}

// === Init Function ===

/// Initialize the decoder registry with all action decoders
/// This is called once during protocol deployment
fun init(witness: DECODER_REGISTRY_INIT, ctx: &mut TxContext) {
    // Create the decoder registry
    let mut registry = schema::init_registry(ctx);

    // Get the registry ID before sharing
    let registry_id = object::id(&registry);

    // Register all decoders
    register_all_decoders(&mut registry, ctx);

    // Share the registry for public access
    transfer::public_share_object(registry);

    // Create and share a RegistryInfo object that stores the registry ID
    let info = RegistryInfo {
        id: object::new(ctx),
        registry_id,
    };
    transfer::public_share_object(info);

    // Create admin capability
    let admin_cap = DecoderAdminCap {
        id: object::new(ctx),
    };
    transfer::transfer(admin_cap, ctx.sender());

    // Emit event with the registry ID for off-chain indexing
    event::emit(RegistryCreated { registry_id });
}

// === Public Functions ===

/// Get the registry ID from the shared RegistryInfo object
public fun get_registry_id(info: &RegistryInfo): ID {
    info.registry_id
}

/// Register all decoders from all action modules
public fun register_all_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
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

    // Register access control action decoders
    access_control_decoder::register_decoders(registry, ctx);
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
