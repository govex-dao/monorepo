/// ============================================================================
/// PASS THROUGH PERCENT-CAPPED WINDOWED TWAP ORACLE
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

module futarchy_markets_primitives::PCW_TWAP_oracle;

use std::option;
use std::vector;
use sui::clock::Clock;
use sui::event;

// ============================================================================
// Constants
// ============================================================================

const ONE_MINUTE_MS: u64 = 60_000;
const PPM_DENOMINATOR: u64 = 1_000_000; // Parts per million (1% = 10,000 PPM)
const DEFAULT_MAX_MOVEMENT_PPM: u64 = 10_000; // 1% default cap
const NINETY_DAYS_MS: u64 = 7_776_000_000; // 90 days
const CHECKPOINT_INTERVAL_MS: u64 = 604_800_000; // 7 days
const MAX_CHECKPOINTS: u64 = 20;

// ============================================================================
// Errors
// ============================================================================

const EOverflow: u64 = 0;
const EInvalidConfig: u64 = 1;
const ETimestampRegression: u64 = 2;
const ENotInitialized: u64 = 3;
const EInvalidProjection: u64 = 4;
const EInvalidBackfill: u64 = 5;

// ============================================================================
// Structs
// ============================================================================

/// Long-horizon checkpoint stored roughly once per week
public struct Checkpoint has copy, drop, store {
    timestamp: u64,
    cumulative: u256,
}

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
    /// Total cumulative price × time since initialization (for backfill & blending)
    cumulative_total: u256,
    /// Last observed spot price (used for projection and backfill)
    last_price: u128,
    /// Oracle initialization timestamp
    initialized_at: u64,
    /// Rolling checkpoints used to approximate long windows
    checkpoints: vector<Checkpoint>,
    /// Timestamp of the most recent checkpoint
    last_checkpoint_at: u64,
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

    let mut oracle = SimpleTWAP {
        last_window_twap: initial_price,
        cumulative_price: 0,
        window_start: now,
        last_update: now,
        window_size_ms,
        max_movement_ppm,
        initialized: true, // Initial price is valid TWAP (from AMM ratio or spot TWAP)
        cumulative_total: 0,
        last_price: initial_price,
        initialized_at: now,
        checkpoints: vector::empty(),
        last_checkpoint_at: now,
    };

    record_checkpoint(&mut oracle, now);

    oracle
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

    if (elapsed == 0) {
        oracle.last_price = price;
        return;
    };

    let price_time = (oracle.last_price as u256) * (elapsed as u256);

    // Accumulate price * time for current window
    oracle.cumulative_price = oracle.cumulative_price + price_time;

    // Track total cumulative for longer windows/backfill logic
    oracle.cumulative_total = oracle.cumulative_total + price_time;

    oracle.last_update = now;
    oracle.last_price = price;

    // Check if any window(s) completed
    let time_since_window = now - oracle.window_start;
    let num_windows = time_since_window / oracle.window_size_ms;

    if (num_windows > 0) {
        finalize_window(oracle, now, num_windows);
    };
    maybe_commit_checkpoint(oracle, now);
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
    let max_step_u256 =
        (oracle.last_window_twap as u256) *
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
    oracle.window_start = oracle.window_start + (num_windows * oracle.window_size_ms);
    let remainder_duration = now - oracle.window_start;
    oracle.cumulative_price = (oracle.last_price as u256) * (remainder_duration as u256);
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

/// Check if oracle has at least one full window of observations
public fun is_ready(oracle: &SimpleTWAP, clock: &Clock): bool {
    if (!oracle.initialized) {
        return false
    };
    let now = clock.timestamp_ms();
    if (now <= oracle.initialized_at) {
        return false
    };
    let elapsed = now - oracle.initialized_at;
    elapsed >= oracle.window_size_ms
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

/// Get last observed price
public fun last_price(oracle: &SimpleTWAP): u128 {
    oracle.last_price
}

/// Get last update timestamp
public fun last_update(oracle: &SimpleTWAP): u64 {
    oracle.last_update
}

/// Get oracle initialization timestamp
public fun initialized_at(oracle: &SimpleTWAP): u64 {
    oracle.initialized_at
}

/// Total cumulative price × time since initialization
public fun cumulative_total(oracle: &SimpleTWAP): u256 {
    oracle.cumulative_total
}

/// Project cumulative price × time forward to target_timestamp (must be >= last_update)
public fun projected_cumulative_arithmetic_to(oracle: &SimpleTWAP, target_timestamp: u64): u256 {
    assert!(target_timestamp >= oracle.last_update, EInvalidProjection);
    let elapsed = target_timestamp - oracle.last_update;
    oracle.cumulative_total + ((oracle.last_price as u256) * (elapsed as u256))
}

/// Backfill oracle with conditional-period cumulative after proposal ends
public fun backfill_from_conditional(
    oracle: &mut SimpleTWAP,
    proposal_start: u64,
    proposal_end: u64,
    period_cumulative: u256,
    period_final_price: u128,
) {
    assert!(proposal_end > proposal_start, EInvalidBackfill);
    assert!(proposal_start == oracle.last_update, EInvalidBackfill);
    assert!(period_final_price > 0, EInvalidBackfill);

    oracle.cumulative_total = oracle.cumulative_total + period_cumulative;

    // Calculate number of windows spanned by backfill period
    let backfill_duration = proposal_end - proposal_start;
    let num_windows = backfill_duration / oracle.window_size_ms;

    // Apply capping logic to prevent security bypass
    if (num_windows > 0) {
        // Calculate FIXED cap for this backfill (% of current TWAP)
        let max_step_u256 =
            (oracle.last_window_twap as u256) *
            (oracle.max_movement_ppm as u256) / (PPM_DENOMINATOR as u256);
        assert!(max_step_u256 <= (std::u128::max_value!() as u256), EOverflow);
        let max_step = (max_step_u256 as u128);

        // Calculate total gap
        let (total_gap, going_up) = if (period_final_price > oracle.last_window_twap) {
            (period_final_price - oracle.last_window_twap, true)
        } else {
            (oracle.last_window_twap - period_final_price, false)
        };

        // Calculate total movement (capped by num_windows × max_step)
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

        // Apply capped movement
        oracle.last_window_twap = if (going_up) {
            oracle.last_window_twap + actual_movement
        } else {
            oracle.last_window_twap - actual_movement
        };
    };
    // else: backfill duration < window_size, keep current TWAP

    // Reset window starting at proposal end
    oracle.window_start = proposal_end;
    oracle.cumulative_price = 0;
    oracle.last_update = proposal_end;
    oracle.last_price = period_final_price;

    maybe_commit_checkpoint(oracle, proposal_end);
}

/// Attempt to commit a long-window checkpoint if interval elapsed
public fun try_commit_checkpoint(oracle: &mut SimpleTWAP, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    if (now >= oracle.last_checkpoint_at + CHECKPOINT_INTERVAL_MS) {
        record_checkpoint(oracle, now);
        true
    } else {
        false
    }
}

/// Force a checkpoint regardless of interval (e.g., low-activity periods)
public fun force_commit_checkpoint(oracle: &mut SimpleTWAP, clock: &Clock) {
    let now = clock.timestamp_ms();
    if (now > oracle.last_checkpoint_at) {
        record_checkpoint(oracle, now);
    }
}

/// Get long-window TWAP using checkpoints.
/// Returns None if not enough history (no checkpoint older than window_ms)
public fun get_window_twap(
    oracle: &SimpleTWAP,
    window_ms: u64,
    clock: &Clock,
): option::Option<u128> {
    let now = clock.timestamp_ms();
    if (now <= window_ms) {
        return option::none()
    };

    let target = now - window_ms;
    let len = vector::length(&oracle.checkpoints);
    if (len == 0) {
        return option::none()
    };

    let mut idx_opt = option::none();
    let mut i = len;
    while (i > 0) {
        i = i - 1;
        let cp = vector::borrow(&oracle.checkpoints, i);
        if (cp.timestamp <= target) {
            idx_opt = option::some(i);
            break;
        };
    };

    if (option::is_none(&idx_opt)) {
        return option::none()
    };

    let idx = option::destroy_some(idx_opt);
    let cp = vector::borrow(&oracle.checkpoints, idx);
    let start_ts = cp.timestamp;
    let start_cumulative = cp.cumulative;

    let duration = now - start_ts;
    if (duration == 0) {
        return option::none()
    };

    let current_cumulative = projected_cumulative_arithmetic_to(oracle, now);
    let diff = current_cumulative - start_cumulative;
    let avg_u256 = diff / (duration as u256);
    assert!(avg_u256 <= (std::u128::max_value!() as u256), EOverflow);

    option::some(avg_u256 as u128)
}

/// Convenience wrapper for 90-day TWAP (returns None if insufficient history)
public fun get_ninety_day_twap(oracle: &SimpleTWAP, clock: &Clock): option::Option<u128> {
    get_window_twap(oracle, NINETY_DAYS_MS, clock)
}

/// Find checkpoint at or before target timestamp.
/// Returns None if no checkpoint exists before target.
public fun checkpoint_at_or_before(
    oracle: &SimpleTWAP,
    target_timestamp: u64,
): option::Option<Checkpoint> {
    let len = vector::length(&oracle.checkpoints);
    if (len == 0) {
        return option::none()
    };

    let mut i = len;
    while (i > 0) {
        i = i - 1;
        let cp = vector::borrow(&oracle.checkpoints, i);
        if (cp.timestamp <= target_timestamp) {
            return option::some(*cp)
        };
    };

    option::none()
}

// ============================================================================
// Internal Helpers
// ============================================================================

fun maybe_commit_checkpoint(oracle: &mut SimpleTWAP, now: u64) {
    if (now >= oracle.last_checkpoint_at + CHECKPOINT_INTERVAL_MS) {
        record_checkpoint(oracle, now);
    }
}

fun record_checkpoint(oracle: &mut SimpleTWAP, timestamp: u64) {
    let checkpoint = Checkpoint { timestamp, cumulative: oracle.cumulative_total };

    if (vector::length(&oracle.checkpoints) >= MAX_CHECKPOINTS) {
        let _ = vector::remove(&mut oracle.checkpoints, 0);
    };

    vector::push_back(&mut oracle.checkpoints, checkpoint);
    oracle.last_checkpoint_at = timestamp;
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
        cumulative_total: _,
        last_price: _,
        initialized_at: _,
        checkpoints: _,
        last_checkpoint_at: _,
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

#[test_only]
public fun get_cumulative_total(oracle: &SimpleTWAP): u256 {
    oracle.cumulative_total
}

#[test_only]
public fun get_initialized_at(oracle: &SimpleTWAP): u64 {
    oracle.initialized_at
}
