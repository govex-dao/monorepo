// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Decoder for protocol admin actions in futarchy DAOs
module futarchy_governance_actions::protocol_admin_decoder;

use account_protocol::schema::{Self as schema, ActionDecoderRegistry};
use futarchy_governance_actions::protocol_admin_actions::{
    SetFactoryPausedAction,
    AddStableTypeAction,
    RemoveStableTypeAction,
    UpdateDaoCreationFeeAction,
    UpdateProposalFeeAction,
    UpdateVerificationFeeAction,
    AddVerificationLevelAction,
    RemoveVerificationLevelAction,
    RequestVerificationAction,
    ApproveVerificationAction,
    RejectVerificationAction,
    SetLaunchpadTrustScoreAction,
    UpdateRecoveryFeeAction,
    WithdrawFeesToTreasuryAction
};
use std::type_name;
use sui::dynamic_object_field;
use sui::object::{Self, UID};

// === Decoder Objects ===

/// Decoder for SetFactoryPausedAction
public struct SetFactoryPausedActionDecoder has key, store {
    id: UID,
}

/// Decoder for AddStableTypeAction
public struct AddStableTypeActionDecoder has key, store {
    id: UID,
}

/// Decoder for RemoveStableTypeAction
public struct RemoveStableTypeActionDecoder has key, store {
    id: UID,
}

/// Decoder for UpdateDaoCreationFeeAction
public struct UpdateDaoCreationFeeActionDecoder has key, store {
    id: UID,
}

/// Decoder for UpdateProposalFeeAction
public struct UpdateProposalFeeActionDecoder has key, store {
    id: UID,
}

/// Decoder for UpdateVerificationFeeAction
public struct UpdateVerificationFeeActionDecoder has key, store {
    id: UID,
}

/// Decoder for AddVerificationLevelAction
public struct AddVerificationLevelActionDecoder has key, store {
    id: UID,
}

/// Decoder for RemoveVerificationLevelAction
public struct RemoveVerificationLevelActionDecoder has key, store {
    id: UID,
}

/// Decoder for RequestVerificationAction
public struct RequestVerificationActionDecoder has key, store {
    id: UID,
}

/// Decoder for ApproveVerificationAction
public struct ApproveVerificationActionDecoder has key, store {
    id: UID,
}

/// Decoder for RejectVerificationAction
public struct RejectVerificationActionDecoder has key, store {
    id: UID,
}

/// Decoder for SetLaunchpadTrustScoreAction
public struct SetLaunchpadTrustScoreActionDecoder has key, store {
    id: UID,
}

/// Decoder for UpdateRecoveryFeeAction
public struct UpdateRecoveryFeeActionDecoder has key, store {
    id: UID,
}

/// Decoder for WithdrawFeesToTreasuryAction
public struct WithdrawFeesToTreasuryActionDecoder has key, store {
    id: UID,
}


// === Registration Functions ===

/// Register all protocol admin decoders
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    register_set_factory_paused_decoder(registry, ctx);
    register_add_stable_type_decoder(registry, ctx);
    register_remove_stable_type_decoder(registry, ctx);
    register_update_dao_creation_fee_decoder(registry, ctx);
    register_update_proposal_fee_decoder(registry, ctx);
    register_update_verification_fee_decoder(registry, ctx);
    register_add_verification_level_decoder(registry, ctx);
    register_remove_verification_level_decoder(registry, ctx);
    register_request_verification_decoder(registry, ctx);
    register_approve_verification_decoder(registry, ctx);
    register_reject_verification_decoder(registry, ctx);
    register_set_launchpad_trust_score_decoder(registry, ctx);
    register_update_recovery_fee_decoder(registry, ctx);
    register_withdraw_fees_to_treasury_decoder(registry, ctx);
}

fun register_set_factory_paused_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = SetFactoryPausedActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<SetFactoryPausedAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_add_stable_type_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = AddStableTypeActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<AddStableTypeAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_remove_stable_type_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = RemoveStableTypeActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<RemoveStableTypeAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_update_dao_creation_fee_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = UpdateDaoCreationFeeActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<UpdateDaoCreationFeeAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_update_proposal_fee_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = UpdateProposalFeeActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<UpdateProposalFeeAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_update_verification_fee_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = UpdateVerificationFeeActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<UpdateVerificationFeeAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_add_verification_level_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = AddVerificationLevelActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<AddVerificationLevelAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_remove_verification_level_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = RemoveVerificationLevelActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<RemoveVerificationLevelAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_request_verification_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = RequestVerificationActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<RequestVerificationAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_approve_verification_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ApproveVerificationActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<ApproveVerificationAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_reject_verification_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = RejectVerificationActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<RejectVerificationAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_set_launchpad_trust_score_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = SetLaunchpadTrustScoreActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<SetLaunchpadTrustScoreAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_update_recovery_fee_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = UpdateRecoveryFeeActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<UpdateRecoveryFeeAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_withdraw_fees_to_treasury_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = WithdrawFeesToTreasuryActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<WithdrawFeesToTreasuryAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
