/// Global decoder registry for all Futarchy protocol actions
/// This module initializes and manages the single ActionDecoderRegistry
/// that all futarchy actions register with
module futarchy_decoders::futarchy_decoder_registry;

// === Imports ===

use sui::object::{Self, ID, UID};
use sui::transfer;
use sui::event;
use account_protocol::schema::{Self, ActionDecoderRegistry};

// Registry modules for registration
use futarchy_lifecycle::payment_decoder;
use futarchy_lifecycle::stream_decoder;
use futarchy_lifecycle::oracle_decoder;
use futarchy_lifecycle::dissolution_decoder;
use futarchy_lifecycle::protocol_admin_decoder;
use futarchy_actions::config_decoder;
use futarchy_actions::liquidity_decoder;
use futarchy_actions::governance_decoder;
use futarchy_actions::memo_decoder;
use futarchy_multisig::security_council_decoder;
use futarchy_multisig::policy_decoder;
use futarchy_specialized_actions::operating_agreement_decoder;
use futarchy_vault::custody_decoder;

// Move framework decoders
use account_actions::vault_decoder;
use account_actions::currency_decoder;
use account_actions::transfer_decoder;
use account_actions::vesting_decoder;
use account_actions::package_upgrade_decoder;
use account_actions::access_control_decoder;
use account_actions::kiosk_decoder;

// === Events ===

/// Emitted when the registry is created, containing its ID
public struct RegistryCreated has copy, drop {
    registry_id: ID,
}

// === Structs ===

/// One-time witness for initialization
public struct FUTARCHY_DECODER_REGISTRY has drop {}

/// Registry info object that stores the registry ID
/// This is a shared object that anyone can read to get the registry ID
public struct RegistryInfo has key, store {
    id: UID,
    registry_id: ID,
}

// === Functions ===

/// Initialize the global decoder registry
/// This should only be called once during protocol deployment
fun init(witness: FUTARCHY_DECODER_REGISTRY, ctx: &mut TxContext) {
    // Create the registry
    let mut registry = schema::init_registry(ctx);

    // Get the registry ID before sharing
    let registry_id = object::id(&registry);

    // Register all Futarchy protocol decoders
    register_futarchy_decoders(&mut registry, ctx);

    // Register all Move framework decoders
    register_framework_decoders(&mut registry, ctx);

    // Share the registry globally
    transfer::public_share_object(registry);

    // Create and share a RegistryInfo object that stores the registry ID
    let info = RegistryInfo {
        id: object::new(ctx),
        registry_id,
    };
    transfer::public_share_object(info);

    // Emit event with the registry ID for off-chain indexing
    event::emit(RegistryCreated { registry_id });
}

/// Get the registry ID from the shared RegistryInfo object
public fun get_registry_id(info: &RegistryInfo): ID {
    info.registry_id
}

/// Register all Futarchy-specific decoders
fun register_futarchy_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    // Payment and stream decoders
    payment_decoder::register_decoders(registry, ctx);
    stream_decoder::register_decoders(registry, ctx);

    // Oracle and dissolution decoders
    oracle_decoder::register_decoders(registry, ctx);
    dissolution_decoder::register_decoders(registry, ctx);

    // Protocol admin decoders
    protocol_admin_decoder::register_decoders(registry, ctx);

    // Config and governance decoders
    config_decoder::register_decoders(registry, ctx);
    governance_decoder::register_decoders(registry, ctx);
    memo_decoder::register_decoders(registry, ctx);

    // Liquidity decoders
    liquidity_decoder::register_decoders(registry, ctx);

    // Multisig decoders
    security_council_decoder::register_decoders(registry, ctx);
    policy_decoder::register_decoders(registry, ctx);

    // Operating agreement decoder
    operating_agreement_decoder::register_decoders(registry, ctx);

    // Vault custody decoder
    custody_decoder::register_decoders(registry, ctx);
}

/// Register all Move framework decoders
fun register_framework_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    // Vault actions
    vault_decoder::register_decoders(registry, ctx);

    // Currency actions
    currency_decoder::register_decoders(registry, ctx);

    // Transfer actions
    transfer_decoder::register_decoders(registry, ctx);

    // Vesting actions
    vesting_decoder::register_decoders(registry, ctx);

    // Package upgrade actions
    package_upgrade_decoder::register_decoders(registry, ctx);

    // Access control actions
    access_control_decoder::register_decoders(registry, ctx);

    // Kiosk actions
    kiosk_decoder::register_decoders(registry, ctx);
}