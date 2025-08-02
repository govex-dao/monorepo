module futarchy::treasury_executor;

use sui::coin::{Self, Coin};
use sui::clock::{Self, Clock};
use sui::tx_context::TxContext;
use sui::transfer;
use sui::object;
use std::type_name;

use futarchy::{
    treasury::{Self, Treasury},
    action_registry::{Self,
        TransferAction, 
        MintAction,
        BurnAction,
        RecurringPaymentAction,
        CancelStreamAction
    },
    execution_context::{Self, ProposalExecutionContext},
    recurring_payments::{Self},
    recurring_payment_registry::{Self, PaymentStreamRegistry},
};

// === Errors ===
const E_TYPE_MISMATCH: u64 = 0;
const E_INVALID_AMOUNT: u64 = 1;
const E_UNSUPPORTED_OPERATION: u64 = 2;

// === Treasury Action Executors ===

/// Execute a treasury transfer action
public fun execute_transfer<CoinType: drop>(
    treasury: &mut Treasury,
    action: TransferAction,
    context: &ProposalExecutionContext,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify the coin_type in the action matches the generic type passed.
    assert!(*action_registry::get_transfer_coin_type(&action) == type_name::get<CoinType>(), E_TYPE_MISMATCH);
    assert!(action_registry::get_transfer_amount(&action) > 0, E_INVALID_AMOUNT);

    let auth = treasury::create_auth_for_proposal(treasury, context);

    treasury::withdraw_to<CoinType>(
        auth,
        treasury,
        action_registry::get_transfer_amount(&action),
        action_registry::get_transfer_recipient(&action),
        clock,
        ctx
    );
}

/// Execute a mint action
public fun execute_mint<CoinType: drop>(
    treasury: &mut Treasury,
    action: MintAction,
    context: &ProposalExecutionContext,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Note: Minting functionality is not available in the treasury module
    // This would need to be implemented or moved to a different module
    abort E_TYPE_MISMATCH
}

/// Execute a burn action
public fun execute_burn<CoinType: drop>(
    treasury: &mut Treasury,
    action: BurnAction,
    context: &ProposalExecutionContext,
    coins: vector<Coin<CoinType>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Note: Burning functionality is not available in the treasury module
    // This would need to be implemented or moved to a different module
    abort E_TYPE_MISMATCH
}

/// Execute a recurring payment setup action
public fun execute_recurring_payment<CoinType: drop>(
    treasury: &mut Treasury,
    payment_registry: &mut PaymentStreamRegistry,
    action: RecurringPaymentAction,
    context: &ProposalExecutionContext,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify the coin_type in the action matches the generic type passed.
    assert!(*action_registry::get_recurring_payment_coin_type(&action) == type_name::get<CoinType>(), E_TYPE_MISMATCH);
    assert!(action_registry::get_recurring_payment_amount_per_epoch(&action) > 0, E_INVALID_AMOUNT);
    assert!(action_registry::get_recurring_payment_num_epochs(&action) > 0, E_INVALID_AMOUNT);

    let auth = treasury::create_auth_for_proposal(treasury, context);
    treasury::consume_auth(auth);

    // Calculate the start and end timestamps based on epochs
    let start_timestamp = clock::timestamp_ms(clock);
    let epoch_duration = action_registry::get_recurring_payment_epoch_duration_ms(&action);
    let num_epochs = action_registry::get_recurring_payment_num_epochs(&action);
    let end_timestamp = option::some(start_timestamp + (epoch_duration * num_epochs));
    let max_total = option::some(action_registry::get_recurring_payment_amount_per_epoch(&action) * num_epochs);

    // Create the payment stream
    let _stream_id = recurring_payments::create_payment_stream<CoinType>(
        object::id(treasury), // dao_id
        payment_registry,
        action_registry::get_recurring_payment_recipient(&action),
        action_registry::get_recurring_payment_amount_per_epoch(&action),
        epoch_duration, // payment_interval
        start_timestamp,
        end_timestamp,
        max_total,
        *action_registry::get_recurring_payment_description(&action),
        clock,
        ctx
    );
}

/// Execute a cancel stream action
public fun execute_cancel_stream<CoinType>(
    treasury: &mut Treasury,
    payment_registry: &mut PaymentStreamRegistry,
    action: CancelStreamAction,
    context: &ProposalExecutionContext,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Note: Stream cancellation requires the actual PaymentStream object,
    // not just an ID. This would need to be refactored to work properly.
    abort E_UNSUPPORTED_OPERATION
}

// === Batch Execution Helper ===

/// Execute multiple treasury transfers in a single transaction
public fun execute_batch_transfers<CoinType: drop>(
    treasury: &mut Treasury,
    actions: vector<TransferAction>,
    context: &ProposalExecutionContext,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut i = 0;
    let len = vector::length(&actions);
    while (i < len) {
        let action = *vector::borrow(&actions, i);
        execute_transfer<CoinType>(treasury, action, context, clock, ctx);
        i = i + 1;
    };
}