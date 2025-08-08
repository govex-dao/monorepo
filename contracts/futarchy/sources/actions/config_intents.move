/// Config intent creation - simplified version without non-existent helper functions
module futarchy::config_intents;

// === Imports (Organized) ===
use std::{string::String, ascii::String as AsciiString, option};
use sui::{clock::Clock, url::Url};
use account_protocol::{
    account::Account,
    executable::Executable,
    intents::{Intent, Params},
    intent_interface,
};
use futarchy::{
    config_actions,
    advanced_config_actions,
    version,
};

// === Aliases ===
use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

// === Single Witness ===
public struct ConfigIntent has copy, drop {}

// === Intent Creation Functions ===

/// Create intent to update DAO metadata
public fun create_update_metadata_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    name: AsciiString,
    icon_url: Url,
    description: String,
    ctx: &mut TxContext
) {
    account.build_intent!(
        params,
        outcome,
        b"config_update_metadata".to_string(),
        version::current(),
        ConfigIntent {},
        ctx,
        |intent, iw| {
            // Create the metadata update action directly
            let action = advanced_config_actions::new_metadata_update_action(
                option::some(name),
                option::some(icon_url),
                option::some(description)
            );
            intent.add_action(action, iw);
        }
    );
}

/// Create intent to update trading params
public fun create_update_trading_params_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    review_period_ms: u64,
    trading_period_ms: u64,
    proposal_fee_per_outcome: u64,
    max_concurrent_proposals: u64,
    ctx: &mut TxContext
) {
    account.build_intent!(
        params,
        outcome,
        b"config_update_trading_params".to_string(),
        version::current(),
        ConfigIntent {},
        ctx,
        |intent, iw| {
            // Create the trading params update action directly
            let action = advanced_config_actions::new_trading_params_update_action(
                option::none(), // min_asset_amount
                option::none(), // min_stable_amount
                option::some(review_period_ms),
                option::some(trading_period_ms),
                option::none()  // amm_total_fee_bps
            );
            intent.add_action(action, iw);
            
            // Note: proposal_fee_per_outcome and max_concurrent_proposals 
            // would need to be handled separately as governance params
        }
    );
}

/// Create intent to update TWAP params
public fun create_update_twap_params_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    twap_start_delay: u64,
    twap_step_max: u64,
    twap_initial_observation: u128,
    twap_threshold: u64,
    ctx: &mut TxContext
) {
    account.build_intent!(
        params,
        outcome,
        b"config_update_twap_params".to_string(),
        version::current(),
        ConfigIntent {},
        ctx,
        |intent, iw| {
            // Create the TWAP config update action directly
            let action = advanced_config_actions::new_twap_config_update_action(
                option::some(twap_start_delay),
                option::some(twap_step_max),
                option::some(twap_initial_observation),
                option::some(twap_threshold)
            );
            intent.add_action(action, iw);
        }
    );
}

/// Create intent to update fee params (maps to queue params now)
public fun create_update_fee_params_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    amm_total_fee_bps: u64,
    fee_manager_address: address,
    activator_reward_bps: u64,
    ctx: &mut TxContext
) {
    account.build_intent!(
        params,
        outcome,
        b"config_update_fee_params".to_string(),
        version::current(),
        ConfigIntent {},
        ctx,
        |intent, iw| {
            // Fee params don't map directly - using trading params for fee
            let action = advanced_config_actions::new_trading_params_update_action(
                option::none(), // min_asset_amount
                option::none(), // min_stable_amount
                option::none(), // review_period_ms
                option::none(), // trading_period_ms
                option::some(amm_total_fee_bps)
            );
            intent.add_action(action, iw);
            
            // Note: fee_manager_address and activator_reward_bps would need 
            // separate handling as they don't map to current actions
        }
    );
}

// === Intent Processing Functions ===
// Intent processing is handled through the action_dispatcher
// Create intents with the functions above, then execute via:
// action_dispatcher::execute_all_actions()