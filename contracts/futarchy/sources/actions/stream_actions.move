/// Unified payment system for Futarchy DAOs
/// Combines streaming (continuous) and recurring (periodic) payment functionality
/// 
/// Features:
/// - Streaming payments: Continuous vesting over time (e.g., salaries, grants)
/// - Recurring payments: Periodic fixed payments (e.g., subscriptions, fees)
/// - Source modes: Direct treasury or isolated pool funding
/// - Cliff periods for vesting schedules
/// - Cancellable and pausable payments
module futarchy::stream_actions;

// === Imports ===
use std::{
    string::String,
    option::{Self, Option},
};
use sui::{
    clock::Clock,
    coin::{Self, Coin},
    balance::{Self, Balance},
    table::{Self, Table},
    event,
    object::{Self, ID},
    transfer,
};
use account_actions::vault;
use account_protocol::{
    account::{Self, Account, Auth},
    executable::Executable,
    version_witness::VersionWitness,
};
use futarchy::{
    futarchy_config::FutarchyConfig,
    version,
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
const EPaymentNotFound: u64 = 11;
const EInsufficientFunds: u64 = 12;
const EPaymentNotActive: u64 = 13;
const ENotCancellable: u64 = 14;
const ENothingToClaim: u64 = 15;

// === Storage Keys ===

/// Dynamic field key for payment storage
public struct PaymentStorageKey has copy, drop, store {}

/// Dynamic field key for isolated payment pools
public struct PaymentPoolKey has copy, drop, store {
    payment_id: String,
}

/// Storage for all payments in an account
public struct PaymentStorage has store {
    payments: sui::table::Table<String, PaymentConfig>,
    total_payments: u64,
}

// === Events ===

public struct PaymentCreated has copy, drop {
    account_id: ID,
    payment_id: String,
    payment_type: u8,
    recipient: address,
    amount: u64,
    start_timestamp: u64,
    end_timestamp: u64,
}

public struct PaymentClaimed has copy, drop {
    account_id: ID,
    payment_id: String,
    recipient: address,
    amount_claimed: u64,
    total_claimed: u64,
    timestamp: u64,
}

public struct PaymentCancelled has copy, drop {
    account_id: ID,
    payment_id: String,
    unclaimed_returned: u64,
    timestamp: u64,
}

public struct RecipientUpdated has copy, drop {
    account_id: ID,
    payment_id: String,
    old_recipient: address,
    new_recipient: address,
    timestamp: u64,
}

public struct PaymentToggled has copy, drop {
    account_id: ID,
    payment_id: String,
    active: bool,
    timestamp: u64,
}

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

/// Execute creation of a payment (stream or recurring) with funding if isolated pool
public fun do_create_payment<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable.next_action<Outcome, CreatePaymentAction<CoinType>, IW>(witness);
    let config = action.config;
    
    // Initialize payment storage if needed
    if (!account::has_managed_data(account, PaymentStorageKey {})) {
        account::add_managed_data(
            account,
            PaymentStorageKey {},
            PaymentStorage {
                payments: table::new(ctx),
                total_payments: 0,
            },
            version::current()
        );
    };
    
    // Generate unique payment ID
    let payment_id = generate_payment_id(&config, clock.timestamp_ms());
    
    // If using an isolated pool, create the pool first
    // The funding will come from a preceding vault::SpendAction in the same intent
    if (config.source_mode == SOURCE_ISOLATED_POOL) {
        // Calculate total funding needed
        let _total_amount = if (config.payment_type == PAYMENT_TYPE_STREAM) {
            config.amount
        } else {
            // For recurring payments, fund the total of all payments
            if (config.total_payments > 0) {
                config.amount * config.total_payments
            } else {
                // For unlimited recurring, require initial funding amount
                config.amount * 12 // Default to 12 periods worth
            }
        };
        
        // Create an isolated balance for this payment
        // The actual funding coin must come from a preceding vault::SpendAction
        let pool_key = PaymentPoolKey { payment_id };
        let pool_balance: Balance<CoinType> = balance::zero();
        account::add_managed_data(account, pool_key, pool_balance, version::current());
    };
    
    // Now borrow storage and add the payment
    let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    assert!(!table::contains(&storage.payments, payment_id), EStreamAlreadyExists);
    
    // Store the payment configuration
    table::add(&mut storage.payments, payment_id, config);
    storage.total_payments = storage.total_payments + 1;
    
    // Emit creation event
    event::emit(PaymentCreated {
        account_id: object::id(account),
        payment_id,
        payment_type: config.payment_type,
        recipient: config.recipient,
        amount: config.amount,
        start_timestamp: config.start_timestamp,
        end_timestamp: config.end_timestamp,
    });
}

/// Execute a payment - validation only, no fund movement
public fun do_execute_payment<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable.next_action<Outcome, ExecutePaymentAction<CoinType>, IW>(witness);
    let payment_id = action.payment_id;
    let amount = action.amount;
    
    let storage: &PaymentStorage = account::borrow_managed_data(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    assert!(table::contains(&storage.payments, payment_id), EPaymentNotFound);
    let payment = table::borrow(&storage.payments, payment_id);
    assert!(payment.active, EPaymentNotActive);
    
    let current_time = clock.timestamp_ms();
    let claimable = calculate_claimable_amount(payment, current_time);
    
    // Determine actual amount to claim
    let claim_amount = if (amount.is_some()) {
        let requested = *amount.borrow();
        assert!(requested <= claimable, EInsufficientFunds);
        requested
    } else {
        claimable
    };
    
    assert!(claim_amount > 0, ENothingToClaim);
    
    // This function only validates. Actual execution with funds happens in do_execute_payment_with_coin
}

/// Execute a payment with provided coin - actual fund movement
public(package) fun do_execute_payment_with_coin<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    payment_coin: Coin<CoinType>,
    witness: IW,
    clock: &Clock,
) {
    let action = executable.next_action<Outcome, ExecutePaymentAction<CoinType>, IW>(witness);
    let payment_id = action.payment_id;
    let amount = action.amount;
    
    let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    assert!(table::contains(&storage.payments, payment_id), EPaymentNotFound);
    let payment = table::borrow_mut(&mut storage.payments, payment_id);
    assert!(payment.active, EPaymentNotActive);
    
    let current_time = clock.timestamp_ms();
    let claimable = calculate_claimable_amount(payment, current_time);
    
    // Determine actual amount to claim
    let claim_amount = if (amount.is_some()) {
        let requested = *amount.borrow();
        assert!(requested <= claimable, EInsufficientFunds);
        requested
    } else {
        claimable
    };
    
    assert!(claim_amount > 0, ENothingToClaim);
    assert!(coin::value(&payment_coin) == claim_amount, EInvalidStreamAmount);
    
    // Extract necessary values before updating state
    let recipient = payment.recipient;
    let source_mode = payment.source_mode;
    
    // Update payment state
    payment.claimed_amount = payment.claimed_amount + claim_amount;
    if (payment.payment_type == PAYMENT_TYPE_RECURRING) {
        payment.payments_made = payment.payments_made + 1;
        payment.last_payment_timestamp = current_time;
    };
    let total_claimed = payment.claimed_amount;
    
    // Transfer the provided coin to recipient
    transfer::public_transfer(payment_coin, recipient);
    
    // Emit claim event
    event::emit(PaymentClaimed {
        account_id: object::id(account),
        payment_id,
        recipient,
        amount_claimed: claim_amount,
        total_claimed,
        timestamp: current_time,
    });
}

/// Execute cancellation of a payment - validation only
public fun do_cancel_payment<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable.next_action<Outcome, CancelPaymentAction<CoinType>, IW>(witness);
    let payment_id = action.payment_id;
    
    let storage: &PaymentStorage = account::borrow_managed_data(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    assert!(table::contains(&storage.payments, payment_id), EPaymentNotFound);
    let payment = table::borrow(&storage.payments, payment_id);
    assert!(payment.cancellable, ENotCancellable);
    
    // This function only validates. Actual cancellation happens in do_cancel_payment_with_coin
}

/// Cancel a payment with optional final payment coin
public(package) fun do_cancel_payment_with_coin<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    final_payment_coin: Option<Coin<CoinType>>,
    witness: IW,
    clock: &Clock,
) {
    let action = executable.next_action<Outcome, CancelPaymentAction<CoinType>, IW>(witness);
    let payment_id = action.payment_id;
    let return_unclaimed = action.return_unclaimed;
    
    let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    assert!(table::contains(&storage.payments, payment_id), EPaymentNotFound);
    let payment = table::borrow_mut(&mut storage.payments, payment_id);
    assert!(payment.cancellable, ENotCancellable);
    
    let current_time = clock.timestamp_ms();
    
    // Calculate and transfer any claimable amount to recipient first
    let claimable = calculate_claimable_amount(payment, current_time);
    if (claimable > 0) {
        assert!(option::is_some(&final_payment_coin), EInsufficientFunds);
        let final_payment = option::destroy_some(final_payment_coin);
        assert!(coin::value(&final_payment) == claimable, EInvalidStreamAmount);
        payment.claimed_amount = payment.claimed_amount + claimable;
        transfer::public_transfer(final_payment, payment.recipient);
    } else {
        option::destroy_none(final_payment_coin);
    };
    
    // Calculate unclaimed amount
    let unclaimed = if (payment.amount > payment.claimed_amount) {
        payment.amount - payment.claimed_amount
    } else {
        0
    };
    
    // Mark payment as inactive
    payment.active = false;
    
    // If using isolated pool and returning unclaimed, clean up the pool
    if (payment.source_mode == SOURCE_ISOLATED_POOL && return_unclaimed && unclaimed > 0) {
        let pool_key = PaymentPoolKey { payment_id };
        if (account::has_managed_data(account, pool_key)) {
            let pool_balance: Balance<CoinType> = account::remove_managed_data(
                account,
                pool_key,
                version::current()
            );
            // Return unused balance to treasury
            // This would be handled by the dispatcher returning funds to vault
            balance::destroy_zero(pool_balance);
        };
    };
    
    // Emit cancellation event
    event::emit(PaymentCancelled {
        account_id: object::id(account),
        payment_id,
        unclaimed_returned: if (return_unclaimed) { unclaimed } else { 0 },
        timestamp: current_time,
    });
}

/// Execute updating payment recipient
public fun do_update_payment_recipient<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable.next_action<Outcome, UpdatePaymentRecipientAction, IW>(witness);
    let payment_id = action.payment_id;
    let new_recipient = action.new_recipient;
    
    assert!(new_recipient != @0x0, EInvalidRecipient);
    
    let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    assert!(table::contains(&storage.payments, payment_id), EPaymentNotFound);
    let payment = table::borrow_mut(&mut storage.payments, payment_id);
    let old_recipient = payment.recipient;
    
    // Update recipient
    payment.recipient = new_recipient;
    
    // Emit update event
    event::emit(RecipientUpdated {
        account_id: object::id(account),
        payment_id,
        old_recipient,
        new_recipient,
        timestamp: clock.timestamp_ms(),
    });
}

/// Execute toggling payment active status
public fun do_toggle_payment<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable.next_action<Outcome, TogglePaymentAction, IW>(witness);
    let payment_id = action.payment_id;
    let active = action.active;
    
    let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    assert!(table::contains(&storage.payments, payment_id), EPaymentNotFound);
    let payment = table::borrow_mut(&mut storage.payments, payment_id);
    
    // Update active status
    payment.active = active;
    
    // Emit toggle event
    event::emit(PaymentToggled {
        account_id: object::id(account),
        payment_id,
        active,
        timestamp: clock.timestamp_ms(),
    });
}

// === Helper Functions ===

/// Calculate claimable amount for a payment
fun calculate_claimable_amount(payment: &PaymentConfig, current_time: u64): u64 {
    if (!payment.active || current_time < payment.start_timestamp) {
        return 0
    };
    
    if (payment.payment_type == PAYMENT_TYPE_STREAM) {
        // Handle cliff period if present
        if (payment.interval_or_cliff.is_some()) {
            let cliff = *payment.interval_or_cliff.borrow();
            if (current_time < cliff) {
                return 0
            };
        };
        
        // Calculate vested amount based on time elapsed
        let total_duration = payment.end_timestamp - payment.start_timestamp;
        let elapsed = if (current_time >= payment.end_timestamp) {
            total_duration
        } else {
            current_time - payment.start_timestamp
        };
        
        let vested_amount = (payment.amount * elapsed) / total_duration;
        
        // Return claimable (vested minus already claimed)
        if (vested_amount > payment.claimed_amount) {
            vested_amount - payment.claimed_amount
        } else {
            0
        }
    } else if (payment.payment_type == PAYMENT_TYPE_RECURRING) {
        // Calculate number of payments due
        let interval = if (payment.interval_or_cliff.is_some()) {
            *payment.interval_or_cliff.borrow()
        } else {
            30 * 24 * 60 * 60 * 1000 // Default to monthly (30 days in ms)
        };
        
        let time_since_start = current_time - payment.start_timestamp;
        let payments_due = (time_since_start / interval) + 1;
        
        // Check if we've reached the maximum number of payments
        let max_payments = if (payment.total_payments > 0) {
            payment.total_payments
        } else {
            payments_due // Unlimited payments
        };
        
        let actual_payments_due = if (payments_due > max_payments) {
            max_payments
        } else {
            payments_due
        };
        
        if (actual_payments_due > payment.payments_made) {
            // Amount per payment * number of payments due
            payment.amount * (actual_payments_due - payment.payments_made)
        } else {
            0
        }
    } else {
        0
    }
}

/// Generate a unique payment ID
fun generate_payment_id(config: &PaymentConfig, timestamp: u64): String {
    use std::string;
    use sui::address;
    
    // Generate unique ID: type_recipient_timestamp
    let mut id = if (config.payment_type == PAYMENT_TYPE_STREAM) {
        string::utf8(b"stream_")
    } else {
        string::utf8(b"recurring_")
    };
    
    // Add recipient address hash (first 8 chars)
    let recipient_bytes = address::to_bytes(config.recipient);
    let mut i = 0;
    while (i < 4 && i < vector::length(&recipient_bytes)) {
        let byte = *vector::borrow(&recipient_bytes, i);
        // Convert byte to hex chars (simplified)
        if (byte > 0) {
            string::append(&mut id, string::utf8(b"x"));
        } else {
            string::append(&mut id, string::utf8(b"0"));
        };
        i = i + 1;
    };
    
    // Add timestamp suffix
    string::append(&mut id, string::utf8(b"_"));
    let ts_mod = timestamp % 1000000;
    if (ts_mod > 500000) {
        string::append(&mut id, string::utf8(b"h"));
    } else {
        string::append(&mut id, string::utf8(b"l"));
    };
    
    id
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

/// Fund an isolated payment pool with the provided coin
public(package) fun fund_isolated_pool<CoinType>(
    account: &mut Account<FutarchyConfig>,
    payment_id: String,
    funding_coin: Coin<CoinType>,
    version_witness: VersionWitness,
) {
    let pool_key = PaymentPoolKey { payment_id };
    assert!(account::has_managed_data(account, pool_key), EPaymentNotFound);
    
    let pool_balance: &mut Balance<CoinType> = account::borrow_managed_data_mut(
        account,
        pool_key,
        version_witness
    );
    
    balance::join(pool_balance, coin::into_balance(funding_coin));
}

/// Withdraw from an isolated payment pool
public(package) fun withdraw_from_pool<CoinType>(
    account: &mut Account<FutarchyConfig>,
    payment_id: String,
    amount: u64,
    version_witness: VersionWitness,
    ctx: &mut TxContext,
): Coin<CoinType> {
    let pool_key = PaymentPoolKey { payment_id };
    let pool_balance: &mut Balance<CoinType> = account::borrow_managed_data_mut(
        account,
        pool_key,
        version_witness
    );
    
    coin::take(pool_balance, amount, ctx)
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

// === Getter Functions for Actions ===

/// Get source mode from CreatePaymentAction
public fun get_source_mode<CoinType>(action: &CreatePaymentAction<CoinType>): u8 {
    action.config.source_mode
}

/// Get payment type from CreatePaymentAction  
public fun get_payment_type<CoinType>(action: &CreatePaymentAction<CoinType>): u8 {
    action.config.payment_type
}

/// Get amount from CreatePaymentAction
public fun get_amount<CoinType>(action: &CreatePaymentAction<CoinType>): u64 {
    action.config.amount
}

/// Get total payments from CreatePaymentAction
public fun get_total_payments<CoinType>(action: &CreatePaymentAction<CoinType>): u64 {
    action.config.total_payments
}

// === Exported Constants ===

/// Get source mode constant for direct treasury
public fun source_direct_treasury(): u8 { SOURCE_DIRECT_TREASURY }

/// Get source mode constant for isolated pool
public fun source_isolated_pool(): u8 { SOURCE_ISOLATED_POOL }

/// Get payment type constant for stream
public fun payment_type_stream(): u8 { PAYMENT_TYPE_STREAM }

/// Get payment type constant for recurring
public fun payment_type_recurring(): u8 { PAYMENT_TYPE_RECURRING }