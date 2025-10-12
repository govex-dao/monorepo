/// ============================================================================
/// SPOT ORACLE INTERFACE - UNIFIED ACCESS POINT FOR ALL PRICE QUERIES
/// ============================================================================
///
/// PURPOSE: Single interface that abstracts away futarchy complexity
///
/// USED BY:
/// - Lending protocols that need continuous prices
/// - Governance actions that need long-term TWAPs
/// - Any external protocol integrating with the DAO token
///
/// KEY FEATURES:
/// - Automatically switches between spot and conditional oracles
/// - Hides proposal state from external consumers
/// - Provides both short (lending) and long (governance) windows
/// - Never returns empty/null - always has a price
///
/// WHY IT EXISTS:
/// External protocols shouldn't need to understand futarchy mechanics.
/// This interface makes our complex oracle system look like a standard
/// Uniswap oracle to the outside world. Lending protocols can integrate
/// without knowing about proposals, conditional AMMs, or quantum liquidity.
///
/// HOW IT WORKS:
/// - Normal times: Reads from spot's 90-day TWAP oracle
/// - During proposals: Reads from winning conditional when spot has <50% liquidity
/// - Seamless transition with no gaps in price feed
///
/// ============================================================================

module futarchy_markets::spot_oracle_interface;

use sui::clock::Clock;
use futarchy_markets::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets::conditional_amm::{Self, LiquidityPool};
use futarchy_markets::simple_twap::{Self, SimpleTWAP};
use std::vector;
use std::option;

// ============================================================================
// Constants
// ============================================================================

const LENDING_WINDOW_SECONDS: u64 = 1800; // 30 minutes standard
const GOVERNANCE_MAX_WINDOW: u64 = 7_776_000; // 90 days maximum

// Oracle threshold for liquidity-weighted oracle switching
// 5000 bps = 50% - oracle reads from conditionals when spot has <50% liquidity
const ORACLE_CONDITIONAL_THRESHOLD_BPS: u64 = 5000;

// Errors
const ENoOracles: u64 = 1;
const ESpotLocked: u64 = 2;

// ============================================================================
// Public Functions for Lending Protocols
// ============================================================================

/// Get TWAP for lending protocols (continuous, 30-minute window)
/// This ALWAYS returns a value, even during proposals
/// Uses liquidity-weighted logic: reads from thicker market (spot vs conditionals)
/// After finalization: reads from spot (which has merged winning data)
public fun get_lending_twap<AssetType, StableType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    conditional_pools: &vector<LiquidityPool>,
    clock: &Clock,
): u128 {
    // Liquidity-weighted oracle: read from conditionals when spot has <50% liquidity
    // Only read from conditionals if: locked AND conditional_ratio >= 50%
    if (unified_spot_pool::is_locked_for_proposal(spot_pool) &&
        unified_spot_pool::get_conditional_liquidity_ratio_bps(spot_pool) >= ORACLE_CONDITIONAL_THRESHOLD_BPS) {
        // Conditionals have >=50% (spot has <=50%) - trust conditionals
        get_highest_conditional_twap(conditional_pools, LENDING_WINDOW_SECONDS, clock)
    } else {
        // Spot has >50% - trust spot even if locked!
        unified_spot_pool::get_twap_with_conditional(spot_pool, option::none(), clock)
    }
}

/// Get custom window TWAP (for protocols that need different windows)
public fun get_twap_custom_window<AssetType, StableType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    conditional_pools: &vector<LiquidityPool>,
    _seconds: u64,  // Note: Currently ignored, spot uses 90-day window
    clock: &Clock,
): u128 {
    // Liquidity-weighted oracle: read from conditionals when spot has <50% liquidity
    if (unified_spot_pool::is_locked_for_proposal(spot_pool) &&
        unified_spot_pool::get_conditional_liquidity_ratio_bps(spot_pool) >= ORACLE_CONDITIONAL_THRESHOLD_BPS) {
        get_highest_conditional_twap(conditional_pools, _seconds, clock)
    } else {
        // Use spot's SimpleTWAP (always 90-day window)
        unified_spot_pool::get_twap_with_conditional(spot_pool, option::none(), clock)
    }
}

/// Get instantaneous price
public fun get_spot_price<AssetType, StableType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    conditional_pools: &vector<LiquidityPool>,
    _clock: &Clock,
): u128 {
    // Liquidity-weighted oracle: read from conditionals when spot has <50% liquidity
    if (unified_spot_pool::is_locked_for_proposal(spot_pool) &&
        unified_spot_pool::get_conditional_liquidity_ratio_bps(spot_pool) >= ORACLE_CONDITIONAL_THRESHOLD_BPS) {
        get_highest_conditional_price(conditional_pools)
    } else {
        unified_spot_pool::get_spot_price(spot_pool)
    }
}

// ============================================================================
// Public Functions for Governance/Minting
// ============================================================================

/// Get longest possible TWAP for governance decisions and token minting
/// Uses SimpleTWAP from spot AMM (90-day window)
/// Uses sophisticated cumulative combination during proposals
public fun get_governance_twap<AssetType, StableType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    conditional_pools: &vector<LiquidityPool>,
    clock: &Clock,
): u128 {
    // For governance, we want the 90-day TWAP with proper time weighting
    if (unified_spot_pool::is_locked_for_proposal(spot_pool) &&
        unified_spot_pool::get_conditional_liquidity_ratio_bps(spot_pool) >= ORACLE_CONDITIONAL_THRESHOLD_BPS) {
        // Conditionals have >=50% (spot has <=50%) - use sophisticated cumulative combination
        let winning_conditional_oracle = get_highest_conditional_oracle(conditional_pools);

        // Sophisticated cumulative combination (not naive averaging)
        unified_spot_pool::get_twap_with_conditional(spot_pool, option::some(winning_conditional_oracle), clock)
    } else {
        // Spot has >50% - use spot's SimpleTWAP only
        unified_spot_pool::get_twap_with_conditional(spot_pool, option::none(), clock)
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Get SimpleTWAP oracle from highest priced conditional pool
/// Used for sophisticated cumulative combination with spot oracle
fun get_highest_conditional_oracle(pools: &vector<LiquidityPool>): &SimpleTWAP {
    assert!(!pools.is_empty(), ENoOracles);

    let mut highest_idx = 0;
    let mut highest_price = 0u128;
    let mut i = 0;

    // Find pool with highest price
    while (i < pools.length()) {
        let pool = pools.borrow(i);
        let pool_simple_twap = conditional_amm::get_simple_twap(pool);
        let price = simple_twap::get_spot_price(pool_simple_twap);
        if (price > highest_price) {
            highest_price = price;
            highest_idx = i;
        };
        i = i + 1;
    };

    // Return oracle from highest priced pool
    let winning_pool = pools.borrow(highest_idx);
    conditional_amm::get_simple_twap(winning_pool)
}

/// Get highest TWAP from conditional pools using SimpleTWAP
/// Note: SimpleTWAP uses 90-day window, `seconds` parameter is ignored
fun get_highest_conditional_twap(
    pools: &vector<LiquidityPool>,
    _seconds: u64,  // Note: SimpleTWAP uses fixed 90-day window
    clock: &Clock,
): u128 {
    assert!(!pools.is_empty(), ENoOracles);

    let mut highest_twap = 0u128;
    let mut i = 0;

    while (i < pools.length()) {
        let pool = pools.borrow(i);
        let pool_simple_twap = conditional_amm::get_simple_twap(pool);
        let twap = simple_twap::get_twap(pool_simple_twap, clock);
        if (twap > highest_twap) {
            highest_twap = twap;
        };
        i = i + 1;
    };

    highest_twap
}

/// Get highest current price from conditional pools using SimpleTWAP
fun get_highest_conditional_price(pools: &vector<LiquidityPool>): u128 {
    assert!(!pools.is_empty(), ENoOracles);

    let mut highest_price = 0u128;
    let mut i = 0;

    while (i < pools.length()) {
        let pool = pools.borrow(i);
        let pool_simple_twap = conditional_amm::get_simple_twap(pool);
        let price = simple_twap::get_spot_price(pool_simple_twap);
        if (price > highest_price) {
            highest_price = price;
        };
        i = i + 1;
    };

    highest_price
}

/// Check if TWAP is available for a given window
public fun is_twap_available<AssetType, StableType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    _conditional_pools: &vector<LiquidityPool>,
    _seconds: u64,  // Note: Currently ignored, spot TWAP readiness is based on 90-day window
    clock: &Clock,
): bool {
    // Check if spot's base fair value TWAP is ready (requires 90 days of history)
    unified_spot_pool::is_twap_ready(spot_pool, clock)
}