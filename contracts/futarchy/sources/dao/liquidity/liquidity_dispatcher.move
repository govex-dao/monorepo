/// Dispatcher for liquidity actions
module futarchy::liquidity_dispatcher;

// === Imports ===
use sui::tx_context::TxContext;
use account_protocol::{
    account::Account,
    executable::{Self, Executable},
};
use futarchy::{
    futarchy_config::FutarchyConfig,
    version,
    liquidity_actions,
};

// === Public(friend) Functions ===

/// Try to execute liquidity actions (pool management actions)
public(package) fun try_execute_liquidity_action<IW: drop, Outcome: store + drop + copy>(
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
/// Handles validation for typed liquidity operations
public(package) fun try_execute_typed_liquidity_action<AssetType: drop + store, StableType: drop + store, IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): bool {
    // For add liquidity actions, validate and document execution requirements
    if (executable::contains_action<Outcome, liquidity_actions::AddLiquidityAction<AssetType, StableType>>(executable)) {
        validate_add_liquidity_action<AssetType, StableType, IW, Outcome>(
            executable,
            account,
            witness,
            ctx
        );
        return true
    };
    
    // For remove liquidity actions, validate and document execution requirements  
    if (executable::contains_action<Outcome, liquidity_actions::RemoveLiquidityAction<AssetType, StableType>>(executable)) {
        validate_remove_liquidity_action<AssetType, StableType, IW, Outcome>(
            executable,
            account,
            witness,
            ctx
        );
        return true
    };
    
    // Try to execute CreatePoolAction
    if (executable::contains_action<Outcome, liquidity_actions::CreatePoolAction<AssetType, StableType>>(executable)) {
        liquidity_actions::do_create_pool<AssetType, StableType, Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    false
}

// === Helper Functions ===

/// Validate add liquidity action parameters
use futarchy::{
    futarchy_config,
};
use sui::object;
use account_protocol::account;

// === Constants ===
const EInvalidAmount: u64 = 4;
const ENoSpotPool: u64 = 5;
const EInvalidPoolId: u64 = 6;

fun validate_add_liquidity_action<AssetType, StableType, IW: drop, Outcome: store + drop + copy>(
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
    
    // Action validated - actual execution requires execute_add_liquidity_with_pool
    // with coins obtained from vault operations using Move framework vault intents:
    //
    // Example integration pattern:
    // 1. This function validates the AddLiquidityAction
    // 2. Use vault_intents::execute_spend() to withdraw asset_amount and stable_amount
    // 3. Call execute_add_liquidity_with_pool with the withdrawn coins
    // 4. LP tokens are automatically deposited to the custody registry
}

/// Validate remove liquidity action parameters
fun validate_remove_liquidity_action<AssetType, StableType, IW: drop, Outcome: store + drop + copy>(
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
    
    // Action validated - actual execution requires execute_remove_liquidity_with_pool
    // with LP tokens obtained from the custody system using Move framework patterns:
    //
    // Example integration pattern:
    // 1. This function validates the RemoveLiquidityAction
    // 2. Retrieve LP tokens from custody using lp_token_custody::withdraw_lp_token()
    // 3. Call execute_remove_liquidity_with_pool with the LP tokens
    // 4. Resulting coins can be deposited back to vault via vault_intents::execute_deposit()
}