// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Liquidity-related actions for futarchy DAOs
/// This module defines action structs and execution logic for liquidity management
module futarchy_actions::liquidity_actions;

// === Imports ===
use std::string::{Self, String};
use std::option::{Self, Option};
use sui::{
    coin::{Self, Coin},
    object::{Self, ID},
    clock::Clock,
    tx_context::TxContext,
    balance::{Self, Balance},
    transfer,
    bcs::{Self, BCS},
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents::{Self, Expired, ActionSpec},
    version_witness::VersionWitness,
    bcs_validation,
    action_validation,
};
use account_actions::vault;
// === Action Type Markers ===

/// Create a liquidity pool
public struct CreatePool has drop {}
/// Update pool parameters
public struct UpdatePoolParams has drop {}
/// Add liquidity to pool
public struct AddLiquidity has drop {}
/// Withdraw LP tokens
public struct WithdrawLpToken has drop {}
/// Remove liquidity from pool
public struct RemoveLiquidity has drop {}
/// Swap tokens
public struct Swap has drop {}
/// Collect trading fees
public struct CollectFees has drop {}
/// Set pool status (active/paused)
public struct SetPoolStatus has drop {}
/// Withdraw collected fees
public struct WithdrawFees has drop {}
use futarchy_core::{
    futarchy_config::{Self, FutarchyConfig},
    version,
};
use futarchy_core::resource_requests::{Self, ResourceRequest, ResourceReceipt};
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool, LPToken};
use futarchy_markets_operations::lp_token_custody;
// AddLiquidityAction defined locally since futarchy_one_shot_utils module doesn't exist

// === Friend Modules === (deprecated in 2024 edition, using public(package) instead)

// === Errors ===
const EInvalidAmount: u64 = 1;
const EInvalidRatio: u64 = 2;
const EEmptyPool: u64 = 4;
const EInsufficientVaultBalance: u64 = 5;
const EWrongToken: u64 = 6;
const EBypassNotAllowed: u64 = 7;

// === Constants ===
const DEFAULT_VAULT_NAME: vector<u8> = b"treasury";

// === Action Structs ===

/// Action to add liquidity to a pool
public struct AddLiquidityAction<phantom AssetType, phantom StableType> has store, drop, copy {
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    min_lp_out: u64, // Slippage protection
}

/// Action to withdraw an LP token from custody
public struct WithdrawLpTokenAction<phantom AssetType, phantom StableType> has store, drop, copy {
    pool_id: ID,
    token_id: ID,
}

/// Action to remove liquidity from a pool
public struct RemoveLiquidityAction<phantom AssetType, phantom StableType> has store, drop, copy {
    pool_id: ID,
    token_id: ID,
    lp_amount: u64,
    min_asset_amount: u64, // Slippage protection
    min_stable_amount: u64, // Slippage protection
    bypass_minimum: bool,
}

/// Action to perform a swap in the pool
public struct SwapAction<phantom AssetType, phantom StableType> has store, drop {
    pool_id: ID,
    swap_asset: bool, // true = swap asset for stable, false = swap stable for asset
    amount_in: u64,
    min_amount_out: u64, // Slippage protection
}

/// Action to collect fees from the pool
public struct CollectFeesAction<phantom AssetType, phantom StableType> has store, drop {
    pool_id: ID,
}

/// Action to withdraw accumulated fees to treasury
public struct WithdrawFeesAction<phantom AssetType, phantom StableType> has store, drop {
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
}

/// Action to create a new liquidity pool
public struct CreatePoolAction<phantom AssetType, phantom StableType> has store, drop, copy {
    initial_asset_amount: u64,
    initial_stable_amount: u64,
    fee_bps: u64,
    minimum_liquidity: u64,
}

/// Action to update pool parameters
public struct UpdatePoolParamsAction has store, drop, copy {
    pool_id: ID,           // Direct pool ID
    new_fee_bps: u64,
    new_minimum_liquidity: u64,
}

/// Action to pause/unpause a pool
public struct SetPoolStatusAction has store, drop, copy {
    pool_id: ID,           // Direct pool ID
    is_paused: bool,
}

// === Execution Functions ===

/// Execute a create pool action with type validation
/// Creates a hot potato ResourceRequest that must be fulfilled with coins and pool
public fun do_create_pool<AssetType: drop, StableType: drop, Outcome: store, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    _version: VersionWitness,
    witness: IW,
    ctx: &mut TxContext,
): resource_requests::ResourceRequest<CreatePoolAction<AssetType, StableType>> {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<CreatePool>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization
    let mut reader = bcs::new(*action_data);
    let initial_asset_amount = bcs::peel_u64(&mut reader);
    let initial_stable_amount = bcs::peel_u64(&mut reader);
    let fee_bps = bcs::peel_u64(&mut reader);
    let minimum_liquidity = bcs::peel_u64(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    // Create action struct
    let action = CreatePoolAction<AssetType, StableType> {
        initial_asset_amount,
        initial_stable_amount,
        fee_bps,
        minimum_liquidity,
    };
    
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

/// Execute an update pool params action with type validation
/// Updates fee and minimum liquidity requirements for a pool
public fun do_update_pool_params<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    _version: VersionWitness,
    witness: IW,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<UpdatePoolParams>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization - simplified without placeholders
    let mut reader = bcs::new(*action_data);
    let pool_id = object::id_from_address(bcs::peel_address(&mut reader));
    let new_fee_bps = bcs::peel_u64(&mut reader);
    let new_minimum_liquidity = bcs::peel_u64(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);
    
    // Validate parameters
    assert!(new_fee_bps <= 10000, EInvalidRatio);
    assert!(new_minimum_liquidity > 0, EInvalidAmount);
    
    // Verify this pool belongs to the DAO
    let _config = account::config<FutarchyConfig>(account);
    // Pool validation would be done against stored pools in the Account
    // For now, just validate pool_id is not zero
    assert!(pool_id != object::id_from_address(@0x0), EEmptyPool);

    // Note: The pool object must be passed by the caller since it's a shared object
    // This function just validates the action - actual update happens in dispatcher
    // which has access to the pool object

    // Execute and increment
    executable::increment_action_idx(executable);
}

/// Execute a set pool status action with type validation
/// Pauses or unpauses trading in a pool
public fun do_set_pool_status<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    _version: VersionWitness,
    witness: IW,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<SetPoolStatus>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization - simplified without placeholders
    let mut reader = bcs::new(*action_data);
    let pool_id = object::id_from_address(bcs::peel_address(&mut reader));
    let is_paused = bcs::peel_bool(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);
    
    // Verify this pool belongs to the DAO
    let _config = account::config<FutarchyConfig>(account);
    // Pool validation would be done against stored pools in the Account
    // For now, just validate pool_id is not zero
    assert!(pool_id != object::id_from_address(@0x0), EEmptyPool);
    
    // Note: The pool object must be passed by the caller since it's a shared object
    // This function just validates the action - actual update happens in dispatcher
    // which has access to the pool object

    // Store the status for future reference
    let _ = is_paused;

    // Execute and increment
    executable::increment_action_idx(executable);
}

/// Fulfill pool creation request with coins from vault
public fun fulfill_create_pool<AssetType: drop, StableType: drop, IW: copy + drop>(
    request: ResourceRequest<CreatePoolAction<AssetType, StableType>>,
    account: &mut Account,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    witness: IW,
    ctx: &mut TxContext,
): (ResourceReceipt<CreatePoolAction<AssetType, StableType>>, ID) {
    // Extract parameters from request
    let initial_asset_amount: u64 = resource_requests::get_context(&request, string::utf8(b"initial_asset_amount"));
    let initial_stable_amount: u64 = resource_requests::get_context(&request, string::utf8(b"initial_stable_amount"));
    let fee_bps: u64 = resource_requests::get_context(&request, string::utf8(b"fee_bps"));
    let _minimum_liquidity: u64 = resource_requests::get_context(&request, string::utf8(b"minimum_liquidity"));
    
    // Verify coins match requested amounts
    assert!(coin::value(&asset_coin) >= initial_asset_amount, EInvalidAmount);
    assert!(coin::value(&stable_coin) >= initial_stable_amount, EInvalidAmount);
    
    // Create the pool using account_spot_pool
    let mut pool = unified_spot_pool::new<AssetType, StableType>(fee_bps, ctx);
    
    // Add initial liquidity to the pool
    let lp_token = unified_spot_pool::add_liquidity_and_return(
        &mut pool,
        asset_coin,
        stable_coin,
        0, // min_lp_out - 0 for initial liquidity
        ctx
    );

    // Get pool ID before sharing
    let pool_id = object::id(&pool);

    // Share the pool so it can be accessed by anyone (must share before depositing LP)
    unified_spot_pool::share(pool);

    // Deposit LP token to custody (using witness for auth)
    lp_token_custody::deposit_lp_token(
        account,
        pool_id,
        lp_token,
        witness,
        ctx
    );

    // Return receipt and pool ID
    (resource_requests::fulfill(request), pool_id)
}

/// Execute add liquidity with type validation - creates request for vault coins
public fun do_add_liquidity<AssetType: drop, StableType: drop, Outcome: store, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    _version: VersionWitness,
    witness: IW,
    ctx: &mut TxContext,
): ResourceRequest<AddLiquidityAction<AssetType, StableType>> {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<AddLiquidity>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization
    let mut reader = bcs::new(*action_data);
    let pool_id = object::id_from_address(bcs::peel_address(&mut reader));
    let asset_amount = bcs::peel_u64(&mut reader);
    let stable_amount = bcs::peel_u64(&mut reader);
    let min_lp_out = bcs::peel_u64(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    // Create action struct
    let action = AddLiquidityAction<AssetType, StableType> {
        pool_id,
        asset_amount,
        stable_amount,
        min_lp_out
    };
    
    // Check vault has sufficient balance
    let vault_name = string::utf8(DEFAULT_VAULT_NAME);
    let vault = vault::borrow_vault(account, vault_name);
    assert!(vault::coin_type_exists<AssetType>(vault), EInsufficientVaultBalance);
    assert!(vault::coin_type_exists<StableType>(vault), EInsufficientVaultBalance);
    assert!(vault::coin_type_value<AssetType>(vault) >= action.asset_amount, EInsufficientVaultBalance);
    assert!(vault::coin_type_value<StableType>(vault) >= action.stable_amount, EInsufficientVaultBalance);
    
    // Create resource request with action details (make a copy since action has copy ability)
    let mut request = resource_requests::new_request<AddLiquidityAction<AssetType, StableType>>(ctx);
    // Context not needed for typed requests
    // resource_requests::add_context(&mut request, string::utf8(b"action"), action);
    resource_requests::add_context(&mut request, string::utf8(b"account_id"), object::id(account));

    request
}

/// Fulfill add liquidity request with vault coins and pool
/// Deposits LP token to custody automatically
public fun fulfill_add_liquidity<AssetType: drop, StableType: drop, Outcome: store, IW: copy + drop>(
    request: ResourceRequest<AddLiquidityAction<AssetType, StableType>>,
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    witness: IW,
    ctx: &mut TxContext,
): ResourceReceipt<AddLiquidityAction<AssetType, StableType>> {
    // Extract action from request (this consumes the request)
    let action: AddLiquidityAction<AssetType, StableType> =
        resource_requests::extract_action(request);

    // Get action parameters
    let pool_id = action.pool_id;
    let min_lp_amount = action.min_lp_out;

    // Verify pool ID matches
    assert!(pool_id == object::id(pool), EEmptyPool);

    // Use vault::do_spend to withdraw coins (this is the proper way)
    // Requires proper action setup in the executable
    let asset_coin = vault::do_spend<FutarchyConfig, Outcome, AssetType, IW>(
        executable,
        account,
        version::current(),
        witness,
        ctx
    );

    let stable_coin = vault::do_spend<FutarchyConfig, Outcome, StableType, IW>(
        executable,
        account,
        version::current(),
        witness,
        ctx
    );

    // Add liquidity to pool and get LP token
    let lp_token = unified_spot_pool::add_liquidity_and_return(
        pool,
        asset_coin,
        stable_coin,
        min_lp_amount,
        ctx
    );

    // Deposit LP token to custody (using witness for auth)
    lp_token_custody::deposit_lp_token(
        account,
        pool_id,
        lp_token,
        witness,
        ctx
    );

    // Create and return receipt
    resource_requests::create_receipt(action)
}

/// Execute withdraw LP token action with type validation
/// Returns a hot potato that must be fulfilled to obtain the LP token
public fun do_withdraw_lp_token<AssetType: drop, StableType: drop, Outcome: store, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    _version: VersionWitness,
    _witness: IW,
    ctx: &mut TxContext,
): resource_requests::ResourceRequest<WithdrawLpTokenAction<AssetType, StableType>> {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<WithdrawLpToken>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization
    let mut reader = bcs::new(*action_data);
    let pool_id = object::id_from_address(bcs::peel_address(&mut reader));
    let token_id = object::id_from_address(bcs::peel_address(&mut reader));
    bcs_validation::validate_all_bytes_consumed(reader);

    // Create action struct
    let action = WithdrawLpTokenAction<AssetType, StableType> {
        pool_id,
        token_id,
    };

    // Ensure the token exists in custody before fulfillment
    let token_amount = lp_token_custody::get_token_amount(account, token_id);
    assert!(token_amount > 0, EWrongToken);

    // Execute and increment
    executable::increment_action_idx(executable);

    resource_requests::new_resource_request(action, ctx)
}

/// Fulfill withdraw LP token request by releasing the LP from custody
public fun fulfill_withdraw_lp_token<AssetType: drop, StableType: drop, W: copy + drop>(
    request: resource_requests::ResourceRequest<WithdrawLpTokenAction<AssetType, StableType>>,
    account: &mut Account,
    witness: W,
    ctx: &mut TxContext,
): (LPToken<AssetType, StableType>, resource_requests::ResourceReceipt<WithdrawLpTokenAction<AssetType, StableType>>) {
    let action = resource_requests::extract_action(request);

    let lp_token = lp_token_custody::withdraw_lp_token<AssetType, StableType, W>(
        account,
        action.pool_id,
        action.token_id,
        witness,
        ctx
    );

    let receipt = resource_requests::create_receipt(action);
    (lp_token, receipt)
}

/// Execute remove liquidity with type validation
/// Returns a hot potato that must be fulfilled with the released LP token
public fun do_remove_liquidity<AssetType: drop, StableType: drop, Outcome: store, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    _version: VersionWitness,
    witness: IW,
    ctx: &mut TxContext,
): resource_requests::ResourceRequest<RemoveLiquidityAction<AssetType, StableType>> {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<RemoveLiquidity>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization
    let mut reader = bcs::new(*action_data);
    let pool_id = object::id_from_address(bcs::peel_address(&mut reader));
    let token_id = object::id_from_address(bcs::peel_address(&mut reader));
    let lp_amount = bcs::peel_u64(&mut reader);
    let min_asset_amount = bcs::peel_u64(&mut reader);
    let min_stable_amount = bcs::peel_u64(&mut reader);
    let bypass_minimum = bcs::peel_bool(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    assert!(lp_amount > 0, EInvalidAmount);
    assert!(!bypass_minimum, EBypassNotAllowed);

    let action = RemoveLiquidityAction<AssetType, StableType> {
        pool_id,
        token_id,
        lp_amount,
        min_asset_amount,
        min_stable_amount,
        bypass_minimum: false,
    };

    let _ = account;
    let _ = witness;

    // Execute and increment
    executable::increment_action_idx(executable);

    resource_requests::new_resource_request(action, ctx)
}

/// Fulfill remove liquidity request with released LP token and pool reference
public fun fulfill_remove_liquidity<AssetType: drop, StableType: drop, W: copy + drop>(
    request: resource_requests::ResourceRequest<RemoveLiquidityAction<AssetType, StableType>>,
    account: &mut Account,
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    lp_token: LPToken<AssetType, StableType>,
    witness: W,
    ctx: &mut TxContext,
): (Coin<AssetType>, Coin<StableType>, resource_requests::ResourceReceipt<RemoveLiquidityAction<AssetType, StableType>>) {
    let action = resource_requests::extract_action(request);

    assert!(action.pool_id == object::id(pool), EEmptyPool);
    assert!(action.token_id == object::id(&lp_token), EWrongToken);

    // Verify the DAO authorization before burning the LP token
    let auth = account::new_auth<FutarchyConfig, W>(account, version::current(), witness);
    account::verify(account, auth);

    let actual_lp_amount = unified_spot_pool::lp_token_amount(&lp_token);
    assert!(actual_lp_amount >= action.lp_amount, EInvalidAmount);

    let (asset_coin, stable_coin) = if (action.bypass_minimum) {
        {
            let dao_state = futarchy_config::state_mut_from_account(account);
            assert!(
                futarchy_config::operational_state(dao_state) == futarchy_config::state_terminated(),
                EBypassNotAllowed
            );
        };

        let (asset_coin, stable_coin) = unified_spot_pool::remove_liquidity_for_dissolution(
            pool,
            lp_token,
            true,
            ctx
        );

        assert!(coin::value(&asset_coin) >= action.min_asset_amount, EInvalidAmount);
        assert!(coin::value(&stable_coin) >= action.min_stable_amount, EInvalidAmount);

        (asset_coin, stable_coin)
    } else {
        unified_spot_pool::remove_liquidity(
            pool,
            lp_token,
            action.min_asset_amount,
            action.min_stable_amount,
            ctx
        )
    };

    let receipt = resource_requests::create_receipt(action);

    (asset_coin, stable_coin, receipt)
}

/// Execute a swap action with type validation
public fun do_swap<AssetType: drop, StableType: drop, Outcome: store, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account,
    _version: VersionWitness,
    witness: IW,
    _ctx: &mut TxContext,
): ResourceRequest<SwapAction<AssetType, StableType>> {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<Swap>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization
    let mut reader = bcs::new(*action_data);
    let pool_id = object::id_from_address(bcs::peel_address(&mut reader));
    let swap_asset = bcs::peel_bool(&mut reader);
    let amount_in = bcs::peel_u64(&mut reader);
    let min_amount_out = bcs::peel_u64(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    // Create action struct
    let action = SwapAction<AssetType, StableType> {
        pool_id,
        swap_asset,
        amount_in,
        min_amount_out,
    };

    // Validate parameters
    assert!(action.amount_in > 0, EInvalidAmount);
    assert!(action.min_amount_out > 0, EInvalidAmount);

    // Create resource request
    let mut request = resource_requests::new_request<SwapAction<AssetType, StableType>>(_ctx);
    resource_requests::add_context(&mut request, string::utf8(b"pool_id"), pool_id);
    resource_requests::add_context(&mut request, string::utf8(b"swap_asset"), if (swap_asset) 1 else 0);
    resource_requests::add_context(&mut request, string::utf8(b"amount_in"), amount_in);
    resource_requests::add_context(&mut request, string::utf8(b"min_amount_out"), min_amount_out);

    request
}

/// Execute collect fees action with type validation
public fun do_collect_fees<AssetType: drop, StableType: drop, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    _version: VersionWitness,
    witness: IW,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<CollectFees>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization
    let mut reader = bcs::new(*action_data);
    let pool_id = object::id_from_address(bcs::peel_address(&mut reader));
    bcs_validation::validate_all_bytes_consumed(reader);

    // Verify this pool belongs to the DAO
    let _config = account::config<FutarchyConfig>(account);
    // Pool validation would be done against stored pools in the Account
    // For now, just validate pool_id is not zero
    assert!(pool_id != object::id_from_address(@0x0), EEmptyPool);

    // Note: Actual fee collection happens in dispatcher with pool access

    // Execute and increment
    executable::increment_action_idx(executable);
}

/// Execute withdraw fees action with type validation
public fun do_withdraw_fees<AssetType: drop, StableType: drop, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    _version: VersionWitness,
    witness: IW,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<WithdrawFees>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization
    let mut reader = bcs::new(*action_data);
    let pool_id = object::id_from_address(bcs::peel_address(&mut reader));
    let asset_amount = bcs::peel_u64(&mut reader);
    let stable_amount = bcs::peel_u64(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    // Verify this pool belongs to the DAO
    let _config = account::config<FutarchyConfig>(account);
    // Pool validation would be done against stored pools in the Account
    // For now, just validate pool_id is not zero
    assert!(pool_id != object::id_from_address(@0x0), EEmptyPool);

    // Validate amounts
    assert!(asset_amount > 0 || stable_amount > 0, EInvalidAmount);

    // Note: Actual withdrawal happens in dispatcher with pool access
    let _ = asset_amount;
    let _ = stable_amount;

    // Execute and increment
    executable::increment_action_idx(executable);
}

// === Cleanup Functions ===

/// Delete an add liquidity action from an expired intent
public fun delete_add_liquidity<AssetType, StableType>(expired: &mut Expired) {
    let action_spec = intents::remove_action_spec(expired);
    // Action spec data will be dropped automatically
    // Expired intent is automatically destroyed when it goes out of scope
}

/// Delete a withdraw LP token action from an expired intent
public fun delete_withdraw_lp_token<AssetType, StableType>(expired: &mut Expired) {
    let action_spec = intents::remove_action_spec(expired);
    // Action spec data will be dropped automatically
    // Expired intent is automatically destroyed when it goes out of scope
}

/// Delete a remove liquidity action from an expired intent
public fun delete_remove_liquidity<AssetType, StableType>(expired: &mut Expired) {
    let action_spec = intents::remove_action_spec(expired);
    // Action spec data will be dropped automatically
    // Expired intent is automatically destroyed when it goes out of scope
}

/// Delete a create pool action from an expired intent
public fun delete_create_pool<AssetType, StableType>(expired: &mut Expired) {
    let action_spec = intents::remove_action_spec(expired);
    // Action spec data will be dropped automatically
    // Expired intent is automatically destroyed when it goes out of scope
}

/// Delete an update pool params action from an expired intent
public fun delete_update_pool_params(expired: &mut Expired) {
    let action_spec = intents::remove_action_spec(expired);
    // Action spec data will be dropped automatically
    // Expired intent is automatically destroyed when it goes out of scope
}

/// Delete a set pool status action from an expired intent
public fun delete_set_pool_status(expired: &mut Expired) {
    let action_spec = intents::remove_action_spec(expired);
    // Action spec data will be dropped automatically
    // Expired intent is automatically destroyed when it goes out of scope
}

/// Delete a swap action from an expired intent
public fun delete_swap<AssetType, StableType>(expired: &mut Expired) {
    let action_spec = intents::remove_action_spec(expired);
    // Action spec data will be dropped automatically
    // Expired intent is automatically destroyed when it goes out of scope
}

/// Delete a collect fees action from an expired intent
public fun delete_collect_fees<AssetType, StableType>(expired: &mut Expired) {
    let action_spec = intents::remove_action_spec(expired);
    // Action spec data will be dropped automatically
    // Expired intent is automatically destroyed when it goes out of scope
}

/// Delete a withdraw fees action from an expired intent
public fun delete_withdraw_fees<AssetType, StableType>(expired: &mut Expired) {
    let action_spec = intents::remove_action_spec(expired);
    // Action spec data will be dropped automatically
    // Expired intent is automatically destroyed when it goes out of scope
}

// === Helper Functions ===

/// Create a new add liquidity action with serialization
public fun new_add_liquidity_action<AssetType, StableType>(
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    min_lp_out: u64,
): AddLiquidityAction<AssetType, StableType> {
    assert!(asset_amount > 0, EInvalidAmount);
    assert!(stable_amount > 0, EInvalidAmount);
    assert!(min_lp_out > 0, EInvalidAmount);

    let action = AddLiquidityAction {
        pool_id,
        asset_amount,
        stable_amount,
        min_lp_out,
    };
    action
}

/// Create a new remove liquidity action with serialization
public fun new_remove_liquidity_action<AssetType, StableType>(
    pool_id: ID,
    token_id: ID,
    lp_amount: u64,
    min_asset_amount: u64,
    min_stable_amount: u64,
): RemoveLiquidityAction<AssetType, StableType> {
    assert!(lp_amount > 0, EInvalidAmount);

    RemoveLiquidityAction<AssetType, StableType> {
        pool_id,
        token_id,
        lp_amount,
        min_asset_amount,
        min_stable_amount,
        bypass_minimum: false,
    }
}

/// Create a new withdraw LP token action
public fun new_withdraw_lp_token_action<AssetType, StableType>(
    pool_id: ID,
    token_id: ID,
): WithdrawLpTokenAction<AssetType, StableType> {
    WithdrawLpTokenAction<AssetType, StableType> {
        pool_id,
        token_id,
    }
}

/// Enable bypass mode for a remove liquidity request (restricted to dissolution state)
public fun enable_remove_liquidity_bypass<AssetType, StableType>(
    request: &mut resource_requests::ResourceRequest<RemoveLiquidityAction<AssetType, StableType>>,
    account: &mut Account,
) {
    {
        let dao_state = futarchy_config::state_mut_from_account(account);
        assert!(
            futarchy_config::operational_state(dao_state) == futarchy_config::state_terminated(),
            EBypassNotAllowed
        );
    };

    let key = string::utf8(b"action");
    let action: RemoveLiquidityAction<AssetType, StableType> = resource_requests::take_context(request, key);

    let RemoveLiquidityAction {
        pool_id,
        token_id,
        lp_amount,
        min_asset_amount,
        min_stable_amount,
        bypass_minimum,
    } = action;
    assert!(!bypass_minimum, EBypassNotAllowed);

    let updated_action = RemoveLiquidityAction<AssetType, StableType> {
        pool_id,
        token_id,
        lp_amount,
        min_asset_amount,
        min_stable_amount,
        bypass_minimum: true,
    };

    resource_requests::add_context(
        request,
        string::utf8(b"action"),
        updated_action,
    );
}

/// Create a new create pool action with serialization
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

    let action = CreatePoolAction<AssetType, StableType> {
        initial_asset_amount,
        initial_stable_amount,
        fee_bps,
        minimum_liquidity,
    };
    action
}

/// Create a new update pool params action with serialization
public fun new_update_pool_params_action(
    pool_id: ID,
    new_fee_bps: u64,
    new_minimum_liquidity: u64,
): UpdatePoolParamsAction {
    assert!(new_fee_bps <= 10000, EInvalidRatio); // Max 100%
    assert!(new_minimum_liquidity > 0, EInvalidAmount);

    let action = UpdatePoolParamsAction {
        pool_id,
        new_fee_bps,
        new_minimum_liquidity,
    };
    action
}

/// Create a new set pool status action with serialization
public fun new_set_pool_status_action(
    pool_id: ID,
    is_paused: bool,
): SetPoolStatusAction {
    let action = SetPoolStatusAction {
        pool_id,
        is_paused,
    };
    action
}

/// Create a new swap action with serialization
public fun new_swap_action<AssetType, StableType>(
    pool_id: ID,
    swap_asset: bool,
    amount_in: u64,
    min_amount_out: u64,
): SwapAction<AssetType, StableType> {
    assert!(amount_in > 0, EInvalidAmount);
    assert!(min_amount_out > 0, EInvalidAmount);

    let action = SwapAction<AssetType, StableType> {
        pool_id,
        swap_asset,
        amount_in,
        min_amount_out,
    };
    action
}

/// Create a new collect fees action with serialization
public fun new_collect_fees_action<AssetType, StableType>(
    pool_id: ID,
): CollectFeesAction<AssetType, StableType> {
    let action = CollectFeesAction<AssetType, StableType> {
        pool_id,
    };
    action
}

/// Create a new withdraw fees action with serialization
public fun new_withdraw_fees_action<AssetType, StableType>(
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
): WithdrawFeesAction<AssetType, StableType> {
    assert!(asset_amount > 0 || stable_amount > 0, EInvalidAmount);

    let action = WithdrawFeesAction<AssetType, StableType> {
        pool_id,
        asset_amount,
        stable_amount,
    };
    action
}

// === Getter Functions ===

/// Get pool ID from AddLiquidityAction (alias for action_data_structs)
public fun get_pool_id<AssetType, StableType>(action: &AddLiquidityAction<AssetType, StableType>): ID {
    action.pool_id
}

/// Get asset amount from AddLiquidityAction (alias for action_data_structs)
public fun get_asset_amount<AssetType, StableType>(action: &AddLiquidityAction<AssetType, StableType>): u64 {
    action.asset_amount
}

/// Get stable amount from AddLiquidityAction (alias for action_data_structs)
public fun get_stable_amount<AssetType, StableType>(action: &AddLiquidityAction<AssetType, StableType>): u64 {
    action.stable_amount
}

/// Get minimum LP amount from AddLiquidityAction (alias for action_data_structs)
public fun get_min_lp_amount<AssetType, StableType>(action: &AddLiquidityAction<AssetType, StableType>): u64 {
    action.min_lp_out
}

/// Get pool ID from RemoveLiquidityAction
public fun get_remove_pool_id<AssetType, StableType>(action: &RemoveLiquidityAction<AssetType, StableType>): ID {
    action.pool_id
}

/// Get token ID from RemoveLiquidityAction
public fun get_remove_token_id<AssetType, StableType>(action: &RemoveLiquidityAction<AssetType, StableType>): ID {
    action.token_id
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

/// Get bypass flag from RemoveLiquidityAction
public fun get_bypass_minimum<AssetType, StableType>(action: &RemoveLiquidityAction<AssetType, StableType>): bool {
    action.bypass_minimum
}

/// Get pool ID from WithdrawLpTokenAction
public fun get_withdraw_pool_id<AssetType, StableType>(action: &WithdrawLpTokenAction<AssetType, StableType>): ID {
    action.pool_id
}

/// Get token ID from WithdrawLpTokenAction
public fun get_withdraw_token_id<AssetType, StableType>(action: &WithdrawLpTokenAction<AssetType, StableType>): ID {
    action.token_id
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

/// Get LP token value helper
public fun lp_value<AssetType, StableType>(lp_token: &LPToken<AssetType, StableType>): u64 {
    unified_spot_pool::lp_token_amount(lp_token)
}

// === Destruction Functions ===

/// Destroy CreatePoolAction after use
public fun destroy_create_pool_action<AssetType, StableType>(action: CreatePoolAction<AssetType, StableType>) {
    let CreatePoolAction {
        initial_asset_amount: _,
        initial_stable_amount: _,
        fee_bps: _,
        minimum_liquidity: _,
    } = action;
}

/// Destroy UpdatePoolParamsAction after use
public fun destroy_update_pool_params_action(action: UpdatePoolParamsAction) {
    let UpdatePoolParamsAction {
        pool_id: _,
        new_fee_bps: _,
        new_minimum_liquidity: _,
    } = action;
}

/// Destroy AddLiquidityAction after use (delegate to action_data_structs)
public fun destroy_add_liquidity_action<AssetType, StableType>(action: AddLiquidityAction<AssetType, StableType>) {
    // AddLiquidityAction has drop ability, so it will be automatically dropped
    let _ = action;
}

/// Destroy RemoveLiquidityAction after use
public fun destroy_remove_liquidity_action<AssetType, StableType>(action: RemoveLiquidityAction<AssetType, StableType>) {
    let RemoveLiquidityAction {
        pool_id: _,
        token_id: _,
        lp_amount: _,
        min_asset_amount: _,
        min_stable_amount: _,
        bypass_minimum: _,
    } = action;
}

/// Destroy WithdrawLpTokenAction after use
public fun destroy_withdraw_lp_token_action<AssetType, StableType>(action: WithdrawLpTokenAction<AssetType, StableType>) {
    let WithdrawLpTokenAction {
        pool_id: _,
        token_id: _,
    } = action;
}

/// Destroy SetPoolStatusAction after use
public fun destroy_set_pool_status_action(action: SetPoolStatusAction) {
    let SetPoolStatusAction {
        pool_id: _,
        is_paused: _,
    } = action;
}

/// Destroy SwapAction after use
public fun destroy_swap_action<AssetType, StableType>(action: SwapAction<AssetType, StableType>) {
    let SwapAction {
        pool_id: _,
        swap_asset: _,
        amount_in: _,
        min_amount_out: _,
    } = action;
}

/// Destroy CollectFeesAction after use
public fun destroy_collect_fees_action<AssetType, StableType>(action: CollectFeesAction<AssetType, StableType>) {
    let CollectFeesAction {
        pool_id: _,
    } = action;
}

/// Destroy WithdrawFeesAction after use
public fun destroy_withdraw_fees_action<AssetType, StableType>(action: WithdrawFeesAction<AssetType, StableType>) {
    let WithdrawFeesAction {
        pool_id: _,
        asset_amount: _,
        stable_amount: _,
    } = action;
}

// === Public Exports for External Access ===

// Export action structs for decoder and other modules
// Note: use fun declarations removed due to incorrect syntax

// Export destroy functions for cleanup
public use fun destroy_create_pool_action as CreatePoolAction.destroy;
public use fun destroy_update_pool_params_action as UpdatePoolParamsAction.destroy;
// Destroy functions for actions with drop ability are not needed
// Actions are automatically dropped when they go out of scope

// === Deserialization Constructors ===

/// Deserialize AddLiquidityAction from bytes (alias for action_data_structs)
public(package) fun add_liquidity_action_from_bytes<AssetType, StableType>(bytes: vector<u8>): AddLiquidityAction<AssetType, StableType> {
    // Deserialize from bytes
    let mut bcs = bcs::new(bytes);
    AddLiquidityAction {
        pool_id: object::id_from_address(bcs::peel_address(&mut bcs)),
        asset_amount: bcs::peel_u64(&mut bcs),
        stable_amount: bcs::peel_u64(&mut bcs),
        min_lp_out: bcs::peel_u64(&mut bcs),
    }
}

/// Deserialize RemoveLiquidityAction from bytes
public(package) fun remove_liquidity_action_from_bytes<AssetType, StableType>(bytes: vector<u8>): RemoveLiquidityAction<AssetType, StableType> {
    let mut bcs = bcs::new(bytes);
    RemoveLiquidityAction {
        pool_id: object::id_from_address(bcs::peel_address(&mut bcs)),
        token_id: object::id_from_address(bcs::peel_address(&mut bcs)),
        lp_amount: bcs::peel_u64(&mut bcs),
        min_asset_amount: bcs::peel_u64(&mut bcs),
        min_stable_amount: bcs::peel_u64(&mut bcs),
        bypass_minimum: bcs::peel_bool(&mut bcs),
    }
}

/// Deserialize WithdrawLpTokenAction from bytes
public(package) fun withdraw_lp_token_action_from_bytes<AssetType, StableType>(bytes: vector<u8>): WithdrawLpTokenAction<AssetType, StableType> {
    let mut bcs = bcs::new(bytes);
    WithdrawLpTokenAction {
        pool_id: object::id_from_address(bcs::peel_address(&mut bcs)),
        token_id: object::id_from_address(bcs::peel_address(&mut bcs)),
    }
}

/// Deserialize CreatePoolAction from bytes
public(package) fun create_pool_action_from_bytes<AssetType, StableType>(bytes: vector<u8>): CreatePoolAction<AssetType, StableType> {
    let mut bcs = bcs::new(bytes);
    CreatePoolAction {
        initial_asset_amount: bcs::peel_u64(&mut bcs),
        initial_stable_amount: bcs::peel_u64(&mut bcs),
        fee_bps: bcs::peel_u64(&mut bcs),
        minimum_liquidity: bcs::peel_u64(&mut bcs),
    }
}

/// Deserialize UpdatePoolParamsAction from bytes
public(package) fun update_pool_params_action_from_bytes(bytes: vector<u8>): UpdatePoolParamsAction {
    let mut bcs = bcs::new(bytes);
    UpdatePoolParamsAction {
        pool_id: object::id_from_address(bcs::peel_address(&mut bcs)),
        new_fee_bps: bcs::peel_u64(&mut bcs),
        new_minimum_liquidity: bcs::peel_u64(&mut bcs),
    }
}

/// Deserialize SetPoolStatusAction from bytes
public(package) fun set_pool_status_action_from_bytes(bytes: vector<u8>): SetPoolStatusAction {
    let mut bcs = bcs::new(bytes);
    SetPoolStatusAction {
        pool_id: object::id_from_address(bcs::peel_address(&mut bcs)),
        is_paused: bcs::peel_bool(&mut bcs),
    }
}

/// Deserialize SwapAction from bytes
public(package) fun swap_action_from_bytes<AssetType, StableType>(bytes: vector<u8>): SwapAction<AssetType, StableType> {
    let mut bcs = bcs::new(bytes);
    SwapAction {
        pool_id: object::id_from_address(bcs::peel_address(&mut bcs)),
        swap_asset: bcs::peel_bool(&mut bcs),
        amount_in: bcs::peel_u64(&mut bcs),
        min_amount_out: bcs::peel_u64(&mut bcs),
    }
}

/// Deserialize CollectFeesAction from bytes
public(package) fun collect_fees_action_from_bytes<AssetType, StableType>(bytes: vector<u8>): CollectFeesAction<AssetType, StableType> {
    let mut bcs = bcs::new(bytes);
    CollectFeesAction {
        pool_id: object::id_from_address(bcs::peel_address(&mut bcs)),
    }
}

/// Deserialize WithdrawFeesAction from bytes
public(package) fun withdraw_fees_action_from_bytes<AssetType, StableType>(bytes: vector<u8>): WithdrawFeesAction<AssetType, StableType> {
    let mut bcs = bcs::new(bytes);
    WithdrawFeesAction {
        pool_id: object::id_from_address(bcs::peel_address(&mut bcs)),
        asset_amount: bcs::peel_u64(&mut bcs),
        stable_amount: bcs::peel_u64(&mut bcs),
    }
}
