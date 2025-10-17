// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// ============================================================================
/// PRICE-BASED UNLOCKS ORACLE - UNIFIED ACCESS POINT FOR ALL PRICE QUERIES
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

module futarchy_markets_operations::price_based_unlocks_oracle;

use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use futarchy_markets_primitives::PCW_TWAP_oracle::{Self, SimpleTWAP};
use std::option;
use std::vector;
use sui::clock::Clock;

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

/// Get TWAP for lending protocols (continuous, 30-minute arithmetic window)
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
    if (
        unified_spot_pool::is_locked_for_proposal(spot_pool) &&
        unified_spot_pool::get_conditional_liquidity_ratio_percent(spot_pool) >= ORACLE_CONDITIONAL_THRESHOLD_BPS
    ) {
        // Conditionals have >=50% (spot has <=50%) - trust conditionals
        get_highest_conditional_lending_twap(conditional_pools, clock)
    } else {
        // Spot has >50% - trust spot even if locked!
        unified_spot_pool::get_lending_twap(spot_pool, clock)
    }
}

/// Get current TWAP (reads from conditionals during proposals, spot otherwise)
/// NOTE: Returns TWAP from conditional pools during proposals, not instant price from reserves
/// This is acceptable because TWAP updates every block and provides manipulation resistance
public fun get_current_twap<AssetType, StableType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    conditional_pools: &vector<LiquidityPool>,
    _clock: &Clock,
): u128 {
    // Liquidity-weighted oracle: read from conditionals when spot has <50% liquidity
    if (
        unified_spot_pool::is_locked_for_proposal(spot_pool) &&
        unified_spot_pool::get_conditional_liquidity_ratio_percent(spot_pool) >= ORACLE_CONDITIONAL_THRESHOLD_BPS
    ) {
        get_highest_conditional_twap(conditional_pools)
    } else {
        unified_spot_pool::get_spot_price(spot_pool)
    }
}

// ============================================================================
// Public Functions for Governance/Minting
// ============================================================================

/// Get 90-day TWAP for oracle grants (long-horizon governance window)
/// Uses SimpleTWAP checkpoint ring to evaluate 90-day averages
public fun get_geometric_governance_twap<AssetType, StableType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    conditional_pools: &vector<LiquidityPool>,
    clock: &Clock,
): u128 {
    // For governance, we want the 90-day checkpoint-based TWAP (manipulation-resistant)
    if (
        unified_spot_pool::is_locked_for_proposal(spot_pool) &&
        unified_spot_pool::get_conditional_liquidity_ratio_percent(spot_pool) >= ORACLE_CONDITIONAL_THRESHOLD_BPS
    ) {
        // Conditionals have >=50% (spot has <=50%) - read from conditionals
        get_highest_conditional_governance_twap(conditional_pools, clock)
    } else {
        // Spot has >50% - use spot's governance TWAP
        unified_spot_pool::get_geometric_twap(spot_pool, clock)
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Get highest lending TWAP (30-minute arithmetic) from conditional pools
/// Used when spot has <50% liquidity during proposals
fun get_highest_conditional_lending_twap(pools: &vector<LiquidityPool>, _clock: &Clock): u128 {
    assert!(!pools.is_empty(), ENoOracles);

    let mut highest_twap = 0u128;
    let mut i = 0;

    while (i < pools.length()) {
        let pool = pools.borrow(i);
        let pool_simple_twap = conditional_amm::get_simple_twap(pool);
        let twap = PCW_TWAP_oracle::get_twap(pool_simple_twap);
        if (twap > highest_twap) {
            highest_twap = twap;
        };
        i = i + 1;
    };

    highest_twap
}

/// Get highest 90-day TWAP from conditional pools
/// Used when spot has <50% liquidity during proposals
fun get_highest_conditional_governance_twap(pools: &vector<LiquidityPool>, clock: &Clock): u128 {
    assert!(!pools.is_empty(), ENoOracles);

    let mut highest_twap = 0u128;
    let mut i = 0;

    while (i < pools.length()) {
        let pool = pools.borrow(i);
        let pool_simple_twap = conditional_amm::get_simple_twap(pool);
        let twap = resolve_long_window(pool_simple_twap, clock);
        if (twap > highest_twap) {
            highest_twap = twap;
        };
        i = i + 1;
    };

    highest_twap
}

fun resolve_long_window(oracle: &SimpleTWAP, clock: &Clock): u128 {
    let base = PCW_TWAP_oracle::get_twap(oracle);
    let opt = PCW_TWAP_oracle::get_ninety_day_twap(oracle, clock);
    if (option::is_some(&opt)) {
        option::destroy_some(opt)
    } else {
        option::destroy_none(opt);
        base
    }
}

/// Get highest TWAP from conditional pools using SimpleTWAP
/// Returns time-weighted average, not instant price from reserves
/// This provides manipulation resistance at the cost of price lag
fun get_highest_conditional_twap(pools: &vector<LiquidityPool>): u128 {
    assert!(!pools.is_empty(), ENoOracles);

    let mut highest_twap = 0u128;
    let mut i = 0;

    while (i < pools.length()) {
        let pool = pools.borrow(i);
        let pool_simple_twap = conditional_amm::get_simple_twap(pool);
        // SimpleTWAP only exposes TWAP, not instant prices
        let twap = PCW_TWAP_oracle::get_twap(pool_simple_twap);
        if (twap > highest_twap) {
            highest_twap = twap;
        };
        i = i + 1;
    };

    highest_twap
}

/// Check if TWAP is available for a given window
public fun is_twap_available<AssetType, StableType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    _conditional_pools: &vector<LiquidityPool>,
    _seconds: u64, // Note: Currently ignored, spot TWAP readiness is based on 90-day window
    clock: &Clock,
): bool {
    // Check if spot's base fair value TWAP is ready (requires 90 days of history)
    unified_spot_pool::is_twap_ready(spot_pool, clock)
}
