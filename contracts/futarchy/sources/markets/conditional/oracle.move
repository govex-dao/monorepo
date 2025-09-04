/// ============================================================================
/// FUTARCHY ORACLE - WRITE-THROUGH TWAP FOR PREDICTION MARKETS
/// ============================================================================
/// 
/// PURPOSE: Core oracle for futarchy decision-making and proposal resolution
/// 
/// USED BY:
/// - Conditional AMMs during proposals (outcome evaluation)
/// - Proposal resolution (determining winners based on TWAP)
/// - SpotAMM for governance TWAP (base fair value)
/// - NOT for lending protocols (use ring_buffer_oracle instead)
/// 
/// KEY FEATURES:
/// - Write-through pattern (MUST update before reading)
/// - Price capping to prevent manipulation
/// - Complex window-based accumulation
/// - Designed specifically for futarchy mechanics
/// - Does NOT merge with ring buffer data (separate concerns)
/// 
/// BEHAVIOR:
/// - During proposals: Each conditional AMM maintains its own oracle
/// - After finalization: Winning outcome's TWAP fills gap in spot oracle
/// - Ring buffer handles continuous feeds, this handles governance
/// 
/// WHY IT EXISTS:
/// Futarchy needs precise, manipulation-resistant price discovery during
/// proposals. This oracle enforces atomic write-then-read to ensure prices
/// are always fresh and prevents time-based manipulation attacks.
/// The separation from ring_buffer_oracle ensures governance decisions
/// cannot be influenced by lending protocol requirements.
/// 
/// ============================================================================

module futarchy::oracle;

use futarchy_utils::math;
use futarchy_utils::constants;
use std::u128;
use std::u64;
use sui::clock::Clock;
use sui::event;

// === Introduction ===
// Crankless Time Weighted Average Price (TWAP) Oracle

// === Constants ===
// Constants moved to constants module
// Using constants::twap_price_cap_window(), constants::one_week_ms(), constants::ppm_denominator()

// === Errors ===
const ETimestampRegression: u64 = 0;
const ETwapNotStarted: u64 = 1;
const EZeroPeriod: u64 = 2;
const EZeroInitialization: u64 = 3;
const EZeroStep: u64 = 4;
const ELongDelay: u64 = 5;
const EStaleTwap: u64 = 6;
const EOverflowVRamp: u64 = 7;
const EOverflowVFlat: u64 = 8;
const EOverflowSDevMag: u64 = 9;
const EOverflowBasePriceSumFinal: u64 = 10;
const EOverflowVSumPricesAdd: u64 = 11;
const EInternalTwapError: u64 = 12;
const ENoneFullWindowTwapDelay: u64 = 13;
const EMarketNotStarted: u64 = 14;
const EMarketAlreadyStarted: u64 = 15;
const EInvalidCapPpm: u64 = 16;
const EStepOverflow: u64 = 17;

// === Structs ===
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
    // Scaled relative maximum step size for TWAP calculations
    market_start_time: Option<u64>,
    twap_initialization_price: u128,
}

// === Events ===

public struct PriceEvent has copy, drop {
    last_price: u128,
}

// === Public Functions ===
public(package) fun new_oracle(
    twap_initialization_price: u128,
    twap_start_delay: u64,
    twap_cap_ppm: u64,
    ctx: &mut TxContext,
): Oracle {
    assert!(twap_initialization_price > 0, EZeroInitialization);
    assert!(twap_cap_ppm > 0, EZeroStep);
    assert!(twap_cap_ppm <= constants::ppm_denominator(), EInvalidCapPpm);
    assert!(twap_start_delay < constants::one_week_ms(), ELongDelay); // One week in milliseconds
    assert!((twap_start_delay % constants::twap_price_cap_window()) == 0, ENoneFullWindowTwapDelay);
    
    // Calculate the absolute step from PPM and initialization price
    // Use checked multiplication to avoid overflow
    let step_u128 = if (twap_cap_ppm > 0 && twap_initialization_price > (u128::max_value!() / (twap_cap_ppm as u128))) {
        // Would overflow, use max u64 as step
        (u64::max_value!() as u128)
    } else {
        twap_initialization_price * (twap_cap_ppm as u128) / (constants::ppm_denominator() as u128)
    };
    assert!(step_u128 <= (std::u64::max_value!() as u128), EStepOverflow);
    let mut twap_cap_step = step_u128 as u64;
    // Ensure step is at least 1 to avoid division by zero
    if (twap_cap_step == 0) {
        twap_cap_step = 1;
    };

    Oracle {
        id: object::new(ctx),
        last_price: twap_initialization_price,
        last_timestamp: 0, // set to current time when trading starts
        total_cumulative_price: 0,
        last_window_end_cumulative_price: 0,
        last_window_end: 0, // set to current time when trading starts
        last_window_twap: twap_initialization_price,
        twap_start_delay: twap_start_delay,
        twap_cap_step: twap_cap_step,
        market_start_time: option::none(), // nullable so that TWAP is not valid if not properly initialized
        twap_initialization_price: twap_initialization_price,
    }
}

// === Private Functions ===
fun one_step_cap_price_change(twap_base: u128, new_price: u128, twap_cap_step: u64): u128 {
    if (new_price > twap_base) {
        // Cap upward movement: min(new_price, saturating_add(twap_base, max_change))
        u128::min(new_price, math::saturating_add(twap_base, (twap_cap_step as u128)))
    } else {
        // Cap downward movement: max(new_price, saturating_sub(twap_base, max_change))
        u128::max(new_price, math::saturating_sub(twap_base, (twap_cap_step as u128)))
    }
}

// Called before swaps, LP events and before reading TWAP
public(package) fun write_observation(oracle: &mut Oracle, timestamp: u64, price: u128) {
    // Sanity time checks
    assert!(oracle.market_start_time.is_some(), EMarketNotStarted);
    let market_start_time_val = *oracle.market_start_time.borrow();
    assert!(timestamp >= oracle.last_timestamp, ETimestampRegression);

    let delay_threshold = market_start_time_val + oracle.twap_start_delay;
    // --- Case 0: No time has passed ---
    if (timestamp == oracle.last_timestamp) {
        // If last_price update is not needed here, just return.
        // twap_accumulate would also do nothing if called with 0 duration.
        return
    };

    // --- Case 1: Current observation interval is entirely BEFORE delay_threshold ---
    if (oracle.last_timestamp < delay_threshold && timestamp < delay_threshold) {
        twap_accumulate(oracle, timestamp, price);
        return
    };

    // --- Case 2: Current observation interval CROSSES (or starts at and goes beyond) delay_threshold ---
    if (oracle.last_timestamp <= delay_threshold && timestamp >= delay_threshold) {
        // Part A: Process segment up to delay_threshold.
        if (delay_threshold > oracle.last_timestamp) {
            twap_accumulate(oracle, delay_threshold, price);
        };

        // Part B: RESET accumulators and mark the true start of the accumulation period.
        oracle.total_cumulative_price = 0;
        oracle.last_window_end_cumulative_price = 0;
        oracle.last_window_end = delay_threshold;

        // Part C: Process segment from delay_threshold to current `timestamp`.
        // This uses the fresh accumulators.
        if (timestamp > delay_threshold) {
            // Ensure there's a duration for this segment
            // twap_accumulate will use oracle.last_timestamp (which is delay_threshold)
            twap_accumulate(oracle, timestamp, price);
        };
        return
    };

    // --- Case 3: Current observation interval is entirely AT or AFTER delay_threshold ---
    if (oracle.last_timestamp >= delay_threshold) {
        twap_accumulate(oracle, timestamp, price);
        return
    }
}

fun twap_accumulate(oracle: &mut Oracle, timestamp: u64, price: u128) {
    // --- Input Validation ---
    // Ensure timestamp is not regressing
    assert!(timestamp >= oracle.last_timestamp, ETimestampRegression);
    // Ensure initial state is consistent (last_timestamp should not be before the window end it relates to)
    // This is a pre-condition check, assuming the state was valid before this call.
    assert!(oracle.last_timestamp >= oracle.last_window_end, ETimestampRegression);

    // --- Handle Edge Case: No time passed ---
    let time_since_last_update = timestamp - oracle.last_timestamp;

    // --- Stage 1: Accumulate for the initial partial window segment ---
    // This segment starts at oracle.last_timestamp and ends at the first of:
    // 1. The next window boundary (relative to oracle.last_window_end).
    // 2. The final input timestamp.

    let diff_from_last_boundary = oracle.last_timestamp - oracle.last_window_end;
    let elapsed_in_current_segment = diff_from_last_boundary % constants::twap_price_cap_window();

    let time_to_next_boundary = constants::twap_price_cap_window() - elapsed_in_current_segment;

    let duration_stage1 = std::u64::min(
        time_to_next_boundary, // Limit by the time until the next window boundary
        time_since_last_update, // Limit by the total time available until the target timestamp
    );

    if (duration_stage1 > 0) {
        let end_timestamp_stage1 = oracle.last_timestamp + duration_stage1;
        intra_window_accumulation(
            oracle, // Passes mutable reference, state will be updated
            price,
            duration_stage1,
            end_timestamp_stage1, // This timestamp becomes the new oracle.last_timestamp
        );
        // After this call, oracle.last_timestamp is updated to end_timestamp_stage1.
        // If end_timestamp_stage1 hit a window boundary, oracle.last_window_end and TWAP state are also updated.
    };

    // --- Stage 2: Process all full windows that fit *after* Stage 1 ended ---
    // The starting point for these full windows is the current oracle.last_timestamp
    // (which is the end timestamp of the segment processed in Stage 1).

    let time_remaining_after_stage1 = timestamp - oracle.last_timestamp; // Use updated oracle.last_timestamp

    if (time_remaining_after_stage1 >= constants::twap_price_cap_window()) {
        let num_full_windows = time_remaining_after_stage1 / constants::twap_price_cap_window();

        // Calculate the end timestamp after processing these full windows.
        // Start from the *current* oracle.last_timestamp (end of Stage 1 segment).
        let end_timestamp_stage2 = oracle.last_timestamp + num_full_windows * constants::twap_price_cap_window();

        multi_full_window_accumulation(
            oracle, // Passes mutable reference, state will be updated
            price,
            num_full_windows,
            end_timestamp_stage2, // This timestamp becomes the new oracle.last_timestamp and oracle.last_window_end
        );
        // After this call, oracle.last_timestamp and oracle.last_window_end are updated to end_timestamp_stage2.
        // The oracle's TWAP state (last_window_twap, cumulative_price) is also updated for these full windows.
    };

    // --- Stage 3: Process any remaining partial window after Stage 2 ended ---
    // The starting point is the current oracle.last_timestamp
    // (which is the end timestamp of the segment processed in Stage 2, or Stage 1 if Stage 2 was skipped).

    let duration_stage3 = timestamp - oracle.last_timestamp; // Use updated oracle.last_timestamp

    // If duration_stage3 > 0, there is time left to accumulate up to the final timestamp.
    if (duration_stage3 > 0) {
        intra_window_accumulation(
            oracle, // Passes mutable reference, state will be updated
            price,
            duration_stage3,
            timestamp, // The end timestamp for this final segment is the target timestamp
        );
        // After this call, oracle.last_timestamp is updated to the final input timestamp.
        // If the final timestamp hits a window boundary, oracle.last_window_end and TWAP state are also updated.
    };
    assert!(oracle.last_timestamp == timestamp, EInternalTwapError); // Assuming an internal error code
}

fun intra_window_accumulation(
    oracle: &mut Oracle,
    price: u128,
    additional_time_to_include: u64,
    timestamp: u64,
) {
    let capped_price = one_step_cap_price_change(
        oracle.last_window_twap,
        price,
        oracle.twap_cap_step,
    );

    // Add accumulation for the partial period within the current (still open) window
    let scaled_price = (capped_price as u256);
    let price_contribution = scaled_price * (additional_time_to_include as u256);
    oracle.total_cumulative_price = oracle.total_cumulative_price + price_contribution;

    let time_since_last_window_end = timestamp - oracle.last_window_end;
    oracle.last_timestamp = timestamp;
    oracle.last_price = (scaled_price as u128);

    event::emit(PriceEvent {
        last_price: oracle.last_price,
    });

    if (time_since_last_window_end == constants::twap_price_cap_window()) {
        // Update last window data on window boundary
        oracle.last_window_end = timestamp;
        oracle.last_window_twap = (
            (
                (oracle.total_cumulative_price - oracle.last_window_end_cumulative_price) / (constants::twap_price_cap_window() as u256),
            ) as u128,
        );
        oracle.last_window_end_cumulative_price = oracle.total_cumulative_price
    }
}

fun multi_full_window_accumulation(
    oracle: &mut Oracle,
    price: u128,
    num_new_windows: u64, // N_W
    timestamp: u64,
) {
    // Notation: v_ = value, n_ = number/count, k_ = index, s_ = sum, g_ = gap
    // G_abs = |P - B|
    let g_abs: u128;
    if (price > oracle.last_window_twap) {
        g_abs = price - oracle.last_window_twap;
    } else {
        g_abs = oracle.last_window_twap - price;
    };

    let k_cap_idx_u128: u128;
    if (g_abs == 0) {
        k_cap_idx_u128 = 0;
    } else if (oracle.twap_cap_step == 0) {
        // If step is 0 (from very small PPM), treat as unlimited steps
        k_cap_idx_u128 = (u64::max_value!() as u128);
    } else {
        k_cap_idx_u128 = (g_abs - 1) / (oracle.twap_cap_step as u128) + 1;
    };

    let k_cap_idx: u64;
    if (k_cap_idx_u128 > (u64::max_value!() as u128)) {
        k_cap_idx = u64::max_value!();
    } else {
        k_cap_idx = k_cap_idx_u128 as u64;
    };

    let k_ramp_limit: u64;
    if (k_cap_idx == 0) {
        k_ramp_limit = 0;
    } else {
        k_ramp_limit = k_cap_idx - 1;
    };

    // N_ramp_terms = min(N_W, k_ramp_limit)
    let n_ramp_terms = std::u64::min(num_new_windows, k_ramp_limit); // n_ramp_terms is u64

    // V_ramp = \Delta_M * N_ramp_terms * (N_ramp_terms + 1) / 2
    let v_ramp: u128;
    if (n_ramp_terms == 0) {
        v_ramp = 0;
    } else {
        let nrt_u128 = n_ramp_terms as u128;
        let sum_indices_part: u128;
        // Calculate nrt_u128 * (nrt_u128 + 1) / 2 safely to avoid overflow.
        // Max nrt_u128 is std::u64::MAX (~2^64).
        // (nrt_u128/2) * (nrt_u128+1) OR ((nrt_u128+1)/2) * nrt_u128 will be ~2^63 * 2^64 = 2^127, which fits u128.
        if (nrt_u128 % 2 == 0) {
            sum_indices_part = (nrt_u128 / 2) * (nrt_u128 + 1);
        } else {
            sum_indices_part = ((nrt_u128 + 1) / 2) * nrt_u128;
        };

        // Check for overflow: delta_max_per_step * sum_indices_part
        if (
            sum_indices_part > 0 && (oracle.twap_cap_step as u128) > 0 && (oracle.twap_cap_step as u128) > u128::max_value!() / sum_indices_part
        ) {
            abort (EOverflowVRamp)
        };
        v_ramp = (oracle.twap_cap_step as u128) * sum_indices_part;
    };

    // V_flat = G_abs * (N_W - N_ramp_terms)
    let num_flat_terms = num_new_windows - n_ramp_terms; // u64
    let v_flat: u128;
    if (num_flat_terms == 0) {
        v_flat = 0;
    } else {
        let nft_u128 = num_flat_terms as u128;
        // Check for overflow: g_abs * nft_u128
        if (nft_u128 > 0 && g_abs > 0 && g_abs > u128::max_value!() / nft_u128) {
            abort (EOverflowVFlat)
        };
        v_flat = g_abs * nft_u128;
    };

    // S_dev_mag = V_ramp + V_flat
    // Check for overflow: v_ramp + v_flat
    if (v_ramp > u128::max_value!() - v_flat) {
        // Equivalent to v_ramp + v_flat > u128::max_value!()
        abort (EOverflowSDevMag)
    };
    let s_dev_mag = v_ramp + v_flat;

    // V_sum_prices = N_W * B + sign(P-B) * S_dev_mag
    let base_price_sum: u128;
    let nw_u128 = num_new_windows as u128;
    // Check for overflow: oracle.last_window_twap * nw_u128
    if (
        nw_u128 > 0 && oracle.last_window_twap > 0 && oracle.last_window_twap > u128::max_value!() / nw_u128
    ) {
        abort (EOverflowBasePriceSumFinal)
    };
    base_price_sum = oracle.last_window_twap * nw_u128;

    let v_sum_prices: u128;
    if (price >= oracle.last_window_twap) {
        // sign(P-B) is 0 or 1
        // Check for overflow: base_price_sum + s_dev_mag
        if (base_price_sum > u128::max_value!() - s_dev_mag) {
            abort (EOverflowVSumPricesAdd)
        };
        v_sum_prices = base_price_sum + s_dev_mag;
    } else {
        // sign(P-B) is -1
        // Since P'_i = B - dev_i, and we assume price (P) >= 0,
        // then P'_i >= 0 (as B - dev_i >= P >= 0).
        // So sum of P'_i (which is V_sum_prices) must be >= 0.
        // This also implies N_W * B >= S_dev_mag.
        // Thus, base_price_sum >= s_dev_mag, and subtraction will not underflow below zero.
        v_sum_prices = base_price_sum - s_dev_mag;
    };

    // P'_N_W = B + sign(P-B) * min(N_W * \Delta_M, G_abs)
    let p_n_w_effective: u128;

    // Calculate N_W * \Delta_M
    // delta_max_per_step is > 0 here. num_new_windows > 0.
    // No overflow possible: num_new_windows is u64, twap_cap_step is u64
    let nw_times_delta_m = (num_new_windows as u128) * (oracle.twap_cap_step as u128);

    let deviation_for_p_n_w = std::u128::min(nw_times_delta_m, g_abs);

    if (price >= oracle.last_window_twap) {
        p_n_w_effective = math::saturating_add(oracle.last_window_twap, deviation_for_p_n_w);
    } else {
        // price < oracle.last_window_twap
        p_n_w_effective = math::saturating_sub(oracle.last_window_twap, deviation_for_p_n_w);
    };

    oracle.last_timestamp = timestamp;
    oracle.last_window_end = timestamp;
    let cumulative_price_contribution = (v_sum_prices as u256) * (constants::twap_price_cap_window() as u256);
    oracle.last_window_end_cumulative_price =
        oracle.total_cumulative_price + cumulative_price_contribution;
    oracle.total_cumulative_price = oracle.total_cumulative_price + cumulative_price_contribution;
    oracle.last_price = p_n_w_effective;

    event::emit(PriceEvent {
        last_price: oracle.last_price,
    });

    oracle.last_window_twap = p_n_w_effective;
}

/// ARCHITECTURAL DECISION: Mutation-Required TWAP Oracle
/// 
/// This oracle REQUIRES write_observation() before get_twap() in the same transaction.
/// The assertion `current_time == oracle.last_timestamp` is INTENTIONAL.
/// 
/// Why this differs from read-only TWAP patterns:
/// - Stale prices are attack vectors, not features
/// - Interpolation adds complexity and manipulation surface  
/// - The AMM determines prices; the oracle just tracks them
/// - Every TWAP read MUST reflect current AMM state
/// 
/// This design makes it IMPOSSIBLE to:
/// ✗ Read stale/manipulated TWAPs
/// ✗ Forget to update before critical operations
/// ✗ Have price inconsistency within a transaction
/// 
/// This pattern differs from typical read-only oracles by design.
/// Serving stale TWAPs for "cleaner interfaces" is how protocols get exploited.
/// 
/// The AMM's get_twap() handles the update + read atomically. 
/// The oracle just validates freshness. This is correct.
public(package) fun get_twap(oracle: &Oracle, clock: &Clock): u128 {
    assert!(oracle.market_start_time.is_some(), EMarketNotStarted);
    let market_start_time_val = *oracle.market_start_time.borrow();
    let current_time = clock.timestamp_ms();

    // REQUIRED: Caller must have called write_observation() in this same transaction
    // This ensures TWAP is always fresh and prevents stale price exploitation
    assert!(current_time == oracle.last_timestamp, EStaleTwap);

    // Time checks
    assert!(oracle.last_timestamp != 0, ETimestampRegression);
    assert!(current_time - market_start_time_val >= oracle.twap_start_delay, ETwapNotStarted);
    assert!(current_time >= market_start_time_val, ETimestampRegression);

    // Calculate period
    let period = ( current_time - market_start_time_val) - oracle.twap_start_delay;
    assert!(period > 0, EZeroPeriod);

    // Calculate TWAP - dividing cumulative price by period gives average price
    // Safe cast: For reasonable token prices over max 7-day proposals, 
    // TWAP will be far below u128::MAX (even 10^18 price × 7 days / period ≈ 10^15)
    let twap = (oracle.total_cumulative_price) / (period as u256);

    (twap as u128)
}

public(package) fun set_oracle_start_time(oracle: &mut Oracle, market_start_time_param: u64) {
    // Prevent re-initialization
    assert!(oracle.market_start_time.is_none(), EMarketAlreadyStarted);

    oracle.market_start_time = option::some(market_start_time_param);
    oracle.last_window_end = market_start_time_param;
    oracle.last_timestamp = market_start_time_param;
}

// === View Functions ===
public fun last_price(oracle: &Oracle): u128 {
    oracle.last_price
}

public fun last_timestamp(oracle: &Oracle): u64 {
    oracle.last_timestamp
}

public fun config(oracle: &Oracle): (u64, u64) {
    (oracle.twap_start_delay, oracle.twap_cap_step)
}

public fun market_start_time(oracle: &Oracle): Option<u64> {
    oracle.market_start_time
}

public fun twap_initialization_price(oracle: &Oracle): u128 {
    oracle.twap_initialization_price
}

public fun total_cumulative_price(oracle: &Oracle): u256 {
    oracle.total_cumulative_price
}

public fun id(o: &Oracle): &UID {
    &o.id
}

// === Test Functions ===
#[test_only]
use std::debug;

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
        60_000, // twap_start_delay
        1000, // twap_cap_ppm (0.1% of initialization price)
        ctx,
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
    id.delete();
}

#[test_only]
public fun debug_get_window_twap(oracle: &Oracle): u128 {
    oracle.last_window_twap
}

#[test_only]
public fun is_twap_valid(oracle: &Oracle, min_period: u64, clock: &Clock): bool {
    let current_time = clock.timestamp_ms();
    current_time >= oracle.last_timestamp + min_period
}

#[test_only]
public fun debug_get_full_state(
    oracle: &Oracle,
): (
    u128, // last_price
    u64, // last_timestamp
    u256, // total_cumulative_price
    u256, // last_window_end_cumulative_price
    u64, // last_window_end
    u128, // last_window_twap
    Option<u64>, // market_start_time
    u128, // twap_initialization_price
    u64, // twap_start_delay
    u64, // twap_cap_step
) {
    (
        oracle.last_price,
        oracle.last_timestamp,
        oracle.total_cumulative_price,
        oracle.last_window_end_cumulative_price,
        oracle.last_window_end,
        oracle.last_window_twap,
        oracle.market_start_time,
        oracle.twap_initialization_price,
        oracle.twap_start_delay,
        oracle.twap_cap_step,
    )
}

#[test_only]
public fun set_last_timestamp_for_testing(oracle: &mut Oracle, new_last_timestamp: u64) {
    oracle.last_timestamp = new_last_timestamp;
}

#[test_only]
public fun set_last_window_end_for_testing(oracle: &mut Oracle, new_last_window_end: u64) {
    oracle.last_window_end = new_last_window_end;
}

#[test_only]
public fun set_last_window_twap_for_testing(oracle: &mut Oracle, new_last_window_twap: u128) {
    oracle.last_window_twap = new_last_window_twap;
}

#[test_only]
public fun set_cumulative_prices_for_testing(
    oracle: &mut Oracle,
    total_cumulative_price: u256,
    last_window_end_cumulative_price: u256,
) {
    oracle.total_cumulative_price = total_cumulative_price;
    oracle.last_window_end_cumulative_price = last_window_end_cumulative_price;
}

#[test_only]
public fun call_twap_accumulate_for_testing(oracle: &mut Oracle, timestamp: u64, price: u128) {
    twap_accumulate(oracle, timestamp, price);
}

#[test_only]
public fun get_last_window_end_cumulative_price_for_testing(oracle: &Oracle): u256 {
    oracle.last_window_end_cumulative_price
}

#[test_only]
public fun get_total_cumulative_price_for_testing(oracle: &Oracle): u256 {
    oracle.total_cumulative_price
}

#[test_only]
public fun get_last_window_end_for_testing(oracle: &Oracle): u64 {
    oracle.last_window_end
}

#[test_only]
public fun call_intra_window_accumulation_for_testing(
    oracle: &mut Oracle,
    price: u128,
    additional_time_to_include: u64,
    timestamp: u64,
) {
    intra_window_accumulation(
        oracle,
        price,
        additional_time_to_include,
        timestamp,
    );
}

#[test_only]
public fun call_multi_full_window_accumulation_for_testing(
    oracle: &mut Oracle,
    price: u128,
    num_new_windows: u64,
    timestamp: u64,
) {
    multi_full_window_accumulation(
        oracle,
        price,
        num_new_windows,
        timestamp,
    );
}
