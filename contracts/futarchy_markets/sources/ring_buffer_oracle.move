/// ============================================================================
/// RING BUFFER ORACLE - CONTINUOUS PRICE FEED FOR LENDING PROTOCOLS
/// ============================================================================
/// 
/// PURPOSE: Provides uninterrupted price feeds for external integrations
/// 
/// USED BY:
/// - Lending protocols (Compound, Aave style)
/// - Liquidation bots
/// - Price aggregators
/// - Minting actions (longest TWAP for security)
/// - Any protocol needing standard TWAP access
/// 
/// KEY FEATURES:
/// - Ring buffer with up to 65535 observations (~9 days)
/// - Updates on every swap/liquidity event
/// - Standard read-only TWAP queries (no write requirement)
/// - Flexible time windows (1 second to 9 days)
/// - Observation merging for proposal finalization
/// 
/// BEHAVIOR:
/// - SpotAMM: Continuously updated during normal trading
/// - ConditionalAMMs: Updated during proposals for each outcome
/// - During proposals: Spot reads from highest conditional (no storage)
/// - After finalization: Winning conditional's data merges into spot
/// 
/// WHY IT EXISTS:
/// Lending protocols expect continuous, queryable price feeds that work like
/// Uniswap V2/V3 oracles. This module provides that standard interface while
/// the futarchy oracle handles the specialized prediction market mechanics.
/// The ring buffer ensures lending protocols always have fresh prices, even
/// during proposals when liquidity moves to conditional markets.
/// 
/// INTEGRATION:
/// - Each SpotAMM has one for normal trading
/// - Each ConditionalAMM has one for proposal periods
/// - spot_oracle_interface combines them seamlessly
/// - merge_observations() consolidates winning data after finalization
/// 
/// ============================================================================

module futarchy_markets::ring_buffer_oracle;

use std::vector;
use sui::clock::Clock;
use futarchy_one_shot_utils::math;

// ============================================================================
// Constants
// ============================================================================

const MAX_OBSERVATIONS: u64 = 65535; // ~9 days at 12 second blocks
const PRICE_SCALE: u128 = 1_000_000_000_000; // 10^12 for precision
const MIN_UPDATE_INTERVAL_MS: u64 = 1000; // 1 second minimum between updates

// Errors
const ENotInitialized: u64 = 1;
const EInvalidWindow: u64 = 2;
const EInsufficientHistory: u64 = 3;
const EUpdateTooSoon: u64 = 4;

// ============================================================================
// Structs
// ============================================================================

/// Single price observation
public struct Observation has store, copy, drop {
    timestamp_ms: u64,
    cumulative_price: u256,  // Price × time accumulator
    price: u128,              // Spot price at observation
}

/// Ring buffer oracle used by AMMs
public struct RingBufferOracle has store {
    observations: vector<Observation>,
    current_index: u64,
    num_observations: u64,
    capacity: u64,
    last_update_ms: u64,
}

// ============================================================================
// Core Functions
// ============================================================================

/// Create new ring buffer oracle
public fun new(initial_capacity: u64): RingBufferOracle {
    let mut observations = vector::empty();
    let mut i = 0;
    while (i < initial_capacity) {
        observations.push_back(Observation {
            timestamp_ms: 0,
            cumulative_price: 0,
            price: 0,
        });
        i = i + 1;
    };
    
    RingBufferOracle {
        observations,
        current_index: 0,
        num_observations: 0,
        capacity: initial_capacity,
        last_update_ms: 0,
    }
}

/// Write new price observation
public fun write(
    oracle: &mut RingBufferOracle,
    price: u128,
    clock: &Clock,
) {
    let now = clock.timestamp_ms();
    
    // Prevent spam - skip update if too soon rather than aborting
    if (oracle.last_update_ms > 0 && now < oracle.last_update_ms + MIN_UPDATE_INTERVAL_MS) {
        return; // silently skip; keep the last observation
    };
    
    // Calculate cumulative
    let new_cumulative = if (oracle.num_observations > 0) {
        let last = oracle.observations.borrow(oracle.current_index);
        let time_delta = now - last.timestamp_ms;
        last.cumulative_price + ((last.price as u256) * (time_delta as u256))
    } else {
        0
    };
    
    // Move to next slot
    let next_index = if (oracle.num_observations == 0) {
        0
    } else {
        (oracle.current_index + 1) % oracle.capacity
    };
    
    // Write observation
    *oracle.observations.borrow_mut(next_index) = Observation {
        timestamp_ms: now,
        cumulative_price: new_cumulative,
        price,
    };
    
    oracle.current_index = next_index;
    if (oracle.num_observations < oracle.capacity) {
        oracle.num_observations = oracle.num_observations + 1;
    };
    oracle.last_update_ms = now;
}

/// Get TWAP for any time window
public fun get_twap(
    oracle: &RingBufferOracle,
    seconds_ago: u64,
    clock: &Clock,
): u128 {
    assert!(oracle.num_observations > 0, ENotInitialized);
    
    let now = clock.timestamp_ms();
    let target_ms = now - (seconds_ago * 1000);
    
    // Find observations for TWAP calculation
    let (old_obs, new_obs) = find_observations_for_twap(oracle, target_ms, now);
    
    // Calculate TWAP
    let time_diff = new_obs.timestamp_ms - old_obs.timestamp_ms;
    if (time_diff == 0) {
        return new_obs.price
    };
    
    let cumulative_diff = new_obs.cumulative_price - old_obs.cumulative_price;
    ((cumulative_diff / (time_diff as u256)) as u128)
}

/// Get TWAP for lending (30 minutes standard)
public fun get_lending_twap(
    oracle: &RingBufferOracle,
    clock: &Clock,
): u128 {
    get_twap(oracle, 1800, clock) // 30 minutes
}

/// Get longest possible TWAP (for governance)
public fun get_longest_twap(
    oracle: &RingBufferOracle,
    clock: &Clock,
): u128 {
    if (oracle.num_observations == 0) {
        return PRICE_SCALE
    };
    
    // Find oldest observation
    let oldest_idx = if (oracle.num_observations < oracle.capacity) {
        0
    } else {
        (oracle.current_index + 1) % oracle.capacity
    };
    
    let oldest = oracle.observations.borrow(oldest_idx);
    let now = clock.timestamp_ms();
    let age_seconds = (now - oldest.timestamp_ms) / 1000;
    
    if (age_seconds > 0) {
        get_twap(oracle, age_seconds, clock)
    } else {
        oracle.observations.borrow(oracle.current_index).price
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Find observations for TWAP calculation
fun find_observations_for_twap(
    oracle: &RingBufferOracle,
    target_ms: u64,
    now_ms: u64,
): (Observation, Observation) {
    // Get newest observation
    let newest = *oracle.observations.borrow(oracle.current_index);
    
    // Handle single observation
    if (oracle.num_observations == 1) {
        return (newest, newest)
    };
    
    // Find oldest index
    let oldest_idx = if (oracle.num_observations < oracle.capacity) {
        0
    } else {
        (oracle.current_index + 1) % oracle.capacity
    };
    
    // Linear search for target (simple for Move)
    let mut before = *oracle.observations.borrow(oldest_idx);
    let mut i = 0;
    
    while (i < oracle.num_observations) {
        let idx = (oldest_idx + i) % oracle.capacity;
        let obs = *oracle.observations.borrow(idx);
        
        if (obs.timestamp_ms <= target_ms) {
            before = obs;
        } else {
            break
        };
        
        i = i + 1;
    };
    
    // Interpolate if needed
    if (before.timestamp_ms < target_ms && i < oracle.num_observations) {
        let after_idx = (oldest_idx + i) % oracle.capacity;
        let after = *oracle.observations.borrow(after_idx);
        
        // Interpolate to exact target time
        let time_before = target_ms - before.timestamp_ms;
        let interpolated_cumulative = before.cumulative_price + 
            ((before.price as u256) * (time_before as u256));
        
        before = Observation {
            timestamp_ms: target_ms,
            cumulative_price: interpolated_cumulative,
            price: before.price,
        };
    };
    
    // Add time since last observation for "now"
    let mut newest_adjusted = newest;
    if (newest.timestamp_ms < now_ms) {
        let time_since = now_ms - newest.timestamp_ms;
        newest_adjusted.cumulative_price = newest.cumulative_price + 
            ((newest.price as u256) * (time_since as u256));
        newest_adjusted.timestamp_ms = now_ms;
    };
    
    (before, newest_adjusted)
}

/// Check if sufficient history exists
public fun has_sufficient_history(
    oracle: &RingBufferOracle,
    seconds_required: u64,
    clock: &Clock,
): bool {
    if (oracle.num_observations == 0) {
        return false
    };
    
    let oldest_idx = if (oracle.num_observations < oracle.capacity) {
        0
    } else {
        (oracle.current_index + 1) % oracle.capacity
    };
    
    let oldest = oracle.observations.borrow(oldest_idx);
    let now = clock.timestamp_ms();
    
    (now - oldest.timestamp_ms) >= (seconds_required * 1000)
}

/// Get latest price
public fun get_latest_price(oracle: &RingBufferOracle): u128 {
    if (oracle.num_observations > 0) {
        oracle.observations.borrow(oracle.current_index).price
    } else {
        0
    }
}

/// Merge observations from source oracle into target oracle
/// Used when proposal finalizes to merge winning conditional's history into spot
public fun merge_observations(
    target: &mut RingBufferOracle,
    source: &RingBufferOracle,
    start_ms: u64,  // Start of period to merge
    end_ms: u64,    // End of period to merge
) {
    if (source.num_observations == 0) {
        return
    };
    
    // Find starting index in source
    let oldest_idx = if (source.num_observations < source.capacity) {
        0
    } else {
        (source.current_index + 1) % source.capacity
    };
    
    // Copy observations within time range
    let mut i = 0;
    while (i < source.num_observations) {
        let idx = (oldest_idx + i) % source.capacity;
        let obs = source.observations.borrow(idx);
        
        // Only merge observations within the proposal period
        if (obs.timestamp_ms >= start_ms && obs.timestamp_ms <= end_ms) {
            // Write to target (this handles cumulative calculation)
            write_with_timestamp(target, obs.price, obs.timestamp_ms);
        };
        
        i = i + 1;
    };
}

/// Internal write with specific timestamp (for merging)
fun write_with_timestamp(
    oracle: &mut RingBufferOracle,
    price: u128,
    timestamp_ms: u64,
) {
    // Calculate cumulative
    let new_cumulative = if (oracle.num_observations > 0) {
        let last = oracle.observations.borrow(oracle.current_index);
        if (timestamp_ms > last.timestamp_ms) {
            let time_delta = timestamp_ms - last.timestamp_ms;
            last.cumulative_price + ((last.price as u256) * (time_delta as u256))
        } else {
            // Skip if timestamp is not newer
            return
        }
    } else {
        0
    };
    
    // Move to next slot
    let next_index = if (oracle.num_observations == 0) {
        0
    } else {
        (oracle.current_index + 1) % oracle.capacity
    };
    
    // Write observation
    *oracle.observations.borrow_mut(next_index) = Observation {
        timestamp_ms,
        cumulative_price: new_cumulative,
        price,
    };
    
    oracle.current_index = next_index;
    if (oracle.num_observations < oracle.capacity) {
        oracle.num_observations = oracle.num_observations + 1;
    };
    oracle.last_update_ms = timestamp_ms;
}

// ============================================================================
// Test Functions
// ============================================================================

#[test_only]
/// Destroy oracle for testing
public fun destroy_for_testing(oracle: RingBufferOracle) {
    let RingBufferOracle {
        observations: _,
        current_index: _,
        num_observations: _,
        capacity: _,
        last_update_ms: _,
    } = oracle;
}