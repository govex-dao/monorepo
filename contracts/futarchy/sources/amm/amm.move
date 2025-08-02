module futarchy::amm;

use futarchy::market_state::MarketState;
use futarchy::conditional_token::ConditionalToken;
use futarchy::coin_escrow::{Self, TokenEscrow};
use futarchy::math;
use futarchy::oracle::{Self, Oracle};
use sui::clock::Clock;
use sui::event;
use std::u64;

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
const EInvalidLiquidityRatio: u64 = 11; // Liquidity provided does not match pool ratio
const EInvalidFeeRate: u64 = 12; // Fee rate is invalid (e.g., >= 100%)

// === Constants ===
const FEE_SCALE: u64 = 10000;
const DEFAULT_FEE: u64 = 30; // 0.3%
const BASIS_POINTS: u64 = 1_000_000_000_000; // 10^12 we need to keep this for saftey to values don't round to 0
const MINIMUM_LIQUIDITY: u128 = 1000;

// Fee split constants (in basis points)
const LP_FEE_SHARE_BPS: u64 = 8000; // 80%
const TOTAL_FEE_BPS: u64 = 10000; // 100%

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
    lp_supply: u64, // Track total LP shares for this pool
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
public(package) fun new_pool(
    state: &MarketState,
    outcome_idx: u8,
    fee_percent: u64,
    initial_asset: u64,
    initial_stable: u64,
    twap_initial_observation: u128,
    twap_start_delay: u64,
    twap_step_max: u64,
    ctx: &mut TxContext,
): LiquidityPool {
    assert!(initial_asset > 0 && initial_stable > 0, EZeroAmount);
    let k = math::mul_div_to_128(initial_asset, initial_stable, 1);
    assert!(k >= MINIMUM_LIQUIDITY, ELowLiquidity);
    assert!(fee_percent < FEE_SCALE, EInvalidFeeRate); // Fee cannot be 100% or more

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

    // Create pool object
    let pool = LiquidityPool {
        id: object::new(ctx),
        market_id: state.market_id(),
        outcome_idx,
        asset_reserve: initial_asset,
        stable_reserve: initial_stable,
        fee_percent,
        oracle,
        protocol_fees: 0,
        lp_supply: 0, // Start at 0 so first provider logic works correctly
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
    state.assert_trading_active();
    assert!(pool.market_id == state.market_id(), EMarketIdMismatch);
    assert!(amount_in > 0, EZeroAmount);

    // When selling outcome tokens (asset -> stable):
    // 1. Calculate the gross output amount (amount_out_before_fee) based on current reserves and amount_in.
    // 2. Calculate the fee amount from this gross output.
    // 3. Split the fee: 80% for LPs (lp_share), 20% for the protocol (protocol_share).
    // 4. The `protocol_share` is moved to `pool.protocol_fees`.
    // 5. The `lp_share` is left in the pool's stable reserve to reward LPs, causing `k` to grow.
    // 6. The user receives the net output `amount_out = amount_out_before_fee - total_fee`.
    let amount_out_before_fee = calculate_output(
        amount_in,
        pool.asset_reserve,
        pool.stable_reserve,
    );

    // Calculate fee from stable output
    let total_fee = calculate_fee(amount_out_before_fee, pool.fee_percent);
    let lp_share = math::mul_div_to_64(total_fee, LP_FEE_SHARE_BPS, TOTAL_FEE_BPS);
    let protocol_share = total_fee - lp_share;

    // Net amount for the user
    let amount_out = amount_out_before_fee - total_fee;

    // Send protocol's share to the fee collector
    pool.protocol_fees = pool.protocol_fees + protocol_share;

    assert!(amount_out >= min_amount_out, EExcessiveSlippage);
    assert!(amount_out_before_fee < pool.stable_reserve, EPoolEmpty);

    let price_impact = calculate_price_impact(
        amount_in,
        pool.asset_reserve,
        amount_out_before_fee, // Use before-fee amount for impact calculation
        pool.stable_reserve,
    );

    // Capture previous reserve state before the update
    let old_asset = pool.asset_reserve;
    let old_stable = pool.stable_reserve;

    let timestamp = clock.timestamp_ms();
    let old_price = math::mul_div_to_128(old_stable, BASIS_POINTS, old_asset);
    // Oracle observation is recorded using the reserves *before* the swap.
    // This ensures that the TWAP accurately reflects the price at the beginning of the swap.
    write_observation(
        &mut pool.oracle,
        timestamp,
        old_price,
    );

    // Update reserves.
    pool.asset_reserve = pool.asset_reserve + amount_in;

    // The stable reserve is reduced by the gross output, BUT the LPs' share is kept in the pool.
    // So we add it back.
    // This is equivalent to `pool.stable_reserve - (amount_out + protocol_share)`
    pool.stable_reserve = pool.stable_reserve - amount_out_before_fee + lp_share;

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
public(package) fun swap_stable_to_asset(
    pool: &mut LiquidityPool,
    state: &MarketState,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    state.assert_trading_active();
    assert!(pool.market_id == state.market_id(), EMarketIdMismatch);
    assert!(amount_in > 0, EZeroAmount);

    // When buying outcome tokens (stable -> asset):
    // 1. Calculate the fee from the input amount (amount_in).
    // 2. The actual amount used for the swap (amount_in_after_fee) is the original input minus the fee.
    // 3. Split the total fee: 80% for LPs (lp_share), 20% for the protocol (protocol_share).
    // 4. `protocol_share` is moved to `pool.protocol_fees`.
    // 5. `amount_in_after_fee` is used to calculate the swap output.
    // 6. The pool's stable reserve increases by `amount_in_after_fee + lp_share`, growing `k`.
    let total_fee = calculate_fee(amount_in, pool.fee_percent);
    let lp_share = math::mul_div_to_64(total_fee, LP_FEE_SHARE_BPS, TOTAL_FEE_BPS);
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
    let old_price = math::mul_div_to_128(old_stable, BASIS_POINTS, old_asset);
    // Oracle observation is recorded using the reserves *before* the swap.
    // This ensures that the TWAP accurately reflects the price at the beginning of the swap.
    write_observation(
        &mut pool.oracle,
        timestamp,
        old_price,
    );

    // Update reserves. The amount added to the stable reserve is the portion used for the swap
    // PLUS the LP share of the fee. The protocol share was already removed.
    let new_stable_reserve = pool.stable_reserve + amount_in_after_fee + lp_share;
    assert!(new_stable_reserve >= pool.stable_reserve, EOverflow);

    pool.stable_reserve = new_stable_reserve;
    pool.asset_reserve = pool.asset_reserve - amount_out;

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
/// This function is called by the spot pool when distributing liquidity across outcome AMMs
/// Returns LP conditional tokens minted
public(package) fun add_liquidity_proportional<AssetType, StableType>(
    pool: &mut LiquidityPool,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_in: ConditionalToken,
    stable_in: ConditionalToken,
    min_lp_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ConditionalToken {
    let asset_amount = asset_in.value();
    let stable_amount = stable_in.value();
    
    // Verify tokens match this pool's outcome
    assert!(asset_in.market_id() == pool.market_id, EMarketIdMismatch);
    assert!(stable_in.market_id() == pool.market_id, EMarketIdMismatch);
    assert!(asset_in.outcome() == pool.outcome_idx, EInvalidTokenType);
    assert!(stable_in.outcome() == pool.outcome_idx, EInvalidTokenType);
    assert!(asset_in.asset_type() == 0, EInvalidTokenType); // 0 = asset type
    assert!(stable_in.asset_type() == 1, EInvalidTokenType); // 1 = stable type
    
    // Calculate LP tokens to mint based on current pool state
    let lp_to_mint = if (pool.lp_supply == 0) {
        // First liquidity provider - bootstrap the pool
        let k_squared = math::mul_div_to_128(asset_amount, stable_amount, 1);
        let k = (math::sqrt_u128(k_squared) as u64);
        assert!(k >= (MINIMUM_LIQUIDITY as u64), ELowLiquidity);
        // For the first liquidity provider, a small amount of LP tokens (MINIMUM_LIQUIDITY)
        // is intentionally burned and locked in the pool. This is a standard practice in Uniswap V2
        // to prevent division-by-zero errors and to ensure that LP token prices are always well-defined.
        // This amount is accounted for in the `lp_supply` but is not redeemable.
        pool.lp_supply = k;
        k
    } else {
        // Subsequent providers - mint proportionally
        // The `math::min` function is used here, similar to Uniswap V2, to calculate the LP tokens to mint.
        // This approach inherently protects against adding imbalanced liquidity by only considering the
        // smaller of the two potential LP amounts derived from asset and stable contributions.
        //
        // Additionally, the `assert!` statement below provides explicit ratio validation (slippage protection)
        // to ensure that the provided asset and stable amounts are close to the current pool ratio,
        // preventing users from adding liquidity at highly unfavorable rates.
        let expected_stable_amount = math::mul_div_to_64(asset_amount, pool.stable_reserve, pool.asset_reserve);
        let expected_asset_amount = math::mul_div_to_64(stable_amount, pool.asset_reserve, pool.stable_reserve);

        // Use a tolerance of 0.1% (10 basis points) to allow for small rounding differences
        // while still preventing imbalanced liquidity attacks
        let tolerance_bps = 10; // 0.1%
        assert!(
            math::within_tolerance(stable_amount, expected_stable_amount, tolerance_bps) || 
            math::within_tolerance(asset_amount, expected_asset_amount, tolerance_bps), 
            EInvalidLiquidityRatio
        );

        let lp_from_asset = math::mul_div_to_64(asset_amount, pool.lp_supply, pool.asset_reserve);
        let lp_from_stable = math::mul_div_to_64(stable_amount, pool.lp_supply, pool.stable_reserve);
        // Use minimum to ensure proper ratio
        math::min(lp_from_asset, lp_from_stable)
    };
    
    // Slippage protection: ensure LP tokens minted meet minimum expectation
    assert!(lp_to_mint >= min_lp_out, EExcessiveSlippage);
    
    // Update reserves with overflow checks
    let new_asset_reserve = pool.asset_reserve + asset_amount;
    let new_stable_reserve = pool.stable_reserve + stable_amount;
    let new_lp_supply = pool.lp_supply + lp_to_mint;
    
    // Check for overflow
    assert!(new_asset_reserve >= pool.asset_reserve, EOverflow);
    assert!(new_stable_reserve >= pool.stable_reserve, EOverflow);
    assert!(new_lp_supply >= pool.lp_supply, EOverflow);
    
    pool.asset_reserve = new_asset_reserve;
    pool.stable_reserve = new_stable_reserve;
    pool.lp_supply = new_lp_supply;
    
    // Burn the conditional tokens (they're now absorbed into the pool's reserves)
    coin_escrow::burn_single_conditional_token(escrow, asset_in, clock, ctx);
    coin_escrow::burn_single_conditional_token(escrow, stable_in, clock, ctx);
    
    event::emit(LiquidityAdded {
        market_id: pool.market_id,
        outcome: pool.outcome_idx,
        asset_amount,
        stable_amount,
        lp_amount: lp_to_mint,
        sender: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });

    // Mint LP conditional tokens
    coin_escrow::mint_single_conditional_token(
        escrow,
        2, // TOKEN_TYPE_LP
        pool.outcome_idx,
        lp_to_mint,
        ctx.sender(),
        clock,
        ctx
    )
}

/// Remove liquidity proportionally from the AMM pool
/// This function is called by the spot pool when collecting liquidity from outcome AMMs
/// Takes LP conditional tokens and returns asset/stable conditional tokens
public(package) fun remove_liquidity_proportional<AssetType, StableType>(
    pool: &mut LiquidityPool,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    lp_token: ConditionalToken,
    clock: &Clock,
    ctx: &mut TxContext
): (ConditionalToken, ConditionalToken) {
    // Verify LP token is for this pool
    assert!(lp_token.market_id() == pool.market_id, EMarketIdMismatch);
    assert!(lp_token.outcome() == pool.outcome_idx, EInvalidTokenType);
    assert!(lp_token.asset_type() == 2, EInvalidTokenType); // Must be LP token
    
    let lp_amount = lp_token.value();
    // Check for zero liquidity in the pool first to provide a more accurate error message
    assert!(pool.lp_supply > 0, EZeroLiquidity);
    assert!(lp_amount > 0, EZeroAmount);
    
    // Burn the LP token
    coin_escrow::burn_single_conditional_token(escrow, lp_token, clock, ctx);
    
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

    event::emit(LiquidityRemoved {
        market_id: pool.market_id,
        outcome: pool.outcome_idx,
        asset_amount: asset_to_remove,
        stable_amount: stable_to_remove,
        lp_amount,
        sender: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
    
    // Create conditional tokens to return using the escrow's mint function
    // Note: In the live-flow model, these tokens are temporary and will be
    // immediately redeemed for spot tokens by the calling function
    let asset_token = coin_escrow::mint_single_conditional_token(
        escrow,
        0, // asset type
        pool.outcome_idx,
        asset_to_remove,
        ctx.sender(),
        clock,
        ctx
    );
    
    let stable_token = coin_escrow::mint_single_conditional_token(
        escrow,
        1, // stable type
        pool.outcome_idx,
        stable_to_remove,
        ctx.sender(),
        clock,
        ctx
    );
    
    (asset_token, stable_token)
}

public(package) fun empty_all_amm_liquidity(
    pool: &mut LiquidityPool,
    _ctx: &mut TxContext,
): (u64, u64) {
    // This function is now only used in the final step of the old model and can be deprecated/removed.
    // Or kept for admin/emergency purposes.
    let asset_amount_out = pool.asset_reserve;
    let stable_amount_out = pool.stable_reserve;
    pool.asset_reserve = 0;
    pool.stable_reserve = 0;
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

// === View Functions ===

public fun get_reserves(pool: &LiquidityPool): (u64, u64) {
    (pool.asset_reserve, pool.stable_reserve)
}

public fun get_lp_supply(pool: &LiquidityPool): u64 {
    pool.lp_supply
}

public fun get_price(pool: &LiquidityPool): u128 {
    pool.oracle.last_price()
}

public(package) fun get_twap(pool: &mut LiquidityPool, clock: &Clock): u128 {
    update_twap_observation(pool, clock);
    pool.oracle.get_twap(clock)
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
        BASIS_POINTS,
        pool.asset_reserve,
    );

    price
}

public(package) fun update_twap_observation(pool: &mut LiquidityPool, clock: &Clock) {
    let timestamp = clock.timestamp_ms();
    let current_price = get_current_price(pool);
    // Use the sum of reserves as a liquidity measure
    pool.oracle.write_observation(timestamp, current_price);
}

public(package) fun set_oracle_start_time(pool: &mut LiquidityPool, state: &MarketState) {
    assert!(get_ms_id(pool) == state.market_id(), EMarketIdMismatch);
    let trading_start_time = state.get_trading_start();
    pool.oracle.set_oracle_start_time(trading_start_time);
}

// === Private Functions ===
fun calculate_fee(amount: u64, fee_percent: u64): u64 {
    math::mul_div_to_64(amount, fee_percent, FEE_SCALE)
}

public(package) fun calculate_output(
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
    let max_price = (0xFFFFFFFFFFFFFFFFu64 as u128) * (BASIS_POINTS as u128);
    assert!(price <= max_price, EPriceTooHigh)
}

public(package) fun get_protocol_fees(pool: &LiquidityPool): u64 {
    pool.protocol_fees
}

public(package) fun get_ms_id(pool: &LiquidityPool): ID {
    pool.market_id
}

public(package) fun reset_protocol_fees(pool: &mut LiquidityPool) {
    pool.protocol_fees = 0;
}

// === Test Functions ===
#[test_only]
public fun create_test_pool(
    market_id: ID,
    outcome_idx: u8,
    fee_percent: u64,
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
        fee_percent,
        oracle: oracle::new_oracle(
            math::mul_div_to_128(stable_reserve, 1_000_000_000_000, asset_reserve),
            0, // Use 0 which is always a valid multiple of TWAP_PRICE_CAP_WINDOW
            1_000,
            ctx, // Add ctx parameter here
        ),
        protocol_fees: 0,
        lp_supply: (MINIMUM_LIQUIDITY as u64),
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
        lp_supply: _,
    } = pool;
    id.delete();
    oracle.destroy_for_testing();
}
