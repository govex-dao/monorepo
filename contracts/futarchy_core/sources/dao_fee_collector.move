module futarchy_core::dao_fee_collector;

use sui::{
    coin::{Self, Coin},
    sui::SUI,
    clock::Clock,
    event,
};
use futarchy_core::dao_payment_tracker::{Self, DaoPaymentTracker};

// === Errors ===
const EInsufficientTreasuryBalance: u64 = 0;

// === Events ===

public struct FeeCollected has copy, drop {
    dao_id: ID,
    amount: u64,
    timestamp: u64,
}

public struct FeeCollectionFailed has copy, drop {
    dao_id: ID,
    amount_requested: u64,
    amount_available: u64,
    debt_accumulated: u64,
    timestamp: u64,
}

// === Public Functions ===

/// Try to collect a fee from a DAO's treasury
/// If the treasury has insufficient funds, accumulate debt and block the DAO
/// Returns (success, fee_coin, remaining_funds)
public fun try_collect_fee(
    payment_tracker: &mut DaoPaymentTracker,
    dao_id: ID,
    fee_amount: u64,
    mut available_funds: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
): (bool, Coin<SUI>, Coin<SUI>) {
    let available_amount = available_funds.value();
    
    if (available_amount >= fee_amount) {
        // Sufficient funds - collect the fee
        let fee_coin = available_funds.split(fee_amount, ctx);
        
        event::emit(FeeCollected {
            dao_id,
            amount: fee_amount,
            timestamp: clock.timestamp_ms(),
        });
        
        // Return success, the fee coin, and remaining funds
        (true, fee_coin, available_funds)
    } else {
        // Insufficient funds - accumulate debt
        let debt_amount = fee_amount - available_amount;
        dao_payment_tracker::accumulate_debt(payment_tracker, dao_id, debt_amount);
        
        event::emit(FeeCollectionFailed {
            dao_id,
            amount_requested: fee_amount,
            amount_available: available_amount,
            debt_accumulated: debt_amount,
            timestamp: clock.timestamp_ms(),
        });
        
        // Return failure, all available funds as partial payment, and empty coin
        (false, available_funds, coin::zero(ctx))
    }
}

/// Collect a fee or accumulate debt if insufficient funds
/// This is a convenience function that handles the full flow
/// Returns (fee_collected, remaining_funds)
public fun collect_fee_or_block(
    payment_tracker: &mut DaoPaymentTracker,
    dao_id: ID,
    fee_amount: u64,
    available_funds: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<SUI>, Coin<SUI>) {
    let (success, fee_coin, remaining) = try_collect_fee(
        payment_tracker,
        dao_id,
        fee_amount,
        available_funds,
        clock,
        ctx
    );
    
    // If collection failed, the DAO is now blocked
    // Return the fee coin (partial or full) and any remaining funds
    (fee_coin, remaining)
}

/// Check if a DAO can afford a fee without actually collecting it
public fun can_afford_fee(
    available_balance: u64,
    fee_amount: u64,
): bool {
    available_balance >= fee_amount
}

/// Collect fee from DAO treasury with automatic debt handling
/// If the provided funds are insufficient, debt is accumulated and DAO is blocked
public fun collect_fee_with_debt_handling(
    payment_tracker: &mut DaoPaymentTracker,
    dao_id: ID,
    required_fee: u64,
    mut payment: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<SUI>, Coin<SUI>) {
    let payment_amount = payment.value();
    
    if (payment_amount >= required_fee) {
        // Full payment available
        let fee = payment.split(required_fee, ctx);
        
        event::emit(FeeCollected {
            dao_id,
            amount: required_fee,
            timestamp: clock.timestamp_ms(),
        });
        
        (fee, payment) // Return fee and change
    } else {
        // Partial payment - accumulate debt for the difference
        let debt_amount = required_fee - payment_amount;
        dao_payment_tracker::accumulate_debt(payment_tracker, dao_id, debt_amount);
        
        event::emit(FeeCollectionFailed {
            dao_id,
            amount_requested: required_fee,
            amount_available: payment_amount,
            debt_accumulated: debt_amount,
            timestamp: clock.timestamp_ms(),
        });
        
        // Return all available funds as fee, no change
        (payment, coin::zero(ctx))
    }
}