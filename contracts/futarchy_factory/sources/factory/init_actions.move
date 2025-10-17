// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Init Actions - Launchpad initialization executor
///
/// Launchpad raises stage configuration changes as `InitActionSpecs`.
/// When the raise finalizes successfully, this module converts those specs
/// into a temporary governance intent and replays the actions atomically
/// against the unshared DAO account before it is shared.
module futarchy_factory::init_actions;

use account_protocol::account::{Self, Account};
use account_protocol::executable::{Self, Executable};
use account_protocol::intents::{Self, Intent};
use futarchy_actions::config_actions;
use futarchy_actions::config_intents;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_core::priority_queue::{Self, ProposalQueue};
use futarchy_core::version;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_types::action_type_markers;
use futarchy_types::init_action_specs::{Self, InitActionSpecs};
use std::string::{Self, String};
use std::type_name::{Self, TypeName};
use std::vector;
use sui::clock::Clock;
use sui::event;
use sui::object;
use sui::tx_context::TxContext;

/// Outcome placeholder for launchpad initialization intents
public struct InitExecutionOutcome has copy, drop, store {}

/// Event emitted for each init action attempted (for launchpad tracking)
public struct InitActionAttempted has copy, drop {
    dao_id: address,
    action_type: String, // TypeName as string
    action_index: u64,
    success: bool,
}

/// Event for init batch completion
public struct InitBatchCompleted has copy, drop {
    dao_id: address,
    total_actions: u64,
    successful_actions: u64,
    failed_actions: u64,
}

// === Constants ===
const MAX_INIT_ACTIONS: u64 = 50; // Reasonable limit to prevent gas issues

// === Helpers ===

fun action_type_label(action_type: TypeName): String {
    let mut label = action_type.module_string();
    label.append(b"::".to_string());
    label.append(action_type.name_string());
    label
}

fun append_action_to_intent(
    intent: &mut Intent<InitExecutionOutcome>,
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

fun execute_config_action(
    executable: &mut Executable<InitExecutionOutcome>,
    account: &mut Account<FutarchyConfig>,
    action_type: TypeName,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    if (action_type == type_name::with_defining_ids<action_type_markers::SetProposalsEnabled>()) {
        config_actions::do_set_proposals_enabled<InitExecutionOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::UpdateName>()) {
        config_actions::do_update_name<InitExecutionOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::TradingParamsUpdate>()) {
        config_actions::do_update_trading_params<InitExecutionOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::MetadataUpdate>()) {
        config_actions::do_update_metadata<InitExecutionOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::TwapConfigUpdate>()) {
        config_actions::do_update_twap_config<InitExecutionOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::GovernanceUpdate>()) {
        config_actions::do_update_governance<InitExecutionOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::MetadataTableUpdate>()) {
        config_actions::do_update_metadata_table<InitExecutionOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::QueueParamsUpdate>()) {
        config_actions::do_update_queue_params<InitExecutionOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::SlashDistributionUpdate>()) {
        config_actions::do_update_slash_distribution<InitExecutionOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::StorageConfigUpdate>()) {
        config_actions::do_update_storage_config<InitExecutionOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::UpdateConditionalMetadata>()) {
        config_actions::do_update_conditional_metadata<InitExecutionOutcome, config_intents::ConfigIntent>(
            executable,
            account,
            version::current(),
            config_intents::ConfigIntent {},
            clock,
            ctx,
        );
    } else if (action_type == type_name::with_defining_ids<action_type_markers::EarlyResolveConfigUpdate>()) {
        config_actions::do_update_early_resolve_config<InitExecutionOutcome, config_intents::ConfigIntent>(
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

// === Main Execution Function ===

/// Execute init actions with resources during launchpad finalization
/// This function processes all init actions in the specs and applies them to the DAO
/// before it becomes public. All actions must succeed or the entire transaction reverts.
public fun execute_init_intent_with_resources<RaiseToken, StableCoin>(
    account: &mut Account<FutarchyConfig>,
    specs: InitActionSpecs,
    _queue: &mut ProposalQueue<StableCoin>,
    _spot_pool: &mut UnifiedSpotPool<RaiseToken, StableCoin>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let dao_id = object::id_address(account);
    let action_count = init_action_specs::action_count(&specs);
    assert!(action_count <= MAX_INIT_ACTIONS, ETooManyInitActions);

    if (action_count == 0) {
        event::emit(InitBatchCompleted {
            dao_id,
            total_actions: 0,
            successful_actions: 0,
            failed_actions: 0,
        });
        return
    };

    let mut intent_key = b"launchpad_init_".to_string();
    intent_key.append(clock.timestamp_ms().to_string());
    intent_key.append(b"_".to_string());
    intent_key.append(object::id_address(account).to_string());

    let params = intents::new_params(
        intent_key.clone(),
        b"Launchpad Init Actions".to_string(),
        vector[clock.timestamp_ms()],
        clock.timestamp_ms() + 60_000,
        clock,
        ctx,
    );

    let mut intent = account::create_intent(
        account,
        params,
        InitExecutionOutcome {},
        b"LaunchpadInit".to_string(),
        version::current(),
        config_intents::ConfigIntent {},
        ctx,
    );

    let actions = init_action_specs::actions(&specs);
    let mut i = 0;
    let len = vector::length(actions);
    while (i < len) {
        let action = vector::borrow(actions, i);
        let action_type = init_action_specs::action_type(action);
        let action_data = *init_action_specs::action_data(action);
        append_action_to_intent(&mut intent, action_type, action_data);
        i = i + 1;
    };

    account::insert_intent(account, intent, version::current(), config_intents::ConfigIntent {});

    let (_, mut executable) = account::create_executable<
        FutarchyConfig,
        InitExecutionOutcome,
        config_intents::ConfigIntent
    >(
        account,
        intent_key.clone(),
        clock,
        version::current(),
        config_intents::ConfigIntent {},
        ctx,
    );

    let mut processed = 0u64;
    loop {
        let current_idx = executable::action_idx(&executable);
        if (current_idx >= len) {
            break
        };

        let action_type = executable::current_action_type(&executable);
        execute_config_action(&mut executable, account, action_type, clock, ctx);

        event::emit(InitActionAttempted {
            dao_id,
            action_type: action_type_label(action_type),
            action_index: current_idx,
            success: true,
        });

        processed = processed + 1;
    };

    assert!(processed == len, EInitActionFailed);

    account::confirm_execution(account, executable);

    let mut expired = account::destroy_empty_intent<FutarchyConfig, InitExecutionOutcome>(
        account,
        intent_key,
        ctx,
    );

    while (intents::expired_action_count(&expired) > 0) {
        let _ = intents::remove_action_spec(&mut expired);
    };
    intents::destroy_empty_expired(expired);

    event::emit(InitBatchCompleted {
        dao_id,
        total_actions: len,
        successful_actions: processed,
        failed_actions: 0,
    });
}

// === Errors ===
const EUnhandledAction: u64 = 1;
const EActionNotAllowedAtInit: u64 = 2;
const EInitActionFailed: u64 = 3;
const ETooManyInitActions: u64 = 4;
