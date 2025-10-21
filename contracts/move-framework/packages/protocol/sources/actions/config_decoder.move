// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Decoder registry for account configuration actions
///
/// This module provides lightweight decoder structs for UX validation.
/// Actual BCS decoding happens off-chain in TypeScript/indexers.
module account_protocol::config_decoder;

// === Decoder Objects ===

/// Decoder for ConfigDepsAction
/// Registered to enable assert_decoder_exists() validation
public struct ConfigDepsActionDecoder has key, store {
    id: UID,
}

/// Decoder for ToggleUnverifiedAllowedAction
public struct ToggleUnverifiedAllowedActionDecoder has key, store {
    id: UID,
}

/// Decoder for ConfigureDepositsAction
public struct ConfigureDepositsActionDecoder has key, store {
    id: UID,
}

/// Decoder for ManageWhitelistAction
public struct ManageWhitelistActionDecoder has key, store {
    id: UID,
}

// === Registration Functions ===

/// Register all config action decoders
public fun register_decoders(registry: &mut account_protocol::schema::ActionDecoderRegistry, ctx: &mut TxContext) {
    register_config_deps_decoder(registry, ctx);
    register_toggle_unverified_decoder(registry, ctx);
    register_configure_deposits_decoder(registry, ctx);
    register_manage_whitelist_decoder(registry, ctx);
}

/// Register ConfigDepsAction decoder
fun register_config_deps_decoder(
    registry: &mut account_protocol::schema::ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    use account_protocol::config;

    let decoder = ConfigDepsActionDecoder { id: object::new(ctx) };
    // Register with the ACTION TYPE MARKER, not the action data struct
    // This is what gets stored in ActionSpec.action_type
    let type_key = std::type_name::with_defining_ids<config::ConfigUpdateDeps>();

    sui::dynamic_object_field::add(
        account_protocol::schema::registry_id_mut(registry),
        type_key,
        decoder
    );
}

/// Register ToggleUnverifiedAllowedAction decoder
fun register_toggle_unverified_decoder(
    registry: &mut account_protocol::schema::ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    use account_protocol::config;

    let decoder = ToggleUnverifiedAllowedActionDecoder { id: object::new(ctx) };
    // Register with the ACTION TYPE MARKER
    let type_key = std::type_name::with_defining_ids<config::ConfigToggleUnverified>();

    sui::dynamic_object_field::add(
        account_protocol::schema::registry_id_mut(registry),
        type_key,
        decoder
    );
}

/// Register ConfigureDepositsAction decoder
fun register_configure_deposits_decoder(
    registry: &mut account_protocol::schema::ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    use account_protocol::config;

    let decoder = ConfigureDepositsActionDecoder { id: object::new(ctx) };
    // Register with the ACTION TYPE MARKER
    let type_key = std::type_name::with_defining_ids<config::ConfigUpdateDeposits>();

    sui::dynamic_object_field::add(
        account_protocol::schema::registry_id_mut(registry),
        type_key,
        decoder
    );
}

/// Register ManageWhitelistAction decoder
fun register_manage_whitelist_decoder(
    registry: &mut account_protocol::schema::ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    use account_protocol::config;

    let decoder = ManageWhitelistActionDecoder { id: object::new(ctx) };
    // Register with the ACTION TYPE MARKER
    let type_key = std::type_name::with_defining_ids<config::ConfigManageWhitelist>();

    sui::dynamic_object_field::add(
        account_protocol::schema::registry_id_mut(registry),
        type_key,
        decoder
    );
}
