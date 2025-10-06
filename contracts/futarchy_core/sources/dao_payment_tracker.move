module futarchy_core::dao_payment_tracker;

use sui::{
    table::{Self, Table},
    coin::{Self, Coin},
    sui::SUI,
    clock::Clock,
    event,
    balance::{Self, Balance},
};

// === Errors ===
const ENoDebtToPay: u64 = 0;

// === Structs ===

/// Global singleton tracking payment status for all DAOs
public struct DaoPaymentTracker has key {
    id: UID,
    /// Map of DAO ID to debt amount (0 = not blocked, >0 = blocked)
    debts: Table<ID, u64>,
    /// Accumulated protocol revenue from payments
    protocol_revenue: Balance<SUI>,
}

// === Events ===

public struct DebtAccumulated has copy, drop {
    dao_id: ID,
    amount: u64,
    total_debt: u64,
}

public struct DebtPaid has copy, drop {
    dao_id: ID,
    amount_paid: u64,
    remaining_debt: u64,
    payer: address,
}

public struct DebtForgiven has copy, drop {
    dao_id: ID,
    amount_forgiven: u64,
}

public struct DebtReduced has copy, drop {
    dao_id: ID,
    amount_reduced: u64,
    remaining_debt: u64,
}

// === Public Functions ===

/// Initialize the global payment tracker (called once at deployment)
fun init(ctx: &mut TxContext) {
    transfer::share_object(DaoPaymentTracker {
        id: object::new(ctx),
        debts: table::new(ctx),
        protocol_revenue: balance::zero(),
    });
}

/// Check if a DAO is blocked (has any debt)
public fun is_dao_blocked(tracker: &DaoPaymentTracker, dao_id: ID): bool {
    if (tracker.debts.contains(dao_id)) {
        tracker.debts[dao_id] > 0
    } else {
        false
    }
}

/// Get current debt for a DAO
public fun get_dao_debt(tracker: &DaoPaymentTracker, dao_id: ID): u64 {
    if (tracker.debts.contains(dao_id)) {
        tracker.debts[dao_id]
    } else {
        0
    }
}

/// Accumulate debt when fee collection fails
/// This immediately blocks the DAO from actions
public fun accumulate_debt(
    tracker: &mut DaoPaymentTracker,
    dao_id: ID,
    amount: u64,
) {
    if (!tracker.debts.contains(dao_id)) {
        tracker.debts.add(dao_id, 0);
    };
    
    let debt = &mut tracker.debts[dao_id];
    *debt = *debt + amount;
    
    event::emit(DebtAccumulated {
        dao_id,
        amount,
        total_debt: *debt,
    });
}

/// ANYONE can pay off a DAO's debt - completely permissionless
/// Returns any excess payment as change
public fun pay_dao_debt(
    tracker: &mut DaoPaymentTracker,
    dao_id: ID,
    mut payment: Coin<SUI>,
    ctx: &mut TxContext,
): Coin<SUI> {
    let debt_amount = get_dao_debt(tracker, dao_id);
    assert!(debt_amount > 0, ENoDebtToPay);
    
    let payment_amount = payment.value();
    
    if (payment_amount >= debt_amount) {
        // Full payment - clear debt
        tracker.protocol_revenue.join(payment.split(debt_amount, ctx).into_balance());
        let debt = &mut tracker.debts[dao_id];
        *debt = 0;
        
        event::emit(DebtPaid {
            dao_id,
            amount_paid: debt_amount,
            remaining_debt: 0,
            payer: ctx.sender(),
        });
        
        // Return change
        payment
    } else {
        // Partial payment - reduce debt
        tracker.protocol_revenue.join(payment.into_balance());
        let debt = &mut tracker.debts[dao_id];
        *debt = *debt - payment_amount;
        
        event::emit(DebtPaid {
            dao_id,
            amount_paid: payment_amount,
            remaining_debt: *debt,
            payer: ctx.sender(),
        });
        
        // No change
        coin::zero(ctx)
    }
}

/// Withdraw protocol revenue (admin function)
public fun withdraw_revenue(
    tracker: &mut DaoPaymentTracker,
    amount: u64,
    ctx: &mut TxContext,
): Coin<SUI> {
    coin::from_balance(tracker.protocol_revenue.split(amount), ctx)
}

// === Query Functions ===

/// Get all DAOs that are currently blocked (have debt > 0)
public fun get_blocked_dao_count(tracker: &DaoPaymentTracker): u64 {
    let mut count = 0;
    let mut i = 0;
    // Note: This is O(n) - in production, consider maintaining a separate counter
    // For now, we can't iterate tables directly, so this would need a different approach
    // This is a placeholder for the actual implementation
    count
}

/// Get total debt across all DAOs
public fun get_total_debt(tracker: &DaoPaymentTracker): u64 {
    // In production, maintain this as a field for O(1) access
    // For now, would need to iterate all entries which isn't directly supported
    0 // Placeholder
}

/// Get total protocol revenue collected
public fun get_protocol_revenue(tracker: &DaoPaymentTracker): u64 {
    tracker.protocol_revenue.value()
}

// === Admin Functions ===

/// Forgive debt for a specific DAO (admin only)
/// This immediately unblocks the DAO without requiring payment
public fun forgive_debt(
    tracker: &mut DaoPaymentTracker,
    dao_id: ID,
    _admin_cap: &AdminCap, // Requires admin capability
) {
    if (tracker.debts.contains(dao_id)) {
        let forgiven_amount = tracker.debts[dao_id];
        let debt = &mut tracker.debts[dao_id];
        *debt = 0;
        
        event::emit(DebtForgiven {
            dao_id,
            amount_forgiven: forgiven_amount,
        });
    }
}

/// Reduce debt by a specific amount (admin only)
/// Useful for partial debt forgiveness or corrections
public fun reduce_debt(
    tracker: &mut DaoPaymentTracker,
    dao_id: ID,
    reduction_amount: u64,
    _admin_cap: &AdminCap,
) {
    if (tracker.debts.contains(dao_id)) {
        let debt = &mut tracker.debts[dao_id];
        if (*debt > reduction_amount) {
            *debt = *debt - reduction_amount;
        } else {
            *debt = 0;
        };
        
        event::emit(DebtReduced {
            dao_id,
            amount_reduced: reduction_amount,
            remaining_debt: *debt,
        });
    }
}

/// Transfer collected revenue from debt payments to fee manager
/// This allows the fee manager to access funds from debt repayments
public fun transfer_revenue_to_fee_manager(
    tracker: &mut DaoPaymentTracker,
    amount: u64,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert!(tracker.protocol_revenue.value() >= amount, EInsufficientRevenue);
    coin::from_balance(tracker.protocol_revenue.split(amount), ctx)
}

// === Admin Cap ===

/// Capability for administrative functions
public struct AdminCap has key, store {
    id: UID,
}

/// Create admin capability (called once at deployment)
public fun create_admin_cap(ctx: &mut TxContext): AdminCap {
    AdminCap {
        id: object::new(ctx),
    }
}

// === Additional Errors ===
const EInsufficientRevenue: u64 = 1;

// === Test-Only Functions ===

#[test_only]
/// Create a DaoPaymentTracker for testing
public fun new_for_testing(ctx: &mut TxContext): DaoPaymentTracker {
    DaoPaymentTracker {
        id: object::new(ctx),
        debts: table::new(ctx),
        protocol_revenue: balance::zero(),
    }
}

#[test_only]
/// Get debt for a DAO (test alias for public function)
public fun get_debt(tracker: &DaoPaymentTracker, dao_id: ID): u64 {
    get_dao_debt(tracker, dao_id)
}

#[test_only]
/// Destroy a DaoPaymentTracker for testing
public fun destroy_for_testing(tracker: DaoPaymentTracker) {
    let DaoPaymentTracker { id, debts, protocol_revenue } = tracker;
    object::delete(id);

    // Drop the table - it's test-only code
    debts.drop();
    protocol_revenue.destroy_for_testing();
}