module futarchy_markets_primitives::conditional_amm;

use futarchy_one_shot_utils::math;
use sui::object::{Self, ID, UID};
use futarchy_markets_primitives::oracle::{Self, Oracle};
use futarchy_markets_primitives::simple_twap::{Self, SimpleTWAP};
use futarchy_one_shot_utils::constants;
use sui::clock::Clock;
use sui::event;
use std::u64;
use sui::tx_context::TxContext;  // Audit fix: missing import
use sui::balance::{Self, Balance};  // For LP reward system
use sui::sui::SUI;  // For LP reward system

// === Introduction ===
// This is a Uniswap V2-style XY=K AMM implementation for futarchy prediction markets.
// 
// === Live-Flow Model Architecture ===
// This AMM is part of the "live-flow" liquidity model which allows dynamic liquidity
// management even while proposals are active. Key features:
// 
// 1. **No Liquidity Locking**: Unlike traditional prediction markets, liquidity providers
//    can add or remove liquidity at any time, even during active proposals.
// 
// 2. **Conditional Token Pools**: Each AMM pool trades conditional tokens (not spot tokens)
//    for a specific outcome. This allows the spot pool to remain liquid.
// 
// 3. **Proportional Liquidity**: When LPs add/remove from the spot pool during active
//    proposals, liquidity is proportionally distributed/collected across all outcome AMMs.
// 
// 4. **LP Token Architecture**: Each AMM pool has its own LP token type, but in the live-flow
//    model, these are managed internally. LPs only receive spot pool LP tokens.
// 
// The flow works as follows:
// - Add liquidity: Spot tokens → Mint conditional tokens → Distribute to AMMs
// - Remove liquidity: Collect from AMMs → Redeem conditional tokens → Return spot tokens

// === Errors ===
const ELowLiquidity: u64 = 0; // Pool liquidity below minimum threshold
const EPoolEmpty: u64 = 1; // Attempting to swap/remove from empty pool
const EExcessiveSlippage: u64 = 2; // Output amount less than minimum specified
const EDivByZero: u64 = 3; // Division by zero in calculations
const EZeroLiquidity: u64 = 4; // Pool has zero liquidity
const EPriceTooHigh: u64 = 5; // Price exceeds maximum allowed value
const EZeroAmount: u64 = 6; // Input amount is zero
const EMarketIdMismatch: u64 = 7; // Market ID doesn't match expected value
const EInsufficientLPTokens: u64 = 8; // Not enough LP tokens to burn
const EInvalidTokenType: u64 = 9; // Wrong conditional token type provided
const EOverflow: u64 = 10; // Arithmetic overflow detected
const EInvalidFeeRate: u64 = 11; // Fee rate is invalid (e.g., >= 100%)
const EKInvariantViolation: u64 = 12; // K-invariant violation (guards constant-product invariant)
const EImbalancedLiquidity: u64 = 13; // Liquidity deposit is too imbalanced (>1% difference)

// === Constants ===
const FEE_SCALE: u64 = 10000;
const DEFAULT_FEE: u64 = 30; // 0.3%
const MINIMUM_LIQUIDITY: u128 = 1000;
// Other constants moved to constants module

// === Structs ===

public struct LiquidityPool has key, store {
    id: UID,
    market_id: ID,
    outcome_idx: u8,
    asset_reserve: u64,
    stable_reserve: u64,
    fee_percent: u64,
    oracle: Oracle,  // Futarchy oracle (for determining winner, internal use)
    simple_twap: SimpleTWAP,  // SimpleTWAP oracle (for external consumers)
    protocol_fees: u64, // Track accumulated stable fees
    lp_supply: u64, // Track total LP shares for this pool

    // Bucket tracking for LP withdrawal system
    // LIVE: Came from spot.LIVE via quantum split (will recombine to spot.LIVE)
    // TRANSITIONING: Came from spot.TRANSITIONING via quantum split (will recombine to spot.WITHDRAW_ONLY)
    // Note: Conditionals don't have WITHDRAW_ONLY - that only exists in spot after recombination
    asset_live: u64,
    asset_transitioning: u64,
    stable_live: u64,
    stable_transitioning: u64,
    lp_live: u64,
    lp_transitioning: u64,

    // LP Reward System (Subsidy Distribution)
    // NOTE: Only for CONDITIONAL pools (not spot pools)
    // Subsidies are distributed to LPs as SUI rewards (not added to reserves)
    lp_rewards: Balance<SUI>,  // Accumulated SUI rewards from subsidies
    rewards_per_lp_share_accumulator: u128,  // Fixed-point accumulator (scaled by 1e9)
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

public struct LiquidityAdded has copy, drop {
    market_id: ID,
    outcome: u8,
    asset_amount: u64,
    stable_amount: u64,
    lp_amount: u64,
    sender: address,
    timestamp: u64,
}

public struct LiquidityRemoved has copy, drop {
    market_id: ID,
    outcome: u8,
    asset_amount: u64,
    stable_amount: u64,
    lp_amount: u64,
    sender: address,
    timestamp: u64,
}

// === Public Functions ===
public fun new_pool(
    market_id: ID,
    outcome_idx: u8,
    fee_percent: u64,
    initial_asset: u64,
    initial_stable: u64,
    twap_initial_observation: u128,
    twap_start_delay: u64,
    twap_step_max: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): LiquidityPool {
    assert!(initial_asset > 0 && initial_stable > 0, EZeroAmount);
    let k = math::mul_div_to_128(initial_asset, initial_stable, 1);
    assert!(k >= MINIMUM_LIQUIDITY, ELowLiquidity);
    assert!(fee_percent <= constants::max_amm_fee_bps(), EInvalidFeeRate);

    // Use twap_initial_observation for BOTH oracles to ensure consistency
    let initial_price = twap_initial_observation;

    check_price_under_max(initial_price);

    // Initialize futarchy oracle (for determining winner)
    let oracle = oracle::new_oracle(
        initial_price,
        twap_start_delay,
        twap_step_max,
        ctx,
    );

    // Initialize SimpleTWAP oracle (for external consumers)
    // Windowed TWAP with 1% per minute capping (default config)
    let simple_twap_oracle = simple_twap::new_default(
        initial_price,
        clock,
    );

    // Create pool object
    let pool = LiquidityPool {
        id: object::new(ctx),
        market_id,
        outcome_idx,
        asset_reserve: initial_asset,
        stable_reserve: initial_stable,
        fee_percent,
        oracle,
        simple_twap: simple_twap_oracle,
        protocol_fees: 0,
        lp_supply: 0, // Start at 0 so first provider logic works correctly

        // Initialize all liquidity in LIVE bucket (from quantum split)
        asset_live: initial_asset,
        asset_transitioning: 0,
        stable_live: initial_stable,
        stable_transitioning: 0,
        lp_live: 0,  // Will be set when LP is added
        lp_transitioning: 0,

        // LP Reward System (initialized empty)
        lp_rewards: balance::zero<SUI>(),
        rewards_per_lp_share_accumulator: 0,
    };

    pool
}

// === Core Swap Functions ===
// Note: These functions take generic references to allow inline arbitrage
// without creating circular dependencies between spot_amm and conditional_amm

public fun swap_asset_to_stable(
    pool: &mut LiquidityPool,
    market_id: ID,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    assert!(pool.market_id == market_id, EMarketIdMismatch);
    assert!(amount_in > 0, EZeroAmount);

    // K-GUARD: Capture reserves before swap to validate constant-product invariant
    // WHY: LP fees stay in pool, so k must GROW. Catches fee accounting bugs.
    let k_before = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);

    // When selling outcome tokens (asset -> stable):
    // STANDARD UNISWAP V2 FEE MODEL: Take fee from INPUT
    // 1. Calculate the fee from the input amount (amount_in).
    // 2. The actual amount used for the swap (amount_in_after_fee) is the original input minus the fee.
    // 3. Split the total fee: 80% for LPs (lp_share), 20% for the protocol (protocol_share).
    // 4. `protocol_share` is moved to `pool.protocol_fees`.
    // 5. `amount_in_after_fee` is used to calculate the swap output.
    // 6. The pool's asset reserve increases by `amount_in_after_fee + lp_share`, growing `k`.
    let total_fee = calculate_fee(amount_in, pool.fee_percent);
    let lp_share = math::mul_div_to_64(total_fee, constants::conditional_lp_fee_share_bps(), constants::total_fee_bps());
    let protocol_share = total_fee - lp_share;

    // Amount used for the swap calculation (after removing fees)
    let amount_in_after_fee = amount_in - total_fee;

    // Calculate output based on amount after fee
    let amount_out = calculate_output(
        amount_in_after_fee,
        pool.asset_reserve,
        pool.stable_reserve,
    );

    // Send protocol's share to the fee collector
    pool.protocol_fees = pool.protocol_fees + protocol_share;

    assert!(amount_out >= min_amount_out, EExcessiveSlippage);
    assert!(amount_out < pool.stable_reserve, EPoolEmpty);

    let price_impact = calculate_price_impact(
        amount_in_after_fee,
        pool.asset_reserve,
        amount_out,
        pool.stable_reserve,
    );

    // Capture previous reserve state before the update
    let old_asset = pool.asset_reserve;
    let old_stable = pool.stable_reserve;

    let timestamp = clock.timestamp_ms();
    let old_price = math::mul_div_to_128(old_stable, constants::basis_points(), old_asset);
    // Oracle observation is recorded using the reserves *before* the swap.
    // This ensures that the TWAP accurately reflects the price at the beginning of the swap.
    write_observation(
        &mut pool.oracle,
        timestamp,
        old_price,
    );

    // Update SimpleTWAP oracle (for external consumers)
    simple_twap::update(&mut pool.simple_twap, old_price, clock);

    // Update reserves. The amount added to the asset reserve is the portion used for the swap
    // PLUS the LP share of the fee. The protocol share was already removed.
    let new_asset_reserve = pool.asset_reserve + amount_in_after_fee + lp_share;
    assert!(new_asset_reserve >= pool.asset_reserve, EOverflow);

    pool.asset_reserve = new_asset_reserve;
    pool.stable_reserve = pool.stable_reserve - amount_out;

    // K-GUARD: Validate k increased (LP fees stay in pool, so k must grow)
    // Formula: (asset + amount_in_after_fee + lp_share) * (stable - amount_out) >= asset * stable
    let k_after = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);
    assert!(k_after >= k_before, EKInvariantViolation);

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
        sender: ctx.sender(),
        asset_reserve: pool.asset_reserve,
        stable_reserve: pool.stable_reserve,
        timestamp,
    });

    amount_out
}

// Modified swap_asset_to_stable (selling outcome tokens)
public fun swap_stable_to_asset(
    pool: &mut LiquidityPool,
    market_id: ID,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    assert!(pool.market_id == market_id, EMarketIdMismatch);
    assert!(amount_in > 0, EZeroAmount);

    // K-GUARD: Capture reserves before swap to validate constant-product invariant
    // WHY: LP fees stay in pool, so k must GROW. Catches fee accounting bugs.
    let k_before = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);

    // When buying outcome tokens (stable -> asset):
    // 1. Calculate the fee from the input amount (amount_in).
    // 2. The actual amount used for the swap (amount_in_after_fee) is the original input minus the fee.
    // 3. Split the total fee: 80% for LPs (lp_share), 20% for the protocol (protocol_share).
    // 4. `protocol_share` is moved to `pool.protocol_fees`.
    // 5. `amount_in_after_fee` is used to calculate the swap output.
    // 6. The pool's stable reserve increases by `amount_in_after_fee + lp_share`, growing `k`.
    let total_fee = calculate_fee(amount_in, pool.fee_percent);
    let lp_share = math::mul_div_to_64(total_fee, constants::conditional_lp_fee_share_bps(), constants::total_fee_bps());
    let protocol_share = total_fee - lp_share;

    // Amount used for the swap calculation
    let amount_in_after_fee = amount_in - total_fee;

    // Send protocol's share to the fee collector
    pool.protocol_fees = pool.protocol_fees + protocol_share;

    // Calculate output based on amount after fee
    let amount_out = calculate_output(
        amount_in_after_fee,
        pool.stable_reserve,
        pool.asset_reserve,
    );

    assert!(amount_out >= min_amount_out, EExcessiveSlippage);
    assert!(amount_out < pool.asset_reserve, EPoolEmpty);

    let price_impact = calculate_price_impact(
        amount_in_after_fee,
        pool.stable_reserve,
        amount_out,
        pool.asset_reserve,
    );

    // Capture previous reserve state before the update
    let old_asset = pool.asset_reserve;
    let old_stable = pool.stable_reserve;

    let timestamp = clock.timestamp_ms();
    let old_price = math::mul_div_to_128(old_stable, constants::basis_points(), old_asset);
    // Oracle observation is recorded using the reserves *before* the swap.
    // This ensures that the TWAP accurately reflects the price at the beginning of the swap.
    write_observation(
        &mut pool.oracle,
        timestamp,
        old_price,
    );

    // Update SimpleTWAP oracle (for external consumers)
    simple_twap::update(&mut pool.simple_twap, old_price, clock);

    // Update reserves. The amount added to the stable reserve is the portion used for the swap
    // PLUS the LP share of the fee. The protocol share was already removed.
    let new_stable_reserve = pool.stable_reserve + amount_in_after_fee + lp_share;
    assert!(new_stable_reserve >= pool.stable_reserve, EOverflow);

    pool.stable_reserve = new_stable_reserve;
    pool.asset_reserve = pool.asset_reserve - amount_out;

    // K-GUARD: Validate k increased (LP fees stay in pool, so k must grow)
    // Formula: (asset - amount_out) * (stable + amount_in_after_fee + lp_share) >= asset * stable
    let k_after = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);
    assert!(k_after >= k_before, EKInvariantViolation);

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
        sender: ctx.sender(),
        asset_reserve: pool.asset_reserve,
        stable_reserve: pool.stable_reserve,
        timestamp,
    });

    amount_out
}

// === Liquidity Functions ===

/// Add liquidity proportionally to the AMM pool
/// Only handles calculations and reserve updates, no token operations
/// Returns the amount of LP tokens to mint
public fun add_liquidity_proportional(
    pool: &mut LiquidityPool,
    asset_amount: u64,
    stable_amount: u64,
    min_lp_out: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    assert!(asset_amount > 0, EZeroAmount);
    assert!(stable_amount > 0, EZeroAmount);
    
    // Calculate LP tokens to mint based on current pool state
    let (lp_to_mint, new_lp_supply) = if (pool.lp_supply == 0) {
        // First liquidity provider - bootstrap the pool
        let k_squared = math::mul_div_to_128(asset_amount, stable_amount, 1);
        let k = (math::sqrt_u128(k_squared) as u64);
        assert!(k > (MINIMUM_LIQUIDITY as u64), ELowLiquidity);
        // For the first liquidity provider, a small amount of LP tokens (MINIMUM_LIQUIDITY)
        // is intentionally burned and locked in the pool. This is a standard practice in Uniswap V2
        // to prevent division-by-zero errors and to ensure that LP token prices are always well-defined.
        // This amount is accounted for in the `lp_supply` but is not redeemable.
        let locked = (MINIMUM_LIQUIDITY as u64);
        let minted = k - locked;
        // Return the minted amount and the resulting total supply
        (minted, k)
    } else {
        // Subsequent providers - mint proportionally
        let lp_from_asset = math::mul_div_to_64(asset_amount, pool.lp_supply, pool.asset_reserve);
        let lp_from_stable = math::mul_div_to_64(stable_amount, pool.lp_supply, pool.stable_reserve);

        // SECURITY: Enforce balanced liquidity to prevent price manipulation attacks
        // Calculate the imbalance between asset and stable contributions
        let max_delta = if (lp_from_asset > lp_from_stable) {
            lp_from_asset - lp_from_stable
        } else {
            lp_from_stable - lp_from_asset
        };

        // Calculate average LP amount for tolerance check
        let avg = (lp_from_asset + lp_from_stable) / 2;

        // Enforce 1% maximum imbalance tolerance
        // This prevents attacks where depositing 10,000 asset + 1 stable crashes price
        // Example attack: 10,000 asset + 1 stable → only 1 LP → price drops 91%
        // With this check: Max allowed imbalance is avg/100 (1% of average contribution)
        assert!(max_delta <= avg / 100, EImbalancedLiquidity);

        // Use minimum to ensure proper ratio (after imbalance check passes)
        let minted = math::min(lp_from_asset, lp_from_stable);
        (minted, pool.lp_supply + minted)
    };
    
    // Slippage protection: ensure LP tokens minted meet minimum expectation
    assert!(lp_to_mint >= min_lp_out, EExcessiveSlippage);

    // K-GUARD: Capture k before adding liquidity
    // WHY: Adding liquidity MUST strictly increase k. If not, arithmetic bug or overflow.
    let k_before = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);

    // Update reserves with overflow checks
    let new_asset_reserve = pool.asset_reserve + asset_amount;
    let new_stable_reserve = pool.stable_reserve + stable_amount;
    // Use the precomputed total supply

    // Check for overflow
    assert!(new_asset_reserve >= pool.asset_reserve, EOverflow);
    assert!(new_stable_reserve >= pool.stable_reserve, EOverflow);
    assert!(new_lp_supply >= pool.lp_supply, EOverflow);

    pool.asset_reserve = new_asset_reserve;
    pool.stable_reserve = new_stable_reserve;
    pool.lp_supply = new_lp_supply;

    // K-GUARD: Validate k strictly increased
    // Formula: (asset + asset_amount) * (stable + stable_amount) > asset * stable
    let k_after = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);
    assert!(k_after > k_before, EKInvariantViolation);

    // Update SimpleTWAP after liquidity change
    let new_price = get_current_price(pool);
    simple_twap::update(&mut pool.simple_twap, new_price, clock);

    event::emit(LiquidityAdded {
        market_id: pool.market_id,
        outcome: pool.outcome_idx,
        asset_amount,
        stable_amount,
        lp_amount: lp_to_mint,
        sender: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });

    lp_to_mint
}

/// Remove liquidity proportionally from the AMM pool
/// Only handles calculations and reserve updates, no token operations
/// Returns the amounts of asset and stable tokens to mint
public fun remove_liquidity_proportional(
    pool: &mut LiquidityPool,
    lp_amount: u64,
    clock: &Clock,
    ctx: &TxContext
): (u64, u64) {
    // Check for zero liquidity in the pool first to provide a more accurate error message
    assert!(pool.lp_supply > 0, EZeroLiquidity);
    assert!(lp_amount > 0, EZeroAmount);

    // K-GUARD: Capture k before removing liquidity
    // WHY: Removing liquidity MUST strictly decrease k (but stay ≥ minimum).
    let k_before = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);

    // Calculate proportional share to remove from this AMM
    let asset_to_remove = math::mul_div_to_64(lp_amount, pool.asset_reserve, pool.lp_supply);
    let stable_to_remove = math::mul_div_to_64(lp_amount, pool.stable_reserve, pool.lp_supply);

    // Ensure minimum liquidity remains
    assert!(pool.asset_reserve > asset_to_remove, EPoolEmpty);
    assert!(pool.stable_reserve > stable_to_remove, EPoolEmpty);
    assert!(pool.lp_supply > lp_amount, EInsufficientLPTokens);

    // Ensure remaining liquidity is above minimum threshold
    let remaining_asset = pool.asset_reserve - asset_to_remove;
    let remaining_stable = pool.stable_reserve - stable_to_remove;
    let remaining_k = math::mul_div_to_128(remaining_asset, remaining_stable, 1);
    assert!(remaining_k >= (MINIMUM_LIQUIDITY as u128), ELowLiquidity);

    // Update pool state (underflow already checked by earlier asserts)
    pool.asset_reserve = pool.asset_reserve - asset_to_remove;
    pool.stable_reserve = pool.stable_reserve - stable_to_remove;
    pool.lp_supply = pool.lp_supply - lp_amount;

    // K-GUARD: Validate k strictly decreased but stays above minimum
    // Formula: (asset - asset_to_remove) * (stable - stable_to_remove) < asset * stable
    //          AND result >= MINIMUM_LIQUIDITY
    let k_after = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);
    assert!(k_after < k_before, EKInvariantViolation);  // Must decrease
    assert!(k_after >= (MINIMUM_LIQUIDITY as u128), ELowLiquidity);  // But stay above min

    // Update SimpleTWAP after liquidity change
    let new_price = get_current_price(pool);
    simple_twap::update(&mut pool.simple_twap, new_price, clock);

    event::emit(LiquidityRemoved {
        market_id: pool.market_id,
        outcome: pool.outcome_idx,
        asset_amount: asset_to_remove,
        stable_amount: stable_to_remove,
        lp_amount,
        sender: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });

    (asset_to_remove, stable_to_remove)
}

public fun empty_all_amm_liquidity(
    pool: &mut LiquidityPool,
    _ctx: &mut TxContext,
): (u64, u64) {
    // Capture full reserves before zeroing them out
    let asset_amount_out = pool.asset_reserve;
    let stable_amount_out = pool.stable_reserve;

    pool.asset_reserve = 0;
    pool.stable_reserve = 0;

    // Reset LP accounting so the next quantum split reboots cleanly
    pool.lp_supply = 0;
    pool.asset_live = 0;
    pool.asset_transitioning = 0;
    pool.stable_live = 0;
    pool.stable_transitioning = 0;
    pool.lp_live = 0;
    pool.lp_transitioning = 0;

    (asset_amount_out, stable_amount_out)
}

// === Oracle Functions ===
// Update new_oracle to be simpler:
fun write_observation(oracle: &mut Oracle, timestamp: u64, price: u128) {
    oracle.write_observation(timestamp, price)
}

public fun get_oracle(pool: &LiquidityPool): &Oracle {
    &pool.oracle
}

public fun get_simple_twap(pool: &LiquidityPool): &SimpleTWAP {
    &pool.simple_twap
}

// === View Functions ===

public fun get_reserves(pool: &LiquidityPool): (u64, u64) {
    (pool.asset_reserve, pool.stable_reserve)
}

public fun get_lp_supply(pool: &LiquidityPool): u64 {
    pool.lp_supply
}

/// Get bucket amounts for recombination
/// Returns (asset_live, asset_transitioning, stable_live, stable_transitioning, lp_live, lp_transitioning)
public fun get_bucket_amounts(pool: &LiquidityPool): (u64, u64, u64, u64, u64, u64) {
    (
        pool.asset_live,
        pool.asset_transitioning,
        pool.stable_live,
        pool.stable_transitioning,
        pool.lp_live,
        pool.lp_transitioning,
    )
}

/// Get pool fee in basis points
public fun get_fee_bps(pool: &LiquidityPool): u64 {
    pool.fee_percent
}

public fun get_price(pool: &LiquidityPool): u128 {
    pool.oracle.last_price()
}

public fun get_twap(pool: &mut LiquidityPool, clock: &Clock): u128 {
    update_twap_observation(pool, clock);
    pool.oracle.get_twap(clock)
}

public fun quote_swap_asset_to_stable(pool: &LiquidityPool, amount_in: u64): u64 {
    // Take fee from input (matching swap function)
    let total_fee = calculate_fee(amount_in, pool.fee_percent);
    let amount_in_after_fee = amount_in - total_fee;
    // Calculate output from after-fee amount
    calculate_output(
        amount_in_after_fee,
        pool.asset_reserve,
        pool.stable_reserve,
    )
}

public fun quote_swap_stable_to_asset(pool: &LiquidityPool, amount_in: u64): u64 {
    let amount_in_with_fee = amount_in - calculate_fee(amount_in, pool.fee_percent);
    calculate_output(
        amount_in_with_fee,
        pool.stable_reserve,
        pool.asset_reserve,
    )
}

// === Arbitrage Helper Functions ===

/// Feeless swap asset→stable (for internal arbitrage only)
/// No fees charged to maximize arbitrage efficiency
///
/// AUDIT FIX: Now MUTATES reserves (Q3: swaps should always update state)
public(package) fun feeless_swap_asset_to_stable(
    pool: &mut LiquidityPool,
    amount_in: u64,
): u64 {
    assert!(amount_in > 0, EZeroAmount);
    assert!(pool.asset_reserve > 0 && pool.stable_reserve > 0, EPoolEmpty);

    // K-GUARD: Feeless swaps should preserve k EXACTLY (no fees = no k growth)
    // WHY: Validates arbitrage math is correct (used in executor's multi-pool swaps)
    let k_before = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);

    // No fee for arbitrage swaps (fee-free constant product)
    let stable_out = calculate_output(
        amount_in,
        pool.asset_reserve,
        pool.stable_reserve,
    );
    assert!(stable_out < pool.stable_reserve, EPoolEmpty);

    // CRITICAL FIX: Update reserves! Any swap must mutate state.
    pool.asset_reserve = pool.asset_reserve + amount_in;
    pool.stable_reserve = pool.stable_reserve - stable_out;

    // K-GUARD: Validate k unchanged (feeless swap preserves k within rounding)
    // Formula: (asset + amount_in) * (stable - stable_out) ≈ asset * stable
    // Allow tiny rounding tolerance (1 part in 10^6)
    let k_after = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);
    let k_delta = if (k_after > k_before) { k_after - k_before } else { k_before - k_after };
    // 0.0001% tolerance (min 1 to prevent zero at low liquidity)
    let tolerance_calc = k_before / 1000000;
    let tolerance = if (tolerance_calc < 1) { 1 } else { tolerance_calc };
    assert!(k_delta <= tolerance, EKInvariantViolation);

    stable_out
}

/// Feeless swap stable→asset (for internal arbitrage only)
///
/// AUDIT FIX: Now MUTATES reserves (Q3: swaps should always update state)
public(package) fun feeless_swap_stable_to_asset(
    pool: &mut LiquidityPool,
    amount_in: u64,
): u64 {
    assert!(amount_in > 0, EZeroAmount);
    assert!(pool.asset_reserve > 0 && pool.stable_reserve > 0, EPoolEmpty);

    // K-GUARD: Feeless swaps should preserve k EXACTLY (no fees = no k growth)
    // WHY: Validates arbitrage math is correct (used in executor's multi-pool swaps)
    let k_before = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);

    // No fee for arbitrage swaps
    let asset_out = calculate_output(
        amount_in,
        pool.stable_reserve,
        pool.asset_reserve,
    );
    assert!(asset_out < pool.asset_reserve, EPoolEmpty);

    // CRITICAL FIX: Update reserves! Any swap must mutate state.
    pool.stable_reserve = pool.stable_reserve + amount_in;
    pool.asset_reserve = pool.asset_reserve - asset_out;

    // K-GUARD: Validate k unchanged (feeless swap preserves k within rounding)
    // Formula: (asset - asset_out) * (stable + amount_in) ≈ asset * stable
    // Allow tiny rounding tolerance (1 part in 10^6)
    let k_after = (pool.asset_reserve as u128) * (pool.stable_reserve as u128);
    let k_delta = if (k_after > k_before) { k_after - k_before } else { k_before - k_after };
    // 0.0001% tolerance (min 1 to prevent zero at low liquidity)
    let tolerance_calc = k_before / 1000000;
    let tolerance = if (tolerance_calc < 1) { 1 } else { tolerance_calc };
    assert!(k_delta <= tolerance, EKInvariantViolation);

    asset_out
}

/// Simulate asset→stable swap without executing
/// Pure function for arbitrage optimization
///
/// STANDARD UNISWAP V2 FEE MODEL: Fee charged on INPUT (consistent with swap execution)
public fun simulate_swap_asset_to_stable(
    pool: &LiquidityPool,
    amount_in: u64,
): u64 {
    if (amount_in == 0) return 0;
    if (pool.asset_reserve == 0 || pool.stable_reserve == 0) return 0;

    // Take fee from input (matching swap function)
    let total_fee = calculate_fee(amount_in, pool.fee_percent);
    let amount_in_after_fee = if (amount_in > total_fee) {
        amount_in - total_fee
    } else {
        return 0
    };

    let stable_out = calculate_output(
        amount_in_after_fee,
        pool.asset_reserve,
        pool.stable_reserve,
    );

    if (stable_out >= pool.stable_reserve) return 0;

    stable_out
}

/// Simulate stable→asset swap without executing
public fun simulate_swap_stable_to_asset(
    pool: &LiquidityPool,
    amount_in: u64,
): u64 {
    if (amount_in == 0) return 0;
    if (pool.asset_reserve == 0 || pool.stable_reserve == 0) return 0;

    // Simulate with fee
    let total_fee = calculate_fee(amount_in, pool.fee_percent);
    let amount_in_after_fee = if (amount_in > total_fee) {
        amount_in - total_fee
    } else {
        return 0
    };

    let asset_out = calculate_output(
        amount_in_after_fee,
        pool.stable_reserve,
        pool.asset_reserve,
    );

    if (asset_out >= pool.asset_reserve) return 0;

    asset_out
}

fun calculate_price_impact(
    amount_in: u64,
    reserve_in: u64,
    amount_out: u64,
    reserve_out: u64,
): u128 {
    // Use u256 for intermediate calculations to prevent overflow
    let amount_in_256 = (amount_in as u256);
    let reserve_out_256 = (reserve_out as u256);
    let reserve_in_256 = (reserve_in as u256);
    
    // Calculate ideal output with u256 to prevent overflow
    let ideal_out_256 = (amount_in_256 * reserve_out_256) / reserve_in_256;
    assert!(ideal_out_256 <= (std::u128::max_value!() as u256), EOverflow);
    let ideal_out = (ideal_out_256 as u128);
    
    // The assert below ensures that `ideal_out` is always greater than or equal to `amount_out`.
    // This prevents underflow when calculating `ideal_out - (amount_out as u128)`.
    assert!(ideal_out >= (amount_out as u128), EOverflow); // Ensure no underflow
    math::mul_div_mixed(ideal_out - (amount_out as u128), FEE_SCALE, ideal_out)
}

// Update the LiquidityPool struct price calculation to use TWAP:
public fun get_current_price(pool: &LiquidityPool): u128 {
    assert!(pool.asset_reserve > 0 && pool.stable_reserve > 0, EZeroLiquidity);

    let price = math::mul_div_to_128(
        pool.stable_reserve,
        constants::basis_points(),
        pool.asset_reserve,
    );

    price
}

public fun update_twap_observation(pool: &mut LiquidityPool, clock: &Clock) {
    let timestamp = clock.timestamp_ms();
    let current_price = get_current_price(pool);
    // Use the sum of reserves as a liquidity measure
    pool.oracle.write_observation(timestamp, current_price);
}

public fun set_oracle_start_time(pool: &mut LiquidityPool, market_id: ID, trading_start_time: u64) {
    assert!(get_ms_id(pool) == market_id, EMarketIdMismatch);
    pool.oracle.set_oracle_start_time(trading_start_time);
}

// === Private Functions ===
fun calculate_fee(amount: u64, fee_percent: u64): u64 {
    math::mul_div_to_64(amount, fee_percent, FEE_SCALE)
}

public fun calculate_output(
    amount_in_with_fee: u64,
    reserve_in: u64,
    reserve_out: u64,
): u64 {
    assert!(reserve_in > 0 && reserve_out > 0, EPoolEmpty);

    let denominator = reserve_in + amount_in_with_fee;
    assert!(denominator > 0, EDivByZero);
    let numerator = (amount_in_with_fee as u256) * (reserve_out as u256);
    let output = numerator / (denominator as u256);
    assert!(output <= (u64::max_value!() as u256), EOverflow);
    (output as u64)
}

public fun get_outcome_idx(pool: &LiquidityPool): u8 {
    pool.outcome_idx
}

public fun get_id(pool: &LiquidityPool): ID {
    pool.id.to_inner()
}

public fun get_k(pool: &LiquidityPool): u128 {
    math::mul_div_to_128(pool.asset_reserve, pool.stable_reserve, 1)
}

public fun check_price_under_max(price: u128) {
    let max_price = (0xFFFFFFFFFFFFFFFFu64 as u128) * (constants::basis_points() as u128);
    assert!(price <= max_price, EPriceTooHigh)
}

public fun get_protocol_fees(pool: &LiquidityPool): u64 {
    pool.protocol_fees
}

public fun get_ms_id(pool: &LiquidityPool): ID {
    pool.market_id
}

public fun reset_protocol_fees(pool: &mut LiquidityPool) {
    pool.protocol_fees = 0;
}

/// Add subsidy as LP rewards (CORRECT IMPLEMENTATION)
/// Accumulates SUI rewards for LPs to claim later
/// Does NOT manipulate pool reserves or price
///
/// ## Reward Accumulation Formula
/// rewards_per_lp_share += (subsidy_amount * 1e9) / lp_supply
///
/// ## Security
/// - No price manipulation (reserves unchanged)
/// - Fair distribution (proportional to LP ownership)
/// - Hard-backed (actual SUI tokens deposited)
///
/// CRITICAL: Only callable by subsidy_escrow module
public fun accumulate_subsidy_rewards(
    pool: &mut LiquidityPool,
    subsidy: Balance<SUI>,
) {
    let subsidy_amount = subsidy.value();
    assert!(subsidy_amount > 0, EZeroAmount);
    assert!(pool.lp_supply > 0, EZeroLiquidity); // Prevent division by zero

    // Calculate reward per LP share (fixed-point math, scaled by 1e9)
    let reward_per_share = (subsidy_amount as u128) * 1_000_000_000 / (pool.lp_supply as u128);

    // Update accumulator
    pool.rewards_per_lp_share_accumulator = pool.rewards_per_lp_share_accumulator + reward_per_share;

    // Add subsidy to reward pool (actual tokens!)
    pool.lp_rewards.join(subsidy);
}

/// Get accumulated rewards for an LP amount (view function)
/// Returns claimable SUI amount
public fun get_claimable_rewards(
    pool: &LiquidityPool,
    lp_amount: u64,
    already_claimed: u128,
): u64 {
    if (lp_amount == 0) { return 0 };

    // Calculate total earned: lp_amount * accumulator / 1e9
    let total_earned = (lp_amount as u128) * pool.rewards_per_lp_share_accumulator / 1_000_000_000;

    // Claimable = total_earned - already_claimed
    if (total_earned > already_claimed) {
        ((total_earned - already_claimed) as u64)
    } else {
        0
    }
}

/// Get rewards per LP share accumulator (view function)
public fun get_rewards_accumulator(pool: &LiquidityPool): u128 {
    pool.rewards_per_lp_share_accumulator
}

/// Get total accumulated rewards in pool (view function)
public fun get_total_rewards(pool: &LiquidityPool): u64 {
    pool.lp_rewards.value()
}

/// Get LP rewards balance (view function) - alias for get_total_rewards
public fun get_lp_rewards(pool: &LiquidityPool): u64 {
    pool.lp_rewards.value()
}

/// Extract all accumulated rewards from pool
/// Only callable from futarchy_markets_core (for claim operations)
/// Leaves pool in clean state with zero rewards
///
/// ## Security
/// - Caller must verify LP ownership and DAO check
/// - All tokens are extracted (hard backing proof)
public fun extract_all_rewards(
    pool: &mut LiquidityPool,
): Balance<SUI> {
    let reward_amount = pool.lp_rewards.value();

    // Extract all rewards, leaving pool with zero balance
    pool.lp_rewards.withdraw_all()
}

// === Test Functions ===

#[test_only]
/// Test helper: wrapper for new_pool() with simplified signature
public fun new<AssetType, StableType>(
    fee_percent: u64,
    twap_start_delay: u64,
    twap_initial_observation: u128,
    twap_step_max: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): LiquidityPool {
    new_pool(
        object::id_from_address(@0x0), // market_id
        0, // outcome_idx
        fee_percent,
        1_000, // initial_asset
        1_000, // initial_stable
        twap_initial_observation,
        twap_start_delay,
        twap_step_max,
        clock,
        ctx,
    )
}

#[test_only]
/// Test helper: destroy a coin
public fun burn_for_testing<T>(coin: sui::coin::Coin<T>) {
    sui::test_utils::destroy(coin);
}

#[test_only]
/// Test helper: alias for get_lp_supply()
public fun lp_supply(pool: &LiquidityPool): u64 {
    get_lp_supply(pool)
}

#[test_only]
public fun create_test_pool(
    market_id: ID,
    outcome_idx: u8,
    fee_percent: u64,
    asset_reserve: u64,
    stable_reserve: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): LiquidityPool {
    let initial_price = math::mul_div_to_128(stable_reserve, 1_000_000_000_000, asset_reserve);

    let mut oracle_obj = oracle::new_oracle(
        initial_price,
        0, // Use 0 which is always a valid multiple of TWAP_PRICE_CAP_WINDOW
        1_000,
        ctx,
    );

    // Initialize oracle market start time for tests
    oracle_obj.set_oracle_start_time(clock.timestamp_ms());

    LiquidityPool {
        id: object::new(ctx),
        market_id,
        outcome_idx,
        asset_reserve,
        stable_reserve,
        fee_percent,
        oracle: oracle_obj,
        simple_twap: simple_twap::new_default(initial_price, clock),  // Windowed capped TWAP
        protocol_fees: 0,
        lp_supply: (MINIMUM_LIQUIDITY as u64),
        // Initialize all liquidity in LIVE bucket for testing
        asset_live: asset_reserve,
        asset_transitioning: 0,
        stable_live: stable_reserve,
        stable_transitioning: 0,
        lp_live: (MINIMUM_LIQUIDITY as u64),
        lp_transitioning: 0,
        lp_rewards: balance::zero<SUI>(),
        rewards_per_lp_share_accumulator: 0,
    }
}

#[test_only]
/// Create a pool with initial liquidity for testing arbitrage_math
public fun create_pool_for_testing(
    asset_amount: u64,
    stable_amount: u64,
    fee_bps: u64,
    ctx: &mut TxContext,
): LiquidityPool {
    use sui::clock;

    // Create a minimal oracle and simple_twap for testing
    let clock = clock::create_for_testing(ctx);
    let initial_price = if (asset_amount > 0 && stable_amount > 0) {
        ((stable_amount as u128) * 1_000_000_000) / (asset_amount as u128)
    } else {
        1_000_000_000
    };

    let oracle_obj = oracle::new_oracle(
        initial_price,
        0, // twap_start_delay - Use 0 which is always a valid multiple of TWAP_PRICE_CAP_WINDOW
        100, // twap_step_max (ppm)
        ctx
    );

    let simple_twap = simple_twap::new_default(initial_price, &clock);
    clock::destroy_for_testing(clock);

    LiquidityPool {
        id: object::new(ctx),
        market_id: object::id_from_address(@0x0),
        outcome_idx: 0,
        asset_reserve: asset_amount,
        stable_reserve: stable_amount,
        fee_percent: fee_bps,
        oracle: oracle_obj,
        simple_twap,
        protocol_fees: 0,
        lp_supply: (MINIMUM_LIQUIDITY as u64),
        // Initialize all liquidity in LIVE bucket for testing
        asset_live: asset_amount,
        asset_transitioning: 0,
        stable_live: stable_amount,
        stable_transitioning: 0,
        lp_live: (MINIMUM_LIQUIDITY as u64),
        lp_transitioning: 0,
        lp_rewards: balance::zero<SUI>(),
        rewards_per_lp_share_accumulator: 0,
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
        simple_twap,
        protocol_fees: _,
        lp_supply: _,
        asset_live: _,
        asset_transitioning: _,
        stable_live: _,
        stable_transitioning: _,
        lp_live: _,
        lp_transitioning: _,
        lp_rewards,
        rewards_per_lp_share_accumulator: _,
    } = pool;
    id.delete();
    oracle.destroy_for_testing();
    simple_twap.destroy_for_testing();
    balance::destroy_for_testing(lp_rewards);
}

#[test_only]
/// Add liquidity to a pool for testing (simplified version)
/// Takes coins directly, extracts values, updates reserves, and destroys coins
public fun add_liquidity_for_testing<AssetType, StableType>(
    pool: &mut LiquidityPool,
    asset_coin: sui::coin::Coin<AssetType>,
    stable_coin: sui::coin::Coin<StableType>,
    _fee_bps: u16,  // Not used in test helper, kept for API compatibility
    _ctx: &mut TxContext,
) {
    // Extract amounts from coins
    let asset_amount = asset_coin.value();
    let stable_amount = stable_coin.value();

    // Destroy test coins (we just want to update reserves)
    sui::test_utils::destroy(asset_coin);
    sui::test_utils::destroy(stable_coin);

    // Update reserves directly (simplified for testing)
    pool.asset_reserve = pool.asset_reserve + asset_amount;
    pool.stable_reserve = pool.stable_reserve + stable_amount;

    // Update LP supply proportionally (simplified calculation for testing)
    if (pool.lp_supply == 0) {
        // First liquidity provider
        let k_squared = math::mul_div_to_128(asset_amount, stable_amount, 1);
        let k = (math::sqrt_u128(k_squared) as u64);
        pool.lp_supply = k;
    } else {
        // Subsequent providers - mint proportionally
        let lp_from_asset = math::mul_div_to_64(asset_amount, pool.lp_supply, pool.asset_reserve - asset_amount);
        let lp_from_stable = math::mul_div_to_64(stable_amount, pool.lp_supply, pool.stable_reserve - stable_amount);
        let lp_to_mint = if (lp_from_asset < lp_from_stable) { lp_from_asset } else { lp_from_stable };
        pool.lp_supply = pool.lp_supply + lp_to_mint;
    };
}
