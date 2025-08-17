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
/// - Normal times: Reads from spot's ring_buffer_oracle
/// - During proposals: Reads from winning conditional's ring_buffer_oracle
/// - Seamless transition with no gaps in price feed
/// 
/// ============================================================================

module futarchy::spot_oracle_interface;

use sui::clock::Clock;
use futarchy::ring_buffer_oracle::{Self, RingBufferOracle};
use futarchy::spot_amm::SpotAMM;
use futarchy::conditional_amm::LiquidityPool;
use std::vector;

// ============================================================================
// Constants
// ============================================================================

const LENDING_WINDOW_SECONDS: u64 = 1800; // 30 minutes standard
const GOVERNANCE_MAX_WINDOW: u64 = 777600; // 9 days maximum

// Errors
const ENoOracles: u64 = 1;
const ESpotLocked: u64 = 2;

// ============================================================================
// Public Functions for Lending Protocols
// ============================================================================

/// Get TWAP for lending protocols (continuous, 30-minute window)
/// This ALWAYS returns a value, even during proposals
/// During proposals: reads from highest conditional (but doesn't store)
/// After finalization: reads from spot (which has merged winning data)
public fun get_lending_twap<AssetType, StableType>(
    spot_pool: &SpotAMM<AssetType, StableType>,
    conditional_pools: &vector<LiquidityPool>,
    clock: &Clock,
): u128 {
    // Check if spot is locked for proposal
    if (spot_pool.is_locked_for_proposal()) {
        // READ from highest priced conditional (no storage in spot)
        // This is temporary - winner can change until finalization
        get_highest_conditional_twap(conditional_pools, LENDING_WINDOW_SECONDS, clock)
    } else {
        // Get TWAP from spot's ring buffer (includes merged history)
        ring_buffer_oracle::get_lending_twap(spot_pool.get_ring_buffer_oracle(), clock)
    }
}

/// Get custom window TWAP (for protocols that need different windows)
public fun get_twap_custom_window<AssetType, StableType>(
    spot_pool: &SpotAMM<AssetType, StableType>,
    conditional_pools: &vector<LiquidityPool>,
    seconds: u64,
    clock: &Clock,
): u128 {
    if (spot_pool.is_locked_for_proposal()) {
        get_highest_conditional_twap(conditional_pools, seconds, clock)
    } else {
        ring_buffer_oracle::get_twap(spot_pool.get_ring_buffer_oracle(), seconds, clock)
    }
}

/// Get instantaneous price (1 second TWAP)
public fun get_spot_price<AssetType, StableType>(
    spot_pool: &SpotAMM<AssetType, StableType>,
    conditional_pools: &vector<LiquidityPool>,
    clock: &Clock,
): u128 {
    if (spot_pool.is_locked_for_proposal()) {
        get_highest_conditional_price(conditional_pools)
    } else {
        ring_buffer_oracle::get_latest_price(spot_pool.get_ring_buffer_oracle())
    }
}

// ============================================================================
// Public Functions for Governance/Minting
// ============================================================================

/// Get longest possible TWAP for governance decisions and token minting
/// Uses base fair value from spot AMM (includes historical stitching)
public fun get_governance_twap<AssetType, StableType>(
    spot_pool: &SpotAMM<AssetType, StableType>,
    conditional_pools: &vector<LiquidityPool>,
    clock: &Clock,
): u128 {
    // For governance, we want the base fair value TWAP
    // This includes historical segments from past proposals
    if (spot_pool.is_locked_for_proposal()) {
        // During proposal, add conditional contribution
        let winning_conditional = get_highest_conditional_twap(
            conditional_pools,
            GOVERNANCE_MAX_WINDOW,
            clock
        );
        // This would integrate with spot's base fair value calculation
        spot_pool.get_twap(option::some(winning_conditional), clock)
    } else {
        // Use spot's longest TWAP
        ring_buffer_oracle::get_longest_twap(spot_pool.get_ring_buffer_oracle(), clock)
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Get highest TWAP from conditional pools
fun get_highest_conditional_twap(
    pools: &vector<LiquidityPool>,
    seconds: u64,
    clock: &Clock,
): u128 {
    assert!(!pools.is_empty(), ENoOracles);
    
    let mut highest_twap = 0u128;
    let mut i = 0;
    
    while (i < pools.length()) {
        let pool = pools.borrow(i);
        let twap = ring_buffer_oracle::get_twap(pool.get_ring_buffer_oracle(), seconds, clock);
        if (twap > highest_twap) {
            highest_twap = twap;
        };
        i = i + 1;
    };
    
    highest_twap
}

/// Get highest current price from conditional pools
fun get_highest_conditional_price(pools: &vector<LiquidityPool>): u128 {
    assert!(!pools.is_empty(), ENoOracles);
    
    let mut highest_price = 0u128;
    let mut i = 0;
    
    while (i < pools.length()) {
        let pool = pools.borrow(i);
        let price = ring_buffer_oracle::get_latest_price(pool.get_ring_buffer_oracle());
        if (price > highest_price) {
            highest_price = price;
        };
        i = i + 1;
    };
    
    highest_price
}

/// Check if TWAP is available for a given window
public fun is_twap_available<AssetType, StableType>(
    spot_pool: &SpotAMM<AssetType, StableType>,
    conditional_pools: &vector<LiquidityPool>,
    seconds: u64,
    clock: &Clock,
): bool {
    if (spot_pool.is_locked_for_proposal()) {
        // Check conditionals
        if (conditional_pools.is_empty()) {
            return false
        };
        let pool = conditional_pools.borrow(0);
        ring_buffer_oracle::has_sufficient_history(pool.get_ring_buffer_oracle(), seconds, clock)
    } else {
        // Check spot
        ring_buffer_oracle::has_sufficient_history(spot_pool.get_ring_buffer_oracle(), seconds, clock)
    }
}

// ============================================================================
// Integration Examples for Lending Protocols
// ============================================================================

/// Example: How a lending protocol would use this
/// 
/// ```move
/// // In lending protocol
/// let price = spot_oracle_interface::get_lending_twap(
///     &spot_pool,
///     &conditional_pools,
///     clock
/// );
/// 
/// // Use price for collateral valuation, liquidations, etc.
/// ```
/// 
/// The lending protocol doesn't need to know about:
/// - Futarchy proposals
/// - Conditional AMMs
/// - Quantum liquidity
/// - Lock states
/// 
/// It just gets a continuous price feed that never stops.