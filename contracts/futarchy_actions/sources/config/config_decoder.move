// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Decoder for configuration actions in futarchy DAOs
module futarchy_actions::config_decoder;

use account_protocol::schema::{Self as schema, ActionDecoderRegistry};
use futarchy_actions::config_actions::{
    SetProposalsEnabledAction,
    UpdateNameAction,
    TradingParamsUpdateAction,
    MetadataUpdateAction,
    TwapConfigUpdateAction,
    GovernanceUpdateAction,
    MetadataTableUpdateAction,
    SlashDistributionUpdateAction,
    QueueParamsUpdateAction,
    StorageConfigUpdateAction,
    ConditionalMetadataUpdateAction,
    EarlyResolveConfigUpdateAction,
    SponsorshipConfigUpdateAction,
    ConfigAction
};
use futarchy_actions::quota_decoder;
use std::type_name;
use sui::dynamic_object_field;
use sui::object::{Self, UID};

// === Decoder Objects ===

/// Decoder for SetProposalsEnabledAction
public struct SetProposalsEnabledActionDecoder has key, store {
    id: UID,
}

/// Decoder for UpdateNameAction
public struct UpdateNameActionDecoder has key, store {
    id: UID,
}

/// Decoder for TradingParamsUpdateAction
public struct TradingParamsUpdateActionDecoder has key, store {
    id: UID,
}

/// Decoder for MetadataUpdateAction
public struct MetadataUpdateActionDecoder has key, store {
    id: UID,
}

/// Decoder for TwapConfigUpdateAction
public struct TwapConfigUpdateActionDecoder has key, store {
    id: UID,
}

/// Decoder for GovernanceUpdateAction
public struct GovernanceUpdateActionDecoder has key, store {
    id: UID,
}

/// Decoder for MetadataTableUpdateAction
public struct MetadataTableUpdateActionDecoder has key, store {
    id: UID,
}

/// Decoder for SlashDistributionUpdateAction
public struct SlashDistributionUpdateActionDecoder has key, store {
    id: UID,
}

/// Decoder for QueueParamsUpdateAction
public struct QueueParamsUpdateActionDecoder has key, store {
    id: UID,
}

/// Decoder for StorageConfigUpdateAction
public struct StorageConfigUpdateActionDecoder has key, store {
    id: UID,
}

/// Decoder for ConditionalMetadataUpdateAction
public struct ConditionalMetadataUpdateActionDecoder has key, store {
    id: UID,
}

/// Decoder for EarlyResolveConfigUpdateAction
public struct EarlyResolveConfigUpdateActionDecoder has key, store {
    id: UID,
}

/// Decoder for SponsorshipConfigUpdateAction
public struct SponsorshipConfigUpdateActionDecoder has key, store {
    id: UID,
}

/// Decoder for ConfigAction
public struct ConfigActionDecoder has key, store {
    id: UID,
}

// === Registration Functions ===

/// Register all config decoders
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    register_set_proposals_enabled_decoder(registry, ctx);
    register_update_name_decoder(registry, ctx);
    register_trading_params_decoder(registry, ctx);
    register_metadata_decoder(registry, ctx);
    register_twap_config_decoder(registry, ctx);
    register_governance_decoder(registry, ctx);
    register_metadata_table_decoder(registry, ctx);
    register_slash_distribution_decoder(registry, ctx);
    register_queue_params_decoder(registry, ctx);
    register_storage_config_decoder(registry, ctx);
    register_conditional_metadata_decoder(registry, ctx);
    register_early_resolve_config_decoder(registry, ctx);
    register_sponsorship_config_decoder(registry, ctx);
    register_config_action_decoder(registry, ctx);

    // Register quota decoders
    quota_decoder::register_decoders(registry, ctx);
}

fun register_set_proposals_enabled_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = SetProposalsEnabledActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<SetProposalsEnabledAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_update_name_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = UpdateNameActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<UpdateNameAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_trading_params_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = TradingParamsUpdateActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<TradingParamsUpdateAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_metadata_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = MetadataUpdateActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<MetadataUpdateAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_twap_config_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = TwapConfigUpdateActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<TwapConfigUpdateAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_governance_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = GovernanceUpdateActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<GovernanceUpdateAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_metadata_table_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = MetadataTableUpdateActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<MetadataTableUpdateAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_slash_distribution_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = SlashDistributionUpdateActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<SlashDistributionUpdateAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_queue_params_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = QueueParamsUpdateActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<QueueParamsUpdateAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_storage_config_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = StorageConfigUpdateActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<StorageConfigUpdateAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_conditional_metadata_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ConditionalMetadataUpdateActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<ConditionalMetadataUpdateAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_early_resolve_config_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = EarlyResolveConfigUpdateActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<EarlyResolveConfigUpdateAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_sponsorship_config_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = SponsorshipConfigUpdateActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<SponsorshipConfigUpdateAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_config_action_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = ConfigActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<ConfigAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
