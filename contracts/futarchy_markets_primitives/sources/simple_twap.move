/// ============================================================================
/// SIMPLE TWAP - UNISWAP V2 STYLE TIME-WEIGHTED AVERAGE PRICE
/// ============================================================================
///
/// PURPOSE: External price oracle for lending protocols and integrations
///
/// KEY FEATURES:
/// - Rolling 90-day window for time-weighted average (longer = safer)
/// - Pure arithmetic mean (no price capping needed)
/// - Uniswap V2 proven design with extended window
/// - Manipulation cost scales with window size (90 days = extremely expensive)
///
/// USED BY:
/// - External lending protocols (Compound, Aave style)
/// - Price aggregators
/// - Any protocol needing standard TWAP
///
/// NOT USED FOR:
/// - Governance decisions (use futarchy oracle)
/// - Determining proposal winners (use futarchy oracle)
///
/// DESIGN:
/// - Accumulates price × time over rolling 90-day window
/// - NO price capping (like Uniswap V2)
/// - Returns TWAP = cumulative / window_duration
/// - Long window makes manipulation economically infeasible
///
/// ============================================================================

module futarchy_markets_primitives::simple_twap;

use futarchy_one_shot_utils::math;
use sui::clock::Clock;
use sui::event;

// ============================================================================
// Constants
// ============================================================================

const NINETY_DAYS_MS: u64 = 7_776_000_000; // 90 days in milliseconds
const PRICE_SCALE: u128 = 1_000_000_000_000; // 10^12 for precision
const PPM_DENOMINATOR: u64 = 1_000_000; // Parts per million

// Errors
const ENotInitialized: u64 = 1;
const EInvalidCapPpm: u64 = 2;
const ETwapNotReady: u64 = 3;
const EBackfillMismatch: u64 = 5;
const EInvalidPeriod: u64 = 6;
const EOverflow: u64 = 7;
const EPriceDeviationTooLarge: u64 = 8;
const ECumulativeOverflow: u64 = 9;

// Safety limits
const MAX_PRICE_DEVIATION_RATIO: u64 = 100; // 100x max price change allowed

// ============================================================================
// Events
// ============================================================================

public struct TWAPUpdated has copy, drop {
    old_price: u128,
    new_price: u128,
    raw_price: u128,
    capped: bool,
    timestamp: u64,
    time_elapsed_ms: u64,
}

public struct WindowSlided has copy, drop {
    old_start: u64,
    new_start: u64,
    removed_duration_ms: u64,
}

public struct BackfillApplied has copy, drop {
    period_start: u64,
    period_end: u64,
    period_cumulative: u256,
    period_final_price: u128,
}

// ============================================================================
// Structs
// ============================================================================

/// Simple TWAP oracle - Uniswap V2 style (pure arithmetic mean)
public struct SimpleTWAP has store {
    // TWAP state
    initialized_at: u64,           // When oracle was initialized
    last_price: u128,              // Last recorded price
    last_timestamp: u64,           // Last update timestamp

    // Rolling window (90 days) - for simple consumers
    window_start_timestamp: u64,   // Start of current 90-day window
    window_cumulative_price: u256, // Cumulative price × time in current window

    // Infinite accumulation (Uniswap V2) - for advanced consumers
    total_cumulative_price: u256,  // Total cumulative since initialization (never resets)
}

// ============================================================================
// Core Functions
// ============================================================================

/// Create new SimpleTWAP oracle - Uniswap V2 style (no capping)
///
/// # Arguments
/// * `initial_price` - Starting price (e.g., stable_reserve / asset_reserve × PRICE_SCALE)
/// * `clock` - Sui clock for timestamp
///
/// # Design
/// - Simple consumers use get_twap() for 90-day TWAP
/// - Advanced consumers use get_cumulative_and_timestamp() for custom windows (Uniswap V2)
public fun new(
    initial_price: u128,
    clock: &Clock,
): SimpleTWAP {
    let now = clock.timestamp_ms();

    SimpleTWAP {
        initialized_at: now,
        last_price: initial_price,
        last_timestamp: now,
        window_start_timestamp: now,
        window_cumulative_price: 0,
        total_cumulative_price: 0,  // Infinite accumulation starts at 0
    }
}

/// Update oracle with new price - Uniswap V2 style (no capping)
public fun update(
    oracle: &mut SimpleTWAP,
    new_price: u128,
    clock: &Clock,
) {
    let now = clock.timestamp_ms();

    // Skip if no time passed
    if (now == oracle.last_timestamp) return;

    let time_elapsed = now - oracle.last_timestamp;

    // Accumulate price × time for elapsed period
    let price_time = (oracle.last_price as u256) * (time_elapsed as u256);

    // Update rolling window (90-day)
    oracle.window_cumulative_price = oracle.window_cumulative_price + price_time;

    // Update infinite cumulative (Uniswap V2 - never resets)
    oracle.total_cumulative_price = oracle.total_cumulative_price + price_time;

    // Update rolling window
    update_rolling_window(oracle, now);

    // Emit event
    event::emit(TWAPUpdated {
        old_price: oracle.last_price,
        new_price,
        raw_price: new_price,
        capped: false,  // Never capped (Uniswap V2 style)
        timestamp: now,
        time_elapsed_ms: time_elapsed,
    });

    // Update state
    oracle.last_price = new_price;
    oracle.last_timestamp = now;
}

/// Get current TWAP over 90-day window with overflow protection
public fun get_twap(oracle: &SimpleTWAP, clock: &Clock): u128 {
    let now = clock.timestamp_ms();

    // Require at least 90 days of history
    assert!(now >= oracle.initialized_at + NINETY_DAYS_MS, ETwapNotReady);

    // Project cumulative to now
    let time_since_last = now - oracle.last_timestamp;
    let projected_cumulative = oracle.window_cumulative_price +
        ((oracle.last_price as u256) * (time_since_last as u256));

    // Calculate window duration
    let window_age = now - oracle.window_start_timestamp;
    let effective_duration = if (window_age > NINETY_DAYS_MS) {
        NINETY_DAYS_MS
    } else {
        window_age
    };

    if (effective_duration > 0) {
        let twap_u256 = projected_cumulative / (effective_duration as u256);
        // Protect against u128 overflow
        assert!(twap_u256 <= (std::u128::max_value!() as u256), EOverflow);
        (twap_u256 as u128)
    } else {
        oracle.last_price
    }
}

/// Get current spot price (last recorded price)
public fun get_spot_price(oracle: &SimpleTWAP): u128 {
    oracle.last_price
}

/// Check if TWAP is ready (has 90+ days of history)
public fun is_ready(oracle: &SimpleTWAP, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    now >= oracle.initialized_at + NINETY_DAYS_MS
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Update rolling 90-day window - Uniswap V2 style (simple estimation)
fun update_rolling_window(oracle: &mut SimpleTWAP, now: u64) {
    let window_age = now - oracle.window_start_timestamp;

    if (window_age > NINETY_DAYS_MS) {
        let old_start = oracle.window_start_timestamp;

        // Slide window forward
        let new_window_start = now - NINETY_DAYS_MS;
        let time_to_remove = new_window_start - oracle.window_start_timestamp;

        // Estimate old price using current price (Uniswap V2 approach)
        // This is an approximation but becomes accurate as window ages
        let current_twap = if (window_age > 0) {
            ((oracle.window_cumulative_price / (window_age as u256)) as u128)
        } else {
            oracle.last_price
        };

        let price_to_remove = (current_twap as u256) * (time_to_remove as u256);

        // Remove old data from accumulator
        if (oracle.window_cumulative_price > price_to_remove) {
            oracle.window_cumulative_price = oracle.window_cumulative_price - price_to_remove;
        } else {
            // Fallback: reset to current price × 90 days
            oracle.window_cumulative_price = (oracle.last_price as u256) * (NINETY_DAYS_MS as u256);
        };

        oracle.window_start_timestamp = new_window_start;

        // Emit event
        event::emit(WindowSlided {
            old_start,
            new_start: new_window_start,
            removed_duration_ms: time_to_remove,
        });
    };
}

// ============================================================================
// Safety Helper Functions
// ============================================================================

/// Validate price is within reasonable bounds (prevents price oracle poisoning)
/// Checks that new_price is within MAX_PRICE_DEVIATION_RATIO of old_price
fun validate_price_deviation(old_price: u128, new_price: u128) {
    // Allow any price if old price is zero (initialization case)
    if (old_price == 0) return;

    // Calculate max and min allowed prices
    let max_allowed = (old_price as u256) * (MAX_PRICE_DEVIATION_RATIO as u256);
    let min_allowed = (old_price as u256) / (MAX_PRICE_DEVIATION_RATIO as u256);

    assert!(
        (new_price as u256) <= max_allowed && (new_price as u256) >= min_allowed,
        EPriceDeviationTooLarge
    );
}

/// Safely add to cumulative with overflow check
fun safe_add_to_cumulative(cumulative: u256, addition: u256): u256 {
    // Check for overflow before adding
    let max_u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    assert!(cumulative <= max_u256 - addition, ECumulativeOverflow);
    cumulative + addition
}

/// Safely multiply u256 values with overflow check
public fun safe_mul_u256(a: u256, b: u256): u256 {
    if (a == 0 || b == 0) return 0;

    let max_u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    assert!(a <= max_u256 / b, EOverflow);
    a * b
}

// ============================================================================
// Getter Functions
// ============================================================================

public fun last_price(oracle: &SimpleTWAP): u128 {
    oracle.last_price
}

public fun last_timestamp(oracle: &SimpleTWAP): u64 {
    oracle.last_timestamp
}

public fun initialized_at(oracle: &SimpleTWAP): u64 {
    oracle.initialized_at
}

public fun window_start(oracle: &SimpleTWAP): u64 {
    oracle.window_start_timestamp
}

/// Get window cumulative price (for combining with conditional TWAP)
public fun window_cumulative_price(oracle: &SimpleTWAP): u256 {
    oracle.window_cumulative_price
}

/// Get window start timestamp (for combining with conditional TWAP)
public fun window_start_timestamp(oracle: &SimpleTWAP): u64 {
    oracle.window_start_timestamp
}

/// Get cumulative and timestamp for Uniswap V2 style custom TWAP calculations
///
/// # Usage (Advanced Consumers - Lending Protocols)
/// ```
/// // Step 1: Store snapshot at desired window start
/// let (snapshot_cumulative, snapshot_timestamp) = get_cumulative_and_timestamp(oracle);
/// // Consumer stores these in their contract
///
/// // Step 2: Later, read current values
/// let (current_cumulative, current_timestamp) = get_cumulative_and_timestamp(oracle);
///
/// // Step 3: Calculate custom TWAP
/// let time_elapsed = current_timestamp - snapshot_timestamp;
/// let cumulative_delta = current_cumulative - snapshot_cumulative;
/// let custom_twap = cumulative_delta / time_elapsed;
/// ```
///
/// # Returns
/// * `cumulative_price` - Total cumulative price × time since initialization
/// * `timestamp` - Last update timestamp in milliseconds
///
/// # Examples
/// - 30-min TWAP: Store snapshot 30 min ago, read now
/// - 1-hour TWAP: Store snapshot 1 hour ago, read now
/// - 24-hour TWAP: Store snapshot 24 hours ago, read now
public fun get_cumulative_and_timestamp(oracle: &SimpleTWAP): (u256, u64) {
    (oracle.total_cumulative_price, oracle.last_timestamp)
}

/// Calculate projected cumulative to a specific timestamp
/// Used for combining spot + conditional TWAPs
public fun projected_cumulative_to(oracle: &SimpleTWAP, target_timestamp: u64): u256 {
    let time_since_last = target_timestamp - oracle.last_timestamp;
    oracle.window_cumulative_price + ((oracle.last_price as u256) * (time_since_last as u256))
}

/// Backfill cumulative data from conditional oracle after proposal ends
/// This "fills the gap" in spot's oracle with winning conditional's data
///
/// # Arguments
/// * `period_start` - When the proposal started (when spot froze)
/// * `period_end` - When the proposal ended
/// * `period_cumulative` - Conditional's cumulative price × time for this period
/// * `period_final_price` - Conditional's final price at proposal end
///
/// # Safety
/// * Validates period aligns with oracle's last timestamp (prevents duplicate backfills)
/// * Validates period_end > period_start
/// * Emits event for observability
public fun backfill_from_conditional(
    oracle: &mut SimpleTWAP,
    period_start: u64,
    period_end: u64,
    period_cumulative: u256,
    period_final_price: u128,
) {
    // CRITICAL: Validate period aligns with oracle state to prevent duplicate backfills
    assert!(period_start == oracle.last_timestamp, EBackfillMismatch);
    assert!(period_end > period_start, EInvalidPeriod);

    // SAFETY: Validate price deviation to prevent oracle poisoning
    validate_price_deviation(oracle.last_price, period_final_price);

    // SAFETY: Add conditional's cumulative to spot's rolling window with overflow protection
    oracle.window_cumulative_price = safe_add_to_cumulative(
        oracle.window_cumulative_price,
        period_cumulative
    );

    // SAFETY: Add to infinite cumulative (for Uniswap V2 style consumers) with overflow protection
    oracle.total_cumulative_price = safe_add_to_cumulative(
        oracle.total_cumulative_price,
        period_cumulative
    );

    // Update state to resume from conditional's final state
    oracle.last_price = period_final_price;
    oracle.last_timestamp = period_end;

    // Recalculate window TWAP with backfilled data
    let window_age = period_end - oracle.window_start_timestamp;
    let window_duration = if (window_age > NINETY_DAYS_MS) {
        NINETY_DAYS_MS
    } else {
        window_age
    };

    if (window_duration > 0) {
        // Note: We removed last_window_twap field, so this calculation is no longer needed
        // The get_twap() function calculates TWAP on the fly from window_cumulative_price
    };

    // Emit event
    event::emit(BackfillApplied {
        period_start,
        period_end,
        period_cumulative,
        period_final_price,
    });
}

// ============================================================================
// Test Functions
// ============================================================================

#[test_only]
public fun destroy_for_testing(oracle: SimpleTWAP) {
    let SimpleTWAP {
        initialized_at: _,
        last_price: _,
        last_timestamp: _,
        window_start_timestamp: _,
        window_cumulative_price: _,
        total_cumulative_price: _,
    } = oracle;
}
