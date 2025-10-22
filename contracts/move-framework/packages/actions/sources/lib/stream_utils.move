// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Common utilities for time-based streaming/vesting functionality.
/// Shared between vault streams and vesting modules to avoid duplication.
/// Provides reusable math helpers for vesting and stream modules.
/// - Vested/unvested split calculations for cancellations
///
/// This enables both vault streams and standalone vestings to have:
/// - Consistent mathematical accuracy
/// - Shared security validations
/// - Unified approach to time-based fund releases

module account_actions::stream_utils;

use std::u128;

// === Imports ===

// === Constants ===
//
// UPGRADABLE CONSTANT PATTERN:
// These constants are defined here in the framework for backwards compatibility,
// but the canonical source is futarchy_one_shot_utils::constants.
//
// To upgrade these values:
// 1. Update futarchy_one_shot_utils::constants::max_beneficiaries()
// 2. Deploy new version of futarchy_one_shot_utils
// 3. All dependent packages inherit new limits on next deployment
//
// This pattern allows system-wide configuration updates without modifying
// the framework package, enabling DAOs to adjust limits via governance.

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
public fun check_withdrawal_limit(amount: u64, max_per_withdrawal: u64): bool {
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
    cliff_time_opt: &Option<u64>,
): u64 {
    let vested = if (cliff_time_opt.is_some()) {
        calculate_vested_with_cliff(
            total_amount,
            start_time,
            end_time,
            *cliff_time_opt.borrow(),
            current_time,
        )
    } else {
        calculate_linear_vested(
            total_amount,
            start_time,
            end_time,
            current_time,
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
    cliff_time_opt: &Option<u64>,
): (u64, u64, u64) {
    let vested = if (cliff_time_opt.is_some()) {
        calculate_vested_with_cliff(
            total_amount,
            start_time,
            end_time,
            *cliff_time_opt.borrow(),
            current_time,
        )
    } else {
        calculate_linear_vested(
            total_amount,
            start_time,
            end_time,
            current_time,
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

// === Expiry Helpers ===

/// Check if stream/vesting has expired
public fun is_expired(expiry_opt: &Option<u64>, current_time: u64): bool {
    if (expiry_opt.is_none()) {
        false // No expiry
    } else {
        current_time >= *expiry_opt.borrow()
    }
}

/// Validate expiry is in the future
public fun validate_expiry(current_time: u64, expiry_timestamp: u64): bool {
    expiry_timestamp > current_time
}

// === State Check Helpers ===

/// Check if claiming is allowed (not expired)
public fun can_claim(
    expiry_opt: &Option<u64>,
    current_time: u64,
): bool {
    !is_expired(expiry_opt, current_time)
}

/// Calculate next vesting timestamp
public fun next_vesting_time(
    start_time: u64,
    end_time: u64,
    cliff_time_opt: &Option<u64>,
    expiry_opt: &Option<u64>,
    current_time: u64,
): Option<u64> {
    // Check expiry first
    if (is_expired(expiry_opt, current_time)) {
        return std::option::none()
    };

    // If before cliff, next vest is cliff time
    if (cliff_time_opt.is_some()) {
        let cliff = *cliff_time_opt.borrow();
        if (current_time < cliff) {
            return std::option::some(cliff)
        };
    };

    // If after end, no more vesting
    if (current_time >= end_time) {
        return std::option::none()
    };

    // Linear vesting - always vesting now
    std::option::some(current_time)
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

