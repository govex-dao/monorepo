/// Simplified spot liquidity pool for use with Account<FutarchyConfig>
/// This module provides a basic AMM pool that doesn't depend on the DAO structure
module futarchy_markets::account_spot_pool;

// === Imports ===
use std::option::{Self, Option};
use sui::{
    balance::{Self, Balance},
    coin::{Self, Coin},
    object::{Self, UID},
    transfer,
    event,
};
use futarchy_one_shot_utils::{
    math,
    constants,
};

// === Errors ===
const EInsufficientLiquidity: u64 = 1;
const EZeroAmount: u64 = 2;
const ESlippageExceeded: u64 = 3;
const EInvalidFee: u64 = 4;
const EPoolNotInitialized: u64 = 5;

// === Constants ===
const MINIMUM_LIQUIDITY: u64 = 1000;

// === Structs ===

/// A simple spot liquidity pool for trading between two assets
public struct AccountSpotPool<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    /// Asset token reserves
    asset_reserve: Balance<AssetType>,
    /// Stable token reserves
    stable_reserve: Balance<StableType>,
    /// Total LP token supply
    lp_supply: u64,
    /// Trading fee in basis points
    fee_bps: u64,
    /// Minimum liquidity locked (for first LP)
    minimum_liquidity: u64,
}

/// LP token for the pool
public struct LPToken<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    /// Amount of LP tokens
    amount: u64,
}

/// Result of a swap operation
public struct SwapResult<phantom T> has drop {
    /// Output amount
    amount_out: u64,
    /// Fee amount
    fee_amount: u64,
}

// === Events ===

public struct PoolCreated<phantom AssetType, phantom StableType> has copy, drop {
    pool_id: ID,
    fee_bps: u64,
}

public struct LiquidityAdded<phantom AssetType, phantom StableType> has copy, drop {
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    lp_minted: u64,
}

public struct LiquidityRemoved<phantom AssetType, phantom StableType> has copy, drop {
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    lp_burned: u64,
}

public struct Swap<phantom AssetType, phantom StableType> has copy, drop {
    pool_id: ID,
    is_asset_to_stable: bool,
    amount_in: u64,
    amount_out: u64,
    fee: u64,
}

// === Public Functions ===

/// Create a new spot pool
public fun new<AssetType, StableType>(
    fee_bps: u64,
    ctx: &mut TxContext,
): AccountSpotPool<AssetType, StableType> {
    assert!(fee_bps <= constants::max_amm_fee_bps(), EInvalidFee);
    
    let id = object::new(ctx);
    let pool_id = object::uid_to_inner(&id);
    
    event::emit(PoolCreated<AssetType, StableType> {
        pool_id,
        fee_bps,
    });
    
    AccountSpotPool {
        id,
        asset_reserve: balance::zero<AssetType>(),
        stable_reserve: balance::zero<StableType>(),
        lp_supply: 0,
        fee_bps,
        minimum_liquidity: MINIMUM_LIQUIDITY,
    }
}

/// Share the pool object
#[allow(lint(custom_state_change, share_owned))]
public fun share<AssetType, StableType>(pool: AccountSpotPool<AssetType, StableType>) {
    transfer::share_object(pool);
}

/// Add liquidity to the pool
public entry fun add_liquidity<AssetType, StableType>(
    pool: &mut AccountSpotPool<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    min_lp_out: u64,
    ctx: &mut TxContext,
) {
    let asset_amount = asset_coin.value();
    let stable_amount = stable_coin.value();
    
    assert!(asset_amount > 0 && stable_amount > 0, EZeroAmount);
    
    let lp_minted = if (pool.lp_supply == 0) {
        // First liquidity provider
        // Calculate initial LP as sqrt(asset * stable)
        let product = (asset_amount as u128) * (stable_amount as u128);
        let initial_lp = math::sqrt_u128(product) as u64;
        assert!(initial_lp > pool.minimum_liquidity, EInsufficientLiquidity);
        
        // Lock minimum liquidity
        pool.lp_supply = pool.minimum_liquidity;
        initial_lp - pool.minimum_liquidity
    } else {
        // Calculate proportional LP tokens
        // Calculate LP tokens based on ratio of added liquidity to existing reserves
        let asset_ratio = math::mul_div_to_64(asset_amount, pool.lp_supply, pool.asset_reserve.value());
        let stable_ratio = math::mul_div_to_64(stable_amount, pool.lp_supply, pool.stable_reserve.value());
        
        // Use the minimum ratio to maintain pool ratio
        math::min(asset_ratio, stable_ratio)
    };
    
    assert!(lp_minted >= min_lp_out, ESlippageExceeded);
    
    // Update reserves
    pool.asset_reserve.join(asset_coin.into_balance());
    pool.stable_reserve.join(stable_coin.into_balance());
    pool.lp_supply = pool.lp_supply + lp_minted;
    
    // Mint LP tokens
    let lp_token = LPToken<AssetType, StableType> {
        id: object::new(ctx),
        amount: lp_minted,
    };
    
    transfer::public_transfer(lp_token, ctx.sender());
    
    event::emit(LiquidityAdded<AssetType, StableType> {
        pool_id: object::id(pool),
        asset_amount,
        stable_amount,
        lp_minted,
    });
}

/// Add liquidity and return LP token (for use in actions)
public fun add_liquidity_and_return<AssetType, StableType>(
    pool: &mut AccountSpotPool<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    min_lp_out: u64,
    ctx: &mut TxContext,
): LPToken<AssetType, StableType> {
    let asset_amount = asset_coin.value();
    let stable_amount = stable_coin.value();
    
    assert!(asset_amount > 0 && stable_amount > 0, EZeroAmount);
    
    let lp_minted = if (pool.lp_supply == 0) {
        // First liquidity provider
        let product = (asset_amount as u128) * (stable_amount as u128);
        let initial_lp = math::sqrt_u128(product) as u64;
        assert!(initial_lp > pool.minimum_liquidity, EInsufficientLiquidity);
        
        // Lock minimum liquidity
        pool.lp_supply = pool.minimum_liquidity;
        initial_lp - pool.minimum_liquidity
    } else {
        // Calculate proportional LP tokens
        let asset_ratio = math::mul_div_to_64(asset_amount, pool.lp_supply, pool.asset_reserve.value());
        let stable_ratio = math::mul_div_to_64(stable_amount, pool.lp_supply, pool.stable_reserve.value());
        math::min(asset_ratio, stable_ratio)
    };
    
    assert!(lp_minted >= min_lp_out, ESlippageExceeded);
    
    // Update reserves
    pool.asset_reserve.join(asset_coin.into_balance());
    pool.stable_reserve.join(stable_coin.into_balance());
    pool.lp_supply = pool.lp_supply + lp_minted;
    
    // Create and return LP token
    let lp_token = LPToken<AssetType, StableType> {
        id: object::new(ctx),
        amount: lp_minted,
    };
    
    event::emit(LiquidityAdded<AssetType, StableType> {
        pool_id: object::id(pool),
        asset_amount,
        stable_amount,
        lp_minted,
    });
    
    lp_token
}

/// Remove liquidity and return coins (for use in actions)
public fun remove_liquidity_and_return<AssetType, StableType>(
    pool: &mut AccountSpotPool<AssetType, StableType>,
    lp_token: LPToken<AssetType, StableType>,
    min_asset_out: u64,
    min_stable_out: u64,
    ctx: &mut TxContext,
): (Coin<AssetType>, Coin<StableType>) {
    let LPToken { id, amount: lp_amount } = lp_token;
    id.delete();
    
    assert!(lp_amount > 0, EZeroAmount);
    assert!(pool.lp_supply > pool.minimum_liquidity, EInsufficientLiquidity);
    
    // Calculate proportional share
    let asset_amount = math::mul_div_to_64(lp_amount, pool.asset_reserve.value(), pool.lp_supply);
    let stable_amount = math::mul_div_to_64(lp_amount, pool.stable_reserve.value(), pool.lp_supply);
    
    assert!(asset_amount >= min_asset_out, ESlippageExceeded);
    assert!(stable_amount >= min_stable_out, ESlippageExceeded);
    
    // Update state
    pool.lp_supply = pool.lp_supply - lp_amount;
    
    // Create coins
    let asset_out = coin::from_balance(
        pool.asset_reserve.split(asset_amount),
        ctx
    );
    let stable_out = coin::from_balance(
        pool.stable_reserve.split(stable_amount),
        ctx
    );
    
    event::emit(LiquidityRemoved<AssetType, StableType> {
        pool_id: object::id(pool),
        asset_amount,
        stable_amount,
        lp_burned: lp_amount,
    });
    
    (asset_out, stable_out)
}

/// Remove liquidity from the pool
public entry fun remove_liquidity<AssetType, StableType>(
    pool: &mut AccountSpotPool<AssetType, StableType>,
    lp_token: LPToken<AssetType, StableType>,
    min_asset_out: u64,
    min_stable_out: u64,
    ctx: &mut TxContext,
) {
    let LPToken { id, amount: lp_amount } = lp_token;
    id.delete();
    
    assert!(lp_amount > 0, EZeroAmount);
    assert!(pool.lp_supply > pool.minimum_liquidity, EInsufficientLiquidity);
    
    // Calculate proportional share
    // Calculate proportional assets to return
    let asset_amount = math::mul_div_to_64(lp_amount, pool.asset_reserve.value(), pool.lp_supply);
    let stable_amount = math::mul_div_to_64(lp_amount, pool.stable_reserve.value(), pool.lp_supply);
    
    assert!(asset_amount >= min_asset_out, ESlippageExceeded);
    assert!(stable_amount >= min_stable_out, ESlippageExceeded);
    
    // Update state
    pool.lp_supply = pool.lp_supply - lp_amount;
    
    // Transfer tokens
    let asset_out = coin::from_balance(
        pool.asset_reserve.split(asset_amount),
        ctx
    );
    let stable_out = coin::from_balance(
        pool.stable_reserve.split(stable_amount),
        ctx
    );
    
    transfer::public_transfer(asset_out, ctx.sender());
    transfer::public_transfer(stable_out, ctx.sender());
    
    event::emit(LiquidityRemoved<AssetType, StableType> {
        pool_id: object::id(pool),
        asset_amount,
        stable_amount,
        lp_burned: lp_amount,
    });
}

/// Swap asset for stable
public entry fun swap_asset_to_stable<AssetType, StableType>(
    pool: &mut AccountSpotPool<AssetType, StableType>,
    asset_in: Coin<AssetType>,
    min_stable_out: u64,
    ctx: &mut TxContext,
) {
    let amount_in = asset_in.value();
    assert!(amount_in > 0, EZeroAmount);
    
    let (amount_out, fee) = calculate_output(
        amount_in,
        pool.asset_reserve.value(),
        pool.stable_reserve.value(),
        pool.fee_bps
    );
    
    assert!(amount_out >= min_stable_out, ESlippageExceeded);
    assert!(amount_out <= pool.stable_reserve.value(), EInsufficientLiquidity);
    
    // Update reserves
    pool.asset_reserve.join(asset_in.into_balance());
    
    // Send output
    let stable_out = coin::from_balance(
        pool.stable_reserve.split(amount_out),
        ctx
    );
    transfer::public_transfer(stable_out, ctx.sender());
    
    event::emit(Swap<AssetType, StableType> {
        pool_id: object::id(pool),
        is_asset_to_stable: true,
        amount_in,
        amount_out,
        fee,
    });
}

/// Swap stable for asset
public entry fun swap_stable_to_asset<AssetType, StableType>(
    pool: &mut AccountSpotPool<AssetType, StableType>,
    stable_in: Coin<StableType>,
    min_asset_out: u64,
    ctx: &mut TxContext,
) {
    let amount_in = stable_in.value();
    assert!(amount_in > 0, EZeroAmount);
    
    let (amount_out, fee) = calculate_output(
        amount_in,
        pool.stable_reserve.value(),
        pool.asset_reserve.value(),
        pool.fee_bps
    );
    
    assert!(amount_out >= min_asset_out, ESlippageExceeded);
    assert!(amount_out <= pool.asset_reserve.value(), EInsufficientLiquidity);
    
    // Update reserves
    pool.stable_reserve.join(stable_in.into_balance());
    
    // Send output
    let asset_out = coin::from_balance(
        pool.asset_reserve.split(amount_out),
        ctx
    );
    transfer::public_transfer(asset_out, ctx.sender());
    
    event::emit(Swap<AssetType, StableType> {
        pool_id: object::id(pool),
        is_asset_to_stable: false,
        amount_in,
        amount_out,
        fee,
    });
}

// === View Functions ===

/// Get pool reserves
public fun get_reserves<AssetType, StableType>(
    pool: &AccountSpotPool<AssetType, StableType>
): (u64, u64) {
    (pool.asset_reserve.value(), pool.stable_reserve.value())
}

/// Get spot price (asset per stable)
public fun get_spot_price<AssetType, StableType>(
    pool: &AccountSpotPool<AssetType, StableType>
): u128 {
    if (pool.asset_reserve.value() == 0) {
        0
    } else {
        // Price = stable_reserve / asset_reserve * price_multiplier_scale
        // This scale is used across the system for price calculations and multipliers
        ((pool.stable_reserve.value() as u128) * (constants::price_multiplier_scale() as u128)) / (pool.asset_reserve.value() as u128)
    }
}

/// Get pool ID
public fun pool_id<AssetType, StableType>(
    pool: &AccountSpotPool<AssetType, StableType>
): ID {
    object::id(pool)
}

/// Get LP supply
public fun lp_supply<AssetType, StableType>(
    pool: &AccountSpotPool<AssetType, StableType>
): u64 {
    pool.lp_supply
}

/// Get fee in basis points
public fun fee_bps<AssetType, StableType>(
    pool: &AccountSpotPool<AssetType, StableType>
): u64 {
    pool.fee_bps
}

// === Internal Functions ===

/// Calculate output amount for a swap
fun calculate_output(
    amount_in: u64,
    reserve_in: u64,
    reserve_out: u64,
    fee_bps: u64,
): (u64, u64) {
    // Calculate fee
    // Calculate fee amount
    let fee_amount = math::mul_div_to_64(amount_in, fee_bps, 10000);
    let amount_in_after_fee = amount_in - fee_amount;
    
    // Calculate output using constant product formula
    // amount_out = (amount_in_after_fee * reserve_out) / (reserve_in + amount_in_after_fee)
    // Use mul_div_to_64 to calculate output amount
    let amount_out = math::mul_div_to_64(amount_in_after_fee, reserve_out, reserve_in + amount_in_after_fee);
    
    (amount_out, fee_amount)
}

// === LP Token Functions ===

/// Get LP token amount
public fun lp_token_amount<AssetType, StableType>(
    token: &LPToken<AssetType, StableType>
): u64 {
    token.amount
}

/// Merge two LP tokens and return the result
public fun merge_lp_tokens<AssetType, StableType>(
    token1: LPToken<AssetType, StableType>,
    token2: LPToken<AssetType, StableType>,
    ctx: &mut TxContext,
): LPToken<AssetType, StableType> {
    let LPToken { id: id1, amount: amount1 } = token1;
    let LPToken { id: id2, amount: amount2 } = token2;
    
    id1.delete();
    id2.delete();
    
    LPToken<AssetType, StableType> {
        id: object::new(ctx),
        amount: amount1 + amount2,
    }
}

/// Merge two LP tokens (entry function)
public entry fun merge_lp_tokens_entry<AssetType, StableType>(
    token1: LPToken<AssetType, StableType>,
    token2: LPToken<AssetType, StableType>,
    ctx: &mut TxContext,
) {
    let merged = merge_lp_tokens(token1, token2, ctx);
    transfer::public_transfer(merged, ctx.sender());
}

/// Split an LP token and return both parts
public fun split_lp_token<AssetType, StableType>(
    token: LPToken<AssetType, StableType>,
    split_amount: u64,
    ctx: &mut TxContext,
): (LPToken<AssetType, StableType>, LPToken<AssetType, StableType>) {
    let LPToken { id, amount } = token;
    id.delete();
    
    assert!(split_amount > 0 && split_amount < amount, EZeroAmount);
    
    let token1 = LPToken<AssetType, StableType> {
        id: object::new(ctx),
        amount: split_amount,
    };
    
    let token2 = LPToken<AssetType, StableType> {
        id: object::new(ctx),
        amount: amount - split_amount,
    };
    
    (token1, token2)
}

/// Split an LP token (entry function)
public entry fun split_lp_token_entry<AssetType, StableType>(
    token: LPToken<AssetType, StableType>,
    split_amount: u64,
    ctx: &mut TxContext,
) {
    let (token1, token2) = split_lp_token(token, split_amount, ctx);
    transfer::public_transfer(token1, ctx.sender());
    transfer::public_transfer(token2, ctx.sender());
}

// === LP Token Recovery Functions ===
// These functions allow DAOs to recover LP tokens that were sent to the account address

/// Get information about an LP token
public fun lp_token_info<AssetType, StableType>(
    token: &LPToken<AssetType, StableType>
): (ID, u64) {
    (object::id(token), token.amount)
}

// === Share Functions ===

/// Share the account spot pool - can only be called by this module
/// Used during DAO initialization after setup is complete
public fun share_pool<AssetType, StableType>(
    pool: AccountSpotPool<AssetType, StableType>
) {
    transfer::share_object(pool);
}