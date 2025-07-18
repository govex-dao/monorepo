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
use futarchy::{
    dao::{DAO},
    recurring_payment_registry::{Self, PaymentStreamRegistry},
};

// === Errors ===
const EPaymentNotDue: u64 = 0;
const EStreamEnded: u64 = 1;
const EInsufficientBalance: u64 = 3;
const EInvalidInterval: u64 = 4;
const EInvalidAmount: u64 = 5;

// === Structs ===

/// Recurring payment stream with pre-funded escrow
public struct PaymentStream<phantom CoinType> has key {
    id: UID,
    // DAO this stream belongs to
    dao_id: ID,
    // Escrowed funds for future payments
    funds: Balance<CoinType>,
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

/// Create a new payment stream with pre-funded coins
public fun create_payment_stream<CoinType: drop>(
    dao: &DAO,
    registry: &mut PaymentStreamRegistry,
    funds: Coin<CoinType>,
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
    recurring_payment_registry::verify_dao_ownership(registry, dao);
    
    // Verify we have sufficient funds
    let fund_amount = funds.value();
    assert!(fund_amount >= amount_per_payment, EInsufficientBalance);
    
    // If max_total is set, verify funds match
    if (max_total.is_some()) {
        assert!(fund_amount >= *max_total.borrow(), EInsufficientBalance);
    };
    
    let stream_id = object::new(ctx);
    let stream_id_inner = stream_id.to_inner();
    
    // Track in registry
    recurring_payment_registry::add_stream(registry, stream_id_inner);
    
    event::emit(StreamCreated {
        stream_id: stream_id_inner,
        dao_id: object::id(dao),
        recipient,
        amount_per_payment,
        payment_interval,
        description: description,
    });
    
    transfer::share_object(PaymentStream<CoinType> {
        id: stream_id,
        dao_id: object::id(dao),
        funds: funds.into_balance(),
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

/// Execute a due payment - can be called permissionlessly by anyone
public entry fun execute_payment<CoinType: drop>(
    stream: &mut PaymentStream<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(stream.active, EStreamEnded);
    
    let current_time = clock.timestamp_ms();
    
    // Check if payment is due
    assert!(current_time >= stream.last_payment + stream.payment_interval, EPaymentNotDue);
    
    // Check if stream has ended
    if (stream.end_timestamp.is_some()) {
        let end_time = *stream.end_timestamp.borrow();
        if (current_time > end_time) {
            stream.active = false;
            abort EStreamEnded
        };
    };
    
    // Check max total
    if (stream.max_total.is_some()) {
        let max = *stream.max_total.borrow();
        if (stream.total_paid + stream.amount_per_payment > max) {
            stream.active = false;
            abort EStreamEnded
        };
    };
    
    // Calculate number of payments due
    let payments_due = (current_time - stream.last_payment) / stream.payment_interval;
    let amount_due = payments_due * stream.amount_per_payment;
    
    // Cap amount if it would exceed max_total
    let amount_to_pay = if (stream.max_total.is_some()) {
        let max = *stream.max_total.borrow();
        let remaining = max - stream.total_paid;
        if (amount_due > remaining) remaining else amount_due
    } else {
        amount_due
    };
    
    // Take payment from the stream's escrowed funds
    assert!(stream.funds.value() >= amount_to_pay, EInsufficientBalance);
    let payment = coin::from_balance(stream.funds.split(amount_to_pay), ctx);
    transfer::public_transfer(payment, stream.recipient);
    
    // Update stream state
    stream.last_payment = stream.last_payment + (payments_due * stream.payment_interval);
    stream.total_paid = stream.total_paid + amount_to_pay;
    
    let payment_number = stream.total_paid / stream.amount_per_payment;
    
    event::emit(PaymentExecuted {
        stream_id: object::id(stream),
        recipient: stream.recipient,
        amount: amount_to_pay,
        payment_number,
        timestamp: current_time,
    });
    
    // Check if stream should end due to depleted funds
    check_and_end_if_depleted(stream);
}

/// Cancel a payment stream and return remaining funds to DAO treasury
/// Only the DAO admin can cancel streams
public fun cancel_stream_with_refund<CoinType: drop>(
    stream: &mut PaymentStream<CoinType>,
    registry: &mut PaymentStreamRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    stream.active = false;
    let stream_id = object::id(stream);
    
    // Remove from registry
    recurring_payment_registry::remove_stream(registry, stream_id);
    
    // Return any remaining funds
    let remaining_balance = stream.funds.withdraw_all();
    let refund = coin::from_balance(remaining_balance, ctx);
    
    event::emit(StreamCancelled {
        stream_id,
        total_paid: stream.total_paid,
        timestamp: clock.timestamp_ms(),
    });
    
    refund
}

/// Check and mark stream as ended if funds are depleted
fun check_and_end_if_depleted<CoinType>(stream: &mut PaymentStream<CoinType>) {
    if (stream.funds.value() < stream.amount_per_payment) {
        stream.active = false;
    };
}

// === View Functions ===

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
    bool     // active
) {
    (
        stream.recipient,
        stream.amount_per_payment,
        stream.payment_interval,
        stream.total_paid,
        stream.active
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