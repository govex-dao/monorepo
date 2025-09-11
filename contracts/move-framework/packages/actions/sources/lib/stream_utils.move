/// Common utilities for time-based streaming/vesting functionality.
/// Shared between vault streams and vesting modules to avoid duplication.
///
/// === Fork Addition (BSL 1.1 Licensed) ===
/// Created to consolidate common logic for streaming/vesting calculations.
/// This module was added to the original Move framework to:
/// 1. Eliminate code duplication between vault.move and vesting.move
/// 2. Provide consistent vesting math across all time-based payment features
/// 3. Enable future modules to leverage tested streaming calculations
/// 4. Support advanced features like cliff periods, pausing, and rate limiting
///
/// Key shared functionality:
/// - Linear vesting calculations with overflow protection
/// - Cliff period support for delayed vesting starts
/// - Pause duration tracking for accurate vesting adjustments
/// - Rate limiting checks for withdrawal protection
/// - Effective time calculations accounting for pauses
/// - Vested/unvested split calculations for cancellations
///
/// This enables both vault streams and standalone vestings to have:
/// - Consistent mathematical accuracy
/// - Shared security validations
/// - Unified approach to time-based fund releases

module account_actions::stream_utils;

// === Imports ===

use std::u128;

// === Constants ===

public fun max_beneficiaries(): u64 { 100 }

// === Vesting Calculation Functions ===

/// Calculates linearly vested amount based on time elapsed
public fun calculate_linear_vested(
    total_amount: u64,
    start_time: u64,
    end_time: u64,
    current_time: u64,
): u64 {
    if (current_time < start_time) return 0;
    if (current_time >= end_time) return total_amount;
    
    let duration = end_time - start_time;
    let elapsed = current_time - start_time;
    
    // Use u128 to prevent overflow in multiplication
    let vested = (total_amount as u128) * (elapsed as u128) / (duration as u128);
    (vested as u64)
}

/// Calculates vested amount with cliff period
public fun calculate_vested_with_cliff(
    total_amount: u64,
    start_time: u64,
    end_time: u64,
    cliff_time: u64,
    current_time: u64,
): u64 {
    // Nothing vests before cliff
    if (current_time < cliff_time) return 0;
    
    // After cliff, calculate linear vesting
    calculate_linear_vested(total_amount, start_time, end_time, current_time)
}

/// Calculates effective time accounting for pause duration
public fun calculate_effective_time(
    current_time: u64,
    end_time: u64,
    paused_duration: u64,
): u64 {
    let effective_end = end_time + paused_duration;
    if (current_time > effective_end) {
        effective_end
    } else {
        current_time
    }
}

/// Validates stream/vesting parameters
public fun validate_time_parameters(
    start_time: u64,
    end_time: u64,
    cliff_time_opt: &Option<u64>,
    current_time: u64,
): bool {
    // End must be after start
    if (end_time <= start_time) return false;
    
    // Start must be in future or present
    if (start_time < current_time) return false;
    
    // If cliff exists, must be between start and end
    if (cliff_time_opt.is_some()) {
        let cliff = *cliff_time_opt.borrow();
        if (cliff < start_time || cliff > end_time) return false;
    };
    
    true
}

/// Calculates pause duration between two timestamps
public fun calculate_pause_duration(
    paused_at: u64,
    resumed_at: u64,
): u64 {
    if (resumed_at > paused_at) {
        resumed_at - paused_at
    } else {
        0
    }
}

/// Checks if withdrawal respects rate limiting
public fun check_rate_limit(
    last_withdrawal_time: u64,
    min_interval_ms: u64,
    current_time: u64,
): bool {
    if (min_interval_ms == 0 || last_withdrawal_time == 0) {
        true
    } else {
        current_time >= last_withdrawal_time + min_interval_ms
    }
}

/// Checks if withdrawal amount respects maximum limit
public fun check_withdrawal_limit(
    amount: u64,
    max_per_withdrawal: u64,
): bool {
    if (max_per_withdrawal == 0) {
        true
    } else {
        amount <= max_per_withdrawal
    }
}

/// Calculates available amount to claim
public fun calculate_claimable(
    total_amount: u64,
    claimed_amount: u64,
    start_time: u64,
    end_time: u64,
    current_time: u64,
    paused_duration: u64,
    cliff_time_opt: &Option<u64>,
): u64 {
    let effective_time = calculate_effective_time(
        current_time, 
        end_time, 
        paused_duration
    );
    
    let vested = if (cliff_time_opt.is_some()) {
        calculate_vested_with_cliff(
            total_amount,
            start_time,
            end_time + paused_duration,
            *cliff_time_opt.borrow(),
            effective_time
        )
    } else {
        calculate_linear_vested(
            total_amount,
            start_time,
            end_time + paused_duration,
            effective_time
        )
    };
    
    if (vested > claimed_amount) {
        vested - claimed_amount
    } else {
        0
    }
}

/// Splits vested and unvested amounts for cancellation
public fun split_vested_unvested(
    total_amount: u64,
    claimed_amount: u64,
    balance_remaining: u64,
    start_time: u64,
    end_time: u64,
    current_time: u64,
    paused_duration: u64,
    cliff_time_opt: &Option<u64>,
): (u64, u64, u64) {
    let effective_time = calculate_effective_time(
        current_time,
        end_time,
        paused_duration
    );
    
    let vested = if (cliff_time_opt.is_some()) {
        calculate_vested_with_cliff(
            total_amount,
            start_time,
            end_time + paused_duration,
            *cliff_time_opt.borrow(),
            effective_time
        )
    } else {
        calculate_linear_vested(
            total_amount,
            start_time,
            end_time + paused_duration,
            effective_time
        )
    };
    
    // Calculate amounts
    let unvested_claimed = if (claimed_amount > vested) {
        claimed_amount - vested
    } else {
        0
    };
    
    let to_pay_beneficiary = if (vested > claimed_amount) {
        let owed = vested - claimed_amount;
        if (owed > balance_remaining) {
            balance_remaining
        } else {
            owed
        }
    } else {
        0
    };
    
    let to_refund = if (balance_remaining > to_pay_beneficiary) {
        balance_remaining - to_pay_beneficiary
    } else {
        0
    };
    
    (to_pay_beneficiary, to_refund, unvested_claimed)
}

// === Test Helpers ===

#[test_only]
public fun test_linear_vesting() {
    // Test before start
    assert!(calculate_linear_vested(1000, 100, 200, 50) == 0);
    
    // Test at start
    assert!(calculate_linear_vested(1000, 100, 200, 100) == 0);
    
    // Test halfway
    assert!(calculate_linear_vested(1000, 100, 200, 150) == 500);
    
    // Test at end
    assert!(calculate_linear_vested(1000, 100, 200, 200) == 1000);
    
    // Test after end
    assert!(calculate_linear_vested(1000, 100, 200, 250) == 1000);
}

#[test_only]
public fun test_cliff_vesting() {
    // Test before cliff
    assert!(calculate_vested_with_cliff(1000, 100, 200, 130, 120) == 0);
    
    // Test at cliff
    assert!(calculate_vested_with_cliff(1000, 100, 200, 130, 130) == 300);
    
    // Test after cliff
    assert!(calculate_vested_with_cliff(1000, 100, 200, 130, 150) == 500);
}

#[test_only]
public fun test_effective_time() {
    // Test no pause
    assert!(calculate_effective_time(150, 200, 0) == 150);
    
    // Test with pause, before adjusted end
    assert!(calculate_effective_time(150, 200, 50) == 150);
    
    // Test with pause, after adjusted end
    assert!(calculate_effective_time(300, 200, 50) == 250);
}