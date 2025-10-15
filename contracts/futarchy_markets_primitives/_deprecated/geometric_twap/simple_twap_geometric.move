/// ============================================================================
/// SIMPLE TWAP - DUAL-WINDOW TIME-WEIGHTED AVERAGE PRICE
/// ============================================================================
///
/// PURPOSE: Provide two specialized TWAPs for different use cases
///
/// WINDOWS:
/// 1. 30-Minute Arithmetic TWAP - For lending protocols (fast response)
/// 2. 90-Day Geometric TWAP - For oracle grants (manipulation resistant)
///
/// KEY FEATURES:
/// - Continuous accumulation (no checkpoints needed)
/// - Pass-through from conditional markets during proposals
/// - Geometric mean naturally resists price manipulation
/// - Both windows update simultaneously (minimal overhead)
///
/// USED BY:
/// - Lending protocols: get_lending_twap() → 30-min arithmetic
/// - Oracle grants: get_geometric_twap() → 90-day geometric
/// - External consumers: Choose based on use case
///
/// MANIPULATION RESISTANCE:
/// Arithmetic mean: Spike to 10x for 1 day → +10% impact on 90-day TWAP
/// Geometric mean: Spike to 10x for 1 day → +2.5% impact on 90-day TWAP
///
/// ============================================================================

module futarchy_markets_primitives::simple_twap;

use futarchy_one_shot_utils::fixed_point_math::{
    Self,
    SignedU256,
    SignedAccumulator,
    accumulator_zero,
    accumulator_add,
    accumulator_to_signed,
    signed_negate,
    signed_sub,
    signed_div_u64,
    signed_abs,
    signed_is_negative,
};
use sui::clock::Clock;
use sui::event;

// ============================================================================
// Constants
// ============================================================================

const THIRTY_MINUTES_MS: u64 = 1_800_000;      // 30 minutes
const NINETY_DAYS_MS: u64 = 7_776_000_000;     // 90 days
const PRICE_SCALE: u128 = 1_000_000_000_000;   // 1e12 for precision
const PPM_DENOMINATOR: u64 = 1_000_000;         // Parts per million

// Errors
const ENotInitialized: u64 = 1;
const ETwapNotReady: u64 = 3;
const EBackfillMismatch: u64 = 5;
const EInvalidPeriod: u64 = 6;
const EOverflow: u64 = 7;
const EPriceDeviationTooLarge: u64 = 8;
const ECumulativeOverflow: u64 = 9;
const EInvalidPrice: u64 = 10;

// Safety limits
const MAX_PRICE_DEVIATION_RATIO: u64 = 100; // 100x max price change allowed

// ============================================================================
// Events
// ============================================================================

public struct TWAPUpdated has copy, drop {
    old_price: u128,
    new_price: u128,
    timestamp: u64,
    time_elapsed_ms: u64,
}

// WindowSlided event removed - no longer needed with observations ring

public struct BackfillApplied has copy, drop {
    period_start: u64,
    period_end: u64,
    period_cumulative_arithmetic: u256,
    period_cumulative_geometric: u256,
    period_final_price: u128,
}

// ============================================================================
// Structs
// ============================================================================

/// Single observation snapshot for exact TWAP calculations
public struct Observation has copy, drop, store {
    timestamp: u64,
    cum_arith: u256,              // Cumulative price × time (arithmetic)
    cum_log: SignedAccumulator,   // Cumulative ln(price) × time (geometric)
    price_at_obs: u128,           // Price at this observation (for virtualization)
}

/// Dual-window TWAP oracle with observations ring
/// - 30-minute arithmetic (lending)
/// - 90-day geometric (oracle grants)
///
/// Uses Uniswap-style observations for exact difference-of-cumulatives
public struct SimpleTWAP has store {
    // Current state
    initialized_at: u64,
    last_price: u128,
    last_timestamp: u64,

    // Current cumulatives (monotonically increasing)
    cumulative_arith: u256,
    cumulative_log: SignedAccumulator,

    // Observations ring buffer (fixed size for gas efficiency)
    observations: vector<Observation>,
    obs_index: u16,           // Current write position (wraps around)
    obs_cardinality: u16,     // Number of populated slots (max = obs.length())
}

// ============================================================================
// Core Functions
// ============================================================================

/// Create new dual-window TWAP oracle
///
/// Initializes with observations ring (capacity for ~1 year of hourly updates)
/// - 8760 observations = 365 days × 24 hours
/// - More than enough for 90-day geometric window
public fun new(
    initial_price: u128,
    clock: &Clock,
): SimpleTWAP {
    assert!(initial_price > 0, EInvalidPrice);

    let now = clock.timestamp_ms();

    // Create first observation at initialization
    let first_obs = Observation {
        timestamp: now,
        cum_arith: 0,
        cum_log: accumulator_zero(),
        price_at_obs: initial_price,
    };

    let mut observations = vector::empty<Observation>();
    vector::push_back(&mut observations, first_obs);

    SimpleTWAP {
        initialized_at: now,
        last_price: initial_price,
        last_timestamp: now,
        cumulative_arith: 0,
        cumulative_log: accumulator_zero(),
        observations,
        obs_index: 0,
        obs_cardinality: 1,
    }
}

/// Update TWAPs with new price
///
/// Called on every swap in spot/conditional pools
/// Appends new observation to ring buffer
public fun update(
    oracle: &mut SimpleTWAP,
    new_price: u128,
    clock: &Clock,
) {
    assert!(new_price > 0, EInvalidPrice);

    let now = clock.timestamp_ms();

    // Skip if no time passed
    if (now == oracle.last_timestamp) return;

    let time_elapsed = now - oracle.last_timestamp;

    // === Integrate using last price (piecewise constant) ===
    let price_time_arithmetic = (oracle.last_price as u256) * (time_elapsed as u256);
    oracle.cumulative_arith = oracle.cumulative_arith + price_time_arithmetic;

    let log_price = fixed_point_math::natural_log(oracle.last_price);
    let log_price_time = fixed_point_math::signed_mul_u64(log_price, time_elapsed);
    oracle.cumulative_log = accumulator_add(oracle.cumulative_log, log_price_time);

    // === Append new observation ===
    write_observation(oracle, now, new_price);

    // Emit event
    event::emit(TWAPUpdated {
        old_price: oracle.last_price,
        new_price,
        timestamp: now,
        time_elapsed_ms: time_elapsed,
    });

    // Update state
    oracle.last_price = new_price;
    oracle.last_timestamp = now;
}

/// Get 30-minute arithmetic TWAP (for lending protocols)
///
/// Returns: Time-weighted average price over last 30 minutes
/// Uses exact difference-of-cumulatives from observations
public fun get_lending_twap(oracle: &SimpleTWAP, clock: &Clock): u128 {
    let now = clock.timestamp_ms();

    // Find target time (30 minutes ago)
    let target_time = if (now > THIRTY_MINUTES_MS) {
        now - THIRTY_MINUTES_MS
    } else {
        oracle.initialized_at  // If < 30min old, use initialization time
    };

    // Get cumulative at now (virtualized from last update)
    let cum_now = virtualize_cumulative_arith(oracle, now);

    // Get cumulative at target_time (from observations + virtualization)
    let (cum_old, actual_old_time) = get_cumulative_at_arith(oracle, target_time);

    // Compute exact TWAP = (cum_now - cum_old) / duration
    let duration = now - actual_old_time;
    if (duration > 0) {
        let twap_u256 = (cum_now - cum_old) / (duration as u256);
        assert!(twap_u256 <= (std::u128::max_value!() as u256), EOverflow);
        (twap_u256 as u128)
    } else {
        oracle.last_price
    }
}

/// Get 90-day geometric TWAP (for oracle grants)
///
/// Returns: Geometric mean price over last 90 days
/// Requires 90+ days of history before ready
///
/// Geometric mean is MORE manipulation-resistant than arithmetic:
/// - Short price spikes have exponentially less impact
/// - Natural choice for log-normally distributed prices
public fun get_geometric_twap(oracle: &SimpleTWAP, clock: &Clock): u128 {
    let now = clock.timestamp_ms();

    // Require at least 90 days of history
    assert!(now >= oracle.initialized_at + NINETY_DAYS_MS, ETwapNotReady);

    // Find target time (90 days ago)
    let target_time = now - NINETY_DAYS_MS;

    // Get cumulative at now (virtualized from last update)
    let cum_log_now = virtualize_cumulative_log(oracle, now);

    // Get cumulative at target_time (from observations + virtualization)
    let (cum_log_old, actual_old_time) = get_cumulative_at_log(oracle, target_time);

    // Compute exact geometric TWAP = exp((cum_log_now - cum_log_old) / duration)
    let duration = now - actual_old_time;
    if (duration > 0) {
        // Subtract cumulatives (both are SignedAccumulator)
        let cum_diff = signed_sub(
            accumulator_to_signed(cum_log_now),
            accumulator_to_signed(cum_log_old)
        );

        // Average: divide by duration
        let log_avg = fixed_point_math::signed_div_u64(cum_diff, duration);

        // Exponentiate to get geometric mean
        fixed_point_math::natural_exp(log_avg)
    } else {
        oracle.last_price
    }
}

/// Get current spot price (last recorded price)
public fun get_spot_price(oracle: &SimpleTWAP): u128 {
    oracle.last_price
}

/// Check if geometric TWAP is ready (has 90+ days of history)
public fun is_ready(oracle: &SimpleTWAP, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    now >= oracle.initialized_at + NINETY_DAYS_MS
}

// ============================================================================
// Observations Ring Buffer Functions
// ============================================================================

/// Write new observation to ring buffer
fun write_observation(oracle: &mut SimpleTWAP, timestamp: u64, price: u128) {
    let new_obs = Observation {
        timestamp,
        cum_arith: oracle.cumulative_arith,
        cum_log: oracle.cumulative_log,
        price_at_obs: price,
    };

    let obs_count = vector::length(&oracle.observations);

    if ((oracle.obs_cardinality as u64) < obs_count) {
        // Ring buffer not full yet, append
        vector::push_back(&mut oracle.observations, new_obs);
        oracle.obs_cardinality = oracle.obs_cardinality + 1;
        oracle.obs_index = oracle.obs_cardinality - 1;
    } else {
        // Ring buffer full, overwrite oldest
        let next_index = (oracle.obs_index + 1) % (obs_count as u16);
        *vector::borrow_mut(&mut oracle.observations, (next_index as u64)) = new_obs;
        oracle.obs_index = next_index;
    };
}

/// Find observation closest to (but not after) target_time
/// Returns observation index, or none if target_time is before all observations
fun find_observation_before(oracle: &SimpleTWAP, target_time: u64): Option<u64> {
    let obs_count = (oracle.obs_cardinality as u64);
    if (obs_count == 0) return option::none();

    // Check if target is before first observation
    let first_obs = vector::borrow(&oracle.observations, 0);
    if (target_time < first_obs.timestamp) return option::none();

    // Linear search (TODO: binary search for large cardinality)
    let mut best_idx = 0;
    let mut best_time = first_obs.timestamp;

    let mut i = 1;
    while (i < obs_count) {
        let obs = vector::borrow(&oracle.observations, i);
        if (obs.timestamp <= target_time && obs.timestamp > best_time) {
            best_idx = i;
            best_time = obs.timestamp;
        };
        i = i + 1;
    };

    option::some(best_idx)
}

/// Virtualize arithmetic cumulative to target_time
fun virtualize_cumulative_arith(oracle: &SimpleTWAP, target_time: u64): u256 {
    let time_since_last = target_time - oracle.last_timestamp;
    oracle.cumulative_arith + ((oracle.last_price as u256) * (time_since_last as u256))
}

/// Virtualize geometric cumulative to target_time
fun virtualize_cumulative_log(oracle: &SimpleTWAP, target_time: u64): SignedAccumulator {
    let time_since_last = target_time - oracle.last_timestamp;
    let log_price = fixed_point_math::natural_log(oracle.last_price);
    let log_price_time = fixed_point_math::signed_mul_u64(log_price, time_since_last);
    accumulator_add(oracle.cumulative_log, log_price_time)
}

/// Get arithmetic cumulative at target_time using observations + virtualization
/// Returns (cumulative, actual_time_used)
fun get_cumulative_at_arith(oracle: &SimpleTWAP, target_time: u64): (u256, u64) {
    // Find observation before target
    let obs_idx_opt = find_observation_before(oracle, target_time);

    if (option::is_none(&obs_idx_opt)) {
        // Target is before all observations, use initialization
        (0, oracle.initialized_at)
    } else {
        let obs_idx = option::destroy_some(obs_idx_opt);
        let obs = vector::borrow(&oracle.observations, obs_idx);

        if (obs.timestamp == target_time) {
            // Exact match
            (obs.cum_arith, obs.timestamp)
        } else {
            // Virtualize from observation to target
            let dt = target_time - obs.timestamp;
            let cum_at_target = obs.cum_arith + ((obs.price_at_obs as u256) * (dt as u256));
            (cum_at_target, target_time)
        }
    }
}

/// Get geometric cumulative at target_time using observations + virtualization
/// Returns (cumulative, actual_time_used)
fun get_cumulative_at_log(oracle: &SimpleTWAP, target_time: u64): (SignedAccumulator, u64) {
    // Find observation before target
    let obs_idx_opt = find_observation_before(oracle, target_time);

    if (option::is_none(&obs_idx_opt)) {
        // Target is before all observations, use initialization
        (accumulator_zero(), oracle.initialized_at)
    } else {
        let obs_idx = option::destroy_some(obs_idx_opt);
        let obs = vector::borrow(&oracle.observations, obs_idx);

        if (obs.timestamp == target_time) {
            // Exact match
            (obs.cum_log, obs.timestamp)
        } else {
            // Virtualize from observation to target
            let dt = target_time - obs.timestamp;
            let log_price = fixed_point_math::natural_log(obs.price_at_obs);
            let log_price_time = fixed_point_math::signed_mul_u64(log_price, dt);
            let cum_at_target = accumulator_add(obs.cum_log, log_price_time);
            (cum_at_target, target_time)
        }
    }
}

// ============================================================================
// Backfill Functions (for conditional market integration)
// ============================================================================

/// Backfill from conditional oracle after proposal ends
///
/// Fills the gap [proposal_start, proposal_end] with winning conditional's data
/// Appends observation at proposal_end
public fun backfill_from_conditional(
    oracle: &mut SimpleTWAP,
    proposal_start: u64,
    proposal_end: u64,
    period_cumulative_arithmetic: u256,
    period_cumulative_geometric: SignedAccumulator,
    period_final_price: u128,
) {
    // CRITICAL: Validate period aligns with oracle state
    assert!(proposal_start == oracle.last_timestamp, EBackfillMismatch);
    assert!(proposal_end > proposal_start, EInvalidPeriod);
    assert!(period_final_price > 0, EInvalidPrice);

    // SAFETY: Validate price deviation
    validate_price_deviation(oracle.last_price, period_final_price);

    // SAFETY: Validate implied average matches final price
    let period_duration = proposal_end - proposal_start;
    let implied_log_avg = signed_div_u64(
        accumulator_to_signed(period_cumulative_geometric),
        period_duration
    );
    let final_log = fixed_point_math::natural_log(period_final_price);

    // Allow 1% tolerance for discretization
    let log_diff = if (signed_is_negative(&implied_log_avg) == signed_is_negative(&final_log)) {
        let implied_abs = signed_abs(&implied_log_avg);
        let final_abs = signed_abs(&final_log);
        if (implied_abs > final_abs) {
            implied_abs - final_abs
        } else {
            final_abs - implied_abs
        }
    } else {
        signed_abs(&implied_log_avg) + signed_abs(&final_log)
    };
    let tolerance = signed_abs(&final_log) / 100;
    assert!(log_diff <= tolerance, EBackfillMismatch);

    // Add conditional's cumulative to spot's cumulative (monotonically increasing)
    oracle.cumulative_arith = safe_add_to_cumulative(
        oracle.cumulative_arith,
        period_cumulative_arithmetic
    );

    oracle.cumulative_log = accumulator_add(
        oracle.cumulative_log,
        accumulator_to_signed(period_cumulative_geometric)
    );

    // Update state
    oracle.last_price = period_final_price;
    oracle.last_timestamp = proposal_end;

    // Append observation at proposal_end
    write_observation(oracle, proposal_end, period_final_price);

    // Emit event
    event::emit(BackfillApplied {
        period_start: proposal_start,
        period_end: proposal_end,
        period_cumulative_arithmetic,
        period_cumulative_geometric: fixed_point_math::accumulator_value(&period_cumulative_geometric),
        period_final_price,
    });
}

/// Calculate projected arithmetic cumulative to a specific timestamp
/// Used for combining spot + conditional TWAPs
public fun projected_cumulative_arithmetic_to(oracle: &SimpleTWAP, target_timestamp: u64): u256 {
    assert!(target_timestamp >= oracle.last_timestamp, EInvalidPeriod);
    let time_since_last = target_timestamp - oracle.last_timestamp;
    oracle.cumulative_arith + ((oracle.last_price as u256) * (time_since_last as u256))
}

/// Calculate projected geometric cumulative to a specific timestamp
/// Used for combining spot + conditional TWAPs
public fun projected_cumulative_geometric_to(oracle: &SimpleTWAP, target_timestamp: u64): SignedAccumulator {
    assert!(target_timestamp >= oracle.last_timestamp, EInvalidPeriod);
    let time_since_last = target_timestamp - oracle.last_timestamp;
    let log_price = fixed_point_math::natural_log(oracle.last_price);
    let log_price_time = fixed_point_math::signed_mul_u64(log_price, time_since_last);
    accumulator_add(oracle.cumulative_log, log_price_time)
}

// ============================================================================
// Safety Helper Functions
// ============================================================================

/// Ceiling division for u256
fun ceil_div_u256(n: u256, d: u256): u256 {
    (n + d - 1) / d
}

/// Validate price is within reasonable bounds (100x max deviation)
fun validate_price_deviation(old_price: u128, new_price: u128) {
    // Allow any price if old price is zero (initialization case)
    if (old_price == 0) return;

    let ratio = MAX_PRICE_DEVIATION_RATIO as u256;
    let max_allowed = (old_price as u256) * ratio;
    let min_allowed = ceil_div_u256(old_price as u256, ratio);  // Fixed: use ceil_div

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

public fun cumulative_arith(oracle: &SimpleTWAP): u256 {
    oracle.cumulative_arith
}

public fun cumulative_log(oracle: &SimpleTWAP): SignedAccumulator {
    oracle.cumulative_log
}

public fun obs_cardinality(oracle: &SimpleTWAP): u16 {
    oracle.obs_cardinality
}

public fun obs_index(oracle: &SimpleTWAP): u16 {
    oracle.obs_index
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
        cumulative_arith: _,
        cumulative_log: _,
        observations: _,
        obs_index: _,
        obs_cardinality: _,
    } = oracle;
}
