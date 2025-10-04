/// Owned fee state stored in Account managed data
/// This provides zero-contention fee checking for multisig operations
///
/// Architecture:
/// - FeeState (owned) = Fast checking on every operation
/// - FeeManager (shared) = Slow collection once per month
///
/// This separates high-frequency reads (owned) from low-frequency writes (shared)
module futarchy_multisig::fee_state;

use sui::clock::Clock;
use account_protocol::account::{Self, Account};
use futarchy_multisig::weighted_multisig::WeightedMultisig;
use futarchy_core::version;

// === Constants ===
const MONTHLY_FEE_PERIOD_MS: u64 = 2_592_000_000; // 30 days
const GRACE_PERIOD_MS: u64 = 432_000_000; // 5 days grace period after fee due

// === Errors ===
const EFeeOverdue: u64 = 0;

// === Structs ===

/// Key for storing FeeState in Account managed data
public struct FeeStateKey has copy, drop, store {}

/// Owned fee state - stored in Account, zero contention
/// Updated monthly during payment, checked on every operation
public struct FeeState has store {
    /// When fees were last paid (any coin type)
    last_payment_ms: u64,
    /// Grace period end - multisig pauses after this time
    paid_until_ms: u64,
}

// === Public Functions ===

/// Initialize fee state for new multisig (called during creation)
/// Sets initial grace period so new multisigs aren't immediately paused
public fun init_fee_state(
    account: &mut Account<WeightedMultisig>,
    clock: &Clock,
) {
    let current_time = clock.timestamp_ms();
    let state = FeeState {
        last_payment_ms: current_time,
        paid_until_ms: current_time + MONTHLY_FEE_PERIOD_MS + GRACE_PERIOD_MS,
    };

    account::add_managed_data(
        account,
        FeeStateKey {},
        state,
        version::current()
    );
}

/// Assert fees are current before allowing operations
/// ZERO shared object access - instant check!
public fun assert_fees_current(
    account: &Account<WeightedMultisig>,
    clock: &Clock,
) {
    let state = account::borrow_managed_data<
        WeightedMultisig,
        FeeStateKey,
        FeeState
    >(account, FeeStateKey {}, version::current());

    assert!(clock.timestamp_ms() <= state.paid_until_ms, EFeeOverdue);
}

/// Update fee state after successful payment
/// Called by fee collection functions after taking payment
/// Extends grace period based on periods paid
public(package) fun mark_fees_paid(
    account: &mut Account<WeightedMultisig>,
    periods_paid: u64,
    clock: &Clock,
) {
    let state = account::borrow_managed_data_mut<
        WeightedMultisig,
        FeeStateKey,
        FeeState
    >(account, FeeStateKey {}, version::current());

    let current_time = clock.timestamp_ms();
    state.last_payment_ms = current_time;

    // Extend grace period by periods paid + buffer
    // If you pay 3 months, you're good for 3 months + 5 days
    let extension_ms = periods_paid * MONTHLY_FEE_PERIOD_MS + GRACE_PERIOD_MS;
    state.paid_until_ms = current_time + extension_ms;
}

/// Check if fees are current (view function)
public fun are_fees_current(
    account: &Account<WeightedMultisig>,
    clock: &Clock,
): bool {
    if (!has_fee_state(account)) {
        // Legacy multisig without fee state - assume current
        return true
    };

    let state = account::borrow_managed_data<
        WeightedMultisig,
        FeeStateKey,
        FeeState
    >(account, FeeStateKey {}, version::current());

    clock.timestamp_ms() <= state.paid_until_ms
}

/// Check if fee state exists (for migration)
public fun has_fee_state(account: &Account<WeightedMultisig>): bool {
    account::has_managed_data<WeightedMultisig, FeeStateKey>(
        account,
        FeeStateKey {}
    )
}

/// Get last payment timestamp (view function)
public fun last_payment_ms(account: &Account<WeightedMultisig>): u64 {
    if (!has_fee_state(account)) {
        return 0
    };

    let state = account::borrow_managed_data<
        WeightedMultisig,
        FeeStateKey,
        FeeState
    >(account, FeeStateKey {}, version::current());

    state.last_payment_ms
}

/// Get paid until timestamp (view function)
public fun paid_until_ms(account: &Account<WeightedMultisig>): u64 {
    if (!has_fee_state(account)) {
        return 0
    };

    let state = account::borrow_managed_data<
        WeightedMultisig,
        FeeStateKey,
        FeeState
    >(account, FeeStateKey {}, version::current());

    state.paid_until_ms
}

/// Calculate days until fee payment required
public fun days_until_due(account: &Account<WeightedMultisig>, clock: &Clock): u64 {
    if (!has_fee_state(account)) {
        return 999999 // Legacy - effectively never due
    };

    let state = account::borrow_managed_data<
        WeightedMultisig,
        FeeStateKey,
        FeeState
    >(account, FeeStateKey {}, version::current());

    let current_time = clock.timestamp_ms();

    if (current_time >= state.paid_until_ms) {
        return 0 // Already overdue
    };

    let time_remaining_ms = state.paid_until_ms - current_time;
    let days_remaining = time_remaining_ms / 86_400_000; // ms to days

    days_remaining
}
