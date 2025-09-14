/// Liquidity actions dispatcher - processes liquidity-related actions
/// Uses Executable with embedded ExecutionContext for sequential processing with placeholders
module futarchy_actions::liquidity_dispatcher;

use std::type_name;
use std::option::{Self, Option};
use sui::bcs;
use sui::clock::Clock;
use sui::coin::Coin;
use sui::object;
use sui::transfer;
use account_protocol::account::Account;
use account_protocol::executable::{Self, Executable, ExecutionContext};
use account_protocol::intents;
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_core::futarchy_config::FutarchyOutcome as ProposalOutcome;
use futarchy_markets::account_spot_pool::AccountSpotPool;
use futarchy_utils::{action_types, version};

// Import liquidity action types
use futarchy_actions::liquidity_actions::{
    Self,
    CreatePoolAction,
    UpdatePoolParamsAction,
    SetPoolStatusAction,
};
use futarchy_actions::resource_requests;
use futarchy_one_shot_utils::action_data_structs::AddLiquidityAction;

/// Process liquidity-related actions sequentially using action_idx cursor
/// This is called as part of a PTB chain for proposal execution
public fun execute_liquidity_actions<AssetType: drop, StableType: drop>(
    executable: &mut Executable<ProposalOutcome>,
    account: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let specs = executable::intent(executable).action_specs();
    let total = specs.length();

    // Process actions sequentially from current index
    while (executable::action_idx(executable) < total) {
        let current_idx = executable::action_idx(executable);
        let spec = specs.borrow(current_idx);
        let action_type = intents::action_spec_type(spec);

        // Check if this is a liquidity action
        if (is_liquidity_action(action_type)) {
            let action_data = intents::action_spec_data(spec);

            if (action_type == type_name::get<action_types::CreatePool>()) {
                // CreatePool uses hot potato pattern and requires external coins
                // It should be handled specially by the PTB, not in this dispatcher
                // Skip for now
            }
            else if (action_type == type_name::get<action_types::UpdatePoolParams>()) {
                // This action can resolve pool ID from placeholder if needed
                liquidity_actions::do_update_pool_params(
                    executable,
                    account,
                    version::current(),
                    action_types::UpdatePoolParams {},
                    ctx
                );
            }
            else if (action_type == type_name::get<action_types::SetPoolStatus>()) {
                // This action can resolve pool ID from placeholder if needed
                liquidity_actions::do_set_pool_status(
                    executable,
                    account,
                    version::current(),
                    action_types::SetPoolStatus {},
                    ctx
                );
            }
            else if (action_type == type_name::get<action_types::AddLiquidity>()) {
                // AddLiquidity uses hot potato pattern and requires external coins/pool
                // Should be handled specially by the PTB
                // Skip for now
            }
            else if (action_type == type_name::get<action_types::RemoveLiquidity>()) {
                // RemoveLiquidity requires LP tokens - needs external provision
                // Should be handled specially by the PTB
                // Skip for now
            };

            // Advance the cursor after processing
            executable::increment_action_idx(executable);
        } else {
            // Not a liquidity action, stop and let next dispatcher handle it
            break
        }
    }
}

/// Special handler for create pool action with placeholder support
/// This would be called directly from PTB with required resources
public fun handle_create_pool_with_placeholder<AssetType: drop, StableType: drop>(
    executable: &mut Executable<ProposalOutcome>,
    account: &mut Account<FutarchyConfig>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Create resource request
    let request = liquidity_actions::do_create_pool(
        executable,
        account,
        version::current(),
        action_types::CreatePool {},
        ctx
    );

    // Get mutable context for placeholder registration
    let context = executable::context_mut(executable);

    // Fulfill with coins and register placeholder
    let (receipt, pool_id) = liquidity_actions::fulfill_create_pool(
        request,
        context,
        account,
        asset_coin,
        stable_coin,
        action_types::CreatePool {},
        ctx
    );

    // Consume receipt
    let _ = receipt;

    // Pool ID is now registered in placeholder if action specified one
}

/// Helper to check if an action type is a liquidity action
fun is_liquidity_action(action_type: TypeName): bool {
    action_type == type_name::get<action_types::CreatePool>() ||
    action_type == type_name::get<action_types::AddLiquidity>() ||
    action_type == type_name::get<action_types::RemoveLiquidity>() ||
    action_type == type_name::get<action_types::UpdatePoolParams>() ||
    action_type == type_name::get<action_types::SetPoolStatus>()
}