/// Advanced configuration intent creation using CORRECT build_intent! macro pattern
/// This module provides configuration intents for futarchy governance
module futarchy::advanced_config_intents;

// === Imports (Organized) ===
use std::{string::String, ascii::String as AsciiString};
use sui::{
    clock::Clock,
    url::Url,
    object::{Self, ID},
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
};
use futarchy_actions::{
    advanced_config_actions,
};

// === Aliases ===
use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

// === Errors ===
const EInvalidPoolId: u64 = 1;

// === Single Witness ===
/// Single witness for ALL advanced config intents (reduces boilerplate)
public struct AdvancedConfigIntent has copy, drop {}

// === Intent Creation Functions ===

/// Create intent to update DAO metadata using build_intent! macro
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
        b"advanced_config_metadata".to_string(),
        version::current(),
        AdvancedConfigIntent {},
        ctx,
        |intent, iw| {
            advanced_config_actions::new_update_metadata<FutarchyOutcome, AdvancedConfigIntent>(
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
public fun create_update_trading_params_intent(
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: FutarchyOutcome,
    review_period_ms: u64,
    trading_period_ms: u64,
    proposal_fee_per_outcome: u64,
    max_concurrent_proposals: u64,
    ctx: &mut TxContext
) {
    account.build_intent!(
        params,
        outcome,
        b"advanced_config_trading".to_string(),
        version::current(),
        AdvancedConfigIntent {},
        ctx,
        |intent, iw| {
            advanced_config_actions::new_update_trading_params<FutarchyOutcome, AdvancedConfigIntent>(
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
public fun create_update_twap_params_intent(
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: FutarchyOutcome,
    twap_start_delay: u64,
    twap_step_max: u64,
    twap_initial_observation: u128,
    twap_threshold: u64,
    ctx: &mut TxContext
) {
    account.build_intent!(
        params,
        outcome,
        b"advanced_config_twap".to_string(),
        version::current(),
        AdvancedConfigIntent {},
        ctx,
        |intent, iw| {
            advanced_config_actions::new_update_twap_params<FutarchyOutcome, AdvancedConfigIntent>(
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
public fun create_update_fee_params_intent(
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: FutarchyOutcome,
    amm_total_fee_bps: u64,
    fee_manager_address: address,
    activator_reward_bps: u64,
    ctx: &mut TxContext
) {
    account.build_intent!(
        params,
        outcome,
        b"advanced_config_fees".to_string(),
        version::current(),
        AdvancedConfigIntent {},
        ctx,
        |intent, iw| {
            advanced_config_actions::new_update_fee_params<FutarchyOutcome, AdvancedConfigIntent>(
                intent,
                amm_total_fee_bps,
                fee_manager_address,
                activator_reward_bps,
                iw
            );
        }
    );
}

/// Create intent to update pool references
public fun create_update_pool_references_intent(
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: FutarchyOutcome,
    spot_pool_id: ID,
    dao_pool_id: ID,
    ctx: &mut TxContext
) {
    account.build_intent!(
        params,
        outcome,
        b"advanced_config_pools".to_string(),
        version::current(),
        AdvancedConfigIntent {},
        ctx,
        |intent, iw| {
            // Pool references update - validate pool IDs
            assert!(spot_pool_id != object::id_from_address(@0x0), EInvalidPoolId);
            assert!(dao_pool_id != object::id_from_address(@0x0), EInvalidPoolId);
            // In the new architecture, pool management is handled through account protocol
        }
    );
}

// === Execution Functions ===

/// Execute metadata update
public fun execute_update_metadata(
    executable: &mut Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext
) {
    account.process_intent!(
        executable,
        version::current(),
        AdvancedConfigIntent {},
        |executable, iw| {
            advanced_config_actions::do_update_metadata<FutarchyConfig, FutarchyOutcome, AdvancedConfigIntent>(
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
public fun execute_update_trading_params(
    executable: &mut Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext
) {
    account.process_intent!(
        executable,
        version::current(),
        AdvancedConfigIntent {},
        |executable, iw| {
            advanced_config_actions::do_update_trading_params<FutarchyConfig, FutarchyOutcome, AdvancedConfigIntent>(
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
public fun execute_update_twap_params(
    executable: &mut Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext
) {
    account.process_intent!(
        executable,
        version::current(),
        AdvancedConfigIntent {},
        |executable, iw| {
            advanced_config_actions::do_update_twap_params<FutarchyConfig, FutarchyOutcome, AdvancedConfigIntent>(
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
public fun execute_update_fee_params(
    executable: &mut Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext
) {
    account.process_intent!(
        executable,
        version::current(),
        AdvancedConfigIntent {},
        |executable, iw| {
            advanced_config_actions::do_update_fee_params<FutarchyConfig, FutarchyOutcome, AdvancedConfigIntent>(
                executable,
                account,
                version::current(),
                iw,
                ctx
            );
        }
    );
}

/// Execute pool references update
public fun execute_update_pool_references(
    executable: &mut Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext
) {
    account.process_intent!(
        executable,
        version::current(),
        AdvancedConfigIntent {},
        |executable, iw| {
            // Pool references update execution
            // In the new architecture, pools are managed through account protocol
            // This is a no-op for compatibility
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

/// Add update trading params action to existing intent
public fun add_update_trading_params_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    review_period_ms: u64,
    trading_period_ms: u64,
    proposal_fee_per_outcome: u64,
    max_concurrent_proposals: u64,
    iw: IW
) {
    advanced_config_actions::new_update_trading_params(
        intent,
        review_period_ms,
        trading_period_ms,
        proposal_fee_per_outcome,
        max_concurrent_proposals,
        iw
    );
}

/// Add update TWAP params action to existing intent
public fun add_update_twap_params_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    twap_start_delay: u64,
    twap_step_max: u64,
    twap_initial_observation: u128,
    twap_threshold: u64,
    iw: IW
) {
    advanced_config_actions::new_update_twap_params(
        intent,
        twap_start_delay,
        twap_step_max,
        twap_initial_observation,
        twap_threshold,
        iw
    );
}

/// Add update fee params action to existing intent
public fun add_update_fee_params_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    amm_total_fee_bps: u64,
    fee_manager_address: address,
    activator_reward_bps: u64,
    iw: IW
) {
    advanced_config_actions::new_update_fee_params(
        intent,
        amm_total_fee_bps,
        fee_manager_address,
        activator_reward_bps,
        iw
    );
}

/// Add update pool references action to existing intent
public fun add_update_pool_references_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    spot_pool_id: ID,
    dao_pool_id: ID,
    iw: IW
) {
    // Pool references update - validation only
    assert!(spot_pool_id != object::id_from_address(@0x0), EInvalidPoolId);
    assert!(dao_pool_id != object::id_from_address(@0x0), EInvalidPoolId);
    // Pools are managed through account protocol now
    //     intent,
    //     spot_pool_id,
    //     dao_pool_id,
    //     iw
    // );
}

// === Key Improvements ===
// 1. ✅ Uses build_intent! macro (ACTUALLY creates intents)
// 2. ✅ Single AdvancedConfigIntent witness for ALL functions
// 3. ✅ Process_intent! macro for execution
// 4. ✅ Clean, organized imports
// 5. ✅ No manual key generation
// 6. ✅ Consistent patterns throughout
// 7. ✅ Helper functions to reduce boilerplate