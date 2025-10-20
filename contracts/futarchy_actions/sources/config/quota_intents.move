// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Quota intent creation module - for managing proposal quotas
module futarchy_actions::quota_intents;

use account_protocol::account::Account;
use account_protocol::executable::Executable;
use account_protocol::intent_interface;
use account_protocol::intents::{Self, Intent, Params};
use account_protocol::schema::{Self, ActionDecoderRegistry};
use futarchy_actions::quota_actions;
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_core::version;
use std::bcs;
use std::type_name;
use sui::clock::Clock;
use sui::tx_context::TxContext;

// === Aliases ===
use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

// === Witness ===
public struct QuotaIntent has copy, drop {}

// === Intent Creation Functions ===

/// Create intent to set quotas for multiple addresses
/// quota_amount = 0 removes quotas
public fun create_set_quotas_intent<Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    registry: &ActionDecoderRegistry,
    params: Params,
    outcome: Outcome,
    users: vector<address>,
    quota_amount: u64,
    quota_period_ms: u64,
    reduced_fee: u64,
    sponsor_quota_amount: u64,
    ctx: &mut TxContext,
) {
    // Enforce decoder exists for this action type
    schema::assert_decoder_exists(
        registry,
        type_name::with_defining_ids<quota_actions::SetQuotasAction>(),
    );

    account.build_intent!(
        params,
        outcome,
        b"quota_set_quotas".to_string(),
        version::current(),
        QuotaIntent {},
        ctx,
        |intent, iw| {
            let action = quota_actions::new_set_quotas(
                users,
                quota_amount,
                quota_period_ms,
                reduced_fee,
                sponsor_quota_amount,
            );
            let action_bytes = bcs::to_bytes(&action);
            intent.add_typed_action(
                type_name::get<quota_actions::SetQuotas>().into_string().to_string(),
                action_bytes,
                iw,
            );
        },
    );
}

/// Create intent to remove quotas (convenience wrapper)
public fun create_remove_quotas_intent<Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    registry: &ActionDecoderRegistry,
    params: Params,
    outcome: Outcome,
    users: vector<address>,
    ctx: &mut TxContext,
) {
    create_set_quotas_intent(
        account,
        registry,
        params,
        outcome,
        users,
        0, // 0 quota_amount = remove
        0, // ignored
        0, // ignored
        0, // ignored - sponsor quota
        ctx,
    )
}
