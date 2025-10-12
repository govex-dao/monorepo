/// ============================================================================
/// ARBITRAGE ENTRY POINTS - Phase 3 Implementation
/// ============================================================================
///
/// Provides aggregator-friendly interfaces and arbitrage bot entry points
/// for the deterministic arbitrage solver (arbitrage_math.move).
///
/// INTERFACES:
/// 1. get_quote() - Quote for aggregators (Aftermath, Cetus, etc.)
/// 2. simulate_arbitrage() - Profit simulation for arbitrage bots
///
/// NOTE ON SUI'S ATOMIC TRANSACTIONS:
/// - There is no MEV (front-running) on Sui due to atomic transaction execution
/// - "MEV bot" here refers to arbitrage bots that capture pricing inefficiencies
/// - All arbitrage is permissionless and happens within atomic transactions
///
/// NOTE: Actual execution requires TokenEscrow integration for:
/// - Minting/burning conditional tokens
/// - Complete set operations (split/recombine)
///
/// This module provides the MATH layer that other modules can call.
/// Full execution is handled by swap.move + coin_escrow.move.
///
/// ============================================================================

module futarchy_markets::arbitrage_entry;

use futarchy_markets::arbitrage_math;
use futarchy_markets::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets::conditional_amm::LiquidityPool;
use futarchy_one_shot_utils::math;

// === Structs ===

/// Quote result for aggregators
///
/// **IMPORTANT**: This quote shows the direct swap output and available arbitrage
/// opportunity, but does NOT claim the user receives the arbitrage profit.
/// The arbitrage profit is calculated on CURRENT pool state, but if user swaps first,
/// the pool state changes and the actual arbitrage profit will differ.
///
/// Use `direct_output` for accurate user output prediction.
/// Use `expected_arb_profit` to understand available arbitrage (for arbitrage bots, not users).
public struct SwapQuote has drop, copy {
    amount_in: u64,
    direct_output: u64,          // Output user receives from direct swap
    optimal_arb_amount: u64,     // Optimal amount to arbitrage (on current state)
    expected_arb_profit: u128,   // Arbitrage profit available (on current state, not added to user output!)
    is_arb_available: bool,      // Whether arbitrage opportunity exists
}

// === Aggregator Interface ===

/// Get swap quote with arbitrage opportunity analysis
/// Aggregators can use this to compare futarchy vs other DEXes
///
/// Returns SwapQuote with:
/// - Direct swap output (what user actually receives)
/// - Available arbitrage profit (for arbitrage bots, NOT added to user output)
///
/// **CRITICAL**: The arbitrage profit is calculated on CURRENT pool state.
/// If user swaps first, pool state changes, and actual arbitrage differs.
/// DO NOT add direct_output + expected_arb_profit - they are not independent!
///
/// **Usage:**
/// ```move
/// let quote = get_quote_asset_to_stable(spot, conditionals, 1000000);
/// // User receives: quote.direct_output (arbitrage profit goes to arbitrageur)
/// if (quote.is_arb_available) {
///     // Arbitrage bot can capture quote.expected_arb_profit (approximately)
/// }
/// ```
public fun get_quote_asset_to_stable<AssetType, StableType>(
    spot: &UnifiedSpotPool<AssetType, StableType>,
    conditionals: &vector<LiquidityPool>,
    amount_in: u64,
): SwapQuote {
    // 1. Calculate direct swap output (what user actually receives)
    let direct_output = unified_spot_pool::simulate_swap_asset_to_stable(spot, amount_in);

    // 2. Calculate optimal arbitrage using NEW EFFICIENT BIDIRECTIONAL SOLVER
    // ✅ Uses b-parameterization (no sqrt)
    // ✅ Active-set pruning (40-60% gas reduction)
    // ✅ Early exit checks
    // ✅ Checks both directions automatically
    let (optimal_arb_amount, expected_arb_profit, _is_spot_to_cond) =
        arbitrage_math::compute_optimal_arbitrage_bidirectional(
            spot,
            conditionals,
            0,  // No min profit for quote (show all opportunities)
        );

    // 3. Check if arbitrage opportunity exists (for arbitrage bots, not user profit!)
    let is_arb_available = optimal_arb_amount > 0 && expected_arb_profit > 0;

    SwapQuote {
        amount_in,
        direct_output,        // User receives this
        optimal_arb_amount,   // Arbitrage amount (on current state)
        expected_arb_profit,  // Arbitrage profit (for arbitrage bot, NOT user!)
        is_arb_available,     // Whether arbitrage exists
    }
}

/// Get swap quote for stable → asset direction
public fun get_quote_stable_to_asset<AssetType, StableType>(
    spot: &UnifiedSpotPool<AssetType, StableType>,
    conditionals: &vector<LiquidityPool>,
    amount_in: u64,
): SwapQuote {
    let direct_output = unified_spot_pool::simulate_swap_stable_to_asset(spot, amount_in);

    // Use NEW EFFICIENT BIDIRECTIONAL SOLVER (same as above)
    let (optimal_arb_amount, expected_arb_profit, _is_spot_to_cond) =
        arbitrage_math::compute_optimal_arbitrage_bidirectional(
            spot,
            conditionals,
            0,  // No min profit for quote
        );

    let is_arb_available = optimal_arb_amount > 0 && expected_arb_profit > 0;

    SwapQuote {
        amount_in,
        direct_output,        // User receives this
        optimal_arb_amount,   // Arbitrage amount (on current state)
        expected_arb_profit,  // Arbitrage profit (for arbitrage bot, NOT user!)
        is_arb_available,     // Whether arbitrage exists
    }
}

// === Arbitrage Bot Interface ===

/// Simulate pure arbitrage with minimum profit threshold
/// Arbitrage bots can call this to check if arbitrage is profitable
///
/// Returns:
/// - optimal_amount: Optimal amount to arbitrage
/// - expected_profit: Expected profit (after min_profit check)
/// - is_spot_to_cond: Direction (true = Spot→Cond, false = Cond→Spot)
///
/// **NEW FEATURES:**
/// ✅ Bidirectional search (finds best direction automatically)
/// ✅ Min profit threshold (don't execute if profit < threshold)
/// ✅ 40-60% more efficient (pruning + early exits + no sqrt)
///
/// **Usage:**
/// ```move
/// let (amount, profit, direction) = simulate_pure_arbitrage_with_min_profit(
///     spot, conditionals, 10000  // min 10k profit
/// );
/// if (profit > 0) {
///     // Execute arbitrage PTB in the profitable direction
///     execute_arbitrage(...);
/// }
/// ```
public fun simulate_pure_arbitrage_with_min_profit<AssetType, StableType>(
    spot: &UnifiedSpotPool<AssetType, StableType>,
    conditionals: &vector<LiquidityPool>,
    min_profit: u64,
): (u64, u128, bool) {
    arbitrage_math::compute_optimal_arbitrage_bidirectional(
        spot,
        conditionals,
        min_profit,
    )
}

/// Legacy interface: Simulate arbitrage in specific direction (asset→stable)
/// NOTE: New code should use simulate_pure_arbitrage_with_min_profit for bidirectional search
public fun simulate_pure_arbitrage_asset_to_stable<AssetType, StableType>(
    spot: &UnifiedSpotPool<AssetType, StableType>,
    conditionals: &vector<LiquidityPool>,
): (u64, u128) {
    let (amount, profit, is_spot_to_cond) = arbitrage_math::compute_optimal_arbitrage_bidirectional(
        spot,
        conditionals,
        0,  // No min profit
    );

    // Return only if direction matches (asset_to_stable = spot_to_cond)
    if (is_spot_to_cond) {
        (amount, profit)
    } else {
        (0, 0)
    }
}

/// Legacy interface: Simulate arbitrage in specific direction (stable→asset)
/// NOTE: New code should use simulate_pure_arbitrage_with_min_profit for bidirectional search
public fun simulate_pure_arbitrage_stable_to_asset<AssetType, StableType>(
    spot: &UnifiedSpotPool<AssetType, StableType>,
    conditionals: &vector<LiquidityPool>,
): (u64, u128) {
    let (amount, profit, is_spot_to_cond) = arbitrage_math::compute_optimal_arbitrage_bidirectional(
        spot,
        conditionals,
        0,  // No min profit
    );

    // Return only if direction matches (stable_to_asset = cond_to_spot)
    if (!is_spot_to_cond) {
        (amount, profit)
    } else {
        (0, 0)
    }
}

// === Quote Getters ===

public fun quote_amount_in(quote: &SwapQuote): u64 {
    quote.amount_in
}

public fun quote_direct_output(quote: &SwapQuote): u64 {
    quote.direct_output
}

public fun quote_optimal_arb_amount(quote: &SwapQuote): u64 {
    quote.optimal_arb_amount
}

public fun quote_expected_arb_profit(quote: &SwapQuote): u128 {
    quote.expected_arb_profit
}

public fun quote_is_arb_available(quote: &SwapQuote): bool {
    quote.is_arb_available
}

/// Get arbitrage profit in basis points relative to direct output
/// Returns 0 if no arbitrage available
/// NOTE: This is the arbitrage bot's potential profit, NOT added to user output!
///
/// BUG FIX: Use mul_div to prevent u128 overflow on (expected_arb_profit * 10000)
public fun quote_arb_profit_bps(quote: &SwapQuote): u64 {
    if (quote.is_arb_available && quote.direct_output > 0) {
        // BPS = (arb_profit / direct_output) * 10000
        // Use mul_div_mixed (accepts u128, u64, u128) to prevent overflow
        let bps = math::mul_div_mixed(
            quote.expected_arb_profit,
            10000,
            quote.direct_output as u128
        );
        (bps as u64)
    } else {
        0
    }
}

// === Future: Execution Functions ===
//
// NOTE: Actual execution requires TokenEscrow integration.
// These will be implemented in Phase 4 after testing.
//
// Future functions:
// - execute_swap_with_arbitrage<AssetType, StableType>()
// - execute_pure_arbitrage<AssetType, StableType>()
//
// Required components:
// - coin_escrow::split_to_conditionals()
// - coin_escrow::recombine_from_conditionals()
// - swap_core::swap_asset_to_stable() for conditional markets
//
