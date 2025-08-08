/// Advanced configuration intents for complex DAO updates
module futarchy::advanced_config_intents;

// === Imports ===
use std::{
    string::String,
    ascii::String as AsciiString,
    option,
};
use sui::{
    clock::Clock,
    url::Url,
};
use account_protocol::{
    account::Account,
    executable::Executable,
    intents::{Intent, Params},
    intent_interface,
};
use futarchy::{
    futarchy_config::{FutarchyConfig, FutarchyOutcome},
    version,
    advanced_config_actions,
};

// === Aliases ===
use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

// === Errors ===
const EInvalidParameter: u64 = 1;

// === Witness ===
public struct AdvancedConfigIntent has copy, drop {}

// === Intent Creation Functions ===

/// Create intent to update DAO metadata
public fun create_update_metadata_intent(
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: FutarchyOutcome,
    name: AsciiString,
    icon_url: Url,
    description: String,
    ctx: &mut TxContext
) {
    account.build_intent!(
        params,
        outcome,
        b"advanced_config_update_metadata".to_string(),
        version::current(),
        AdvancedConfigIntent {},
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

/// Create intent to update trading parameters
public fun create_update_trading_params_intent(
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: FutarchyOutcome,
    review_period_ms: u64,
    trading_period_ms: u64,
    min_asset_amount: u64,
    min_stable_amount: u64,
    ctx: &mut TxContext
) {
    account.build_intent!(
        params,
        outcome,
        b"advanced_config_update_trading_params".to_string(),
        version::current(),
        AdvancedConfigIntent {},
        ctx,
        |intent, iw| {
            // Create the trading params update action
            let action = advanced_config_actions::new_trading_params_update_action(
                option::some(min_asset_amount),
                option::some(min_stable_amount),
                option::some(review_period_ms),
                option::some(trading_period_ms),
                option::none() // amm_total_fee_bps
            );
            intent.add_action(action, iw);
        }
    );
}

/// Create intent to update TWAP configuration
public fun create_update_twap_config_intent(
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: FutarchyOutcome,
    start_delay: u64,
    step_max: u64,
    initial_observation: u128,
    threshold: u64,
    ctx: &mut TxContext
) {
    account.build_intent!(
        params,
        outcome,
        b"advanced_config_update_twap".to_string(),
        version::current(),
        AdvancedConfigIntent {},
        ctx,
        |intent, iw| {
            // Create the TWAP config update action
            let action = advanced_config_actions::new_twap_config_update_action(
                option::some(start_delay),
                option::some(step_max),
                option::some(initial_observation),
                option::some(threshold)
            );
            intent.add_action(action, iw);
        }
    );
}

/// Create intent to update governance settings
public fun create_update_governance_intent(
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: FutarchyOutcome,
    proposals_enabled: bool,
    max_outcomes: u64,
    required_bond_amount: u64,
    ctx: &mut TxContext
) {
    account.build_intent!(
        params,
        outcome,
        b"advanced_config_update_governance".to_string(),
        version::current(),
        AdvancedConfigIntent {},
        ctx,
        |intent, iw| {
            // Create the governance update action
            let action = advanced_config_actions::new_governance_update_action(
                option::some(proposals_enabled),
                option::some(max_outcomes),
                option::some(required_bond_amount)
            );
            intent.add_action(action, iw);
        }
    );
}

/// Create intent to update slash distribution
public fun create_update_slash_distribution_intent(
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: FutarchyOutcome,
    slasher_reward_bps: u16,
    dao_treasury_bps: u16,
    protocol_bps: u16,
    burn_bps: u16,
    ctx: &mut TxContext
) {
    account.build_intent!(
        params,
        outcome,
        b"advanced_config_update_slash_distribution".to_string(),
        version::current(),
        AdvancedConfigIntent {},
        ctx,
        |intent, iw| {
            // Create the slash distribution update action
            let action = advanced_config_actions::new_slash_distribution_update_action(
                slasher_reward_bps,
                dao_treasury_bps,
                protocol_bps,
                burn_bps
            );
            intent.add_action(action, iw);
        }
    );
}

// === Intent Processing Functions ===

/// Process update metadata intent
public fun process_update_metadata_intent(
    account: &mut Account<FutarchyConfig>,
    executable: Executable<FutarchyOutcome>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    // Simply delegate to action_dispatcher which will handle the execution
    use futarchy::action_dispatcher;
    action_dispatcher::execute_all_actions(
        executable,
        account,
        AdvancedConfigIntent {},
        clock,
        ctx
    );
}

/// Process update trading params intent
public fun process_update_trading_params_intent(
    account: &mut Account<FutarchyConfig>,
    executable: Executable<FutarchyOutcome>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    // Simply delegate to action_dispatcher which will handle the execution
    use futarchy::action_dispatcher;
    action_dispatcher::execute_all_actions(
        executable,
        account,
        AdvancedConfigIntent {},
        clock,
        ctx
    );
}

/// Process update TWAP config intent
public fun process_update_twap_config_intent(
    account: &mut Account<FutarchyConfig>,
    executable: Executable<FutarchyOutcome>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    // Simply delegate to action_dispatcher which will handle the execution
    use futarchy::action_dispatcher;
    action_dispatcher::execute_all_actions(
        executable,
        account,
        AdvancedConfigIntent {},
        clock,
        ctx
    );
}

/// Process update governance intent
public fun process_update_governance_intent(
    account: &mut Account<FutarchyConfig>,
    executable: Executable<FutarchyOutcome>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    // Simply delegate to action_dispatcher which will handle the execution
    use futarchy::action_dispatcher;
    action_dispatcher::execute_all_actions(
        executable,
        account,
        AdvancedConfigIntent {},
        clock,
        ctx
    );
}

/// Process update slash distribution intent
public fun process_update_slash_distribution_intent(
    account: &mut Account<FutarchyConfig>,
    executable: Executable<FutarchyOutcome>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    // Simply delegate to action_dispatcher which will handle the execution
    use futarchy::action_dispatcher;
    action_dispatcher::execute_all_actions(
        executable,
        account,
        AdvancedConfigIntent {},
        clock,
        ctx
    );
}