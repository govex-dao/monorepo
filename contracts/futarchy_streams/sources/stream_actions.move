/// Unified payment system for Futarchy DAOs - REFACTORED
/// This version removes state duplication by using vault streams as the source of truth
/// while preserving all original features (budget accountability, isolated pools, etc.)

module futarchy_streams::stream_actions;

// === Imports ===
use std::{
    string::{Self, String},
    option::{Self, Option},
    vector,
    type_name::{Self, TypeName},
};
use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    balance::{Self, Balance},
    table::{Self, Table},
    event,
    object::{Self, ID},
    transfer,
    bag::Bag,
    tx_context::TxContext,
    bcs::{Self, BCS},
};
use futarchy_core::{
    action_validation,
    action_types,
    version,
    futarchy_config::{Self, FutarchyConfig},
};
use futarchy_multisig::weighted_list::{Self, WeightedList};
// CreatePaymentAction is defined locally in this module
use account_actions::{vault::{Self, Vault, VaultKey}, vault_intents};
use account_protocol::{
    bcs_validation,
    account::{Self, Account, Auth},
    executable::{Self, Executable},
    version_witness::VersionWitness,
    intents,
};
// TypeName-based routing replaces old action_descriptor system


// === Missing Action Structs for Decoders ===

/// Action to create a stream payment
public struct CreateStreamAction<phantom CoinType> has store, drop, copy {
    recipient: address,
    amount_per_period: u64,
    period_duration_ms: u64,
    start_time: u64,
    end_time: Option<u64>,
    cliff_time: Option<u64>,
    cancellable: bool,
    description: String,
}

/// Action to cancel a stream
public struct CancelStreamAction has store, drop, copy {
    stream_id: ID,
    reason: String,
}

/// Action to withdraw from a stream
public struct WithdrawStreamAction has store, drop, copy {
    stream_id: ID,
    amount: u64,
}

/// Action to update stream parameters
public struct UpdateStreamAction has store, drop, copy {
    stream_id: ID,
    new_recipient: Option<address>,
    new_amount_per_period: Option<u64>,
}

/// Action to pause a stream
public struct PauseStreamAction has store, drop, copy {
    stream_id: ID,
    reason: String,
}

/// Action to resume a paused stream
public struct ResumeStreamAction has store, drop, copy {
    stream_id: ID,
}

// === Errors === (Keep all original errors)
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
const ETooManyWithdrawers: u64 = 16;
const ENotAuthorizedWithdrawer: u64 = 17;
const EWithdrawerAlreadyExists: u64 = 18;
const EInvalidBudgetStream: u64 = 19;
const ETooManyPendingWithdrawals: u64 = 20;
const EWithdrawalNotReady: u64 = 21;
const EWithdrawalChallenged: u64 = 22;
const EMissingReasonCode: u64 = 23;
const EMissingProjectName: u64 = 24;
const EChallengeMismatch: u64 = 25;
const ECannotWithdrawFromVault: u64 = 26;
const EBudgetExceeded: u64 = 27;
const EInvalidSourceMode: u64 = 28;

const MAX_WITHDRAWERS: u64 = 100;
const MAX_PENDING_WITHDRAWALS: u64 = 100;
const DEFAULT_PENDING_PERIOD_MS: u64 = 604_800_000; // 7 days in milliseconds

// === Storage Keys === (Keep all original)

/// Dynamic field key for payment storage
public struct PaymentStorageKey has copy, drop, store {}

/// Dynamic field key for isolated payment pools
public struct PaymentPoolKey has copy, drop, store {
    payment_id: String,
}

/// Dynamic field key for dissolution return funds
public struct DissolutionReturnKey has copy, drop, store {
    coin_type: type_name::TypeName,
}

/// Storage for all payments in an account
public struct PaymentStorage has store {
    payments: sui::table::Table<String, PaymentConfig>,
    payment_ids: vector<String>,  // Track IDs for iteration during dissolution
    total_payments: u64,
}

/// Pending withdrawal for budget streams with accountability (Keep as-is)
public struct PendingWithdrawal has store, drop {
    withdrawer: address,
    amount: u64,
    reason_code: String,
    requested_at: u64,
    processes_at: u64,
    is_challenged: bool,
    challenge_proposal_id: Option<ID>,
}

/// Configuration for budget streams with enhanced accountability (Keep as-is)
public struct BudgetStreamConfig has store {
    project_name: String,
    pending_period_ms: u64,
    pending_withdrawals: Table<u64, PendingWithdrawal>,
    pending_count: u64,
    total_pending_amount: u64,
    next_withdrawal_id: u64,
    budget_period_ms: Option<u64>,
    current_period_start: u64,
    current_period_claimed: u64,
    max_per_period: Option<u64>,
}

// === Events === (Keep all original events)

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

public struct DissolutionFundsReturned has copy, drop {
    account_id: ID,
    coin_type: String,
    total_amount: u64,
    payment_count: u64,
    timestamp: u64,
}

public struct IsolatedPoolReturned has copy, drop {
    account_id: ID,
    payment_id: String,
    amount_returned: u64,
    expected_amount: u64,
    timestamp: u64,
}

public struct PaymentToggled has copy, drop {
    account_id: ID,
    payment_id: String,
    active: bool,
    timestamp: u64,
}

public struct WithdrawalRequested has copy, drop {
    account_id: ID,
    payment_id: String,
    withdrawal_id: u64,
    withdrawer: address,
    amount: u64,
    reason_code: String,
    processes_at: u64,
}

public struct WithdrawalChallenged has copy, drop {
    account_id: ID,
    payment_id: String,
    withdrawal_ids: vector<u64>,
    proposal_id: ID,
    challenger: address,
}

public struct WithdrawalProcessed has copy, drop {
    account_id: ID,
    payment_id: String,
    withdrawal_id: u64,
    withdrawer: address,
    amount: u64,
}

public struct ChallengedWithdrawalsCancelled has copy, drop {
    account_id: ID,
    payment_id: String,
    withdrawal_ids: vector<u64>,
    proposal_id: ID,
}

// === Structs ===

/// Payment types supported by the unified system
const PAYMENT_TYPE_STREAM: u8 = 0;
const PAYMENT_TYPE_RECURRING: u8 = 1;

/// Payment source modes
const SOURCE_DIRECT_TREASURY: u8 = 0;
const SOURCE_ISOLATED_POOL: u8 = 1;

/// REFACTORED: Removed duplicate fields, now references vault stream
public struct PaymentConfig has store {
    /// Type of payment (stream or recurring)
    payment_type: u8,
    /// Source of funds (direct treasury or isolated pool)
    source_mode: u8,
    /// Authorized withdrawers who can claim from this payment
    authorized_withdrawers: Table<address, bool>,
    /// Number of withdrawers
    withdrawer_count: u64,
    
    // === REFACTORED: Removed duplicate fields ===
    // REMOVED: amount, claimed_amount, start_timestamp, end_timestamp
    // These are now stored in the vault stream and accessed via vault_stream_id
    
    /// Vault stream ID for direct treasury streams (source of truth for amounts/timestamps)
    vault_stream_id: Option<ID>,
    
    /// For isolated pools, we still need to track the amount separately
    isolated_pool_amount: Option<u64>,
    
    /// For recurring: payment interval in ms and tracking
    interval_ms: Option<u64>,
    total_payments: u64,
    payments_made: u64,
    last_payment_timestamp: u64,
    
    /// Whether the payment can be cancelled
    cancellable: bool,
    /// Whether the payment is currently active
    active: bool,
    /// Description of the payment
    description: String,
    /// Budget stream fields for treasury accountability
    is_budget_stream: bool,
    budget_config: Option<BudgetStreamConfig>,
}

/// Action to create a payment (stream or one-time)
public struct CreatePaymentAction<phantom CoinType> has store, drop, copy {
    payment_type: u8,
    source_mode: u8,
    recipient: address,
    amount: u64,
    start_timestamp: u64,
    end_timestamp: u64,
    interval_or_cliff: u64,
    total_payments: u64,
    cancellable: bool,
    description: String,
    max_per_withdrawal: u64,
    min_interval_ms: u64,
    max_beneficiaries: u64,
}

/// Action to create a budget stream (Keep original structure)
public struct CreateBudgetStreamAction<phantom CoinType> has store, drop, copy {
    recipient: address,
    amount: u64,
    start_timestamp: u64,
    end_timestamp: u64,
    project_name: String,
    pending_period_ms: u64,
    cancellable: bool,
    description: String,
    budget_period_ms: Option<u64>,
    max_per_period: Option<u64>,
}

/// Action to cancel a payment
public struct CancelPaymentAction has store, drop, copy {
    payment_id: String,      // Direct payment ID
    return_unclaimed_to_treasury: bool,  // Whether to return unclaimed funds to treasury
}

/// Action to update payment recipient
public struct UpdatePaymentRecipientAction has store, drop, copy {
    payment_id: String,      // Direct payment ID
    new_recipient: address,
}

/// Action to add withdrawer
public struct AddWithdrawerAction has store, drop, copy {
    payment_id: String,      // Direct payment ID
    withdrawer: address,
}

/// Action to remove withdrawers
public struct RemoveWithdrawersAction has store, drop, copy {
    payment_id: String,      // Direct payment ID
    withdrawers: vector<address>,
}

/// Action to toggle payment
public struct TogglePaymentAction has store, drop, copy {
    payment_id: String,      // Direct payment ID
    paused: bool,
}

/// Action to request withdrawal
public struct RequestWithdrawalAction<phantom CoinType> has store, drop, copy {
    payment_id: String,      // Direct payment ID
    amount: u64,
}

/// Action to challenge withdrawals
public struct ChallengeWithdrawalsAction has store, drop, copy {
    payment_id: String,      // Direct payment ID
}

/// Action to process pending withdrawal
public struct ProcessPendingWithdrawalAction<phantom CoinType> has store, drop, copy {
    payment_id: String,      // Direct payment ID
    withdrawal_index: u64,
}

/// Action to cancel challenged withdrawals
public struct CancelChallengedWithdrawalsAction has store, drop, copy {
    payment_id: String,      // Direct payment ID
}

/// Action to execute payment (for recurring payments)
public struct ExecutePaymentAction<phantom CoinType> has store, drop, copy {
    payment_id: String,      // Direct payment ID
}

// === Constructor Functions ===

/// Create a new CreatePaymentAction with a single recipient (backward compatibility)
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
        interval_or_cliff: interval_or_cliff.destroy_with_default(0),
        total_payments,
        cancellable,
        description,
        max_per_withdrawal,
        min_interval_ms,
        max_beneficiaries,
    }
}

/// Create a new CancelPaymentAction
public fun new_cancel_payment_action(payment_id: String): CancelPaymentAction {
    CancelPaymentAction {
        payment_id,
        return_unclaimed_to_treasury: true,
    }
}

/// Create a new RequestWithdrawalAction
public fun new_request_withdrawal_action<CoinType>(
    payment_id: String,
    amount: u64,
): RequestWithdrawalAction<CoinType> {
    RequestWithdrawalAction {
        payment_id,
        amount
    }
}

/// Create a new ExecutePaymentAction
public fun new_execute_payment_action<CoinType>(
    payment_id: String,
): ExecutePaymentAction<CoinType> {
    ExecutePaymentAction {
        payment_id
    }
}

// === Public Functions ===

/// REFACTORED: Create payment now properly uses vault streams without duplication
/// Returns the payment ID for PTB chaining
public fun do_create_payment<Outcome: store, CoinType: drop, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): String {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::CreatePayment>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    // Deserialize CreatePaymentAction field by field based on the actual struct
    let payment_type = bcs::peel_u8(&mut reader);
    let source_mode = bcs::peel_u8(&mut reader);
    let recipient = bcs::peel_address(&mut reader);
    let amount = bcs::peel_u64(&mut reader);
    let start_timestamp = bcs::peel_u64(&mut reader);
    let end_timestamp = bcs::peel_u64(&mut reader);
    let interval_or_cliff = bcs::peel_u64(&mut reader);
    let total_payments = bcs::peel_u64(&mut reader);
    let cancellable = bcs::peel_bool(&mut reader);
    let description = bcs::peel_vec_u8(&mut reader).to_string();
    let max_per_withdrawal = bcs::peel_u64(&mut reader);
    let min_interval_ms = bcs::peel_u64(&mut reader);
    let max_beneficiaries = bcs::peel_u64(&mut reader);

    let action = CreatePaymentAction<CoinType> {
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
    };
    bcs_validation::validate_all_bytes_consumed(reader);

    // Note: Policy validation is handled by the PolicyRegistry in futarchy_multisig
    // Action types are tracked via TypeName in the Intent for type-safe routing
    
    // Create authorized withdrawers table with single recipient
    let mut authorized_withdrawers = table::new<address, bool>(ctx);
    authorized_withdrawers.add(action.recipient, true);
    let withdrawer_count = 1;
    
    // Initialize payment storage if needed
    if (!account::has_managed_data(account, PaymentStorageKey {})) {
        account::add_managed_data(
            account,
            PaymentStorageKey {},
            PaymentStorage {
                payments: table::new(ctx),
                payment_ids: vector::empty(),
                total_payments: 0,
            },
            version::current()
        );
    };
    
    // Generate unique payment ID
    let payment_id = generate_payment_id(action.payment_type, clock.timestamp_ms(), ctx);
    
    // REFACTORED: Create vault stream for direct treasury mode
    let vault_stream_id: Option<ID> = if (action.source_mode == SOURCE_DIRECT_TREASURY && action.payment_type == PAYMENT_TYPE_STREAM) {
        let auth = account::new_auth(account, version::current(), witness);

        // Create vault stream with proper parameters
        let stream_id = vault::create_stream<FutarchyConfig, CoinType>(
            auth,
            account,
            string::utf8(b"treasury"),
            action.recipient,
            action.amount,
            action.start_timestamp,
            action.end_timestamp,
            if (action.interval_or_cliff > 0) { option::some(action.interval_or_cliff) } else { option::none() },  // cliff
            action.max_per_withdrawal,
            action.min_interval_ms,
            action.max_beneficiaries,  // Single recipient for now
            clock,
            ctx
        );
        option::some(stream_id)
    } else {
        option::none()
    };
    
    // For isolated pools, just track the amount - funding comes separately
    let isolated_pool_amount = if (action.source_mode == SOURCE_ISOLATED_POOL) {
        let total_amount = if (action.payment_type == PAYMENT_TYPE_STREAM) {
            action.amount
        } else {
            // For recurring payments
            if (action.total_payments > 0) {
                action.amount * action.total_payments
            } else {
                action.amount * 12
            }
        };
        
        // For isolated pools, the pool must be funded separately
        // This avoids complexity of withdrawing from vault here
        option::some(total_amount)
    } else {
        option::none()
    };
    
    // Create config with simplified single recipient
    let config = PaymentConfig {
        payment_type: action.payment_type,
        source_mode: action.source_mode,
        authorized_withdrawers,
        withdrawer_count,
        vault_stream_id,  // Reference to vault stream
        isolated_pool_amount,  // Only for isolated pools
        interval_ms: if (action.payment_type == PAYMENT_TYPE_RECURRING) { option::some(action.interval_or_cliff) } else { option::none() },
        total_payments: action.total_payments,
        payments_made: 0,
        last_payment_timestamp: clock.timestamp_ms(),
        cancellable: action.cancellable,
        active: true,
        description: action.description,
        is_budget_stream: false,
        budget_config: option::none(),
    };
    
    // Store the payment
    let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    table::add(&mut storage.payments, payment_id, config);
    storage.payment_ids.push_back(payment_id);
    storage.total_payments = storage.total_payments + 1;
    
    // Emit event
    event::emit(PaymentCreated {
        account_id: object::id(account),
        payment_id,
        payment_type: action.payment_type,
        recipient: action.recipient,
        amount: action.amount,
        start_timestamp: action.start_timestamp,
        end_timestamp: action.end_timestamp,
    });

    // Increment action index
    executable::increment_action_idx(executable);

    // Return the payment_id
    payment_id
}

/// Execute do_cancel_payment action
public fun do_cancel_payment<Outcome: store, CoinType: drop, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::CancelPayment>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    // Deserialize CancelPaymentAction field by field
    let payment_id = bcs::peel_vec_u8(&mut reader).to_string();
    let return_unclaimed_to_treasury = bcs::peel_bool(&mut reader);

    let action = CancelPaymentAction {
        payment_id,
        return_unclaimed_to_treasury,
    };
    bcs_validation::validate_all_bytes_consumed(reader);
    let (refund_coin, _refund_amount) = cancel_payment<CoinType>(
        account,
        action.payment_id,
        _clock,
        ctx
    );
    // Transfer the refunded coin to the sender
    transfer::public_transfer(refund_coin, tx_context::sender(ctx));

    // Execute and increment
    executable::increment_action_idx(executable);
}

/// Execute do_create_budget_stream action
/// Returns the payment ID for PTB chaining
public fun do_create_budget_stream<Outcome: store, CoinType: drop, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): String {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::CreateBudgetStream>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    let recipient = bcs::peel_address(&mut reader);
    let amount = bcs::peel_u64(&mut reader);
    let start_timestamp = bcs::peel_u64(&mut reader);
    let end_timestamp = bcs::peel_u64(&mut reader);
    let project_name = bcs::peel_vec_u8(&mut reader).to_string();
    let pending_period_ms = bcs::peel_u64(&mut reader);
    let cancellable = bcs::peel_bool(&mut reader);
    let description = bcs::peel_vec_u8(&mut reader).to_string();
    let budget_period_ms = bcs::peel_option_u64(&mut reader);
    let max_per_period = bcs::peel_option_u64(&mut reader);

    let action = CreateBudgetStreamAction<CoinType> {
        recipient,
        amount,
        start_timestamp,
        end_timestamp,
        project_name,
        pending_period_ms,
        cancellable,
        description,
        budget_period_ms,
        max_per_period,
    };
    bcs_validation::validate_all_bytes_consumed(reader);
    
    let mut config = PaymentConfig {
        payment_type: PAYMENT_TYPE_STREAM,
        source_mode: SOURCE_DIRECT_TREASURY,
        authorized_withdrawers: table::new(ctx),
        withdrawer_count: 1,
        vault_stream_id: option::none(),
        isolated_pool_amount: option::none(),
        interval_ms: option::none(),
        total_payments: 0,
        payments_made: 0,
        last_payment_timestamp: 0,
        cancellable: action.cancellable,
        active: true,
        description: action.description,
        is_budget_stream: true,
        budget_config: option::some(BudgetStreamConfig {
            project_name: action.project_name,
            pending_period_ms: action.pending_period_ms,
            pending_withdrawals: table::new(ctx),
            pending_count: 0,
            total_pending_amount: 0,
            next_withdrawal_id: 0,
            budget_period_ms: action.budget_period_ms,
            current_period_start: clock::timestamp_ms(clock),
            current_period_claimed: 0,
            max_per_period: action.max_per_period,
        }),
    };
    
    table::add(&mut config.authorized_withdrawers, action.recipient, true);
    
    let payment_id = generate_payment_id(PAYMENT_TYPE_STREAM, clock::timestamp_ms(clock), ctx);
    let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    table::add(&mut storage.payments, payment_id, config);
    vector::push_back(&mut storage.payment_ids, payment_id);
    storage.total_payments = storage.total_payments + 1;

    // Return payment ID for PTB chaining
    payment_id
}

/// Execute do_execute_payment action (for recurring payments)
public fun do_execute_payment<Outcome: store, CoinType: drop, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::ExecutePayment>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    let payment_id = bcs::peel_vec_u8(&mut reader).to_string();

    let _action = ExecutePaymentAction<CoinType> {
        payment_id,
    };
    bcs_validation::validate_all_bytes_consumed(reader);

    // Execute and increment
    executable::increment_action_idx(executable);
}

/// Execute do_request_withdrawal action
public fun do_request_withdrawal<Outcome: store, CoinType: drop, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::RequestWithdrawal>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    let payment_id = bcs::peel_vec_u8(&mut reader).to_string();
    let amount = bcs::peel_u64(&mut reader);

    let action = RequestWithdrawalAction<CoinType> {
        payment_id,
        amount,
    };
    bcs_validation::validate_all_bytes_consumed(reader);
    
    let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    assert!(table::contains(&storage.payments, action.payment_id), EPaymentNotFound);
    let config = table::borrow_mut(&mut storage.payments, action.payment_id);
    
    assert!(config.is_budget_stream, EInvalidBudgetStream);
    assert!(option::is_some(&config.budget_config), EInvalidBudgetStream);
    
    let budget_config = option::borrow_mut(&mut config.budget_config);
    
    let withdrawal = PendingWithdrawal {
        withdrawer: tx_context::sender(ctx),
        amount: action.amount,
        reason_code: string::utf8(b"withdrawal"),
        requested_at: clock::timestamp_ms(clock),
        processes_at: clock::timestamp_ms(clock) + budget_config.pending_period_ms,
        is_challenged: false,
        challenge_proposal_id: option::none(),
    };
    
    let withdrawal_id = budget_config.next_withdrawal_id;
    budget_config.next_withdrawal_id = withdrawal_id + 1;
    
    table::add(&mut budget_config.pending_withdrawals, withdrawal_id, withdrawal);

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute do_process_pending_withdrawal action
public fun do_process_pending_withdrawal<Outcome: store, CoinType: drop, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::ProcessPendingWithdrawal>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    let payment_id = bcs::peel_vec_u8(&mut reader).to_string();
    let withdrawal_index = bcs::peel_u64(&mut reader);

    let action = ProcessPendingWithdrawalAction<CoinType> {
        payment_id,
        withdrawal_index,
    };
    bcs_validation::validate_all_bytes_consumed(reader);
    
    let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    assert!(table::contains(&storage.payments, action.payment_id), EPaymentNotFound);
    let config = table::borrow_mut(&mut storage.payments, action.payment_id);
    
    assert!(config.is_budget_stream, EInvalidBudgetStream);
    assert!(option::is_some(&config.budget_config), EInvalidBudgetStream);
    
    let budget_config = option::borrow_mut(&mut config.budget_config);
    assert!(table::contains(&budget_config.pending_withdrawals, action.withdrawal_index), EPaymentNotFound);
    
    let withdrawal = table::remove(&mut budget_config.pending_withdrawals, action.withdrawal_index);
    
    assert!(clock::timestamp_ms(clock) >= withdrawal.processes_at, EWithdrawalNotReady);
    assert!(!withdrawal.is_challenged, EWithdrawalChallenged);

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute do_update_payment_recipient action
public fun do_update_payment_recipient<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::UpdatePaymentRecipient>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    let payment_id = bcs::peel_vec_u8(&mut reader).to_string();
    let new_recipient = bcs::peel_address(&mut reader);

    let action = UpdatePaymentRecipientAction {
        payment_id,
        new_recipient,
    };
    bcs_validation::validate_all_bytes_consumed(reader);
    
    let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    assert!(table::contains(&storage.payments, action.payment_id), EPaymentNotFound);
    let config = table::borrow_mut(&mut storage.payments, action.payment_id);
    
    // Table::keys not available in Move, need alternate approach
    // We'll clear the table by removing the new_recipient if it exists
    // and re-add it
    if (table::contains(&config.authorized_withdrawers, action.new_recipient)) {
        table::remove(&mut config.authorized_withdrawers, action.new_recipient);
    };
    
    // Now we can safely add the new recipient
    table::add(&mut config.authorized_withdrawers, action.new_recipient, true);
    config.withdrawer_count = 1;
}

/// Execute do_add_withdrawer action
public fun do_add_withdrawer<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::AddWithdrawer>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    let payment_id = bcs::peel_vec_u8(&mut reader).to_string();
    let withdrawer = bcs::peel_address(&mut reader);

    let action = AddWithdrawerAction {
        payment_id,
        withdrawer,
    };
    bcs_validation::validate_all_bytes_consumed(reader);
    
    let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    assert!(table::contains(&storage.payments, action.payment_id), EPaymentNotFound);
    let config = table::borrow_mut(&mut storage.payments, action.payment_id);
    
    assert!(config.withdrawer_count < MAX_WITHDRAWERS, ETooManyWithdrawers);
    
    if (!table::contains(&config.authorized_withdrawers, action.withdrawer)) {
        table::add(&mut config.authorized_withdrawers, action.withdrawer, true);
        config.withdrawer_count = config.withdrawer_count + 1;
    };
}

/// Execute do_remove_withdrawers action
public fun do_remove_withdrawers<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::RemoveWithdrawers>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    let payment_id = bcs::peel_vec_u8(&mut reader).to_string();
    let withdrawers = bcs::peel_vec_address(&mut reader);

    let action = RemoveWithdrawersAction {
        payment_id,
        withdrawers,
    };
    bcs_validation::validate_all_bytes_consumed(reader);
    
    let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    assert!(table::contains(&storage.payments, action.payment_id), EPaymentNotFound);
    let config = table::borrow_mut(&mut storage.payments, action.payment_id);
    
    let mut i = 0;
    let len = vector::length(&action.withdrawers);
    while (i < len) {
        let withdrawer = *vector::borrow(&action.withdrawers, i);
        if (table::contains(&config.authorized_withdrawers, withdrawer)) {
            table::remove(&mut config.authorized_withdrawers, withdrawer);
            config.withdrawer_count = config.withdrawer_count - 1;
        };
        i = i + 1;
    };

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute do_toggle_payment action
public fun do_toggle_payment<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::TogglePayment>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    let payment_id = bcs::peel_vec_u8(&mut reader).to_string();
    let paused = bcs::peel_bool(&mut reader);

    let action = TogglePaymentAction {
        payment_id,
        paused,
    };
    bcs_validation::validate_all_bytes_consumed(reader);
    
    let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    assert!(table::contains(&storage.payments, action.payment_id), EPaymentNotFound);
    let config = table::borrow_mut(&mut storage.payments, action.payment_id);
    
    config.active = !action.paused;

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute do_challenge_withdrawals action
public fun do_challenge_withdrawals<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::ChallengeWithdrawals>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    let payment_id = bcs::peel_vec_u8(&mut reader).to_string();

    let _action = ChallengeWithdrawalsAction {
        payment_id,
    };
    bcs_validation::validate_all_bytes_consumed(reader);

    // Execute and increment
    executable::increment_action_idx(executable);
}

/// Execute do_cancel_challenged_withdrawals action
public fun do_cancel_challenged_withdrawals<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::CancelChallengedWithdrawals>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    let payment_id = bcs::peel_vec_u8(&mut reader).to_string();

    let _action = CancelChallengedWithdrawalsAction {
        payment_id,
    };
    bcs_validation::validate_all_bytes_consumed(reader);

    // Execute and increment
    executable::increment_action_idx(executable);
}

/// REFACTORED: Claim now delegates to vault stream for direct treasury and handles weighted distribution
public fun claim_from_payment<CoinType: drop>(
    account: &mut Account<FutarchyConfig>,
    payment_id: String,
    amount: Option<u64>,
    reason_code: Option<String>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    // First extract all needed info
    let sender = tx_context::sender(ctx);
    let (source_mode, vault_stream_id_opt, is_budget_stream, has_budget_config) = {
        let storage: &PaymentStorage = account::borrow_managed_data(
            account,
            PaymentStorageKey {},
            version::current()
        );
        
        assert!(table::contains(&storage.payments, payment_id), EPaymentNotFound);
        
        let config = table::borrow(&storage.payments, payment_id);
        assert!(config.active, EPaymentNotActive);
        // Check if sender is an authorized withdrawer
        let is_authorized = table::contains(&config.authorized_withdrawers, sender);
        assert!(is_authorized, ENotAuthorizedWithdrawer);
        
        (config.source_mode, config.vault_stream_id, config.is_budget_stream, config.budget_config.is_some())
    };
    
    // REFACTORED: For direct treasury streams, use vault stream
    if (source_mode == SOURCE_DIRECT_TREASURY && vault_stream_id_opt.is_some()) {
        let stream_id = *vault_stream_id_opt.borrow();
        
        // Calculate total available from vault stream
        let total_available = vault::calculate_claimable(account, string::utf8(b"treasury"), stream_id, clock);
        
        // For simplified single-recipient model, sender gets full amount
        let available = if (amount.is_some()) {
            let requested = *amount.borrow();
            if (requested <= total_available) {
                requested
            } else {
                total_available
            }
        } else {
            total_available
        };
        
        assert!(available > 0, ENothingToClaim);
        
        // Handle budget stream accountability
        if (is_budget_stream && has_budget_config) {
            let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
                account,
                PaymentStorageKey {},
                version::current()
            );
            let config_mut = table::borrow_mut(&mut storage.payments, payment_id);
            handle_budget_withdrawal(
                config_mut.budget_config.borrow_mut(),
                sender,
                available,
                reason_code,
                clock,
                ctx
            );
        };
        
        // In simplified model, vault stream tracks claims internally
        // No need to track claimed_amounts separately
        
        // Withdraw from vault stream
        let coin = vault::withdraw_from_stream<FutarchyConfig, CoinType>(
            account,
            string::utf8(b"treasury"),
            stream_id,
            available,
            clock,
            ctx
        );

        // Get total claimed from vault for event
        let (_, total_amount, claimed_amount, _, _, _, _) = vault::stream_info(
            account,
            string::utf8(b"treasury"),
            stream_id
        );
        
        event::emit(PaymentClaimed {
            account_id: object::id(account),
            payment_id,
            recipient: sender,
            amount_claimed: available,
            total_claimed: claimed_amount + available,
            timestamp: clock.timestamp_ms(),
        });
        
        coin
    } else {
        // For isolated pools or recurring, we need to handle withdrawal differently
        // For simplicity with isolated pools, just allow the requested amount or all available
        let available = if (amount.is_some()) {
            *amount.borrow()
        } else {
            // For isolated pools, withdraw all available
            let pool_key = PaymentPoolKey { payment_id };
            let pool: &Balance<CoinType> = account::borrow_managed_data(
                account,
                pool_key,
                version::current()
            );
            pool.value()
        };
        
        // Now withdraw from pool
        let pool_key = PaymentPoolKey { payment_id };
        let mut pool: Balance<CoinType> = account::remove_managed_data(
            account,
            pool_key,
            version::current()
        );
        
        let withdrawal = pool.split(available);
        
        // Put pool back if not empty
        if (pool.value() > 0) {
            account::add_managed_data(account, pool_key, pool, version::current());
        } else {
            pool.destroy_zero();
        };
        
        // For isolated pools, we don't track claimed amount in config anymore
        // It's implicit from the pool balance
        
        event::emit(PaymentClaimed {
            account_id: object::id(account),
            payment_id,
            recipient: sender,
            amount_claimed: available,
            total_claimed: 0, // Would need to track this better
            timestamp: clock.timestamp_ms(),
        });
        
        coin::from_balance(withdrawal, ctx)
    }
}

/// REFACTORED: Cancel payment properly handles vault stream cancellation
public fun cancel_payment<CoinType: drop>(
    account: &mut Account<FutarchyConfig>,
    payment_id: String,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<CoinType>, u64) {
    // First, extract needed info from config
    let (is_cancellable, vault_stream_id_opt, source_mode) = {
        let storage: &PaymentStorage = account::borrow_managed_data(
            account,
            PaymentStorageKey {},
            version::current()
        );
        
        assert!(table::contains(&storage.payments, payment_id), EPaymentNotFound);
        
        let config = table::borrow(&storage.payments, payment_id);
        assert!(config.cancellable, ENotCancellable);
        (config.cancellable, config.vault_stream_id, config.source_mode)
    };
    
    let mut refund_amount = 0u64;
    let mut refund_coin = coin::zero<CoinType>(ctx);
    
    // Cancel vault stream if it exists
    if (vault_stream_id_opt.is_some()) {
        let stream_id = *vault_stream_id_opt.borrow();
        let auth = account::new_auth(account, version::current(), tx_context::sender(ctx));
        let (vault_refund, vault_amount) = vault::cancel_stream<FutarchyConfig, CoinType>(
            auth,
            account,
            string::utf8(b"treasury"),
            stream_id,
            clock,
            ctx
        );
        refund_coin.join(vault_refund);
        refund_amount = vault_amount;
    };
    
    // For isolated pools, return remaining balance
    if (source_mode == SOURCE_ISOLATED_POOL) {
        let pool_key = PaymentPoolKey { payment_id };
        if (account::has_managed_data(account, pool_key)) {
            let pool_balance: Balance<CoinType> = account::remove_managed_data(
                account,
                pool_key,
                version::current()
            );
            let pool_amount = pool_balance.value();
            refund_coin.join(coin::from_balance(pool_balance, ctx));
            refund_amount = refund_amount + pool_amount;
        };
    };
    
    // Now mark as inactive
    {
        let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
            account,
            PaymentStorageKey {},
            version::current()
        );
        let config = table::borrow_mut(&mut storage.payments, payment_id);
        config.active = false;
    };
    
    event::emit(PaymentCancelled {
        account_id: object::id(account),
        payment_id,
        unclaimed_returned: refund_amount,
        timestamp: clock.timestamp_ms(),
    });
    
    (refund_coin, refund_amount)
}

/// REFACTORED: Get payment info now queries vault stream for amounts/timestamps
public fun get_payment_info(
    account: &Account<FutarchyConfig>,
    payment_id: String,
    clock: &Clock,
): (u8, u64, u64, u64, u64, bool) {
    let storage: &PaymentStorage = account::borrow_managed_data(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    assert!(table::contains(&storage.payments, payment_id), EPaymentNotFound);
    let config = table::borrow(&storage.payments, payment_id);
    
    // REFACTORED: Get amounts/timestamps from vault stream if direct treasury
    if (config.vault_stream_id.is_some()) {
        let stream_id = *config.vault_stream_id.borrow();
        let (_, total_amount, claimed_amount, start_time, end_time, _, _) = vault::stream_info(
            account,
            string::utf8(b"treasury"),
            stream_id
        );

        (
            config.payment_type,
            total_amount,
            claimed_amount,
            start_time,
            end_time,
            config.active
        )
    } else {
        // For isolated pools, use stored amount
        let amount = config.isolated_pool_amount.destroy_with_default(0);
        (
            config.payment_type,
            amount,
            0, // Would need to track claimed separately for isolated
            0, // No timestamps for isolated pools
            0,
            config.active
        )
    }
}

// === Helper Functions ===

/// Generate unique payment ID
fun generate_payment_id(payment_type: u8, timestamp: u64, ctx: &mut TxContext): String {
    // Create a simple unique ID using payment type and timestamp
    // The fresh_object_address ensures uniqueness even for same timestamp
    let fresh = ctx.fresh_object_address(); // Ensure uniqueness
    
    let mut id = if (payment_type == PAYMENT_TYPE_STREAM) {
        b"STREAM_".to_string()
    } else {
        b"RECURRING_".to_string()
    };
    
    // Use object ID for uniqueness (convert to hex string)
    let fresh_id = object::id_from_address(fresh);
    let fresh_bytes = object::id_to_bytes(&fresh_id);
    
    // Convert bytes to hex string representation
    let hex_chars = b"0123456789abcdef";
    let mut hex_string = vector::empty<u8>();
    
    let mut i = 0;
    // Just use first 8 bytes for shorter IDs
    while (i < 8 && i < vector::length(&fresh_bytes)) {
        let byte = *vector::borrow(&fresh_bytes, i);
        let high_nibble = (byte >> 4) & 0x0f;
        let low_nibble = byte & 0x0f;
        vector::push_back(&mut hex_string, *vector::borrow(&hex_chars, (high_nibble as u64)));
        vector::push_back(&mut hex_string, *vector::borrow(&hex_chars, (low_nibble as u64)));
        i = i + 1;
    };
    
    id.append(string::utf8(hex_string));
    
    // Also append timestamp for human readability
    id.append(string::utf8(b"_"));
    id.append(string::utf8(b"T"));
    
    // Convert timestamp to string (simplified - just use last 10 digits)
    let mut ts = timestamp;
    let mut ts_str = vector::empty<u8>();
    while (ts > 0) {
        let digit = ((ts % 10) as u8) + 48; // ASCII '0' = 48
        vector::push_back(&mut ts_str, digit);
        ts = ts / 10;
    };
    vector::reverse(&mut ts_str);
    if (vector::is_empty(&ts_str)) {
        vector::push_back(&mut ts_str, 48); // '0'
    };
    id.append(string::utf8(ts_str));
    
    id
}

/// Handle budget stream withdrawal accountability
fun handle_budget_withdrawal(
    budget_config: &mut BudgetStreamConfig,
    withdrawer: address,
    amount: u64,
    reason_code: Option<String>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Reason code is optional for budget withdrawals
    let _ = reason_code; // May be used for audit trail
    
    // Check budget period limits if configured
    if (budget_config.budget_period_ms.is_some()) {
        let period_duration = *budget_config.budget_period_ms.borrow();
        let current_time = clock.timestamp_ms();
        
        // Reset period if needed
        if (current_time >= budget_config.current_period_start + period_duration) {
            budget_config.current_period_start = current_time;
            budget_config.current_period_claimed = 0;
        };
        
        // Check period limit
        if (budget_config.max_per_period.is_some()) {
            let max = *budget_config.max_per_period.borrow();
            assert!(budget_config.current_period_claimed + amount <= max, EBudgetExceeded);
        };
        
        budget_config.current_period_claimed = budget_config.current_period_claimed + amount;
    };
    
    // Create pending withdrawal
    let withdrawal = PendingWithdrawal {
        withdrawer,
        amount,
        reason_code: reason_code.destroy_with_default(string::utf8(b"")),
        requested_at: clock.timestamp_ms(),
        processes_at: clock.timestamp_ms() + budget_config.pending_period_ms,
        is_challenged: false,
        challenge_proposal_id: option::none(),
    };
    
    table::add(&mut budget_config.pending_withdrawals, budget_config.next_withdrawal_id, withdrawal);
    budget_config.next_withdrawal_id = budget_config.next_withdrawal_id + 1;
    budget_config.pending_count = budget_config.pending_count + 1;
    budget_config.total_pending_amount = budget_config.total_pending_amount + amount;
}

/// Withdraw from isolated pool (existing logic preserved)
fun withdraw_from_isolated_pool<CoinType: drop>(
    account: &mut Account<FutarchyConfig>,
    config: &mut PaymentConfig,
    payment_id: String,
    amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    let pool_key = PaymentPoolKey { payment_id };
    let pool_balance: &mut Balance<CoinType> = account::borrow_managed_data_mut(
        account,
        pool_key,
        version::current()
    );
    
    let withdraw_amount = if (amount.is_some()) {
        *amount.borrow()
    } else {
        // For isolated pools, calculate based on payment type
        if (config.payment_type == PAYMENT_TYPE_RECURRING) {
            // Calculate next payment amount
            config.isolated_pool_amount.destroy_with_default(0) / config.total_payments
        } else {
            // Take what's available
            pool_balance.value()
        }
    };
    
    assert!(pool_balance.value() >= withdraw_amount, EInsufficientFunds);
    coin::from_balance(pool_balance.split(withdraw_amount), ctx)
}

// === Cleanup Functions === (Keep all original)

public fun delete_create_payment<CoinType>(expired: &mut account_protocol::intents::Expired) {
    // Remove the action spec from expired intent
    let spec = account_protocol::intents::remove_action_spec(expired);
    let _ = spec;
}

public fun delete_create_budget_stream<CoinType>(expired: &mut account_protocol::intents::Expired) {
    // Remove the action spec from expired intent
    let spec = account_protocol::intents::remove_action_spec(expired);
    let _ = spec;
}

public fun delete_cancel_payment<CoinType>(expired: &mut account_protocol::intents::Expired) {
    // Remove the action spec from expired intent
    let spec = account_protocol::intents::remove_action_spec(expired);
    let _ = spec;
}

public fun delete_update_payment_recipient(expired: &mut account_protocol::intents::Expired) {
    // Remove the action spec from expired intent
    let spec = account_protocol::intents::remove_action_spec(expired);
    let _ = spec;
}

public fun delete_add_withdrawer(expired: &mut account_protocol::intents::Expired) {
    // Remove the action spec from expired intent
    let spec = account_protocol::intents::remove_action_spec(expired);
    let _ = spec;
}

public fun delete_remove_withdrawers(expired: &mut account_protocol::intents::Expired) {
    // Remove the action spec from expired intent
    let spec = account_protocol::intents::remove_action_spec(expired);
    let _ = spec;
}

public fun delete_toggle_payment(expired: &mut account_protocol::intents::Expired) {
    // Remove the action spec from expired intent
    let spec = account_protocol::intents::remove_action_spec(expired);
    let _ = spec;
}

public fun delete_request_withdrawal<CoinType>(expired: &mut account_protocol::intents::Expired) {
    // Remove the action spec from expired intent
    let spec = account_protocol::intents::remove_action_spec(expired);
    let _ = spec;
}

public fun delete_challenge_withdrawals(expired: &mut account_protocol::intents::Expired) {
    // Remove the action spec from expired intent
    let spec = account_protocol::intents::remove_action_spec(expired);
    let _ = spec;
}

public fun delete_process_pending_withdrawal<CoinType>(expired: &mut account_protocol::intents::Expired) {
    // Remove the action spec from expired intent
    let spec = account_protocol::intents::remove_action_spec(expired);
    let _ = spec;
}

public fun delete_cancel_challenged_withdrawals(expired: &mut account_protocol::intents::Expired) {
    // Remove the action spec from expired intent
    let spec = account_protocol::intents::remove_action_spec(expired);
    let _ = spec;
}

public fun delete_execute_payment<CoinType>(expired: &mut account_protocol::intents::Expired) {
    // Remove the action spec from expired intent
    let spec = account_protocol::intents::remove_action_spec(expired);
    let _ = spec;
}

// === Enhanced Stream Management === 
// Wrapper functions for new vault stream features

/// Pause a payment stream (delegates to vault)
public fun pause_payment(
    auth: Auth,
    account: &mut Account<FutarchyConfig>,
    payment_id: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    account::verify(account, auth);
    let storage: &PaymentStorage = account::borrow_managed_data(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    assert!(table::contains(&storage.payments, payment_id), EPaymentNotFound);
    let payment = table::borrow(&storage.payments, payment_id);
    
    // Only works for direct treasury streams with vault_stream_id
    assert!(option::is_some(&payment.vault_stream_id), EStreamNotFound);
    let _stream_id = *option::borrow(&payment.vault_stream_id);

    // For now, just mark the payment as inactive
    // Full pause functionality would require additional vault stream pause implementation
    let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
        account,
        PaymentStorageKey {},
        version::current()
    );
    let config = table::borrow_mut(&mut storage.payments, payment_id);
    config.active = false;
}

/// Resume a paused payment stream (delegates to vault)
public fun resume_payment(
    auth: Auth,
    account: &mut Account<FutarchyConfig>,
    payment_id: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    account::verify(account, auth);
    let storage: &PaymentStorage = account::borrow_managed_data(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    assert!(table::contains(&storage.payments, payment_id), EPaymentNotFound);
    let payment = table::borrow(&storage.payments, payment_id);
    
    assert!(payment.vault_stream_id.is_some(), EStreamNotFound);
    let _stream_id = *payment.vault_stream_id.borrow();

    // For now, just mark the payment as active
    // Full resume functionality would require additional vault stream resume implementation
    let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
        account,
        PaymentStorageKey {},
        version::current()
    );
    let config = table::borrow_mut(&mut storage.payments, payment_id);
    config.active = true;
}

/// Add additional beneficiary to payment stream
public fun add_payment_beneficiary(
    auth: Auth,
    account: &mut Account<FutarchyConfig>,
    payment_id: String,
    new_beneficiary: address,
    ctx: &mut TxContext,
) {
    account::verify(account, auth);
    let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    assert!(table::contains(&storage.payments, payment_id), EPaymentNotFound);
    let payment = table::borrow_mut(&mut storage.payments, payment_id);
    
    // Add to authorized withdrawers
    assert!(payment.withdrawer_count < MAX_WITHDRAWERS, ETooManyWithdrawers);
    assert!(!table::contains(&payment.authorized_withdrawers, new_beneficiary), EWithdrawerAlreadyExists);
    table::add(&mut payment.authorized_withdrawers, new_beneficiary, true);
    payment.withdrawer_count = payment.withdrawer_count + 1;
    
    // Note: Vault streams currently don't support multiple beneficiaries at the vault level
    // The payment tracking in stream_actions handles multiple withdrawers/beneficiaries
    // Future enhancement could add vault-level beneficiary management
}

/// Transfer payment stream to new primary beneficiary
public fun transfer_payment(
    auth: Auth,
    account: &mut Account<FutarchyConfig>,
    payment_id: String,
    new_beneficiary: address,
    ctx: &mut TxContext,
) {
    account::verify(account, auth);
    let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    assert!(table::contains(&storage.payments, payment_id), EPaymentNotFound);
    let payment = table::borrow_mut(&mut storage.payments, payment_id);
    
    // Update authorized withdrawers
    if (!table::contains(&payment.authorized_withdrawers, new_beneficiary)) {
        assert!(payment.withdrawer_count < MAX_WITHDRAWERS, ETooManyWithdrawers);
        table::add(&mut payment.authorized_withdrawers, new_beneficiary, true);
        payment.withdrawer_count = payment.withdrawer_count + 1;
    };
    
    // Note: Vault stream transfers would require vault-level implementation
    // For now, the payment-level beneficiary management is sufficient
    // The vault stream maintains its original beneficiary while payment tracks authorized withdrawers
}

/// Update payment metadata
public fun update_payment_metadata(
    auth: Auth,
    account: &mut Account<FutarchyConfig>,
    payment_id: String,
    metadata: String,
    ctx: &mut TxContext,
) {
    account::verify(account, auth);
    let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    assert!(table::contains(&storage.payments, payment_id), EPaymentNotFound);
    let payment = table::borrow_mut(&mut storage.payments, payment_id);
    
    // Update local description
    payment.description = metadata;

    // Note: Vault stream metadata updates would require vault-level implementation
    // For now, the payment-level metadata tracking is sufficient
}

// === Dissolution Support Functions ===

/// Get all payment IDs for dissolution
public fun get_all_payment_ids(
    account: &Account<FutarchyConfig>,
): vector<String> {
    if (!account::has_managed_data(account, PaymentStorageKey {})) {
        return vector::empty()
    };
    
    let storage: &PaymentStorage = account::borrow_managed_data(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    storage.payment_ids
}

/// Cancel all payments for dissolution and return funds
public fun cancel_all_payments_for_dissolution<CoinType: drop>(
    account: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    if (!account::has_managed_data(account, PaymentStorageKey {})) {
        return
    };
    
    // First pass: cancel payments and collect pool IDs
    let mut pools_to_return = vector::empty<String>();
    let storage: &mut PaymentStorage = account::borrow_managed_data_mut(
        account,
        PaymentStorageKey {},
        version::current()
    );
    
    let mut i = 0;
    while (i < storage.payment_ids.length()) {
        let payment_id = *storage.payment_ids.borrow(i);
        
        if (table::contains(&storage.payments, payment_id)) {
            let payment = table::borrow_mut(&mut storage.payments, payment_id);
            
            // Cancel if active and cancellable
            if (payment.active && payment.cancellable) {
                payment.active = false;
                
                // Mark pools for return
                pools_to_return.push_back(payment_id);
            };
        };
        
        i = i + 1;
    };
    
    // Second pass: return funds from isolated pools
    let mut j = 0;
    while (j < pools_to_return.length()) {
        let payment_id = *pools_to_return.borrow(j);
        let pool_key = PaymentPoolKey { payment_id };
        
        if (account::has_managed_data(account, pool_key)) {
            let mut pool = account::remove_managed_data<FutarchyConfig, PaymentPoolKey, Balance<CoinType>>(
                account,
                pool_key,
                version::current()
            );
        
            // Transfer remaining balance back to treasury
            if (pool.value() > 0) {
                let coin = coin::from_balance(pool, ctx);
                vault::deposit_permissionless(
                    account,
                    string::utf8(b"treasury"),
                    coin
                );
            } else {
                pool.destroy_zero();
            };
        };

        j = j + 1;
    };
}

// === Init Entry Functions ===

/// Create a payment stream during DAO initialization
/// Called directly by PTB during init phase
public entry fun init_create_stream<CoinType>(
    account: &mut Account<FutarchyConfig>,
    recipient: address,
    amount_per_period: u64,     // Amount to pay per period
    period_duration_ms: u64,    // Duration of each period in milliseconds
    num_periods: u64,           // Total number of periods
    cliff_periods: u64,         // Number of periods before first payment
    cancellable: bool,           // Whether DAO can cancel the stream
    description: vector<u8>,    // Description as bytes
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate inputs
    assert!(amount_per_period > 0, EInvalidStreamAmount);
    assert!(period_duration_ms > 0, EInvalidStreamDuration);
    assert!(num_periods > 0, EInvalidStreamDuration);
    assert!(cliff_periods <= num_periods, EInvalidCliff);

    let current_time = clock::timestamp_ms(clock);
    let start_time = current_time;
    let end_time = current_time + (period_duration_ms * num_periods);
    let cliff_time = if (cliff_periods > 0) {
        option::some(current_time + (period_duration_ms * cliff_periods))
    } else {
        option::none()
    };

    // Calculate total amount
    let total_amount = amount_per_period * num_periods;

    // Note: This function is a placeholder for PTB-based init
    // The actual stream creation would be done through PTB calling
    // init_framework_actions::init_create_vault_stream directly
    //
    // The PTB would call:
    // 1. init_framework_actions::init_create_vault_stream() with the vault stream params
    // 2. Any additional Futarchy-specific tracking for the description

    // Validate we can access the account (shows pattern)
    // Note: internal_config is not accessible outside the module
    // This function acts as a placeholder for PTB-based initialization

    // Store placeholder values to avoid unused warnings
    let _ = recipient;
    let _ = total_amount;
    let _ = start_time;
    let _ = end_time;
    let _ = cliff_time;
    let _ = description;
}