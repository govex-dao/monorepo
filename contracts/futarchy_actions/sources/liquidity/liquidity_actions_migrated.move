/// Liquidity-related actions for futarchy DAOs - MIGRATED VERSION
/// This module defines action structs using direct IDs instead of placeholders
module futarchy_actions::liquidity_actions_migrated;

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
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents::Expired,
    version_witness::VersionWitness,
};
use account_actions::vault;
use futarchy_core::{futarchy_config::{Self, FutarchyConfig}, version};
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool, LPToken};

// === Errors ===
const EInvalidAmount: u64 = 1;
const EInvalidRatio: u64 = 2;
const EEmptyPool: u64 = 4;
const EInsufficientVaultBalance: u64 = 5;

// === Constants ===
const DEFAULT_VAULT_NAME: vector<u8> = b"treasury";

// === MIGRATED Action Structs ===

/// Action to create a new liquidity pool
public struct CreatePoolAction<phantom AssetType, phantom StableType> has store, drop, copy {
    initial_asset_amount: u64,
    initial_stable_amount: u64,
    fee_bps: u64,
    minimum_liquidity: u64,
}

/// Action to add liquidity to an existing pool
public struct AddLiquidityAction<phantom AssetType, phantom StableType> has store, drop, copy {
    pool_id: ID, // Direct pool ID
    asset_amount: u64,
    stable_amount: u64,
    min_lp_amount: u64, // Slippage protection
}

/// Action to remove liquidity from a pool
/// NOTE: This action should be preceded by a WithdrawAction to get the LP tokens
public struct RemoveLiquidityAction<phantom AssetType, phantom StableType> has store, drop, copy {
    pool_id: ID, // Direct pool ID
    lp_token_id: ID, // ID of the LP token to withdraw (used with WithdrawAction)
    lp_amount: u64, // Amount of LP tokens to remove
    min_asset_amount: u64, // Slippage protection
    min_stable_amount: u64, // Slippage protection
    vault_name: Option<String>, // Vault to deposit returned assets (default: treasury)
    bypass_minimum: bool,
}

/// Action to update pool parameters
public struct UpdatePoolParamsAction has store, drop, copy {
    pool_id: ID, // Direct pool ID
    new_fee_bps: u64,
    new_minimum_liquidity: u64,
}

// === Constructor Functions ===

/// Create a new pool action
public fun new_create_pool<AssetType, StableType>(
    initial_asset_amount: u64,
    initial_stable_amount: u64,
    fee_bps: u64,
    minimum_liquidity: u64,
): CreatePoolAction<AssetType, StableType> {
    CreatePoolAction {
        initial_asset_amount,
        initial_stable_amount,
        fee_bps,
        minimum_liquidity,
    }
}

/// Create an add liquidity action
public fun new_add_liquidity<AssetType, StableType>(
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    min_lp_amount: u64,
): AddLiquidityAction<AssetType, StableType> {
    AddLiquidityAction {
        pool_id,
        asset_amount,
        stable_amount,
        min_lp_amount,
    }
}

/// Create a remove liquidity action
public fun new_remove_liquidity<AssetType, StableType>(
    pool_id: ID,
    lp_token_id: ID,
    lp_amount: u64,
    min_asset_amount: u64,
    min_stable_amount: u64,
    vault_name: Option<String>,
    bypass_minimum: bool,
): RemoveLiquidityAction<AssetType, StableType> {
    RemoveLiquidityAction {
        pool_id,
        lp_token_id,
        lp_amount,
        min_asset_amount,
        min_stable_amount,
        vault_name,
        bypass_minimum,
    }
}

// === MIGRATED Execution Functions ===

/// Execute a create pool action
public fun do_create_pool<AssetType: drop, StableType: drop>(
    params: CreatePoolAction<AssetType, StableType>,
    account: &mut Account<FutarchyConfig>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID { // Returns pool ID for flexibility
    // Validate parameters
    assert!(params.initial_asset_amount > 0, EInvalidAmount);
    assert!(params.initial_stable_amount > 0, EInvalidAmount);
    assert!(params.fee_bps <= 10000, EInvalidRatio);
    assert!(params.minimum_liquidity > 0, EInvalidAmount);

    // Create the pool
    let mut pool = unified_spot_pool::new<AssetType, StableType>(
        params.fee_bps,
        ctx,
    );

    // Add initial liquidity
    let lp_tokens = unified_spot_pool::add_liquidity_and_return<AssetType, StableType>(
        &mut pool,
        asset_coin,
        stable_coin,
        0, // min_lp_out = 0 (accept any amount of LP tokens)
        ctx,
    );

    // LP tokens are handled by the pool itself
    // Transfer LP tokens to DAO's vault
    transfer::public_transfer(lp_tokens, object::id_to_address(&object::id(account)));

    // Get pool ID before sharing
    let pool_id = object::id(&pool);

    // Placeholder registration removed - not needed without ExecutionContext

    // Share the pool
    unified_spot_pool::share(pool);

    pool_id
}

/// Execute add liquidity action
public fun do_add_liquidity<AssetType: drop, StableType: drop>(
    params: AddLiquidityAction<AssetType, StableType>,
    account: &mut Account<FutarchyConfig>,
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    ctx: &mut TxContext,
) {
    // Direct pool ID access
    let pool_id = params.pool_id;

    // Verify pool ID matches
    assert!(object::id(pool) == pool_id, 0);

    // Add liquidity
    let lp_tokens = unified_spot_pool::add_liquidity_and_return<AssetType, StableType>(
        pool,
        asset_coin,
        stable_coin,
        params.min_lp_amount,
        ctx,
    );

    // Verify slippage protection
    // LP tokens are returned - store or transfer as needed
    // Transfer LP tokens to DAO's vault
    transfer::public_transfer(lp_tokens, object::id_to_address(&object::id(account)));
}

/// Execute remove liquidity action - requires WithdrawAction to get LP tokens
/// This demonstrates the composable action pattern where RemoveLiquidityAction
/// is paired with a WithdrawAction to first get the LP tokens from the account
public fun do_remove_liquidity<AssetType: drop, StableType: drop>(
    params: RemoveLiquidityAction<AssetType, StableType>,
    account: &mut Account<FutarchyConfig>,
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    lp_token: LPToken<AssetType, StableType>,
    vault_name: String,
    ctx: &mut TxContext,
) {
    // Direct pool ID access
    let pool_id = params.pool_id;

    // Verify pool ID matches
    assert!(object::id(pool) == pool_id, 0);

    // Remove liquidity from the pool
    let (asset_coin, stable_coin) = unified_spot_pool::remove_liquidity(
        pool,
        lp_token,
        params.min_asset_amount,
        params.min_stable_amount,
        ctx,
    );

    // Deposit the returned assets to the specified vault
    // Using the vault module to deposit the coins back to the account
    // TODO: Use correct vault functions when available
    // For now, just transfer to account
    transfer::public_transfer(asset_coin, object::id_to_address(&object::id(account)));
    transfer::public_transfer(stable_coin, object::id_to_address(&object::id(account)));
}

// === Intent Builder Functions ===

/// Build an intent to remove liquidity - composes WithdrawAction + RemoveLiquidityAction
/// This is the correct way to remove liquidity: first withdraw LP token, then remove liquidity
public fun request_remove_liquidity<Config, AssetType, StableType, Outcome, IW: drop>(
    _intent: &mut ID, // Changed to simple ID since Intent is not imported
    account: &Account<Config>,
    pool_id: ID,
    lp_token_id: ID,
    lp_amount: u64,
    min_asset_amount: u64,
    min_stable_amount: u64,
    vault_name: Option<String>,
    intent_witness: IW,
) {
    // Step 1: Add WithdrawAction to get the LP token from the account
    // TODO: Replace with correct withdraw function when available
    // account_actions::owned::new_withdraw(
    //     intent,
    //     account,
    //     lp_token_id,
    //     intent_witness,
    // );

    // Step 2: Add RemoveLiquidityAction to remove liquidity using the withdrawn LP token
    let action = RemoveLiquidityAction<AssetType, StableType> {
        pool_id,
        lp_token_id,
        lp_amount,
        min_asset_amount,
        min_stable_amount,
        vault_name,
    };

    // Note: This would need to be added to the intent using the proper serialization
    // For now, this demonstrates the pattern of composing actions
    let _ = action;
}
