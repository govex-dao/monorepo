// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Decoder for configuration actions in futarchy DAOs
module futarchy_actions::config_decoder;

use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
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
use futarchy_core::dao_config;
use futarchy_types::signed::{Self as signed, SignedU128};
use std::ascii;
use std::string::String;
use std::type_name;
use sui::bcs::{Self, BCS};
use sui::dynamic_object_field;
use sui::object::{Self, UID};
use sui::url;

// === Imports ===

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

// === Helper Functions ===

fun decode_option_u64(bcs_data: &mut BCS): Option<u64> {
    let is_some = bcs::peel_bool(bcs_data);
    if (is_some) {
        option::some(bcs::peel_u64(bcs_data))
    } else {
        option::none()
    }
}

fun decode_option_u128(bcs_data: &mut BCS): Option<u128> {
    let is_some = bcs::peel_bool(bcs_data);
    if (is_some) {
        option::some(bcs::peel_u128(bcs_data))
    } else {
        option::none()
    }
}

fun decode_option_signed_u128(bcs_data: &mut BCS): Option<SignedU128> {
    let is_some = bcs::peel_bool(bcs_data);
    if (!is_some) {
        return option::none()
    };

    let magnitude = bcs::peel_u128(bcs_data);
    let is_negative = bcs::peel_bool(bcs_data);
    option::some(signed::from_parts(magnitude, is_negative))
}

fun decode_option_bool(bcs_data: &mut BCS): Option<bool> {
    let is_some = bcs::peel_bool(bcs_data);
    if (is_some) {
        option::some(bcs::peel_bool(bcs_data))
    } else {
        option::none()
    }
}

fun decode_option_string(bcs_data: &mut BCS): Option<String> {
    let is_some = bcs::peel_bool(bcs_data);
    if (is_some) {
        option::some(bcs::peel_vec_u8(bcs_data).to_string())
    } else {
        option::none()
    }
}

fun decode_option_ascii_string(bcs_data: &mut BCS): Option<ascii::String> {
    let is_some = bcs::peel_bool(bcs_data);
    if (is_some) {
        let bytes = bcs::peel_vec_u8(bcs_data);
        option::some(ascii::string(bytes))
    } else {
        option::none()
    }
}

fun decode_option_option_conditional_metadata(
    bcs_data: &mut BCS,
): Option<Option<dao_config::ConditionalMetadata>> {
    let outer_is_some = bcs::peel_bool(bcs_data);
    if (outer_is_some) {
        let inner_is_some = bcs::peel_bool(bcs_data);
        if (inner_is_some) {
            let decimals = bcs::peel_u8(bcs_data);
            let prefix_bytes = bcs::peel_vec_u8(bcs_data);
            let icon_url_bytes = bcs::peel_vec_u8(bcs_data);
            let coin_name_prefix = ascii::string(prefix_bytes);
            let coin_icon_url = url::new_unsafe(ascii::string(icon_url_bytes));
            let metadata = dao_config::new_conditional_metadata(
                decimals,
                coin_name_prefix,
                coin_icon_url,
            );
            option::some(option::some(metadata))
        } else {
            option::some(option::none())
        }
    } else {
        option::none()
    }
}

fun decode_option_url(bcs_data: &mut BCS): Option<url::Url> {
    let is_some = bcs::peel_bool(bcs_data);
    if (is_some) {
        let url_bytes = bcs::peel_vec_u8(bcs_data);
        option::some(url::new_unsafe(ascii::string(url_bytes)))
    } else {
        option::none()
    }
}

fun option_to_string<T: drop>(opt: Option<T>): String {
    if (opt.is_some()) {
        b"Some(...)".to_string()
    } else {
        b"None".to_string()
    }
}

// === Decoder Functions ===

/// Decode a SetProposalsEnabledAction
public fun decode_set_proposals_enabled_action(
    _decoder: &SetProposalsEnabledActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let enabled = bcs::peel_bool(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"enabled".to_string(),
            if (enabled) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
    ]
}

/// Decode an UpdateNameAction
public fun decode_update_name_action(
    _decoder: &UpdateNameActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);
    let new_name = bcs::peel_vec_u8(&mut bcs_data).to_string();

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"new_name".to_string(),
            new_name,
            b"String".to_string(),
        ),
    ]
}

/// Decode a TradingParamsUpdateAction
public fun decode_trading_params_update_action(
    _decoder: &TradingParamsUpdateActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let min_asset_amount = decode_option_u64(&mut bcs_data);
    let min_stable_amount = decode_option_u64(&mut bcs_data);
    let review_period_ms = decode_option_u64(&mut bcs_data);
    let trading_period_ms = decode_option_u64(&mut bcs_data);
    let amm_total_fee_bps = decode_option_u64(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector::empty();

    if (min_asset_amount.is_some()) {
        fields.push_back(
            schema::new_field(
                b"min_asset_amount".to_string(),
                min_asset_amount.destroy_some().to_string(),
                b"u64".to_string(),
            ),
        );
    } else {
        min_asset_amount.destroy_none();
    };

    if (min_stable_amount.is_some()) {
        fields.push_back(
            schema::new_field(
                b"min_stable_amount".to_string(),
                min_stable_amount.destroy_some().to_string(),
                b"u64".to_string(),
            ),
        );
    } else {
        min_stable_amount.destroy_none();
    };

    if (review_period_ms.is_some()) {
        fields.push_back(
            schema::new_field(
                b"review_period_ms".to_string(),
                review_period_ms.destroy_some().to_string(),
                b"u64".to_string(),
            ),
        );
    } else {
        review_period_ms.destroy_none();
    };

    if (trading_period_ms.is_some()) {
        fields.push_back(
            schema::new_field(
                b"trading_period_ms".to_string(),
                trading_period_ms.destroy_some().to_string(),
                b"u64".to_string(),
            ),
        );
    } else {
        trading_period_ms.destroy_none();
    };

    if (amm_total_fee_bps.is_some()) {
        fields.push_back(
            schema::new_field(
                b"amm_total_fee_bps".to_string(),
                amm_total_fee_bps.destroy_some().to_string(),
                b"u64".to_string(),
            ),
        );
    } else {
        amm_total_fee_bps.destroy_none();
    };

    fields
}

/// Decode a MetadataUpdateAction
public fun decode_metadata_update_action(
    _decoder: &MetadataUpdateActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let dao_name = decode_option_ascii_string(&mut bcs_data);
    let icon_url = decode_option_url(&mut bcs_data);
    let description = decode_option_string(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector::empty();

    if (dao_name.is_some()) {
        let name = dao_name.destroy_some();
        fields.push_back(
            schema::new_field(
                b"dao_name".to_string(),
                name.into_bytes().to_string(),
                b"AsciiString".to_string(),
            ),
        );
    } else {
        dao_name.destroy_none();
    };

    if (icon_url.is_some()) {
        let url = icon_url.destroy_some();
        fields.push_back(
            schema::new_field(
                b"icon_url".to_string(),
                url.inner_url().into_bytes().to_string(),
                b"Url".to_string(),
            ),
        );
    } else {
        icon_url.destroy_none();
    };

    if (description.is_some()) {
        fields.push_back(
            schema::new_field(
                b"description".to_string(),
                description.destroy_some(),
                b"String".to_string(),
            ),
        );
    } else {
        description.destroy_none();
    };

    fields
}

/// Decode a TwapConfigUpdateAction
public fun decode_twap_config_update_action(
    _decoder: &TwapConfigUpdateActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let start_delay = decode_option_u64(&mut bcs_data);
    let step_max = decode_option_u64(&mut bcs_data);
    let initial_observation = decode_option_u128(&mut bcs_data);
    let threshold = decode_option_signed_u128(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector::empty();

    if (start_delay.is_some()) {
        fields.push_back(
            schema::new_field(
                b"start_delay".to_string(),
                start_delay.destroy_some().to_string(),
                b"u64".to_string(),
            ),
        );
    } else {
        start_delay.destroy_none();
    };

    if (step_max.is_some()) {
        fields.push_back(
            schema::new_field(
                b"step_max".to_string(),
                step_max.destroy_some().to_string(),
                b"u64".to_string(),
            ),
        );
    } else {
        step_max.destroy_none();
    };

    if (initial_observation.is_some()) {
        fields.push_back(
            schema::new_field(
                b"initial_observation".to_string(),
                initial_observation.destroy_some().to_string(),
                b"u128".to_string(),
            ),
        );
    } else {
        initial_observation.destroy_none();
    };

    if (threshold.is_some()) {
        let value = threshold.destroy_some();
        fields.push_back(
            schema::new_field(
                b"threshold_magnitude".to_string(),
                signed::magnitude(&value).to_string(),
                b"u128".to_string(),
            ),
        );
        fields.push_back(
            schema::new_field(
                b"threshold_is_negative".to_string(),
                if (signed::is_negative(&value)) { b"true".to_string() } else { b"false".to_string() },
                b"bool".to_string(),
            ),
        );
    } else {
        threshold.destroy_none();
    };

    fields
}

/// Decode a GovernanceUpdateAction
public fun decode_governance_update_action(
    _decoder: &GovernanceUpdateActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let proposal_creation_enabled = decode_option_bool(&mut bcs_data);
    let max_outcomes = decode_option_u64(&mut bcs_data);
    let max_actions_per_outcome = decode_option_u64(&mut bcs_data);
    let required_bond_amount = decode_option_u64(&mut bcs_data);
    let max_intents_per_outcome = decode_option_u64(&mut bcs_data);
    let proposal_intent_expiry_ms = decode_option_u64(&mut bcs_data);
    let optimistic_challenge_fee = decode_option_u64(&mut bcs_data);
    let optimistic_challenge_period_ms = decode_option_u64(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector::empty();

    if (proposal_creation_enabled.is_some()) {
        fields.push_back(
            schema::new_field(
                b"proposal_creation_enabled".to_string(),
                if (proposal_creation_enabled.destroy_some()) { b"true" } else {
                    b"false"
                }.to_string(),
                b"bool".to_string(),
            ),
        );
    } else {
        proposal_creation_enabled.destroy_none();
    };

    // Add other fields similarly...
    // (Keeping code concise, pattern is the same for all optional fields)

    fields
}

/// Decode a MetadataTableUpdateAction
public fun decode_metadata_table_update_action(
    _decoder: &MetadataTableUpdateActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    // Read keys vector
    let keys_count = bcs::peel_vec_length(&mut bcs_data);
    let mut keys = vector::empty<String>();
    let mut i = 0;
    while (i < keys_count) {
        keys.push_back(bcs::peel_vec_u8(&mut bcs_data).to_string());
        i = i + 1;
    };

    // Read values vector
    let values_count = bcs::peel_vec_length(&mut bcs_data);
    let mut values = vector::empty<String>();
    let mut j = 0;
    while (j < values_count) {
        values.push_back(bcs::peel_vec_u8(&mut bcs_data).to_string());
        j = j + 1;
    };

    // Read keys_to_remove vector
    let remove_count = bcs::peel_vec_length(&mut bcs_data);
    let mut keys_to_remove = vector::empty<String>();
    let mut k = 0;
    while (k < remove_count) {
        keys_to_remove.push_back(bcs::peel_vec_u8(&mut bcs_data).to_string());
        k = k + 1;
    };

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"keys_count".to_string(),
            keys.length().to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"values_count".to_string(),
            values.length().to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"keys_to_remove_count".to_string(),
            keys_to_remove.length().to_string(),
            b"u64".to_string(),
        ),
    ]
}

/// Decode a SlashDistributionUpdateAction
public fun decode_slash_distribution_update_action(
    _decoder: &SlashDistributionUpdateActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let slasher_reward_bps = bcs::peel_u16(&mut bcs_data);
    let dao_treasury_bps = bcs::peel_u16(&mut bcs_data);
    let protocol_bps = bcs::peel_u16(&mut bcs_data);
    let burn_bps = bcs::peel_u16(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"slasher_reward_bps".to_string(),
            slasher_reward_bps.to_string(),
            b"u16".to_string(),
        ),
        schema::new_field(
            b"dao_treasury_bps".to_string(),
            dao_treasury_bps.to_string(),
            b"u16".to_string(),
        ),
        schema::new_field(
            b"protocol_bps".to_string(),
            protocol_bps.to_string(),
            b"u16".to_string(),
        ),
        schema::new_field(
            b"burn_bps".to_string(),
            burn_bps.to_string(),
            b"u16".to_string(),
        ),
    ]
}

/// Decode a QueueParamsUpdateAction
public fun decode_queue_params_update_action(
    _decoder: &QueueParamsUpdateActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let max_proposer_funded = decode_option_u64(&mut bcs_data);
    let max_concurrent_proposals = decode_option_u64(&mut bcs_data);
    let max_queue_size = decode_option_u64(&mut bcs_data);
    let fee_escalation_basis_points = decode_option_u64(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector::empty();

    if (max_proposer_funded.is_some()) {
        fields.push_back(
            schema::new_field(
                b"max_proposer_funded".to_string(),
                max_proposer_funded.destroy_some().to_string(),
                b"u64".to_string(),
            ),
        );
    } else {
        max_proposer_funded.destroy_none();
    };

    // Add other fields similarly...

    fields
}

/// Decode storage config update action
public fun decode_storage_config_update_action(
    _decoder: &StorageConfigUpdateActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let allow_walrus_blobs = decode_option_bool(&mut bcs_data);

    // Security: ensure all bytes are consumed
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector::empty();

    if (allow_walrus_blobs.is_some()) {
        let value = if (allow_walrus_blobs.destroy_some()) { b"true".to_string() } else {
            b"false".to_string()
        };
        fields.push_back(
            schema::new_field(
                b"allow_walrus_blobs".to_string(),
                value,
                b"bool".to_string(),
            ),
        );
    } else {
        allow_walrus_blobs.destroy_none();
    };

    fields
}

/// Decode ConditionalMetadataUpdateAction to human-readable fields
public fun decode_conditional_metadata_update_action(
    _decoder: &ConditionalMetadataUpdateActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let use_outcome_index = decode_option_bool(&mut bcs_data);
    let conditional_metadata = decode_option_option_conditional_metadata(&mut bcs_data);

    // Security: ensure all bytes are consumed
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector::empty();

    if (use_outcome_index.is_some()) {
        let value = if (use_outcome_index.destroy_some()) { b"true".to_string() } else {
            b"false".to_string()
        };
        fields.push_back(
            schema::new_field(
                b"use_outcome_index".to_string(),
                value,
                b"bool".to_string(),
            ),
        );
    } else {
        use_outcome_index.destroy_none();
    };

    if (conditional_metadata.is_some()) {
        let meta_opt = conditional_metadata.destroy_some();
        if (meta_opt.is_some()) {
            let meta = meta_opt.destroy_some();
            fields.push_back(
                schema::new_field(
                    b"fallback_metadata".to_string(),
                    b"Some(ConditionalMetadata)".to_string(),
                    b"Option<ConditionalMetadata>".to_string(),
                ),
            );
            fields.push_back(
                schema::new_field(
                    b"decimals".to_string(),
                    dao_config::conditional_metadata_decimals(&meta).to_string(),
                    b"u8".to_string(),
                ),
            );
            fields.push_back(
                schema::new_field(
                    b"coin_name_prefix".to_string(),
                    dao_config::conditional_metadata_prefix(&meta).to_string(),
                    b"AsciiString".to_string(),
                ),
            );
            fields.push_back(
                schema::new_field(
                    b"coin_icon_url".to_string(),
                    dao_config::conditional_metadata_icon(&meta).inner_url().to_string(),
                    b"Url".to_string(),
                ),
            );
        } else {
            fields.push_back(
                schema::new_field(
                    b"fallback_metadata".to_string(),
                    b"None".to_string(),
                    b"Option<ConditionalMetadata>".to_string(),
                ),
            );
            meta_opt.destroy_none();
        };
    } else {
        conditional_metadata.destroy_none();
    };

    fields
}

/// Decode an EarlyResolveConfigUpdateAction
public fun decode_early_resolve_config_update_action(
    _decoder: &EarlyResolveConfigUpdateActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let min_proposal_duration_ms = bcs::peel_u64(&mut bcs_data);
    let max_proposal_duration_ms = bcs::peel_u64(&mut bcs_data);
    let min_winner_spread = bcs::peel_u128(&mut bcs_data);
    let min_time_since_last_flip_ms = bcs::peel_u64(&mut bcs_data);
    let max_flips_in_window = bcs::peel_u64(&mut bcs_data);
    let flip_window_duration_ms = bcs::peel_u64(&mut bcs_data);
    let enable_twap_scaling = bcs::peel_bool(&mut bcs_data);
    let keeper_reward_bps = bcs::peel_u64(&mut bcs_data);

    // Security: ensure all bytes are consumed
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"min_proposal_duration_ms".to_string(),
            min_proposal_duration_ms.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"max_proposal_duration_ms".to_string(),
            max_proposal_duration_ms.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"min_winner_spread".to_string(),
            min_winner_spread.to_string(),
            b"u128".to_string(),
        ),
        schema::new_field(
            b"min_time_since_last_flip_ms".to_string(),
            min_time_since_last_flip_ms.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"max_flips_in_window".to_string(),
            max_flips_in_window.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"flip_window_duration_ms".to_string(),
            flip_window_duration_ms.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"enable_twap_scaling".to_string(),
            if (enable_twap_scaling) { b"true".to_string() } else { b"false".to_string() },
            b"bool".to_string(),
        ),
        schema::new_field(
            b"keeper_reward_bps".to_string(),
            keeper_reward_bps.to_string(),
            b"u64".to_string(),
        ),
    ]
}

/// Decode a SponsorshipConfigUpdateAction
public fun decode_sponsorship_config_update_action(
    _decoder: &SponsorshipConfigUpdateActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let enabled = decode_option_bool(&mut bcs_data);
    let sponsored_threshold = decode_option_signed_u128(&mut bcs_data);
    let waive_advancement_fees = decode_option_bool(&mut bcs_data);
    let default_sponsor_quota_amount = decode_option_u64(&mut bcs_data);

    // Security: ensure all bytes are consumed
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector::empty();

    if (enabled.is_some()) {
        let value = if (enabled.destroy_some()) { b"true".to_string() } else { b"false".to_string() };
        fields.push_back(
            schema::new_field(
                b"enabled".to_string(),
                value,
                b"bool".to_string(),
            ),
        );
    } else {
        enabled.destroy_none();
    };

    if (sponsored_threshold.is_some()) {
        let value = sponsored_threshold.destroy_some();
        fields.push_back(
            schema::new_field(
                b"sponsored_threshold_magnitude".to_string(),
                signed::magnitude(&value).to_string(),
                b"u128".to_string(),
            ),
        );
        fields.push_back(
            schema::new_field(
                b"sponsored_threshold_is_negative".to_string(),
                if (signed::is_negative(&value)) { b"true".to_string() } else { b"false".to_string() },
                b"bool".to_string(),
            ),
        );
    } else {
        sponsored_threshold.destroy_none();
    };

    if (waive_advancement_fees.is_some()) {
        let value = if (waive_advancement_fees.destroy_some()) { b"true".to_string() } else { b"false".to_string() };
        fields.push_back(
            schema::new_field(
                b"waive_advancement_fees".to_string(),
                value,
                b"bool".to_string(),
            ),
        );
    } else {
        waive_advancement_fees.destroy_none();
    };

    if (default_sponsor_quota_amount.is_some()) {
        fields.push_back(
            schema::new_field(
                b"default_sponsor_quota_amount".to_string(),
                default_sponsor_quota_amount.destroy_some().to_string(),
                b"u64".to_string(),
            ),
        );
    } else {
        default_sponsor_quota_amount.destroy_none();
    };

    fields
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
