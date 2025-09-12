/// Type-based dispatcher for liquidity actions
module futarchy_actions::liquidity_dispatcher;

// === Imports ===
use std::option::{Self, Option};
use std::type_name;
use std::string::String;
use sui::tx_context::TxContext;
use sui::clock::Clock;
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
};
use futarchy_core::version;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_actions::liquidity_actions;
use futarchy_actions::resource_requests::ResourceRequest;
use futarchy_utils::action_types;
use futarchy_one_shot_utils::action_data_structs;
use futarchy_markets::account_spot_pool::AccountSpotPool;

// === Constants ===
const EInvalidAmount: u64 = 4;
const ENoSpotPool: u64 = 5;
const EInvalidPoolId: u64 = 6;

// === Public Functions ===

/// Try to execute liquidity actions using type-based routing
public fun try_execute_liquidity_action<IW: copy + drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext
): bool {
    // Get current action type for O(1) routing
    let action_type = executable::current_action_type(executable);
    
    // Try to execute UpdatePoolParamsAction
    if (action_type == type_name::get<action_types::UpdatePoolParams>()) {
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
    if (action_type == type_name::get<action_types::SetPoolStatus>()) {
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
    // Get current action type for direct routing
    let action_type = executable::current_action_type(executable);

    // For add liquidity actions, validate and document execution requirements
    if (action_type == type_name::get<action_types::AddLiquidity>()) {
        validate_add_liquidity_action<AssetType, StableType, IW, Outcome>(
            executable,
            account,
            witness,
            ctx
        );
        return (true, option::none())
    };
    
    // For remove liquidity actions, validate and document execution requirements  
    if (action_type == type_name::get<action_types::RemoveLiquidity>()) {
        validate_remove_liquidity_action<AssetType, StableType, IW, Outcome>(
            executable,
            account,
            witness,
            ctx
        );
        return (true, option::none())
    };
    
    // Try to execute CreatePoolAction - returns a ResourceRequest that must be fulfilled
    if (action_type == type_name::get<action_types::CreatePool>()) {
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

/// Executes a liquidity-related init action.
/// Returns (bool: success, String: description).
public fun try_execute_init_action<AssetType: drop + store, StableType: drop + store>(
    action_type: &type_name::TypeName,
    action_data: &vector<u8>,
    account: &mut Account<FutarchyConfig>,
    spot_pool: &mut AccountSpotPool<AssetType, StableType>,
    _clock: &Clock,
    ctx: &mut TxContext,
): (bool, String) {
    if (*action_type == type_name::get<action_types::AddLiquidity>()) {
        let action = liquidity_actions::add_liquidity_action_from_bytes<AssetType, StableType>(*action_data);
        // The PTB is responsible for providing the actual Coin objects to the `add_liquidity` function.
        // This init action serves as the on-chain authorization and parameter source.
        // The actual call to `spot_pool.add_liquidity` happens in a higher-level module
        // that orchestrates resource (coin) management.
        // For the dispatcher, successfully deserializing and validating is sufficient.
        validate_add_liquidity_action_internal(account, &action);
        return (true, b"AddLiquidity".to_string())
    };

    if (*action_type == type_name::get<action_types::RemoveLiquidity>()) {
        let action = liquidity_actions::remove_liquidity_action_from_bytes<AssetType, StableType>(*action_data);
        validate_remove_liquidity_action_internal(account, &action);
        return (true, b"RemoveLiquidity".to_string())
    };
    
    // ... handle other liquidity actions like CreatePool ...

    (false, b"UnknownLiquidityAction".to_string())
}

/// Execute add liquidity action and return ResourceRequest
public fun execute_add_liquidity<AssetType: drop + store, StableType: drop + store, IW: copy + drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): ResourceRequest<action_data_structs::AddLiquidityAction<AssetType, StableType>> {
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
    let action: &action_data_structs::AddLiquidityAction<AssetType, StableType> = 
        executable::next_action(executable, witness);
    
    // Get action parameters
    let pool_id = action_data_structs::pool_id(action);
    let asset_amount = action_data_structs::asset_amount(action);
    let stable_amount = action_data_structs::stable_amount(action);
    let _min_lp_amount = action_data_structs::min_lp_out(action);
    
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

/// Internal validation logic, doesn't require executable.
fun validate_add_liquidity_action_internal<AssetType, StableType>(
    account: &Account<FutarchyConfig>,
    action: &action_data_structs::AddLiquidityAction<AssetType, StableType>
) {
    // Validate the action
    assert!(action_data_structs::asset_amount(action) > 0, EInvalidAmount);
    assert!(action_data_structs::stable_amount(action) > 0, EInvalidAmount);

    // Verify pool ID matches config
    let config = account::config(account);
    let stored_pool_id = futarchy_config::spot_pool_id(config);
    assert!(stored_pool_id.is_some(), ENoSpotPool);
    assert!(action_data_structs::pool_id(action) == *stored_pool_id.borrow(), EInvalidPoolId);
}

/// Internal validation logic, doesn't require executable.
fun validate_remove_liquidity_action_internal<AssetType, StableType>(
    account: &Account<FutarchyConfig>,
    action: &liquidity_actions::RemoveLiquidityAction<AssetType, StableType>
) {
    // Validate the action
    assert!(liquidity_actions::get_lp_amount(action) > 0, EInvalidAmount);

    // Verify pool ID matches config
    let config = account::config(account);
    let stored_pool_id = futarchy_config::spot_pool_id(config);
    assert!(stored_pool_id.is_some(), ENoSpotPool);
    assert!(liquidity_actions::get_remove_pool_id(action) == *stored_pool_id.borrow(), EInvalidPoolId);
}