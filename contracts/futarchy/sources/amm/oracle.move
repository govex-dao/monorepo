module futarchy::oracle;

use futarchy::math;
use std::debug;
use std::u128;
use sui::clock::{Self, Clock};

// === Introduction ===
// Crankless Time Weighted Average Price (TWAP) Oracle

// ========== Constants =========
const TWAP_PRICE_CAP_WINDOW: u64 = 60_000; // 60 seconds in milliseconds
const ONE_WEEK_MS: u64 = 604_800_000;

// ======== Error Constants ========
const ETIMESTAMP_REGRESSION: u64 = 0;
const ETWAP_NOT_STARTED: u64 = 1;
const EZERO_PERIOD: u64 = 2;
const EZERO_INITIALIZATION: u64 = 3;
const EZERO_STEP: u64 = 4;
const ELONG_DELAY: u64 = 5;
const ESTALE_TWAP: u64 = 6;

// ======== Configuration Struct ========
public struct Oracle has key, store {
    id: UID,
    last_price: u128,
    last_timestamp: u64,
    total_cumulative_price: u256,
    // TWAP calculation fields - using u256 for overflow protection
    // Max TWAP accumulation is U256 Max ≈1.16 x 10^77
    // Max TWAP daily accumulation:
    //     Max price observation = u64::max_value!() x 1_000_000_000_000;
    //     Milliseconds a day (7 x 24 × 3,600 × 1,000) * max price observation
    //     Allows for 1.04×10 ^ 37 days of accumulation.
    last_window_end_cumulative_price: u256,
    last_window_end: u64,
    last_window_twap: u128,
    twap_start_delay: u64,
    // Reduces attacker advantage with surprise proposals
    twap_cap_step: u64,
    // Maximum relative step size for TWAP calculations
    market_start_time: u64,
    twap_initialization_price: u128,
}

// ======== Constructor ========
public(package) fun new_oracle(
    twap_initialization_price: u128,
    market_start_time: u64,
    twap_start_delay: u64,
    twap_cap_step: u64,
    ctx: &mut TxContext,
): Oracle {
    assert!(twap_initialization_price > 0, EZERO_INITIALIZATION);
    assert!(twap_cap_step > 0, EZERO_STEP);
    assert!(twap_start_delay < ONE_WEEK_MS, ELONG_DELAY); // One week in milliseconds

    Oracle {
        id: object::new(ctx), // Create a unique ID for the oracle
        last_price: twap_initialization_price,
        last_timestamp: market_start_time,
        total_cumulative_price: 0,
        last_window_end_cumulative_price: 0,
        last_window_end: 0,
        last_window_twap: twap_initialization_price,
        twap_start_delay: twap_start_delay,
        twap_cap_step: twap_cap_step,
        market_start_time: market_start_time,
        twap_initialization_price: twap_initialization_price,
    }
}

// ======== Helper Functions ========
// Cap TWAP accumalation price against previous windows to stop an attacker moving it quickly
fun cap_price_change(
    twap_base: u128,
    new_price: u128,
    twap_cap_step: u64,
    full_windows_since_last_update: u64,
): u128 {
    // Calculate max change as absolute value step * number of windows
    // Add 1 because even within the first new window (0 full windows passed),
    // one step of capping applies relative to the previous window's TWAP.
    let steps = full_windows_since_last_update + 1;

    // This could overflow if a proposal went on for longer than approximately 6.5 × 10^29 years, given windows are 60s.
    let max_change = (twap_cap_step as u128) * (steps as u128);

    if (new_price > twap_base) {
        // Cap upward movement: min(new_price, saturating_add(twap_base, max_change))
        u128::min(new_price, math::saturating_add(twap_base, max_change))
    } else {
        // Cap downward movement: max(new_price, saturating_sub(twap_base, max_change))
        u128::max(new_price, math::saturating_sub(twap_base, max_change))
    }
}

// ======== Core Functions ========
// Called before swaps, LP events and before reading TWAP
public(package) fun write_observation(oracle: &mut Oracle, timestamp: u64, price: u128) {
    // Sanity time checks
    assert!(timestamp >= oracle.last_timestamp, ETIMESTAMP_REGRESSION);

    // Ensure the TWAP delay has finished.
    let delay_threshold = oracle.market_start_time + oracle.twap_start_delay;
    if (timestamp < delay_threshold) {
        // Do nothing if before TWAP start delay
        return
    };

    // If the first observation after delay arrives and last_timestamp is still below the threshold,
    // update it so that accumulation starts strictly after the delay.
    if (oracle.last_timestamp < delay_threshold) {
        oracle.last_timestamp = delay_threshold;
        // Initialize last_window_end to the delay threshold as well, so the first window starts here.
        oracle.last_window_end = delay_threshold;
        // Initialize last_window_end_cumulative_price - since no time elapsed yet at threshold, it's 0.
        oracle.last_window_end_cumulative_price = 0; // Assuming total_cumulative_price is also 0 initially
    };

    let additional_time_to_include = timestamp - oracle.last_timestamp;

    // Avoid multiplying by 0 time. Also handles the very first observation case.
    if (additional_time_to_include > 0) {
        // Check if one or more full windows have passed since the last window boundary
        let time_since_last_window_end = timestamp - oracle.last_window_end;
        if (time_since_last_window_end >= TWAP_PRICE_CAP_WINDOW) {
            // Calculate how many full windows have completed since the last boundary update
            let full_windows_since_last_update = (
                time_since_last_window_end / TWAP_PRICE_CAP_WINDOW,
            ); // u64 division is fine

            // Determine the price to use for accumulation, capped relative to the last window's TWAP
            let capped_price = cap_price_change(
                oracle.last_window_twap,
                price,
                oracle.twap_cap_step,
                full_windows_since_last_update, // Pass the number of full windows
            );
            let scaled_price = (capped_price as u256);

            // 1. Determine the New Window End Timestamp
            // This is the exact time the last full window completed before 'timestamp'.
            let new_last_window_end =
                oracle.last_window_end
                + TWAP_PRICE_CAP_WINDOW * full_windows_since_last_update;

            // 2. Calculate Contribution *Only Until* the New Window End
            // Time from the last observation up to the exact end of the completed window(s).
            let time_until_window_end = new_last_window_end - oracle.last_timestamp;
            let price_contribution_until_window_end =
                scaled_price * (time_until_window_end as u256);

            // 3. Calculate Cumulative Price *Exactly At* the New Window End
            // This is the total cumulative price at the precise moment the window(s) ended.
            let cumulative_at_new_window_end =
                oracle.total_cumulative_price + price_contribution_until_window_end;

            // 4. Calculate the TWAP for the Window(s) that Just Ended
            // Accumulation during the window(s) = Cumulative price at end - Cumulative price at start.
            let accumulation_during_windows =
                cumulative_at_new_window_end - oracle.last_window_end_cumulative_price;
            // Total time elapsed during these full window(s).
            let time_elapsed_in_windows =
                (TWAP_PRICE_CAP_WINDOW as u256) * (full_windows_since_last_update as u256);
            assert!(time_elapsed_in_windows > 0, EZERO_PERIOD); // Safety check, should be guaranteed by the if condition
            // Calculate the TWAP for the completed window(s).
            let new_last_window_twap = accumulation_during_windows / time_elapsed_in_windows;

            // 5. Calculate the Remaining Contribution *After* the New Window End
            // Time from the window end up to the current observation timestamp.
            let time_after_window_end = timestamp - new_last_window_end;
            let price_contribution_after_window_end =
                scaled_price * (time_after_window_end as u256);

            // --- Update Oracle State ---
            oracle.last_window_twap = (new_last_window_twap as u128);
            oracle.last_window_end_cumulative_price = cumulative_at_new_window_end; // Set cumulative price AT window end
            oracle.last_window_end = new_last_window_end; // Update window end time
            // Update total price incorporating both parts of the period 
            oracle.total_cumulative_price =
                cumulative_at_new_window_end + price_contribution_after_window_end;
            oracle.last_price = capped_price; // Update last observed (capped) price

            // No window closure: continue accumulating within the current open window
        } else {
            // No full window boundary was crossed since the last update.
            // We still need to apply capping relative to the last completed window's TWAP.
            // `full_windows_since_last_update` is effectively 0 here for capping purposes.
            let capped_price = cap_price_change(
                oracle.last_window_twap,
                price,
                oracle.twap_cap_step,
                0, // 0 full windows crossed since last window end
            );

            // Add accumulation for the partial period within the current (still open) window
            let scaled_price = (capped_price as u256);
            let price_contribution = scaled_price * (additional_time_to_include as u256);
            oracle.total_cumulative_price = oracle.total_cumulative_price + price_contribution;
            oracle.last_price = capped_price; // Update last observed (capped) price
        };

        // Update the timestamp of the last observation AFTER all calculations for the period are done.
        oracle.last_timestamp = timestamp;
    }
    // If additional_time_to_include is 0, do nothing (avoid division by zero or unnecessary updates)
}

public(package) fun get_twap(oracle: &Oracle, clock: &Clock): u128 {
    let current_time = clock::timestamp_ms(clock);

    // TWAP is only allowed to be read in the same instance, after a write has occured
    // So no logic is needed to extrapolate TWAP for last write to current timestamp
    // Check reading in same instance as last write
    assert!(current_time == oracle.last_timestamp, ESTALE_TWAP);

    // Time checks
    assert!(oracle.last_timestamp != 0, ETIMESTAMP_REGRESSION);
    assert!(current_time - oracle.market_start_time >= oracle.twap_start_delay, ETWAP_NOT_STARTED);
    assert!(current_time >= oracle.market_start_time, ETIMESTAMP_REGRESSION);

    // Calculate period
    let period = ( current_time - oracle.market_start_time) - oracle.twap_start_delay;
    assert!(period > 0, EZERO_PERIOD);

    // Calculate and validate TWAP
    let twap = (oracle.total_cumulative_price) / (period as u256);

    (twap as u128)
}

// ======== Getters ========
public fun get_last_price(oracle: &Oracle): u128 {
    oracle.last_price
}

public fun get_last_timestamp(oracle: &Oracle): u64 {
    oracle.last_timestamp
}

public fun get_config(oracle: &Oracle): (u64, u64) {
    (oracle.twap_start_delay, oracle.twap_cap_step)
}

public fun get_market_start_time(oracle: &Oracle): u64 {
    oracle.market_start_time // Access through config
}

public fun get_twap_initialization_price(oracle: &Oracle): u128 {
    oracle.twap_initialization_price // Access through config
}

public fun get_id(o: &Oracle): &UID {
    &o.id
}

// ======== Testing Helpers ========

#[test_only]
public fun debug_print_state(oracle: &Oracle) {
    debug::print(&b"Oracle State:");
    debug::print(&oracle.last_price);
    debug::print(&oracle.last_timestamp);
    debug::print(&oracle.total_cumulative_price);
}

#[test_only]
public fun debug_get_state(oracle: &Oracle): (u128, u64, u256) {
    (oracle.last_price, oracle.last_timestamp, oracle.total_cumulative_price)
}

#[test_only]
public fun test_oracle(ctx: &mut TxContext): Oracle {
    new_oracle(
        10000, // twap_initialization_price
        0, // market_start_time
        2000, // twap_start_delay
        1000, // max_bps_per_step
        ctx, // sixth argument (TxContext)
    )
}

#[test_only]
public fun destroy_for_testing(oracle: Oracle) {
    let Oracle {
        id,
        last_price: _,
        last_timestamp: _,
        total_cumulative_price: _,
        last_window_end: _,
        last_window_end_cumulative_price: _,
        last_window_twap: _,
        twap_start_delay: _,
        twap_cap_step: _,
        market_start_time: _,
        twap_initialization_price: _,
    } = oracle;
    object::delete(id);
}

#[test_only]
public fun debug_get_window_twap(oracle: &Oracle): u128 {
    oracle.last_window_twap
}

#[test_only]
public fun is_twap_valid(oracle: &Oracle, min_period: u64, clock: &Clock): bool {
    let current_time = clock::timestamp_ms(clock);
    current_time >= oracle.last_timestamp + min_period
}
