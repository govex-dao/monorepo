/// DAO admin functions for managing treasury and payment streams
module futarchy::dao_admin;

// === Imports ===
use futarchy::{
    dao::{Self, DAO},
    treasury::{Self, Treasury},
    recurring_payments::{Self, PaymentStream},
    recurring_payment_registry::PaymentStreamRegistry,
};
use sui::{
    clock::Clock,
};

// === Errors ===
const ENotAdmin: u64 = 0;

// === Public Entry Functions ===

/// Cancel a payment stream and return remaining funds to the DAO treasury
/// Only the treasury admin can cancel payment streams
public entry fun cancel_and_refund_payment_stream<CoinType: drop>(
    treasury: &mut Treasury,
    payment_stream_registry: &mut PaymentStreamRegistry,
    stream: &mut PaymentStream<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify caller is the treasury admin
    assert!(treasury::get_admin(treasury) == ctx.sender(), ENotAdmin);
    
    // Cancel the stream (no refund in new model as funds stay in treasury)
    recurring_payments::cancel_stream<CoinType>(
        stream,
        payment_stream_registry,
        clock,
        ctx
    );
}