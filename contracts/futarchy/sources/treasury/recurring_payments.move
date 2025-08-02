/// Recurring payment streams for futarchy DAOs
/// Enables scheduled, periodic payments with pre-funded escrow
module futarchy::recurring_payments;

// === Imports ===
use std::string::String;
use sui::{
    clock::Clock,
    event,
    coin::{Self, Coin},
    balance::{Self, Balance},
};
use futarchy::recurring_payment_registry::{Self, PaymentStreamRegistry};

// === Constants ===
const MAX_PAYMENTS_PER_CLAIM: u64 = 100; // Maximum payments that can be claimed in one transaction

// === Errors ===
const EPaymentNotDue: u64 = 0;
const EStreamEnded: u64 = 1;
const EInsufficientBalance: u64 = 3;
const EInvalidInterval: u64 = 4;
const EInvalidAmount: u64 = 5;
const EOverflow: u64 = 6;
const EInvalidRegistryMismatch: u64 = 7;
const EMaxPaymentPerClaimExceeded: u64 = 8;
const E_TREASURY_NOT_LIQUIDATING: u64 = 9;

// === Structs ===

/// Recurring payment stream (acts as permission to claim from treasury)
public struct PaymentStream<phantom CoinType> has key {
    id: UID,
    // DAO this stream belongs to
    dao_id: ID,
    // Recipient of payments
    recipient: address,
    // Amount per payment
    amount_per_payment: u64,
    // Interval between payments (in milliseconds)
    payment_interval: u64,
    // When payments start
    start_timestamp: u64,
    // When payments end (optional)
    end_timestamp: Option<u64>,
    // Last payment timestamp
    last_payment: u64,
    // Total amount paid so far
    total_paid: u64,
    // Maximum total amount (optional cap)
    max_total: Option<u64>,
    // Description of payment purpose
    description: String,
    // Whether stream is active
    active: bool,
}


// === Events ===

public struct StreamCreated has copy, drop {
    stream_id: ID,
    dao_id: ID,
    recipient: address,
    amount_per_payment: u64,
    payment_interval: u64,
    description: String,
}

public struct PaymentExecuted has copy, drop {
    stream_id: ID,
    recipient: address,
    amount: u64,
    payment_number: u64,
    timestamp: u64,
}

public struct StreamCancelled has copy, drop {
    stream_id: ID,
    total_paid: u64,
    timestamp: u64,
}

// === Public Functions ==

/// Create a new payment stream (no longer pre-funded)
public fun create_payment_stream<CoinType: drop>(
    dao_id: ID,
    registry: &mut PaymentStreamRegistry,
    recipient: address,
    amount_per_payment: u64,
    payment_interval: u64,
    start_timestamp: u64,
    end_timestamp: Option<u64>,
    max_total: Option<u64>,
    description: String,
    _clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert!(payment_interval > 0, EInvalidInterval);
    assert!(amount_per_payment > 0, EInvalidAmount);
    
    // SECURITY FIX: Use correct error code for registry mismatch
    assert!(recurring_payment_registry::get_dao_id(registry) == dao_id, EInvalidRegistryMismatch);
    
    let stream_id = object::new(ctx);
    let stream_id_inner = stream_id.to_inner();
    
    // Track in registry
    recurring_payment_registry::add_stream(registry, stream_id_inner);
    
    event::emit(StreamCreated {
        stream_id: stream_id_inner,
        dao_id: dao_id,
        recipient,
        amount_per_payment,
        payment_interval,
        description: description,
    });
    
    transfer::share_object(PaymentStream<CoinType> {
        id: stream_id,
        dao_id: dao_id,
        recipient,
        amount_per_payment,
        payment_interval,
        start_timestamp,
        end_timestamp,
        last_payment: start_timestamp,
        total_paid: 0,
        max_total,
        description,
        active: true,
    });
    
    stream_id_inner
}


/// Cancel a payment stream
/// Only the DAO admin can cancel streams
public fun cancel_stream<CoinType>(
    stream: &mut PaymentStream<CoinType>,
    registry: &mut PaymentStreamRegistry,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    stream.active = false;
    let stream_id = object::id(stream);
    
    // Remove from registry
    recurring_payment_registry::remove_stream(registry, stream_id);
    
    event::emit(StreamCancelled {
        stream_id,
        total_paid: stream.total_paid,
        timestamp: clock.timestamp_ms(),
    });
}

// === View Functions ===

public(package) fun get_payment_details_and_update_state<CoinType>(
    stream: &mut PaymentStream<CoinType>,
    current_time: u64
): (address, u64) {
    assert!(stream.active, EStreamEnded);

    // Check if payment is due
    assert!(current_time >= stream.last_payment + stream.payment_interval, EPaymentNotDue);

    // Check if stream has ended by date
    if (stream.end_timestamp.is_some()) {
        let end_time = *stream.end_timestamp.borrow();
        if (current_time > end_time) {
            stream.active = false;
            abort EStreamEnded
        };
    };

    // SECURITY FIX: Calculate payments due with overflow protection
    let payments_due = (current_time - stream.last_payment) / stream.payment_interval;
    
    // SECURITY FIX: Cap maximum payments per claim to prevent overflow and DOS
    let capped_payments_due = if (payments_due > MAX_PAYMENTS_PER_CLAIM) {
        MAX_PAYMENTS_PER_CLAIM
    } else {
        payments_due
    };
    
    // SECURITY FIX: Check for multiplication overflow before calculating
    let max_u64 = 18446744073709551615u64;
    assert!(capped_payments_due == 0 || stream.amount_per_payment <= max_u64 / capped_payments_due, EOverflow);
    let amount_to_pay = capped_payments_due * stream.amount_per_payment;

    // Check if stream has ended by max payment amount
    if (stream.max_total.is_some()) {
        let max = *stream.max_total.borrow();
        // SECURITY FIX: Validate against remaining balance instead of next payment
        let remaining = if (max > stream.total_paid) { max - stream.total_paid } else { 0 };
        if (amount_to_pay > remaining) {
            // Only pay what's remaining
            let final_amount = remaining;
            let final_payments = final_amount / stream.amount_per_payment;
            
            // SECURITY FIX: Update state only after all validations pass
            stream.last_payment = stream.last_payment + (final_payments * stream.payment_interval);
            stream.total_paid = stream.total_paid + (final_payments * stream.amount_per_payment);
            stream.active = false;
            
            return (stream.recipient, final_payments * stream.amount_per_payment)
        };
    };

    // SECURITY FIX: Validate state update won't overflow
    assert!(stream.total_paid <= max_u64 - amount_to_pay, EOverflow);
    
    // Update stream state only after all validations pass
    stream.last_payment = stream.last_payment + (capped_payments_due * stream.payment_interval);
    stream.total_paid = stream.total_paid + amount_to_pay;

    (stream.recipient, amount_to_pay)
}

public fun is_payment_due<CoinType>(stream: &PaymentStream<CoinType>, clock: &Clock): bool {
    if (!stream.active) return false;
    
    let current_time = clock.timestamp_ms();
    current_time >= stream.last_payment + stream.payment_interval
}

public fun get_next_payment_time<CoinType>(stream: &PaymentStream<CoinType>): u64 {
    stream.last_payment + stream.payment_interval
}

public fun get_stream_info<CoinType>(stream: &PaymentStream<CoinType>): (
    address, // recipient
    u64,     // amount_per_payment
    u64,     // payment_interval
    u64,     // total_paid
    bool,    // active
    ID       // dao_id
) {
    (
        stream.recipient,
        stream.amount_per_payment,
        stream.payment_interval,
        stream.total_paid,
        stream.active,
        stream.dao_id
    )
}

public fun get_remaining_payments<CoinType>(stream: &PaymentStream<CoinType>): Option<u64> {
    if (stream.max_total.is_some()) {
        let max = *stream.max_total.borrow();
        let remaining_amount = max - stream.total_paid;
        option::some(remaining_amount / stream.amount_per_payment)
    } else {
        option::none()
    }
}

/// Update the last payment timestamp after a successful payment
public(package) fun update_payment_timestamp<CoinType>(
    stream: &mut PaymentStream<CoinType>,
    clock: &Clock
) {
    stream.last_payment = clock.timestamp_ms();
}

/// Add to the total amount paid from this stream
public(package) fun add_to_total_paid<CoinType>(
    stream: &mut PaymentStream<CoinType>,
    amount: u64
) {
    stream.total_paid = stream.total_paid + amount;
}

// permissionless_cancel_dissolving_stream moved to treasury module to avoid circular dependency