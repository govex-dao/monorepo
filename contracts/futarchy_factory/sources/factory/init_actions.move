// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Init intent helpers shared by factory and launchpad.
///
/// Callers stage `InitActionSpecs` against the unshared DAO account
/// before the raise completes. During activation we deterministically
/// reconstruct the intent keys, fetch the stored executables, and replay the
/// actions atomically so a finalizer cannot change parameters.
module futarchy_factory::init_actions;

use account_protocol::account::{Self, Account};
use account_protocol::executable::{Self, Executable};
use account_protocol::intents::{Self, Intent};
use futarchy_actions::config_actions;
use futarchy_actions::config_intents;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_core::version;
use futarchy_types::action_type_markers;
use futarchy_types::init_action_specs::{Self, InitActionSpecs};
use std::string::{Self, String};
use std::type_name::{Self, TypeName};
use std::vector;
use sui::clock::Clock;
use sui::event;
use sui::object::{Self, ID};
use sui::tx_context::TxContext;

/// Outcome stored on launchpad init intents (mainly for observability).
public struct InitIntentOutcome has copy, drop, store {
    key: String,
    index: u64,
}

/// Event for each init action executed during launchpad activation.
public struct InitIntentActionAttempted has copy, drop {
    dao_id: address,
    action_type: String,
    action_index: u64,
}

/// Event emitted after all staged init actions complete successfully.
public struct InitIntentBatchCompleted has copy, drop {
    dao_id: address,
    total_actions: u64,
    successful_actions: u64,
}

// Local guard in case launchpad forgets to enforce per-raise action limits.
const MAX_INIT_ACTIONS: u64 = 50;

// === Helper functions ===

fun build_init_intent_key(owner: &ID, index: u64): String {
    let mut key = b"init_intent_".to_string();
    key.append(owner.id_to_address().to_string());
    key.append(b"_".to_string());
    key.append(index.to_string());
    key
}

fun action_type_label(action_type: TypeName): String {
    type_name::into_string(action_type)
}

fun append_action_to_intent(
    intent: &mut Intent<InitIntentOutcome>,
    action_type: TypeName,
    action_data: vector<u8>,
) {
    if (action_type == type_name::with_defining_ids<action_type_markers::SetProposalsEnabled>()) {
        intents::add_action_spec(
            intent,
            action_type_markers::SetProposalsEnabled {},
            action_data,
            config_intents::ConfigIntent {},
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::UpdateName>()) {
        intents::add_action_spec(
            intent,
            action_type_markers::UpdateName {},
            action_data,
            config_intents::ConfigIntent {},
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::TradingParamsUpdate>()) {
        intents::add_action_spec(
            intent,
            action_type_markers::TradingParamsUpdate {},
            action_data,
            config_intents::ConfigIntent {},
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::MetadataUpdate>()) {
        intents::add_action_spec(
            intent,
            action_type_markers::MetadataUpdate {},
            action_data,
            config_intents::ConfigIntent {},
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::TwapConfigUpdate>()) {
        intents::add_action_spec(
            intent,
            action_type_markers::TwapConfigUpdate {},
            action_data,
            config_intents::ConfigIntent {},
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::GovernanceUpdate>()) {
        intents::add_action_spec(
            intent,
            action_type_markers::GovernanceUpdate {},
            action_data,
            config_intents::ConfigIntent {},
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::MetadataTableUpdate>()) {
        intents::add_action_spec(
            intent,
            action_type_markers::MetadataTableUpdate {},
            action_data,
            config_intents::ConfigIntent {},
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::QueueParamsUpdate>()) {
        intents::add_action_spec(
            intent,
            action_type_markers::QueueParamsUpdate {},
            action_data,
            config_intents::ConfigIntent {},
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::SlashDistributionUpdate>()) {
        intents::add_action_spec(
            intent,
            action_type_markers::SlashDistributionUpdate {},
            action_data,
            config_intents::ConfigIntent {},
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::StorageConfigUpdate>()) {
        intents::add_action_spec(
            intent,
            action_type_markers::StorageConfigUpdate {},
            action_data,
            config_intents::ConfigIntent {},
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::UpdateConditionalMetadata>()) {
        intents::add_action_spec(
            intent,
            action_type_markers::UpdateConditionalMetadata {},
            action_data,
            config_intents::ConfigIntent {},
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::EarlyResolveConfigUpdate>()) {
        intents::add_action_spec(
            intent,
            action_type_markers::EarlyResolveConfigUpdate {},
            action_data,
            config_intents::ConfigIntent {},
        );
    } else {
        abort EUnhandledAction;
    };
}

fun add_actions_to_intent(
    intent: &mut Intent<InitIntentOutcome>,
    spec: &InitActionSpecs,
) {
    let actions = init_action_specs::actions(spec);
    let mut i = 0;
    let len = vector::length(actions);
    while (i < len) {
        let action = vector::borrow(actions, i);
        append_action_to_intent(
            intent,
            init_action_specs::action_type(action),
            *init_action_specs::action_data(action),
        );
        i = i + 1;
    };
}

fun execute_config_action(
    executable: &mut Executable<InitIntentOutcome>,
    account: &mut Account<FutarchyConfig>,
    action_type: TypeName,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    if (action_type == type_name::with_defining_ids<action_type_markers::SetProposalsEnabled>()) {
        config_actions::do_set_proposals_enabled<InitIntentOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::UpdateName>()) {
        config_actions::do_update_name<InitIntentOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::TradingParamsUpdate>()) {
        config_actions::do_update_trading_params<InitIntentOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::MetadataUpdate>()) {
        config_actions::do_update_metadata<InitIntentOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::TwapConfigUpdate>()) {
        config_actions::do_update_twap_config<InitIntentOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::GovernanceUpdate>()) {
        config_actions::do_update_governance<InitIntentOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::MetadataTableUpdate>()) {
        config_actions::do_update_metadata_table<InitIntentOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::QueueParamsUpdate>()) {
        config_actions::do_update_queue_params<InitIntentOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::SlashDistributionUpdate>()) {
        config_actions::do_update_slash_distribution<InitIntentOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::StorageConfigUpdate>()) {
        config_actions::do_update_storage_config<InitIntentOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::UpdateConditionalMetadata>()) {
        config_actions::do_update_conditional_metadata<InitIntentOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::EarlyResolveConfigUpdate>()) {
        config_actions::do_update_early_resolve_config<InitIntentOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else {
        abort EUnhandledAction;
    };
}

// === Public helpers ===

/// Create and store an init intent with deterministic key derived from
/// `(owner_id, staged_index)`.
public fun stage_init_intent(
    account: &mut Account<FutarchyConfig>,
    owner_id: &ID,
    staged_index: u64,
    spec: &InitActionSpecs,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let key = build_init_intent_key(owner_id, staged_index);

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
        config_intents::ConfigIntent {},
        ctx,
    );

    add_actions_to_intent(&mut intent, spec);

    account::insert_intent(account, intent, version::current(), config_intents::ConfigIntent {});
}

/// Execute all staged init intents in order.
public fun execute_init_intents(
    account: &mut Account<FutarchyConfig>,
    owner_id: &ID,
    specs: &vector<InitActionSpecs>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut total_actions = 0u64;
    let len = vector::length(specs);
    let mut idx = 0;

    // Enforce an upper bound to protect against DoS.
    let mut count_check = 0u64;
    while (idx < len) {
        count_check = count_check + init_action_specs::action_count(vector::borrow(specs, idx));
        idx = idx + 1;
    };
    assert!(count_check <= MAX_INIT_ACTIONS, ETooManyInitActions);

    idx = 0;
    while (idx < len) {
        let key = build_init_intent_key(owner_id, idx);
        let (_outcome, mut executable) = account::create_executable<
            FutarchyConfig,
            InitIntentOutcome,
            config_intents::ConfigIntent
        >(
            account,
            key,
            clock,
            version::current(),
            config_intents::ConfigIntent {},
            ctx,
        );

        let spec = vector::borrow(specs, idx);
        let action_count = init_action_specs::action_count(spec);
        let mut processed = 0u64;
        while (processed < action_count) {
            let action_type = executable::current_action_type(&executable);
            execute_config_action(&mut executable, account, action_type, clock, ctx);

            event::emit(InitIntentActionAttempted {
                dao_id: owner_id.id_to_address(),
                action_type: action_type_label(action_type),
                action_index: total_actions + processed,
            });

            processed = processed + 1;
        };

        account::confirm_execution(account, executable);

        let mut expired = account::destroy_empty_intent<
            FutarchyConfig,
            InitIntentOutcome
        >(
            account,
            key,
            ctx,
        );
        while (intents::expired_action_count(&expired) > 0) {
            let _ = intents::remove_action_spec(&mut expired);
        };
        intents::destroy_empty_expired(expired);

        total_actions = total_actions + action_count;
        idx = idx + 1;
    };

    event::emit(InitIntentBatchCompleted {
        dao_id: owner_id.id_to_address(),
        total_actions,
        successful_actions: total_actions,
    });
}

fun cancel_init_intent_internal(
    account: &mut Account<FutarchyConfig>,
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
        futarchy_core::futarchy_config::ConfigWitness {},
        ctx,
    );

    while (intents::expired_action_count(&expired) > 0) {
        let _ = intents::remove_action_spec(&mut expired);
    };
    intents::destroy_empty_expired(expired);
}

/// Cancel a single staged launchpad init intent.
public fun cancel_init_intent(
    account: &mut Account<FutarchyConfig>,
    owner_id: &ID,
    index: u64,
    ctx: &mut TxContext,
) {
    let key = build_init_intent_key(owner_id, index);
    cancel_init_intent_internal(account, key, ctx);
}

/// Remove any staged init intents (used when a workflow aborts).
public fun cleanup_init_intents(
    account: &mut Account<FutarchyConfig>,
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

// === Errors ===
const EUnhandledAction: u64 = 1;
const ETooManyInitActions: u64 = 4;
