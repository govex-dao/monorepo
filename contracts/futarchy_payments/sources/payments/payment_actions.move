/// Payment action structs with proper BCS serialization support
module futarchy_payments::payment_actions;

use std::string::String;
use std::option::Option;
use sui::object::ID;

// ============= Payment/Stream Actions =============

/// Action to create any type of payment (stream, recurring, etc.)
public struct CreatePaymentAction<phantom CoinType> has store, drop, copy {
    payment_type: u8,
    source_mode: u8,
    recipient: address,
    amount: u64,
    start_timestamp: u64,
    end_timestamp: u64,
    interval_or_cliff: Option<u64>,
    total_payments: u64,
    cancellable: bool,
    description: String,
    max_per_withdrawal: u64,
    min_interval_ms: u64,
    max_beneficiaries: u64,
}

/// Constructor for CreatePaymentAction
public fun new_create_payment_action<CoinType>(
    payment_type: u8,
    source_mode: u8,
    recipient: address,
    amount: u64,
    start_timestamp: u64,
    end_timestamp: u64,
    interval_or_cliff: Option<u64>,
    total_payments: u64,
    cancellable: bool,
    description: String,
    max_per_withdrawal: u64,
    min_interval_ms: u64,
    max_beneficiaries: u64,
): CreatePaymentAction<CoinType> {
    CreatePaymentAction {
        payment_type,
        source_mode,
        recipient,
        amount,
        start_timestamp,
        end_timestamp,
        interval_or_cliff,
        total_payments,
        cancellable,
        description,
        max_per_withdrawal,
        min_interval_ms,
        max_beneficiaries,
    }
}

// Getters for CreatePaymentAction
public fun payment_type<CoinType>(action: &CreatePaymentAction<CoinType>): u8 { action.payment_type }
public fun source_mode<CoinType>(action: &CreatePaymentAction<CoinType>): u8 { action.source_mode }
public fun recipient<CoinType>(action: &CreatePaymentAction<CoinType>): address { action.recipient }
public fun amount<CoinType>(action: &CreatePaymentAction<CoinType>): u64 { action.amount }
public fun start_timestamp<CoinType>(action: &CreatePaymentAction<CoinType>): u64 { action.start_timestamp }
public fun end_timestamp<CoinType>(action: &CreatePaymentAction<CoinType>): u64 { action.end_timestamp }
public fun interval_or_cliff<CoinType>(action: &CreatePaymentAction<CoinType>): Option<u64> { action.interval_or_cliff }
public fun total_payments<CoinType>(action: &CreatePaymentAction<CoinType>): u64 { action.total_payments }
public fun cancellable<CoinType>(action: &CreatePaymentAction<CoinType>): bool { action.cancellable }
public fun description<CoinType>(action: &CreatePaymentAction<CoinType>): &String { &action.description }
public fun max_per_withdrawal<CoinType>(action: &CreatePaymentAction<CoinType>): u64 { action.max_per_withdrawal }
public fun min_interval_ms<CoinType>(action: &CreatePaymentAction<CoinType>): u64 { action.min_interval_ms }
public fun max_beneficiaries<CoinType>(action: &CreatePaymentAction<CoinType>): u64 { action.max_beneficiaries }

/// Action to cancel a payment
public struct CancelPaymentAction has store, drop, copy {
    payment_id: String,
}

public fun new_cancel_payment_action(payment_id: String): CancelPaymentAction {
    CancelPaymentAction { payment_id }
}

public fun payment_id(action: &CancelPaymentAction): &String { &action.payment_id }

/// Destruction functions for serialize-then-destroy pattern
public fun destroy_create_payment_action<CoinType>(action: CreatePaymentAction<CoinType>) {
    let CreatePaymentAction {
        payment_type: _,
        source_mode: _,
        recipient: _,
        amount: _,
        start_timestamp: _,
        end_timestamp: _,
        interval_or_cliff: _,
        total_payments: _,
        cancellable: _,
        description: _,
        max_per_withdrawal: _,
        min_interval_ms: _,
        max_beneficiaries: _,
    } = action;
}

public fun destroy_cancel_payment_action(action: CancelPaymentAction) {
    let CancelPaymentAction { payment_id: _ } = action;
}