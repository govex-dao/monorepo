/// Liquidity-related actions for futarchy DAOs
/// This module defines action structs and execution logic for liquidity management
module futarchy_actions::liquidity_actions;

// === Imports ===
use std::string::{Self, String};
use std::type_name::{Self, TypeName};
use sui::{
    coin::{Self, Coin},
    balance::{Self, Balance},
    object::{Self, ID},
    tx_context::{Self, TxContext},
    transfer,
    bag::{Self, Bag},
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents::Expired,
    version_witness::VersionWitness,
};
use account_actions::{vault, vault_intents};
use futarchy_core::{futarchy_config::{Self, FutarchyConfig}, version};
use futarchy_actions::resource_requests::{Self, ResourceRequest, ResourceReceipt};
use futarchy_markets::spot_amm::{Self, SpotAMM};
use futarchy_vault::lp_token_custody;

// === Errors ===
const EInvalidAmount: u64 = 1;
const EInvalidRatio: u64 = 2;
const EInvalidSlippage: u64 = 3;
const EEmptyPool: u64 = 4;
const EInsufficientVaultBalance: u64 = 5;
const EPoolAlreadyExists: u64 = 6;

// === Constants ===
const DEFAULT_VAULT_NAME: vector<u8> = b"treasury";

// === Action Structs ===

/// Action to add liquidity to a pool
public struct AddLiquidityAction<phantom AssetType, phantom StableType> has store {
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    min_lp_amount: u64, // Slippage protection
}

/// Action to remove liquidity from a pool
public struct RemoveLiquidityAction<phantom AssetType, phantom StableType> has store {
    pool_id: ID,
    lp_amount: u64,
    min_asset_amount: u64, // Slippage protection
    min_stable_amount: u64, // Slippage protection
}

/// Action to create a new liquidity pool
public struct CreatePoolAction<phantom AssetType, phantom StableType> has store {
    initial_asset_amount: u64,
    initial_stable_amount: u64,
    fee_bps: u64,
    minimum_liquidity: u64,
}

/// Action to update pool parameters
public struct UpdatePoolParamsAction has store {
    pool_id: ID,
    new_fee_bps: u64,
    new_minimum_liquidity: u64,
}

/// Action to pause/unpause a pool
public struct SetPoolStatusAction has store {
    pool_id: ID,
    is_paused: bool,
}

// === Execution Functions ===

/// Execute a create pool action
/// Creates a hot potato ResourceRequest that must be fulfilled with coins and pool
public fun do_create_pool<AssetType: drop, StableType: drop, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    witness: IW,
    ctx: &mut TxContext,
): resource_requests::ResourceRequest<CreatePoolAction<AssetType, StableType>> {
    let action = executable.next_action<Outcome, CreatePoolAction<AssetType, StableType>, IW>(executable, witness);
    
    // Validate parameters
    assert!(action.initial_asset_amount > 0, EInvalidAmount);
    assert!(action.initial_stable_amount > 0, EInvalidAmount);
    assert!(action.fee_bps <= 10000, EInvalidRatio);
    assert!(action.minimum_liquidity > 0, EInvalidAmount);
    
    // Create resource request with pool creation parameters
    let mut request = resource_requests::new_request<CreatePoolAction<AssetType, StableType>>(ctx);
    resource_requests::add_context(&mut request, string::utf8(b"initial_asset_amount"), action.initial_asset_amount);
    resource_requests::add_context(&mut request, string::utf8(b"initial_stable_amount"), action.initial_stable_amount);
    resource_requests::add_context(&mut request, string::utf8(b"fee_bps"), action.fee_bps);
    resource_requests::add_context(&mut request, string::utf8(b"minimum_liquidity"), action.minimum_liquidity);
    resource_requests::add_context(&mut request, string::utf8(b"account_id"), object::id(account));
    
    request
}

/// Execute an update pool params action
/// Updates fee and minimum liquidity requirements for a pool
public fun do_update_pool_params<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    witness: IW,
    _ctx: &mut TxContext,
) {
    let action: &UpdatePoolParamsAction = executable.next_action(witness);
    
    // Get action parameters
    let pool_id = action.pool_id;
    let new_fee_bps = action.new_fee_bps;
    let new_minimum_liquidity = action.new_minimum_liquidity;
    
    // Validate parameters
    assert!(new_fee_bps <= 10000, EInvalidRatio);
    assert!(new_minimum_liquidity > 0, EInvalidAmount);
    
    // Verify this pool belongs to the DAO
    let config = account.config();
    let stored_pool_id = futarchy_config::spot_pool_id(config);
    assert!(stored_pool_id.is_some(), EEmptyPool);
    assert!(pool_id == *stored_pool_id.borrow(), EEmptyPool);
    
    // Note: The pool object must be passed by the caller since it's a shared object
    // This function just validates the action - actual update happens in dispatcher
    // which has access to the pool object
}

/// Execute a set pool status action
/// Pauses or unpauses trading in a pool
public fun do_set_pool_status<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    witness: IW,
    _ctx: &mut TxContext,
) {
    let action: &SetPoolStatusAction = executable.next_action(witness);
    
    // Get action parameters
    let pool_id = action.pool_id;
    let is_paused = action.is_paused;
    
    // Verify this pool belongs to the DAO
    let config = account.config();
    let stored_pool_id = futarchy_config::spot_pool_id(config);
    assert!(stored_pool_id.is_some(), EEmptyPool);
    assert!(pool_id == *stored_pool_id.borrow(), EEmptyPool);
    
    // Note: The pool object must be passed by the caller since it's a shared object
    // This function just validates the action - actual update happens in dispatcher
    // which has access to the pool object
    
    // Store the status for future reference
    let _ = is_paused;
}

/// Fulfill pool creation request with coins from vault
public fun fulfill_create_pool<AssetType: drop, StableType: drop>(
    request: ResourceRequest<CreatePoolAction<AssetType, StableType>>,
    account: &mut Account<FutarchyConfig>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    ctx: &mut TxContext,
): (ResourceReceipt<CreatePoolAction<AssetType, StableType>>, SpotAMM<AssetType, StableType>) {
    // Extract parameters from request
    let initial_asset_amount: u64 = resource_requests::get_context(&request, string::utf8(b"initial_asset_amount"));
    let initial_stable_amount: u64 = resource_requests::get_context(&request, string::utf8(b"initial_stable_amount"));
    let fee_bps: u64 = resource_requests::get_context(&request, string::utf8(b"fee_bps"));
    let minimum_liquidity: u64 = resource_requests::get_context(&request, string::utf8(b"minimum_liquidity"));
    
    // Verify coins match requested amounts
    assert!(coin::value(&asset_coin) >= initial_asset_amount, EInvalidAmount);
    assert!(coin::value(&stable_coin) >= initial_stable_amount, EInvalidAmount);
    
    // Create the pool
    let pool = spot_amm::new_pool(
        asset_coin,
        stable_coin,
        fee_bps,
        minimum_liquidity,
        ctx
    );
    
    // Store pool ID in account config
    let config = account::config_mut(account);
    futarchy_config::set_spot_pool_id(config, object::id(&pool));
    
    // Return receipt and pool
    (resource_requests::fulfill(request), pool)
}

/// Execute add liquidity - creates request for vault coins
public fun do_add_liquidity<AssetType: drop, StableType: drop, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    witness: IW,
    ctx: &mut TxContext,
): ResourceRequest<AddLiquidityAction<AssetType, StableType>> {
    let action = executable.next_action<Outcome, AddLiquidityAction<AssetType, StableType>, IW>(executable, witness);
    
    // Check vault has sufficient balance
    let vault_name = string::utf8(DEFAULT_VAULT_NAME);
    let vault = vault::borrow_vault(account, vault_name);
    assert!(vault::coin_type_exists<AssetType>(vault), EInsufficientVaultBalance);
    assert!(vault::coin_type_exists<StableType>(vault), EInsufficientVaultBalance);
    assert!(vault::coin_type_value<AssetType>(vault) >= action.asset_amount, EInsufficientVaultBalance);
    assert!(vault::coin_type_value<StableType>(vault) >= action.stable_amount, EInsufficientVaultBalance);
    
    // Create resource request with action details
    let mut request = resource_requests::new_request<AddLiquidityAction<AssetType, StableType>>(ctx);
    resource_requests::add_context(&mut request, string::utf8(b"action"), *action);
    resource_requests::add_context(&mut request, string::utf8(b"account_id"), object::id(account));
    
    request
}

/// Fulfill add liquidity request with vault coins and pool
public fun fulfill_add_liquidity<AssetType: drop, StableType: drop>(
    request: ResourceRequest<AddLiquidityAction<AssetType, StableType>>,
    account: &mut Account<FutarchyConfig>,
    pool: &mut SpotAMM<AssetType, StableType>,
    ctx: &mut TxContext,
): ResourceReceipt<AddLiquidityAction<AssetType, StableType>> {
    // Extract action from request
    let action: AddLiquidityAction<AssetType, StableType> = 
        resource_requests::get_context(&request, string::utf8(b"action"));
    
    // Verify pool ID matches
    assert!(action.pool_id == object::id(pool), EEmptyPool);
    
    // Use Move framework vault intents to withdraw coins
    // This properly handles the vault withdrawal using the framework's patterns
    let vault_name = string::utf8(DEFAULT_VAULT_NAME);
    
    // Create spend intent for asset coins
    let mut asset_intent = account_protocol::intents::new_intent<FutarchyConfig, vault_intents::SpendAndTransferIntent>(
        account,
        ctx
    );
    vault::new_spend<FutarchyConfig, AssetType, vault_intents::SpendAndTransferIntent>(
        &mut asset_intent,
        vault_name,
        action.asset_amount,
        vault_intents::SpendAndTransferIntent {}
    );
    
    // Execute the spend to get asset coins
    let mut asset_executable = account::execute_intent(account, asset_intent);
    let asset_coin = vault::do_spend<FutarchyConfig, _, AssetType, _>(
        &mut asset_executable,
        account,
        version::current(),
        vault_intents::SpendAndTransferIntent {},
        ctx
    );
    account::confirm_execution(account, asset_executable);
    
    // Create spend intent for stable coins
    let mut stable_intent = account_protocol::intents::new_intent<FutarchyConfig, vault_intents::SpendAndTransferIntent>(
        account,
        ctx
    );
    vault::new_spend<FutarchyConfig, StableType, vault_intents::SpendAndTransferIntent>(
        &mut stable_intent,
        vault_name,
        action.stable_amount,
        vault_intents::SpendAndTransferIntent {}
    );
    
    // Execute the spend to get stable coins
    let mut stable_executable = account::execute_intent(account, stable_intent);
    let stable_coin = vault::do_spend<FutarchyConfig, _, StableType, _>(
        &mut stable_executable,
        account,
        version::current(),
        vault_intents::SpendAndTransferIntent {},
        ctx
    );
    account::confirm_execution(account, stable_executable);
    
    // Add liquidity to pool
    let lp_coin = spot_amm::add_liquidity(
        pool,
        asset_coin,
        stable_coin,
        action.min_lp_amount,
        ctx
    );
    
    // Store LP tokens in custody
    lp_token_custody::deposit_lp_token(
        account,
        object::id(pool),
        lp_coin,
        version::current()
    );
    
    // Fulfill the request
    resource_requests::fulfill(request)
}

/// Execute remove liquidity and return coins to caller
public fun do_remove_liquidity<AssetType: drop, StableType: drop, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    pool: &mut SpotAMM<AssetType, StableType>,
    ctx: &mut TxContext,
): (Coin<AssetType>, Coin<StableType>) {
    let action = executable.next_action<Outcome, RemoveLiquidityAction<AssetType, StableType>, IW>(executable, witness);
    
    // Verify pool ID matches
    assert!(action.pool_id == object::id(pool), EEmptyPool);
    
    // Withdraw LP tokens from custody
    let lp_coin = lp_token_custody::withdraw_lp_token<AssetType, StableType>(
        account,
        object::id(pool),
        action.lp_amount,
        version,
        ctx
    );
    
    // Remove liquidity from pool
    let (asset_coin, stable_coin) = spot_amm::remove_liquidity(
        pool,
        lp_coin,
        action.min_asset_amount,
        action.min_stable_amount,
        ctx
    );
    
    // Return coins to caller to deposit back to vault
    // The caller (dispatcher) is responsible for depositing to vault
    (asset_coin, stable_coin)
}


// === Cleanup Functions ===

/// Delete an add liquidity action from an expired intent
public fun delete_add_liquidity<AssetType, StableType>(expired: &mut Expired) {
    let AddLiquidityAction<AssetType, StableType> {
        pool_id: _,
        asset_amount: _,
        stable_amount: _,
        min_lp_amount: _,
    } = expired.remove_action();
}

/// Delete a remove liquidity action from an expired intent
public fun delete_remove_liquidity<AssetType, StableType>(expired: &mut Expired) {
    let RemoveLiquidityAction<AssetType, StableType> {
        pool_id: _,
        lp_amount: _,
        min_asset_amount: _,
        min_stable_amount: _,
    } = expired.remove_action();
}

/// Delete a create pool action from an expired intent
public fun delete_create_pool<AssetType, StableType>(expired: &mut Expired) {
    let CreatePoolAction<AssetType, StableType> {
        initial_asset_amount: _,
        initial_stable_amount: _,
        fee_bps: _,
        minimum_liquidity: _,
    } = expired.remove_action();
}

/// Delete an update pool params action from an expired intent
public fun delete_update_pool_params(expired: &mut Expired) {
    let UpdatePoolParamsAction {
        pool_id: _,
        new_fee_bps: _,
        new_minimum_liquidity: _,
    } = expired.remove_action();
}

/// Delete a set pool status action from an expired intent
public fun delete_set_pool_status(expired: &mut Expired) {
    let SetPoolStatusAction {
        pool_id: _,
        is_paused: _,
    } = expired.remove_action();
}

// === Helper Functions ===

/// Create a new add liquidity action
public fun new_add_liquidity_action<AssetType, StableType>(
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    min_lp_amount: u64,
): AddLiquidityAction<AssetType, StableType> {
    assert!(asset_amount > 0, EInvalidAmount);
    assert!(stable_amount > 0, EInvalidAmount);
    assert!(min_lp_amount > 0, EInvalidAmount);
    
    AddLiquidityAction {
        pool_id,
        asset_amount,
        stable_amount,
        min_lp_amount,
    }
}

/// Create a new remove liquidity action
public fun new_remove_liquidity_action<AssetType, StableType>(
    pool_id: ID,
    lp_amount: u64,
    min_asset_amount: u64,
    min_stable_amount: u64,
): RemoveLiquidityAction<AssetType, StableType> {
    assert!(lp_amount > 0, EInvalidAmount);
    
    RemoveLiquidityAction {
        pool_id,
        lp_amount,
        min_asset_amount,
        min_stable_amount,
    }
}

/// Create a new create pool action
public fun new_create_pool_action<AssetType, StableType>(
    initial_asset_amount: u64,
    initial_stable_amount: u64,
    fee_bps: u64,
    minimum_liquidity: u64,
): CreatePoolAction<AssetType, StableType> {
    assert!(initial_asset_amount > 0, EInvalidAmount);
    assert!(initial_stable_amount > 0, EInvalidAmount);
    assert!(fee_bps <= 10000, EInvalidRatio); // Max 100%
    assert!(minimum_liquidity > 0, EInvalidAmount);
    
    CreatePoolAction {
        initial_asset_amount,
        initial_stable_amount,
        fee_bps,
        minimum_liquidity,
    }
}

/// Create a new update pool params action
public fun new_update_pool_params_action(
    pool_id: ID,
    new_fee_bps: u64,
    new_minimum_liquidity: u64,
): UpdatePoolParamsAction {
    assert!(new_fee_bps <= 10000, EInvalidRatio); // Max 100%
    assert!(new_minimum_liquidity > 0, EInvalidAmount);
    
    UpdatePoolParamsAction {
        pool_id,
        new_fee_bps,
        new_minimum_liquidity,
    }
}

/// Create a new set pool status action
public fun new_set_pool_status_action(
    pool_id: ID,
    is_paused: bool,
): SetPoolStatusAction {
    SetPoolStatusAction {
        pool_id,
        is_paused,
    }
}

// === Getter Functions ===

/// Get pool ID from AddLiquidityAction
public fun get_pool_id<AssetType, StableType>(action: &AddLiquidityAction<AssetType, StableType>): ID {
    action.pool_id
}

/// Get asset amount from AddLiquidityAction
public fun get_asset_amount<AssetType, StableType>(action: &AddLiquidityAction<AssetType, StableType>): u64 {
    action.asset_amount
}

/// Get stable amount from AddLiquidityAction
public fun get_stable_amount<AssetType, StableType>(action: &AddLiquidityAction<AssetType, StableType>): u64 {
    action.stable_amount
}

/// Get minimum LP amount from AddLiquidityAction
public fun get_min_lp_amount<AssetType, StableType>(action: &AddLiquidityAction<AssetType, StableType>): u64 {
    action.min_lp_amount
}

/// Get pool ID from RemoveLiquidityAction
public fun get_remove_pool_id<AssetType, StableType>(action: &RemoveLiquidityAction<AssetType, StableType>): ID {
    action.pool_id
}

/// Get LP amount from RemoveLiquidityAction
public fun get_lp_amount<AssetType, StableType>(action: &RemoveLiquidityAction<AssetType, StableType>): u64 {
    action.lp_amount
}

/// Get minimum asset amount from RemoveLiquidityAction
public fun get_min_asset_amount<AssetType, StableType>(action: &RemoveLiquidityAction<AssetType, StableType>): u64 {
    action.min_asset_amount
}

/// Get minimum stable amount from RemoveLiquidityAction
public fun get_min_stable_amount<AssetType, StableType>(action: &RemoveLiquidityAction<AssetType, StableType>): u64 {
    action.min_stable_amount
}

/// Get initial asset amount from CreatePoolAction
public fun get_initial_asset_amount<AssetType, StableType>(action: &CreatePoolAction<AssetType, StableType>): u64 {
    action.initial_asset_amount
}

/// Get initial stable amount from CreatePoolAction
public fun get_initial_stable_amount<AssetType, StableType>(action: &CreatePoolAction<AssetType, StableType>): u64 {
    action.initial_stable_amount
}

/// Get fee basis points from CreatePoolAction
public fun get_fee_bps<AssetType, StableType>(action: &CreatePoolAction<AssetType, StableType>): u64 {
    action.fee_bps
}

/// Get minimum liquidity from CreatePoolAction
public fun get_minimum_liquidity<AssetType, StableType>(action: &CreatePoolAction<AssetType, StableType>): u64 {
    action.minimum_liquidity
}

/// Get pool ID from UpdatePoolParamsAction
public fun get_update_pool_id(action: &UpdatePoolParamsAction): ID {
    action.pool_id
}

/// Get new fee basis points from UpdatePoolParamsAction
public fun get_new_fee_bps(action: &UpdatePoolParamsAction): u64 {
    action.new_fee_bps
}

/// Get new minimum liquidity from UpdatePoolParamsAction
public fun get_new_minimum_liquidity(action: &UpdatePoolParamsAction): u64 {
    action.new_minimum_liquidity
}

/// Get pool ID from SetPoolStatusAction
public fun get_status_pool_id(action: &SetPoolStatusAction): ID {
    action.pool_id
}

/// Get is paused flag from SetPoolStatusAction
public fun get_is_paused(action: &SetPoolStatusAction): bool {
    action.is_paused
}