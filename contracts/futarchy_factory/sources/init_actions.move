// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Init intent helpers for launchpad DAO creation.
///
/// PATTERN: Store InitActionSpecs onchain → Execute via PTB after raise
///
/// 1. Before raise: Stage InitActionSpecs (validation + storage)
/// 2. After raise: Frontend reads specs → Constructs deterministic PTB → Executes
///
/// PTB calls init helper functions directly with known types.
/// This is SAFER than generic executor (compile-time type safety).
module futarchy_factory::init_actions;

use account_protocol::account::{Self, Account};
use account_protocol::intents::{Self, Intent};
use futarchy_actions::config_intents;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_core::version;
use futarchy_types::init_action_specs::{Self, InitActionSpecs};
use std::string::{Self, String};
use sui::clock::Clock;
use sui::object::ID;
use sui::tx_context::TxContext;

/// Outcome stored on launchpad init intents (for intent system compatibility).
public struct InitIntentOutcome has copy, drop, store {
    key: String,
    index: u64,
}

// === Helper functions ===

fun build_init_intent_key(owner: &ID, index: u64): String {
    let mut key = b"init_intent_".to_string();
    key.append(owner.id_to_address().to_string());
    key.append(b"_".to_string());
    key.append(index.to_string());
    key
}

fun add_actions_to_intent(
    intent: &mut Intent<InitIntentOutcome>,
    spec: &InitActionSpecs,
) {
    let actions = init_action_specs::actions(spec);
    let witness = config_intents::witness();
    let mut i = 0;
    let len = vector::length(actions);
    while (i < len) {
        let action = vector::borrow(actions, i);
        intents::add_action_spec_with_typename(
            intent,
            init_action_specs::action_type(action),
            *init_action_specs::action_data(action),
            witness,
        );
        i = i + 1;
    };
}

// === Public Functions ===

/// Stage init actions for later PTB execution.
///
/// Stores InitActionSpecs as an Intent for validation and tamper-proofing.
/// After raise completes, frontend reads these specs and constructs PTB.
public fun stage_init_intent(
    account: &mut Account,
    owner_id: &ID,
    staged_index: u64,
    spec: &InitActionSpecs,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let key = build_init_intent_key(owner_id, staged_index);
    let witness = config_intents::witness();

    let params = intents::new_params(
        key,
        b"Init Intent Batch".to_string(),
        vector[clock.timestamp_ms()],
        clock.timestamp_ms() + 3_600_000,
        clock,
        ctx,
    );

    let outcome = InitIntentOutcome {
        key,
        index: staged_index,
    };

    let mut intent = account::create_intent(
        account,
        params,
        outcome,
        b"InitIntent".to_string(),
        version::current(),
        witness,
        ctx,
    );

    add_actions_to_intent(&mut intent, spec);

    account::insert_intent(account, intent, version::current(), witness);
}

// === Cleanup Functions ===

fun cancel_init_intent_internal(
    account: &mut Account,
    key: String,
    ctx: &mut TxContext,
) {
    if (!intents::contains(account::intents(account), key)) {
        return
    };

    let mut expired = account::cancel_intent<
        FutarchyConfig,
        InitIntentOutcome,
        futarchy_core::futarchy_config::ConfigWitness
    >(
        account,
        key,
        version::current(),
        futarchy_config::witness(),
        ctx,
    );

    while (intents::expired_action_count(&expired) > 0) {
        let _ = intents::remove_action_spec(&mut expired);
    };
    intents::destroy_empty_expired(expired);
}

/// Cancel a single staged launchpad init intent.
public fun cancel_init_intent(
    account: &mut Account,
    owner_id: &ID,
    index: u64,
    ctx: &mut TxContext,
) {
    let key = build_init_intent_key(owner_id, index);
    cancel_init_intent_internal(account, key, ctx);
}

/// Remove any staged init intents (used when a workflow aborts).
public fun cleanup_init_intents(
    account: &mut Account,
    owner_id: &ID,
    specs: &vector<InitActionSpecs>,
    ctx: &mut TxContext,
) {
    let len = vector::length(specs);
    let mut idx = 0;
    while (idx < len) {
        let key = build_init_intent_key(owner_id, idx);
        cancel_init_intent_internal(account, key, ctx);
        idx = idx + 1;
    };
}
