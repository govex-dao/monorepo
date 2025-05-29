module futarchy::amm;

use futarchy::market_state::{Self, MarketState};
use futarchy::math;
use futarchy::oracle::{Self, Oracle};
use std::u64;
use sui::clock::{Self, Clock};
use sui::event;

// === Introduction ===
// This a Uniswap V2-style XY=K AMM implementation with controlled liquidity methods.

// === Errors ===
const ELOW_LIQUIDITY: u64 = 0;
const EPOOL_EMPTY: u64 = 1;
const EEXCESSIVE_SLIPPAGE: u64 = 2;
const EDIV_BY_ZERO: u64 = 3;
const EZERO_LIQUIDITY: u64 = 4;
const EPRICE_TOO_HIGH: u64 = 5;
const EZERO_AMOUNT: u64 = 6;
const EMARKET_ID_MISMATCH: u64 = 7;

// === Constants ===
const FEE_SCALE: u64 = 10000;
const DEFAULT_FEE: u64 = 30; // 0.3%
const BASIS_POINTS: u64 = 1_000_000_000_000; // 10^12 we need to keep this for saftey to values don't round to 0
const MINIMUM_LIQUIDITY: u128 = 1000;

// === Structs ===
public struct LiquidityPool has key, store {
    id: UID,
    market_id: ID,
    outcome_idx: u8,
    asset_reserve: u64,
    stable_reserve: u64,
    fee_percent: u64,
    oracle: Oracle,
    protocol_fees: u64, // Track accumulated stable fees
}

// === Events ===
public struct SwapEvent has copy, drop {
    market_id: ID,
    outcome: u8,
    is_buy: bool,
    amount_in: u64,
    amount_out: u64,
    price_impact: u128,
    price: u128,
    sender: address,
    asset_reserve: u64,
    stable_reserve: u64,
    timestamp: u64,
}

// === Public Functions ===
public(package) fun new_pool(
    state: &MarketState,
    outcome_idx: u8,
    initial_asset: u64,
    initial_stable: u64,
    twap_initial_observation: u128,
    twap_start_delay: u64,
    twap_step_max: u64,
    ctx: &mut TxContext,
): LiquidityPool {
    assert!(initial_asset > 0 && initial_stable > 0, EZERO_AMOUNT);
    let k = math::mul_div_to_128(initial_asset, initial_stable, 1);
    assert!(k >= MINIMUM_LIQUIDITY, ELOW_LIQUIDITY);

    let twap_initialization_price = twap_initial_observation;
    let initial_price = math::mul_div_to_128(initial_stable, BASIS_POINTS, initial_asset);

    check_price_under_max(initial_price);
    check_price_under_max(twap_initialization_price);

    // Initialize oracle
    let oracle = oracle::new_oracle(
        twap_initialization_price,
        twap_start_delay,
        twap_step_max,
        ctx, // Add ctx parameter here
    );

    // Create pool object as usual
    let pool = LiquidityPool {
        id: object::new(ctx),
        market_id: market_state::market_id(state),
        outcome_idx,
        asset_reserve: initial_asset,
        stable_reserve: initial_stable,
        fee_percent: DEFAULT_FEE,
        oracle,
        protocol_fees: 0,
    };

    pool
}

// === Core Swap Functions ===
public(package) fun swap_asset_to_stable(
    pool: &mut LiquidityPool,
    state: &MarketState,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    market_state::assert_trading_active(state);
    assert!(pool.market_id == market_state::market_id(state), EMARKET_ID_MISMATCH);
    assert!(amount_in > 0, EZERO_AMOUNT);

    // When selling outcome tokens (asset -> stable):
    // 1. We calculate the full swap output first (before fees)
    // 2. Then collect fee from the stable output
    //
    // This approach is used because it:
    // - Maintains accurate asset pricing through the entire reserve
    // - Preserves the XY=K invariant for the actual pool tokens
    let amount_out_before_fee = calculate_output(
        amount_in,
        pool.asset_reserve,
        pool.stable_reserve,
    );

    // Calculate fee from stable output
    let fee_amount = calculate_fee(amount_out_before_fee, pool.fee_percent);
    let amount_out = amount_out_before_fee - fee_amount;

    // Take fee directly as stable tokens (never enters pool)
    pool.protocol_fees = pool.protocol_fees + fee_amount;

    assert!(amount_out >= min_amount_out, EEXCESSIVE_SLIPPAGE);
    assert!(amount_out_before_fee < pool.stable_reserve, EPOOL_EMPTY);

    let price_impact = calculate_price_impact(
        amount_in,
        pool.asset_reserve,
        amount_out_before_fee, // Use before-fee amount for impact calculation
        pool.stable_reserve,
    );

    // Capture previous reserve state before the update
    let old_asset = pool.asset_reserve;
    let old_stable = pool.stable_reserve;

    // Update reserves - include full asset in, but remove amount_out_before_fee
    // This ensures proper pool balance since we're taking fee outside the pool
    pool.asset_reserve = pool.asset_reserve + amount_in;
    pool.stable_reserve = pool.stable_reserve - amount_out_before_fee;

    let timestamp = clock::timestamp_ms(clock);
    let old_price = math::mul_div_to_128(old_stable, BASIS_POINTS, old_asset);
    write_observation(
        &mut pool.oracle,
        timestamp,
        old_price,
    );

    let current_price = get_current_price(pool);
    check_price_under_max(current_price);

    event::emit(SwapEvent {
        market_id: pool.market_id,
        outcome: pool.outcome_idx,
        is_buy: false,
        amount_in,
        amount_out, // Amount after fee for event logging
        price_impact,
        price: current_price,
        sender: tx_context::sender(ctx),
        asset_reserve: pool.asset_reserve,
        stable_reserve: pool.stable_reserve,
        timestamp,
    });

    amount_out
}

// Modified swap_asset_to_stable (selling outcome tokens)
public(package) fun swap_stable_to_asset(
    pool: &mut LiquidityPool,
    state: &MarketState,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    market_state::assert_trading_active(state);
    assert!(pool.market_id == market_state::market_id(state), EMARKET_ID_MISMATCH);
    assert!(amount_in > 0, EZERO_AMOUNT);

    // When buying outcome tokens (stable -> asset):
    // 1. We collect fee from stable input first
    // 2. Then execute swap with the remaining amount
    //
    // This approach is used because it:
    // - Maintains consistent fee collection in stable tokens only
    // - Prevents dilution of the outcome token reserves
    let fee_amount = calculate_fee(amount_in, pool.fee_percent);
    let amount_in_after_fee = amount_in - fee_amount;

    // Take fee directly as stable tokens (never enters pool)
    pool.protocol_fees = pool.protocol_fees + fee_amount;

    // Calculate output based on amount after fee
    let amount_out = calculate_output(
        amount_in_after_fee,
        pool.stable_reserve,
        pool.asset_reserve,
    );

    assert!(amount_out >= min_amount_out, EEXCESSIVE_SLIPPAGE);
    assert!(amount_out < pool.asset_reserve, EPOOL_EMPTY);

    let price_impact = calculate_price_impact(
        amount_in_after_fee,
        pool.stable_reserve,
        amount_out,
        pool.asset_reserve,
    );

    // Capture previous reserve state before the update
    let old_asset = pool.asset_reserve;
    let old_stable = pool.stable_reserve;

    // Update reserves with amount after fee
    pool.stable_reserve = pool.stable_reserve + amount_in_after_fee;
    pool.asset_reserve = pool.asset_reserve - amount_out;

    let timestamp = clock::timestamp_ms(clock);
    let old_price = math::mul_div_to_128(old_stable, BASIS_POINTS, old_asset);
    write_observation(
        &mut pool.oracle,
        timestamp,
        old_price,
    );

    let current_price = get_current_price(pool);
    check_price_under_max(current_price);

    event::emit(SwapEvent {
        market_id: pool.market_id,
        outcome: pool.outcome_idx,
        is_buy: true,
        amount_in, // Original amount for event logging
        amount_out,
        price_impact,
        price: current_price,
        sender: tx_context::sender(ctx),
        asset_reserve: pool.asset_reserve,
        stable_reserve: pool.stable_reserve,
        timestamp,
    });

    amount_out
}

// === Liquidity Functions ===
public(package) fun empty_all_amm_liquidity(
    pool: &mut LiquidityPool,
    _ctx: &mut TxContext,
): (u64, u64) {
    // Since fees are now tracked separately and don't affect the LP ratio,
    // we can simply return all values separately without any adjustments
    let asset_amount_out = pool.asset_reserve;
    let stable_amount_out = pool.stable_reserve;

    // Update reserves
    pool.asset_reserve = 0;
    pool.stable_reserve = 0;

    (asset_amount_out, stable_amount_out)
}

// === Oracle Functions ===
// Update new_oracle to be simpler:
fun write_observation(oracle: &mut Oracle, timestamp: u64, price: u128) {
    oracle::write_observation(oracle, timestamp, price)
}

public fun get_oracle(pool: &LiquidityPool): &Oracle {
    &pool.oracle
}

// === View Functions ===
public fun get_reserves(pool: &LiquidityPool): (u64, u64) {
    (pool.asset_reserve, pool.stable_reserve)
}

public fun get_price(pool: &LiquidityPool): u128 {
    oracle::get_last_price(&pool.oracle)
}

public(package) fun get_twap(pool: &mut LiquidityPool, clock: &Clock): u128 {
    update_twap_observation(pool, clock);
    let oracle_ref = &pool.oracle;
    oracle::get_twap(oracle_ref, clock)
}

public fun quote_swap_asset_to_stable(pool: &LiquidityPool, amount_in: u64): u64 {
    // First calculate total output
    let amount_out_before_fee = calculate_output(
        amount_in,
        pool.asset_reserve,
        pool.stable_reserve,
    );
    // Then take fee from stable output (same as swap function)
    let fee_amount = calculate_fee(amount_out_before_fee, pool.fee_percent);
    amount_out_before_fee - fee_amount
}

public fun quote_swap_stable_to_asset(pool: &LiquidityPool, amount_in: u64): u64 {
    let amount_in_with_fee = amount_in - calculate_fee(amount_in, pool.fee_percent);
    calculate_output(
        amount_in_with_fee,
        pool.stable_reserve,
        pool.asset_reserve,
    )
}

fun calculate_price_impact(
    amount_in: u64,
    reserve_in: u64,
    amount_out: u64,
    reserve_out: u64,
): u128 {
    let ideal_out = math::mul_div_to_128(amount_in, reserve_out, reserve_in);
    math::mul_div_mixed(ideal_out - (amount_out as u128), FEE_SCALE, ideal_out)
}

// Update the LiquidityPool struct price calculation to use TWAP:
public fun get_current_price(pool: &LiquidityPool): u128 {
    assert!(pool.asset_reserve > 0 && pool.stable_reserve > 0, EZERO_LIQUIDITY);

    let price = math::mul_div_to_128(
        pool.stable_reserve,
        BASIS_POINTS,
        pool.asset_reserve,
    );

    price
}

public(package) fun update_twap_observation(pool: &mut LiquidityPool, clock: &Clock) {
    let timestamp = clock::timestamp_ms(clock);
    let current_price = get_current_price(pool);
    // Use the sum of reserves as a liquidity measure
    oracle::write_observation(&mut pool.oracle, timestamp, current_price);
}

public(package) fun set_oracle_start_time(pool: &mut LiquidityPool, market_start_time: u64) {
    oracle::set_oracle_start_time(&mut pool.oracle, market_start_time);
}

// ======== Internal Functions ========
fun calculate_fee(amount: u64, fee_percent: u64): u64 {
    // Calculate fee normally
    let calculated_fee = math::mul_div_to_64(amount, fee_percent, FEE_SCALE);

    // If the calculated fee would be 0 but amount is non-zero, return 1 instead
    if (calculated_fee == 0) {
        1
    } else {
        calculated_fee
    }
}

public(package) fun calculate_output(
    amount_in_with_fee: u64,
    reserve_in: u64,
    reserve_out: u64,
): u64 {
    assert!(reserve_in > 0 && reserve_out > 0, EPOOL_EMPTY);

    let denominator = reserve_in + amount_in_with_fee;
    assert!(denominator > 0, EDIV_BY_ZERO);
    let numerator = math::mul_div_to_128(amount_in_with_fee, reserve_out, 1);
    let output = math::mul_div_mixed(numerator, 1, (denominator as u128));
    (output as u64)
}

public fun get_outcome_idx(pool: &LiquidityPool): u8 {
    pool.outcome_idx
}

public fun get_id(pool: &LiquidityPool): ID {
    object::uid_to_inner(&pool.id)
}

public fun get_k(pool: &LiquidityPool): u128 {
    math::mul_div_to_128(pool.asset_reserve, pool.stable_reserve, 1)
}

public fun check_price_under_max(price: u128) {
    let max_price = (u64::max_value!() as u128) * (BASIS_POINTS as u128);
    assert!(price <= max_price, EPRICE_TOO_HIGH)
}

public(package) fun get_protocol_fees(pool: &LiquidityPool): u64 {
    pool.protocol_fees
}

public(package) fun reset_protocol_fees(pool: &mut LiquidityPool) {
    pool.protocol_fees = 0;
}

// === Test Functions ===
#[test_only]
public fun create_test_pool(
    market_id: ID,
    outcome_idx: u8,
    asset_reserve: u64,
    stable_reserve: u64,
    ctx: &mut TxContext,
): LiquidityPool {
    LiquidityPool {
        id: object::new(ctx),
        market_id,
        outcome_idx,
        asset_reserve,
        stable_reserve,
        fee_percent: DEFAULT_FEE,
        oracle: oracle::new_oracle(
            math::mul_div_to_128(stable_reserve, 1_000_000_000_000, asset_reserve),
            2_000,
            1_000,
            ctx, // Add ctx parameter here
        ),
        protocol_fees: 0,
    }
}

#[test_only]
public fun destroy_for_testing(pool: LiquidityPool) {
    let LiquidityPool {
        id,
        market_id: _,
        outcome_idx: _,
        asset_reserve: _,
        stable_reserve: _,
        fee_percent: _,
        oracle,
        protocol_fees: _,
    } = pool;
    object::delete(id);
    oracle::destroy_for_testing(oracle);
}
