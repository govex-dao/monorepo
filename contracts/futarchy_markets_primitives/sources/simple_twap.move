/// ============================================================================
/// WINDOWED TWAP WITH MULTI-STEP ARITHMETIC CAPPING
/// ============================================================================
///
/// PURPOSE: Provide manipulation-resistant TWAP for oracle grants
///
/// KEY FEATURES:
/// - Fixed-size windows (1 minute default)
/// - TWAP movement capped as % of current window's TWAP
/// - O(1) gas - just arithmetic, no loops or exponentiation
/// - Cap recalculates between batches (grows with TWAP)
///
/// MANIPULATION RESISTANCE:
/// - Attacker spikes price $100 → $200 for 10 minutes
/// - Cap calculated ONCE: 1% of $100 = $1 per window
/// - Take 10 steps of $1 each (ARITHMETIC within batch)
/// - Result: $100 + ($1 × 10) = $110
/// - Next batch: Cap recalculates as 1% of $110 = $1.10
///
/// GAS EFFICIENCY:
/// - O(1) constant time - just multiplication and min()
/// - No loops, no binary search, no exponentiation
/// - Example: 10 missed windows = same cost as 1 window
/// - 10x+ faster than geometric approach with binary search
///
/// SECURITY PROPERTY:
/// - Cap grows with TWAP (percentage-based)
/// - Allows legitimate price movements over time
/// - Still prevents instant manipulation
/// - Example: $100 → $200 instant = capped to $101
/// - Example: $100 → $200 over 100 windows = reaches $200
///
/// USED BY:
/// - Oracle grants: get_twap() → capped 1-minute windowed TWAP
/// - External consumers: Choose based on use case
///
/// ============================================================================

module futarchy_markets_primitives::simple_twap;

use sui::clock::Clock;
use sui::event;

// ============================================================================
// Constants
// ============================================================================

const ONE_MINUTE_MS: u64 = 60_000;
const PPM_DENOMINATOR: u64 = 1_000_000;         // Parts per million (1% = 10,000 PPM)
const DEFAULT_MAX_MOVEMENT_PPM: u64 = 10_000;   // 1% default cap

// ============================================================================
// Errors
// ============================================================================

const EOverflow: u64 = 0;
const EInvalidConfig: u64 = 1;
const ETimestampRegression: u64 = 2;
const ENotInitialized: u64 = 3;

// ============================================================================
// Structs
// ============================================================================

/// Simple TWAP with O(1) arithmetic percentage capping
public struct SimpleTWAP has store {
    /// Last finalized window's TWAP (returned by get_twap())
    last_window_twap: u128,

    /// Cumulative price * time for current (incomplete) window
    cumulative_price: u256,

    /// Start of current window (ms)
    window_start: u64,

    /// Last update timestamp (ms)
    last_update: u64,

    /// Window size (default: 1 minute)
    window_size_ms: u64,

    /// Maximum movement per window in PPM (default: 1% = 10,000 PPM)
    max_movement_ppm: u64,

    /// Whether at least one window has been finalized (TWAP is valid)
    initialized: bool,
}

// ============================================================================
// Events
// ============================================================================

public struct WindowFinalized has copy, drop {
    timestamp: u64,
    raw_twap: u128,
    capped_twap: u128,
    num_windows: u64,
}

// ============================================================================
// Creation
// ============================================================================

/// Create TWAP oracle with default 1-minute windows and 1% cap
public fun new_default(initial_price: u128, clock: &Clock): SimpleTWAP {
    new(initial_price, ONE_MINUTE_MS, DEFAULT_MAX_MOVEMENT_PPM, clock)
}

/// Create TWAP oracle with custom configuration
public fun new(
    initial_price: u128,
    window_size_ms: u64,
    max_movement_ppm: u64,
    clock: &Clock,
): SimpleTWAP {
    assert!(window_size_ms > 0, EInvalidConfig);
    assert!(max_movement_ppm > 0 && max_movement_ppm < PPM_DENOMINATOR, EInvalidConfig);

    let now = clock.timestamp_ms();

    SimpleTWAP {
        last_window_twap: initial_price,
        cumulative_price: 0,
        window_start: now,
        last_update: now,
        window_size_ms,
        max_movement_ppm,
        initialized: true,  // Initial price is valid TWAP (from AMM ratio or spot TWAP)
    }
}

// ============================================================================
// Core Update Logic - Multi-Step Arithmetic Capping
// ============================================================================

/// Update oracle with new price observation
///
/// KEY ALGORITHM:
/// 1. Accumulate price * time into current window
/// 2. If window(s) completed:
///    a. Calculate raw TWAP from accumulated data
///    b. Calculate FIXED cap (% of current TWAP)
///    c. Total movement = min(gap, cap × num_windows)
/// 3. Reset window
///
/// CRITICAL INSIGHT:
/// - Cap calculated ONCE per batch (fixed $ amount)
/// - Total movement = cap × num_windows (arithmetic)
/// - Cap recalculates BETWEEN batches (next update call)
/// - Prevents instant manipulation, allows gradual tracking
///
/// EXAMPLE:
/// - Price jumps $100 → $200, stays for 10 minutes (10 windows)
/// - Batch 1: Cap = 1% of $100 = $1, movement = $1 × 10 = $10 → $110
/// - Next update: Cap = 1% of $110 = $1.10, movement = $1.10 × 10 = $11 → $121
/// - Cap grows between batches, enabling gradual price tracking
///
public fun update(oracle: &mut SimpleTWAP, price: u128, clock: &Clock) {
    let now = clock.timestamp_ms();

    // Prevent timestamp regression
    assert!(now >= oracle.last_update, ETimestampRegression);

    let elapsed = now - oracle.last_update;

    if (elapsed == 0) return;

    // Accumulate price * time for current window
    oracle.cumulative_price = oracle.cumulative_price +
        (price as u256) * (elapsed as u256);

    oracle.last_update = now;

    // Check if any window(s) completed
    let time_since_window = now - oracle.window_start;
    let num_windows = time_since_window / oracle.window_size_ms;

    if (num_windows > 0) {
        finalize_window(oracle, now, num_windows);
    }
}

/// Finalize window - Take multiple capped steps with FIXED cap
///
/// ALGORITHM (matches oracle.move pattern):
/// - Calculate raw TWAP from accumulated price * time
/// - Calculate FIXED cap (% of current TWAP, stays constant for this batch)
/// - Take num_windows steps using the FIXED cap
/// - Cap gets recalculated next batch (grows between batches, not within)
///
/// KEY INSIGHT: Arithmetic steps within batch, geometric growth between batches
/// - Batch 1: Cap = 1% of $100 = $1, take 10 steps → $110
/// - Batch 2: Cap = 1% of $110 = $1.10, take 10 steps → $121
/// Result: Cap grows with TWAP, but steps are arithmetic within each batch
///
fun finalize_window(oracle: &mut SimpleTWAP, now: u64, num_windows: u64) {
    // Calculate raw TWAP from accumulated price * time
    let total_duration = now - oracle.window_start;
    let raw_twap = if (total_duration > 0) {
        let twap_u256 = oracle.cumulative_price / (total_duration as u256);
        assert!(twap_u256 <= (std::u128::max_value!() as u256), EOverflow);
        (twap_u256 as u128)
    } else {
        oracle.last_window_twap
    };

    // Calculate FIXED cap for this entire batch (% of current TWAP)
    let max_step_u256 = (oracle.last_window_twap as u256) *
        (oracle.max_movement_ppm as u256) / (PPM_DENOMINATOR as u256);
    assert!(max_step_u256 <= (std::u128::max_value!() as u256), EOverflow);
    let max_step = (max_step_u256 as u128);

    // Calculate total gap
    let (total_gap, going_up) = if (raw_twap > oracle.last_window_twap) {
        (raw_twap - oracle.last_window_twap, true)
    } else {
        (oracle.last_window_twap - raw_twap, false)
    };

    // Calculate total movement (capped by num_windows × max_step)
    // Protect against overflow: max_step × num_windows
    let max_total_movement = if (max_step > 0 && num_windows > 0) {
        let max_total_u256 = (max_step as u256) * (num_windows as u256);
        if (max_total_u256 > (std::u128::max_value!() as u256)) {
            std::u128::max_value!()
        } else {
            (max_total_u256 as u128)
        }
    } else {
        0
    };

    let actual_movement = if (total_gap > max_total_movement) {
        max_total_movement
    } else {
        total_gap
    };

    // Update TWAP with capped movement
    let capped_twap = if (going_up) {
        oracle.last_window_twap + actual_movement
    } else {
        oracle.last_window_twap - actual_movement
    };

    // Emit event
    event::emit(WindowFinalized {
        timestamp: now,
        raw_twap,
        capped_twap,
        num_windows,
    });

    // Update state (cap will be recalculated next batch based on new capped_twap)
    oracle.last_window_twap = capped_twap;
    oracle.window_start = now;
    oracle.cumulative_price = 0;
    // Note: initialized already set to true in constructor (saves 1 SSTORE ~100 gas)
}

// ============================================================================
// View Functions
// ============================================================================

/// Get current TWAP (last finalized window's capped TWAP)
///
/// NOTE: Oracle is initialized with valid TWAP from:
/// - Spot AMM: Initial pool ratio (e.g., reserve1/reserve0)
/// - Conditional AMM: Spot's TWAP at proposal creation time
///
/// This is O(1) - just returns a stored value
public fun get_twap(oracle: &SimpleTWAP): u128 {
    assert!(oracle.initialized, ENotInitialized);
    oracle.last_window_twap
}

/// Get last finalized window's TWAP (same as get_twap, for compatibility)
public fun last_finalized_twap(oracle: &SimpleTWAP): u128 {
    oracle.last_window_twap
}

/// Get window configuration
public fun window_size_ms(oracle: &SimpleTWAP): u64 {
    oracle.window_size_ms
}

/// Get max movement in PPM
public fun max_movement_ppm(oracle: &SimpleTWAP): u64 {
    oracle.max_movement_ppm
}

// ============================================================================
// Test Helpers
// ============================================================================

#[test_only]
public fun destroy_for_testing(oracle: SimpleTWAP) {
    let SimpleTWAP {
        last_window_twap: _,
        cumulative_price: _,
        window_start: _,
        last_update: _,
        window_size_ms: _,
        max_movement_ppm: _,
        initialized: _,
    } = oracle;
}

#[test_only]
public fun get_cumulative_price(oracle: &SimpleTWAP): u256 {
    oracle.cumulative_price
}

#[test_only]
public fun get_window_start(oracle: &SimpleTWAP): u64 {
    oracle.window_start
}

#[test_only]
public fun get_last_update(oracle: &SimpleTWAP): u64 {
    oracle.last_update
}
