/// Decoder for security council actions in futarchy DAOs
module futarchy_multisig::security_council_decoder;

// === Imports ===

use std::{string::String, type_name::{Self, TypeName}};
use sui::{object::{Self, UID}, dynamic_object_field, bcs};
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_multisig::security_council_actions::{
    UpdateCouncilMembershipAction,
    UnlockAndReturnUpgradeCapAction,
    ApproveGenericAction,
    SweepIntentsAction,
    CouncilCreateOptimisticIntentAction,
    CouncilExecuteOptimisticIntentAction,
    CouncilCancelOptimisticIntentAction,
};
use futarchy_multisig::security_council_actions_with_placeholders::{
    CreateSecurityCouncilAction,
    SetPolicyFromPlaceholderAction,
};
use futarchy_multisig::optimistic_intents::{
    CreateOptimisticIntentAction,
    ChallengeOptimisticIntentsAction,
    ExecuteOptimisticIntentAction,
    CancelOptimisticIntentAction,
    CleanupExpiredIntentsAction,
};

// === Decoder Objects ===

/// Decoder for UpdateCouncilMembershipAction
public struct UpdateCouncilMembershipActionDecoder has key, store {
    id: UID,
}

/// Decoder for UnlockAndReturnUpgradeCapAction
public struct UnlockAndReturnUpgradeCapActionDecoder has key, store {
    id: UID,
}

/// Decoder for ApproveGenericAction
public struct ApproveGenericActionDecoder has key, store {
    id: UID,
}

/// Decoder for SweepIntentsAction
public struct SweepIntentsActionDecoder has key, store {
    id: UID,
}

/// Decoder for CouncilCreateOptimisticIntentAction
public struct CouncilCreateOptimisticIntentActionDecoder has key, store {
    id: UID,
}

/// Decoder for CouncilExecuteOptimisticIntentAction
public struct CouncilExecuteOptimisticIntentActionDecoder has key, store {
    id: UID,
}

/// Decoder for CouncilCancelOptimisticIntentAction
public struct CouncilCancelOptimisticIntentActionDecoder has key, store {
    id: UID,
}

/// Decoder for CreateSecurityCouncilAction
public struct CreateSecurityCouncilActionDecoder has key, store {
    id: UID,
}

/// Decoder for SetPolicyFromPlaceholderAction
public struct SetPolicyFromPlaceholderActionDecoder has key, store {
    id: UID,
}

/// Decoder for CreateOptimisticIntentAction
public struct CreateOptimisticIntentActionDecoder has key, store {
    id: UID,
}

/// Decoder for ChallengeOptimisticIntentsAction
public struct ChallengeOptimisticIntentsActionDecoder has key, store {
    id: UID,
}

/// Decoder for ExecuteOptimisticIntentAction
public struct ExecuteOptimisticIntentActionDecoder has key, store {
    id: UID,
}

/// Decoder for CancelOptimisticIntentAction
public struct CancelOptimisticIntentActionDecoder has key, store {
    id: UID,
}

/// Decoder for CleanupExpiredIntentsAction
public struct CleanupExpiredIntentsActionDecoder has key, store {
    id: UID,
}

// === Helper Functions ===

fun decode_option_type_name(bcs_data: &mut BCS): Option<TypeName> {
    let is_some = bcs::peel_bool(bcs_data);
    if (is_some) {
        // TypeName is a struct with a name field (ASCII string)
        let type_name_bytes = bcs::peel_vec_u8(bcs_data);
        option::some(type_name::from_ascii(ascii::string(type_name_bytes)))
    } else {
        option::none()
    }
}

// === Decoder Functions ===

/// Decode an UpdateCouncilMembershipAction
public fun decode_update_council_membership_action(
    _decoder: &UpdateCouncilMembershipActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    // Read addresses to add
    let add_count = bcs::peel_vec_length(&mut bcs_data);
    let mut i = 0;
    while (i < add_count) {
        bcs::peel_address(&mut bcs_data);
        i = i + 1;
    };

    // Read addresses to remove
    let remove_count = bcs::peel_vec_length(&mut bcs_data);
    let mut j = 0;
    while (j < remove_count) {
        bcs::peel_address(&mut bcs_data);
        j = j + 1;
    };

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"addresses_to_add".to_string(),
            add_count.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"addresses_to_remove".to_string(),
            remove_count.to_string(),
            b"u64".to_string(),
        ),
    ]
}

/// Decode an UnlockAndReturnUpgradeCapAction
public fun decode_unlock_and_return_upgrade_cap_action(
    _decoder: &UnlockAndReturnUpgradeCapActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let upgrade_cap_id = bcs::peel_address(&mut bcs_data);
    let new_policy = bcs::peel_u8(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let policy_str = if (new_policy == 0) {
        b"Immutable"
    } else if (new_policy == 128) {
        b"Compatible"
    } else {
        b"Additive"
    };

    vector[
        schema::new_field(
            b"upgrade_cap_id".to_string(),
            upgrade_cap_id.to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"new_policy".to_string(),
            policy_str.to_string(),
            b"String".to_string(),
        ),
    ]
}

/// Decode an ApproveGenericAction
public fun decode_approve_generic_action(
    _decoder: &ApproveGenericActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let proposal_id = bcs::peel_address(&mut bcs_data);
    let action_index = bcs::peel_u64(&mut bcs_data);
    let approval_note = bcs::peel_vec_u8(&mut bcs_data).to_string();

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"proposal_id".to_string(),
            proposal_id.to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"action_index".to_string(),
            action_index.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"approval_note".to_string(),
            approval_note,
            b"String".to_string(),
        ),
    ]
}

/// Decode a SweepIntentsAction
public fun decode_sweep_intents_action(
    _decoder: &SweepIntentsActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    // Read intent keys vector
    let keys_count = bcs::peel_vec_length(&mut bcs_data);
    let mut i = 0;
    while (i < keys_count) {
        bcs::peel_vec_u8(&mut bcs_data); // Each key is a string
        i = i + 1;
    };

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"intent_keys_count".to_string(),
            keys_count.to_string(),
            b"u64".to_string(),
        ),
    ]
}

/// Decode a CouncilCreateOptimisticIntentAction
public fun decode_council_create_optimistic_intent_action(
    _decoder: &CouncilCreateOptimisticIntentActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let intent_key = bcs::peel_vec_u8(&mut bcs_data).to_string();
    let challenge_period_ms = bcs::peel_u64(&mut bcs_data);
    let description = bcs::peel_vec_u8(&mut bcs_data).to_string();

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"intent_key".to_string(),
            intent_key,
            b"String".to_string(),
        ),
        schema::new_field(
            b"challenge_period_ms".to_string(),
            challenge_period_ms.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"description".to_string(),
            description,
            b"String".to_string(),
        ),
    ]
}

/// Decode a CouncilExecuteOptimisticIntentAction
public fun decode_council_execute_optimistic_intent_action(
    _decoder: &CouncilExecuteOptimisticIntentActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let intent_id = bcs::peel_address(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"intent_id".to_string(),
            intent_id.to_string(),
            b"ID".to_string(),
        ),
    ]
}

/// Decode a CouncilCancelOptimisticIntentAction
public fun decode_council_cancel_optimistic_intent_action(
    _decoder: &CouncilCancelOptimisticIntentActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let intent_id = bcs::peel_address(&mut bcs_data);
    let reason = bcs::peel_vec_u8(&mut bcs_data).to_string();

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"intent_id".to_string(),
            intent_id.to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"reason".to_string(),
            reason,
            b"String".to_string(),
        ),
    ]
}

/// Decode a CreateSecurityCouncilAction
public fun decode_create_security_council_action(
    _decoder: &CreateSecurityCouncilActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    // Read members vector
    let members_count = bcs::peel_vec_length(&mut bcs_data);
    let mut i = 0;
    while (i < members_count) {
        bcs::peel_address(&mut bcs_data);
        i = i + 1;
    };

    let threshold = bcs::peel_u64(&mut bcs_data);
    let challenge_period_ms = bcs::peel_u64(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"members_count".to_string(),
            members_count.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"threshold".to_string(),
            threshold.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"challenge_period_ms".to_string(),
            challenge_period_ms.to_string(),
            b"u64".to_string(),
        ),
    ]
}

/// Decode a SetPolicyFromPlaceholderAction
public fun decode_set_policy_from_placeholder_action(
    _decoder: &SetPolicyFromPlaceholderActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let policy_type = bcs::peel_u8(&mut bcs_data);
    let type_name = decode_option_type_name(&mut bcs_data);
    let approval_type = bcs::peel_u8(&mut bcs_data);
    let council_index = bcs::peel_u64(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let policy_type_str = if (policy_type == 0) {
        b"Type"
    } else {
        b"Object"
    };

    let approval_type_str = if (approval_type == 0) {
        b"DaoOnly"
    } else if (approval_type == 1) {
        b"CouncilOnly"
    } else if (approval_type == 2) {
        b"DaoOrCouncil"
    } else {
        b"DaoAndCouncil"
    };

    let mut fields = vector[
        schema::new_field(
            b"policy_type".to_string(),
            policy_type_str.to_string(),
            b"String".to_string(),
        ),
        schema::new_field(
            b"approval_type".to_string(),
            approval_type_str.to_string(),
            b"String".to_string(),
        ),
        schema::new_field(
            b"council_index".to_string(),
            council_index.to_string(),
            b"u64".to_string(),
        ),
    ];

    if (type_name.is_some()) {
        let name = type_name.destroy_some();
        fields.push_back(schema::new_field(
            b"type_name".to_string(),
            type_name::into_string(name).into_bytes().to_string(),
            b"TypeName".to_string(),
        ));
    } else {
        type_name.destroy_none();
    };

    fields
}

/// Decode a CreateOptimisticIntentAction
public fun decode_create_optimistic_intent_action(
    _decoder: &CreateOptimisticIntentActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let intent_key = bcs::peel_vec_u8(&mut bcs_data).to_string();
    let description = bcs::peel_vec_u8(&mut bcs_data).to_string();

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"intent_key".to_string(),
            intent_key,
            b"String".to_string(),
        ),
        schema::new_field(
            b"description".to_string(),
            description,
            b"String".to_string(),
        ),
    ]
}

/// Decode a ChallengeOptimisticIntentsAction
public fun decode_challenge_optimistic_intents_action(
    _decoder: &ChallengeOptimisticIntentsActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    // Read intent IDs vector
    let ids_count = bcs::peel_vec_length(&mut bcs_data);
    let mut i = 0;
    while (i < ids_count) {
        bcs::peel_address(&mut bcs_data);
        i = i + 1;
    };

    let reason = bcs::peel_vec_u8(&mut bcs_data).to_string();

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"intent_ids_count".to_string(),
            ids_count.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"reason".to_string(),
            reason,
            b"String".to_string(),
        ),
    ]
}

/// Decode an ExecuteOptimisticIntentAction
public fun decode_execute_optimistic_intent_action(
    _decoder: &ExecuteOptimisticIntentActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let intent_id = bcs::peel_address(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"intent_id".to_string(),
            intent_id.to_string(),
            b"ID".to_string(),
        ),
    ]
}

/// Decode a CancelOptimisticIntentAction
public fun decode_cancel_optimistic_intent_action(
    _decoder: &CancelOptimisticIntentActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let intent_id = bcs::peel_address(&mut bcs_data);
    let reason = bcs::peel_vec_u8(&mut bcs_data).to_string();

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"intent_id".to_string(),
            intent_id.to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"reason".to_string(),
            reason,
            b"String".to_string(),
        ),
    ]
}

/// Decode a CleanupExpiredIntentsAction
public fun decode_cleanup_expired_intents_action(
    _decoder: &CleanupExpiredIntentsActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let max_cleanup = bcs::peel_u64(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"max_cleanup".to_string(),
            max_cleanup.to_string(),
            b"u64".to_string(),
        ),
    ]
}

// === Registration Functions ===

/// Register all security council decoders
public fun register_decoders(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    // Security council actions
    register_update_council_membership_decoder(registry, ctx);
    register_unlock_and_return_upgrade_cap_decoder(registry, ctx);
    register_approve_generic_decoder(registry, ctx);
    register_sweep_intents_decoder(registry, ctx);
    register_council_create_optimistic_intent_decoder(registry, ctx);
    register_council_execute_optimistic_intent_decoder(registry, ctx);
    register_council_cancel_optimistic_intent_decoder(registry, ctx);

    // Security council with placeholders
    register_create_security_council_decoder(registry, ctx);
    register_set_policy_from_placeholder_decoder(registry, ctx);

    // Optimistic intents
    register_create_optimistic_intent_decoder(registry, ctx);
    register_challenge_optimistic_intents_decoder(registry, ctx);
    register_execute_optimistic_intent_decoder(registry, ctx);
    register_cancel_optimistic_intent_decoder(registry, ctx);
    register_cleanup_expired_intents_decoder(registry, ctx);
}

fun register_update_council_membership_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = UpdateCouncilMembershipActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<UpdateCouncilMembershipAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_unlock_and_return_upgrade_cap_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = UnlockAndReturnUpgradeCapActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<UnlockAndReturnUpgradeCapAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_approve_generic_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ApproveGenericActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<ApproveGenericAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_sweep_intents_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = SweepIntentsActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<SweepIntentsAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_council_create_optimistic_intent_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CouncilCreateOptimisticIntentActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CouncilCreateOptimisticIntentAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_council_execute_optimistic_intent_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CouncilExecuteOptimisticIntentActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CouncilExecuteOptimisticIntentAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_council_cancel_optimistic_intent_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CouncilCancelOptimisticIntentActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CouncilCancelOptimisticIntentAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_create_security_council_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CreateSecurityCouncilActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CreateSecurityCouncilAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_set_policy_from_placeholder_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = SetPolicyFromPlaceholderActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<SetPolicyFromPlaceholderAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_create_optimistic_intent_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CreateOptimisticIntentActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CreateOptimisticIntentAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_challenge_optimistic_intents_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ChallengeOptimisticIntentsActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<ChallengeOptimisticIntentsAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_execute_optimistic_intent_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ExecuteOptimisticIntentActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<ExecuteOptimisticIntentAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_cancel_optimistic_intent_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CancelOptimisticIntentActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CancelOptimisticIntentAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_cleanup_expired_intents_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CleanupExpiredIntentsActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CleanupExpiredIntentsAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}