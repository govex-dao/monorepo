/// Dispatcher for liquidity actions
module futarchy_actions::liquidity_dispatcher;

// === Imports ===
use std::option::{Self, Option};
use sui::tx_context::TxContext;
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
};
use futarchy_core::version;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_actions::liquidity_actions;
use futarchy_actions::resource_requests::ResourceRequest;

// === Constants ===
const EInvalidAmount: u64 = 4;
const ENoSpotPool: u64 = 5;
const EInvalidPoolId: u64 = 6;

// === Public Functions ===

/// Try to execute liquidity actions (pool management actions)
public fun try_execute_liquidity_action<IW: copy + drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext
): bool {
    // Try to execute UpdatePoolParamsAction
    if (executable::contains_action<Outcome, liquidity_actions::UpdatePoolParamsAction>(executable)) {
        liquidity_actions::do_update_pool_params<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    // Try to execute SetPoolStatusAction
    if (executable::contains_action<Outcome, liquidity_actions::SetPoolStatusAction>(executable)) {
        liquidity_actions::do_set_pool_status<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    // Note: AddLiquidityAction, RemoveLiquidityAction, and CreatePoolAction require specific coin types
    // and are handled in try_execute_typed_liquidity_action
    
    false
}

/// Execute liquidity actions with known types
/// Returns a ResourceRequest if a create pool action is found
public fun try_execute_typed_liquidity_action<AssetType: drop + store, StableType: drop + store, IW: copy + drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): (bool, Option<ResourceRequest<liquidity_actions::CreatePoolAction<AssetType, StableType>>>) {
    // For add liquidity actions, validate and document execution requirements
    if (executable::contains_action<Outcome, liquidity_actions::AddLiquidityAction<AssetType, StableType>>(executable)) {
        validate_add_liquidity_action<AssetType, StableType, IW, Outcome>(
            executable,
            account,
            witness,
            ctx
        );
        return (true, option::none())
    };
    
    // For remove liquidity actions, validate and document execution requirements  
    if (executable::contains_action<Outcome, liquidity_actions::RemoveLiquidityAction<AssetType, StableType>>(executable)) {
        validate_remove_liquidity_action<AssetType, StableType, IW, Outcome>(
            executable,
            account,
            witness,
            ctx
        );
        return (true, option::none())
    };
    
    // Try to execute CreatePoolAction - returns a ResourceRequest that must be fulfilled
    if (executable::contains_action<Outcome, liquidity_actions::CreatePoolAction<AssetType, StableType>>(executable)) {
        // Create pool action returns a ResourceRequest that must be fulfilled
        let request = liquidity_actions::do_create_pool<AssetType, StableType, Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        // Return the request to the caller for fulfillment
        return (true, option::some(request))
    };
    
    (false, option::none())
}

/// Execute add liquidity action and return ResourceRequest
public fun execute_add_liquidity<AssetType: drop + store, StableType: drop + store, IW: copy + drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): ResourceRequest<liquidity_actions::AddLiquidityAction<AssetType, StableType>> {
    liquidity_actions::do_add_liquidity<AssetType, StableType, Outcome, IW>(
        executable,
        account,
        version::current(),
        witness,
        ctx
    )
}

// === Helper Functions ===

/// Validate add liquidity action parameters
fun validate_add_liquidity_action<AssetType, StableType, IW: copy + drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &Account<FutarchyConfig>,
    witness: IW,
    _ctx: &mut TxContext,
) {
    // Extract and validate the action
    let action: &liquidity_actions::AddLiquidityAction<AssetType, StableType> = 
        executable::next_action(executable, witness);
    
    // Get action parameters
    let pool_id = liquidity_actions::get_pool_id(action);
    let asset_amount = liquidity_actions::get_asset_amount(action);
    let stable_amount = liquidity_actions::get_stable_amount(action);
    let _min_lp_amount = liquidity_actions::get_min_lp_amount(action);
    
    // Validate the action
    assert!(asset_amount > 0, EInvalidAmount);
    assert!(stable_amount > 0, EInvalidAmount);
    
    // Verify pool ID matches config
    let config = account::config(account);
    let stored_pool_id = futarchy_config::spot_pool_id(config);
    assert!(stored_pool_id.is_some(), ENoSpotPool);
    assert!(pool_id == *stored_pool_id.borrow(), EInvalidPoolId);
    
    // Action validated - actual execution requires fulfill_add_liquidity
    // with coins obtained from vault operations:
    //
    // Example integration pattern:
    // 1. This function validates the AddLiquidityAction
    // 2. Call execute_add_liquidity to get a ResourceRequest
    // 3. Fulfill the request with vault coins using fulfill_add_liquidity
    // 4. LP tokens are returned to the caller
}

/// Validate remove liquidity action parameters
fun validate_remove_liquidity_action<AssetType, StableType, IW: copy + drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &Account<FutarchyConfig>,
    witness: IW,
    _ctx: &mut TxContext,
) {
    // Extract and validate the action
    let action: &liquidity_actions::RemoveLiquidityAction<AssetType, StableType> = 
        executable::next_action(executable, witness);
    
    // Get action parameters
    let pool_id = liquidity_actions::get_remove_pool_id(action);
    let lp_amount = liquidity_actions::get_lp_amount(action);
    let _min_asset_amount = liquidity_actions::get_min_asset_amount(action);
    let _min_stable_amount = liquidity_actions::get_min_stable_amount(action);
    
    // Validate the action
    assert!(lp_amount > 0, EInvalidAmount);
    
    // Verify pool ID matches config
    let config = account::config(account);
    let stored_pool_id = futarchy_config::spot_pool_id(config);
    assert!(stored_pool_id.is_some(), ENoSpotPool);
    assert!(pool_id == *stored_pool_id.borrow(), EInvalidPoolId);
    
    // Action validated - actual execution requires do_remove_liquidity
    // with LP tokens and pool:
    //
    // Example integration pattern:
    // 1. This function validates the RemoveLiquidityAction
    // 2. Call do_remove_liquidity with LP tokens and pool
    // 3. Resulting coins can be deposited back to vault
}