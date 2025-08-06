/// Config intent creation using the CORRECT pattern with build_intent! macro
module futarchy_actions::config_intents;

// === Imports (Organized) ===
use std::{string::String, ascii::String as AsciiString};
use sui::{clock::Clock, url::Url};
use account_protocol::{
    account::Account,
    executable::Executable,
    intents::{Intent, Params},
    intent_interface,
};
use futarchy_actions::{
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
            advanced_config_actions::new_update_metadata<Outcome, ConfigIntent>(
                intent,
                name,
                icon_url,
                description,
                iw
            );
        }
    );
}

/// Create intent to update trading parameters
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
        b"config_update_trading".to_string(),
        version::current(),
        ConfigIntent {},
        ctx,
        |intent, iw| {
            advanced_config_actions::new_update_trading_params<Outcome, ConfigIntent>(
                intent,
                review_period_ms,
                trading_period_ms,
                proposal_fee_per_outcome,
                max_concurrent_proposals,
                iw
            );
        }
    );
}

/// Create intent to update TWAP parameters
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
        b"config_update_twap".to_string(),
        version::current(),
        ConfigIntent {},
        ctx,
        |intent, iw| {
            advanced_config_actions::new_update_twap_params<Outcome, ConfigIntent>(
                intent,
                twap_start_delay,
                twap_step_max,
                twap_initial_observation,
                twap_threshold,
                iw
            );
        }
    );
}

/// Create intent to update fee parameters
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
        b"config_update_fees".to_string(),
        version::current(),
        ConfigIntent {},
        ctx,
        |intent, iw| {
            advanced_config_actions::new_update_fee_params<Outcome, ConfigIntent>(
                intent,
                amm_total_fee_bps,
                fee_manager_address,
                activator_reward_bps,
                iw
            );
        }
    );
}

// === Execution Functions ===

/// Execute metadata update
public fun execute_update_metadata<Config, Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    ctx: &mut TxContext
) {
    account.process_intent!(
        executable,
        version::current(),
        ConfigIntent {},
        |executable, iw| {
            advanced_config_actions::do_update_metadata<Config, Outcome, ConfigIntent>(
                executable,
                account,
                version::current(),
                iw,
                ctx
            );
        }
    );
}

/// Execute trading params update
public fun execute_update_trading_params<Config, Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    ctx: &mut TxContext
) {
    account.process_intent!(
        executable,
        version::current(),
        ConfigIntent {},
        |executable, iw| {
            advanced_config_actions::do_update_trading_params<Config, Outcome, ConfigIntent>(
                executable,
                account,
                version::current(),
                iw,
                ctx
            );
        }
    );
}

/// Execute TWAP params update
public fun execute_update_twap_params<Config, Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    ctx: &mut TxContext
) {
    account.process_intent!(
        executable,
        version::current(),
        ConfigIntent {},
        |executable, iw| {
            advanced_config_actions::do_update_twap_params<Config, Outcome, ConfigIntent>(
                executable,
                account,
                version::current(),
                iw,
                ctx
            );
        }
    );
}

/// Execute fee params update
public fun execute_update_fee_params<Config, Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    ctx: &mut TxContext
) {
    account.process_intent!(
        executable,
        version::current(),
        ConfigIntent {},
        |executable, iw| {
            advanced_config_actions::do_update_fee_params<Config, Outcome, ConfigIntent>(
                executable,
                account,
                version::current(),
                iw,
                ctx
            );
        }
    );
}

// === Helper Functions ===

/// Add update metadata action to existing intent
public fun add_update_metadata_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: AsciiString,
    icon_url: Url,
    description: String,
    iw: IW
) {
    advanced_config_actions::new_update_metadata(intent, name, icon_url, description, iw);
}

// === Key Improvements ===
// 1. ✅ Uses build_intent! macro consistently
// 2. ✅ Single ConfigIntent witness for all functions
// 3. ✅ Process_intent! macro for execution
// 4. ✅ Clean imports with aliases
// 5. ✅ No manual key generation