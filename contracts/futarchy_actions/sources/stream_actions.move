/// Unified payment system for Futarchy DAOs
/// Combines streaming (continuous) and recurring (periodic) payment functionality
module futarchy_actions::stream_actions;

// === Imports ===
use std::{
    string::String,
    option::{Self, Option},
};
use sui::{
    clock::Clock,
    coin::{Self, Coin},
};
use account_protocol::{
    account::{Self, Account, Auth},
    executable::Executable,
    version_witness::VersionWitness,
};

// === Errors ===
const EInvalidStreamDuration: u64 = 1;
const EInvalidStreamAmount: u64 = 2;
const EStreamNotActive: u64 = 3;
const EStreamAlreadyExists: u64 = 4;
const EInvalidRecipient: u64 = 5;
const EStreamNotFound: u64 = 6;
const EUnauthorizedAction: u64 = 7;
const EInvalidStartTime: u64 = 8;
const EInvalidCliff: u64 = 9;
const EStreamFullyClaimed: u64 = 10;

// === Structs ===

/// Payment types supported by the unified system
const PAYMENT_TYPE_STREAM: u8 = 0;      // Continuous streaming (vesting, salaries)
const PAYMENT_TYPE_RECURRING: u8 = 1;   // Periodic payments

/// Payment source modes
const SOURCE_DIRECT_TREASURY: u8 = 0;   // Payments come directly from treasury
const SOURCE_ISOLATED_POOL: u8 = 1;     // Payments come from isolated/escrowed pool

/// Unified configuration for both streaming and recurring payments
public struct PaymentConfig has store, copy, drop {
    /// Type of payment (stream or recurring)
    payment_type: u8,
    /// Source of funds (direct treasury or isolated pool)
    source_mode: u8,
    /// Recipient address
    recipient: address,
    /// Total amount (for streams) or amount per payment (for recurring)
    amount: u64,
    /// Amount already claimed/paid
    claimed_amount: u64,
    /// Payment start timestamp
    start_timestamp: u64,
    /// Payment end timestamp (for streams) or expiry (for recurring)
    end_timestamp: u64,
    /// For streams: cliff timestamp; For recurring: payment interval in ms
    interval_or_cliff: Option<u64>,
    /// For recurring: total number of payments (0 for unlimited)
    total_payments: u64,
    /// For recurring: number of payments made so far
    payments_made: u64,
    /// For recurring: timestamp of last payment
    last_payment_timestamp: u64,
    /// Whether the payment can be cancelled
    cancellable: bool,
    /// Whether the payment is currently active
    active: bool,
    /// Description of the payment
    description: String,
}

/// Action to create a new payment (stream or recurring)
public struct CreatePaymentAction<phantom CoinType> has store {
    config: PaymentConfig,
}

/// Action to claim/execute a payment
public struct ExecutePaymentAction<phantom CoinType> has store {
    payment_id: String,
    /// Optional amount to claim (None means claim all available for streams)
    amount: Option<u64>,
}

/// Action to cancel a payment
public struct CancelPaymentAction<phantom CoinType> has store {
    payment_id: String,
    /// Whether to return unclaimed tokens to treasury
    return_unclaimed: bool,
}

/// Action to update payment recipient
public struct UpdatePaymentRecipientAction has store {
    payment_id: String,
    new_recipient: address,
}

/// Action to pause/resume a payment
public struct TogglePaymentAction has store {
    payment_id: String,
    active: bool,
}

// === Action Constructors ===

/// Create a new streaming payment action
public fun new_create_stream_action<CoinType>(
    source_mode: u8,
    recipient: address,
    total_amount: u64,
    start_timestamp: u64,
    end_timestamp: u64,
    cliff_timestamp: Option<u64>,
    cancellable: bool,
    description: String,
    clock: &Clock,
): CreatePaymentAction<CoinType> {
    assert!(recipient != @0x0, EInvalidRecipient);
    assert!(total_amount > 0, EInvalidStreamAmount);
    assert!(end_timestamp > start_timestamp, EInvalidStreamDuration);
    assert!(start_timestamp >= clock.timestamp_ms(), EInvalidStartTime);
    assert!(source_mode == SOURCE_DIRECT_TREASURY || source_mode == SOURCE_ISOLATED_POOL, EInvalidRecipient);
    
    // Validate cliff if provided
    if (cliff_timestamp.is_some()) {
        let cliff = *cliff_timestamp.borrow();
        assert!(cliff >= start_timestamp && cliff <= end_timestamp, EInvalidCliff);
    };
    
    let config = PaymentConfig {
        payment_type: PAYMENT_TYPE_STREAM,
        source_mode,
        recipient,
        amount: total_amount,
        claimed_amount: 0,
        start_timestamp,
        end_timestamp,
        interval_or_cliff: cliff_timestamp,
        total_payments: 0, // Not used for streams
        payments_made: 0,  // Not used for streams
        last_payment_timestamp: 0, // Not used for streams
        cancellable,
        active: true,
        description,
    };
    
    CreatePaymentAction { config }
}

/// Create a new recurring payment action
public fun new_create_recurring_payment_action<CoinType>(
    source_mode: u8,
    recipient: address,
    amount_per_payment: u64,
    interval_ms: u64,
    total_payments: u64,
    end_timestamp: Option<u64>,
    cancellable: bool,
    description: String,
    clock: &Clock,
): CreatePaymentAction<CoinType> {
    assert!(recipient != @0x0, EInvalidRecipient);
    assert!(amount_per_payment > 0, EInvalidStreamAmount);
    assert!(interval_ms > 0, EInvalidStreamDuration);
    assert!(source_mode == SOURCE_DIRECT_TREASURY || source_mode == SOURCE_ISOLATED_POOL, EInvalidRecipient);
    
    let config = PaymentConfig {
        payment_type: PAYMENT_TYPE_RECURRING,
        source_mode,
        recipient,
        amount: amount_per_payment,
        claimed_amount: 0,
        start_timestamp: clock.timestamp_ms(),
        end_timestamp: end_timestamp.get_with_default(0),
        interval_or_cliff: option::some(interval_ms),
        total_payments,
        payments_made: 0,
        last_payment_timestamp: clock.timestamp_ms(),
        cancellable,
        active: true,
        description,
    };
    
    CreatePaymentAction { config }
}

/// Create an action to execute/claim a payment
public fun new_execute_payment_action<CoinType>(
    payment_id: String,
    amount: Option<u64>,
): ExecutePaymentAction<CoinType> {
    ExecutePaymentAction { payment_id, amount }
}

/// Create an action to cancel a payment
public fun new_cancel_payment_action<CoinType>(
    payment_id: String,
    return_unclaimed: bool,
): CancelPaymentAction<CoinType> {
    CancelPaymentAction { payment_id, return_unclaimed }
}

/// Create an action to update payment recipient
public fun new_update_payment_recipient_action(
    payment_id: String,
    new_recipient: address,
): UpdatePaymentRecipientAction {
    assert!(new_recipient != @0x0, EInvalidRecipient);
    UpdatePaymentRecipientAction { payment_id, new_recipient }
}

/// Create an action to pause or resume a payment
public fun new_toggle_payment_action(
    payment_id: String,
    active: bool,
): TogglePaymentAction {
    TogglePaymentAction { payment_id, active }
}

// === Execution Functions ===

/// Execute creation of a payment (stream or recurring)
public fun do_create_payment<Config, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let CreatePaymentAction<CoinType> { config } = 
        executable.next_action<Outcome, CreatePaymentAction<CoinType>, IW>(witness);
    
    // Generate unique payment ID
    let payment_id = generate_payment_id(config, clock.timestamp_ms());
    
    // In a real implementation:
    // 1. If SOURCE_ISOLATED_POOL: Create and fund isolated pool
    // 2. If SOURCE_DIRECT_TREASURY: Lock/reserve the funds in treasury
    // 3. Store payment configuration in account metadata
    // 4. Emit payment creation event
}

/// Execute a payment (claim stream tokens or process recurring payment)
public fun do_execute_payment<Config, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let ExecutePaymentAction<CoinType> { payment_id, amount } = 
        executable.next_action<Outcome, ExecutePaymentAction<CoinType>, IW>(witness);
    
    // In a real implementation:
    // 1. Load payment configuration
    // 2. If STREAM: Calculate claimable amount based on vesting
    // 3. If RECURRING: Check if payment is due and process
    // 4. Transfer tokens from appropriate source (treasury or isolated pool)
    // 5. Update payment state (claimed_amount, payments_made, last_payment_timestamp)
    // 6. Emit execution event
}

/// Execute cancellation of a payment
public fun do_cancel_payment<Config, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let CancelPaymentAction<CoinType> { payment_id, return_unclaimed } = 
        executable.next_action<Outcome, CancelPaymentAction<CoinType>, IW>(witness);
    
    // In a real implementation:
    // 1. Load payment configuration
    // 2. Verify payment is cancellable
    // 3. Calculate and transfer any claimable/due amount to recipient
    // 4. If return_unclaimed, return remaining tokens to treasury or close isolated pool
    // 5. Mark payment as inactive
    // 6. Emit cancellation event
}

/// Execute updating payment recipient
public fun do_update_payment_recipient<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    let UpdatePaymentRecipientAction { payment_id, new_recipient } = 
        executable.next_action<Outcome, UpdatePaymentRecipientAction, IW>(witness);
    
    // In a real implementation:
    // 1. Load payment configuration
    // 2. Verify permissions (only recipient or DAO can update)
    // 3. Update recipient address
    // 4. Emit update event
}

/// Execute toggling payment active status
public fun do_toggle_payment<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    let TogglePaymentAction { payment_id, active } = 
        executable.next_action<Outcome, TogglePaymentAction, IW>(witness);
    
    // In a real implementation:
    // 1. Load payment configuration
    // 2. Update active status
    // 3. Emit status change event
}

// === Helper Functions ===

/// Generate a unique payment ID
fun generate_payment_id(config: &PaymentConfig, timestamp: u64): String {
    // In a real implementation, generate unique ID based on config and timestamp
    if (config.payment_type == PAYMENT_TYPE_STREAM) {
        b"stream_".to_string()
    } else {
        b"recurring_".to_string()
    }
}

/// Calculate claimable amount for a streaming payment
public fun calculate_claimable_amount(
    config: &PaymentConfig,
    clock: &Clock,
): u64 {
    assert!(config.payment_type == PAYMENT_TYPE_STREAM, EInvalidStartTime);
    
    if (!config.active) {
        return 0
    };
    
    let current_time = clock.timestamp_ms();
    
    // Check if before start time
    if (current_time < config.start_timestamp) {
        return 0
    };
    
    // Check cliff period
    if (config.interval_or_cliff.is_some()) {
        let cliff = *config.interval_or_cliff.borrow();
        if (current_time < cliff) {
            return 0
        };
    };
    
    // Calculate vested amount
    let vested_amount = if (current_time >= config.end_timestamp) {
        config.amount // total_amount for streams
    } else {
        let elapsed = current_time - config.start_timestamp;
        let duration = config.end_timestamp - config.start_timestamp;
        (config.amount * elapsed) / duration
    };
    
    // Return claimable (vested minus already claimed)
    if (vested_amount > config.claimed_amount) {
        vested_amount - config.claimed_amount
    } else {
        0
    }
}

/// Check if a recurring payment is due
public fun is_recurring_payment_due(
    config: &PaymentConfig,
    clock: &Clock,
): bool {
    assert!(config.payment_type == PAYMENT_TYPE_RECURRING, EInvalidStartTime);
    
    if (!config.active) {
        return false
    };
    
    // Check if payment has ended
    if (config.total_payments > 0 && config.payments_made >= config.total_payments) {
        return false
    };
    
    // Check if payment has expired
    if (config.end_timestamp > 0 && clock.timestamp_ms() >= config.end_timestamp) {
        return false
    };
    
    // Check if enough time has passed since last payment
    let interval = *option::borrow(&config.interval_or_cliff);
    let time_since_last = clock.timestamp_ms() - config.last_payment_timestamp;
    time_since_last >= interval
}

/// Check if a payment is fully vested/completed
public fun is_payment_complete(config: &PaymentConfig, clock: &Clock): bool {
    if (config.payment_type == PAYMENT_TYPE_STREAM) {
        clock.timestamp_ms() >= config.end_timestamp
    } else {
        (config.total_payments > 0 && config.payments_made >= config.total_payments) ||
        (config.end_timestamp > 0 && clock.timestamp_ms() >= config.end_timestamp)
    }
}

/// Check if a payment is fully claimed/paid
public fun is_fully_claimed(config: &PaymentConfig): bool {
    if (config.payment_type == PAYMENT_TYPE_STREAM) {
        config.claimed_amount >= config.amount
    } else {
        config.total_payments > 0 && config.payments_made >= config.total_payments
    }
}

/// Get remaining payment amount
public fun remaining_amount(config: &PaymentConfig): u64 {
    if (config.payment_type == PAYMENT_TYPE_STREAM) {
        if (config.amount > config.claimed_amount) {
            config.amount - config.claimed_amount
        } else {
            0
        }
    } else {
        if (config.total_payments > 0) {
            (config.total_payments - config.payments_made) * config.amount
        } else {
            0 // Unlimited payments
        }
    }
}

/// Get payment progress percentage (basis points)
public fun payment_progress_bps(config: &PaymentConfig, clock: &Clock): u64 {
    if (config.payment_type == PAYMENT_TYPE_STREAM) {
        let current_time = clock.timestamp_ms();
        
        if (current_time <= config.start_timestamp) {
            0
        } else if (current_time >= config.end_timestamp) {
            10000 // 100% in basis points
        } else {
            let elapsed = current_time - config.start_timestamp;
            let duration = config.end_timestamp - config.start_timestamp;
            (elapsed * 10000) / duration
        }
    } else {
        if (config.total_payments == 0) {
            0 // Unlimited payments, no progress concept
        } else {
            (config.payments_made * 10000) / config.total_payments
        }
    }
}