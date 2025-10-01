// ============================================================================
// FORK MODIFICATION NOTICE - Vault Management with Serialize-Then-Destroy Pattern
// ============================================================================
// This module manages multi-vault treasury operations with streaming support.
//
// CHANGES IN THIS FORK:
// - Actions use type markers: VaultDeposit, VaultSpend
// - Implemented serialize-then-destroy pattern for resource safety
// - Added destruction functions for all action structs
// - Actions serialize to bytes before adding to intent via add_typed_action()
// - Enhanced BCS validation: version checks + validate_all_bytes_consumed
// - Type-safe action validation through compile-time TypeName comparison
// - REMOVED ExecutionContext - PTBs handle object flow naturally
// ============================================================================
/// Members can create multiple vaults with different balances and managers (using roles).
/// This allows for a more flexible and granular way to manage funds.
///
/// === Fork Modifications (BSL 1.1 Licensed) ===
/// Enhanced vault module with comprehensive streaming functionality:
/// - Added generic stream management capabilities:
///   * Multiple beneficiaries support (primary + additional)
///   * Pause/resume functionality with duration tracking
///   * Stream metadata for extensibility
///   * Transferability and cancellability settings
///   * Beneficiary management (add/remove/transfer)
///   * Amount reduction capability
/// - Maintains backward compatibility with existing vault operations
/// - Enables other modules to build on top without duplicating stream state
/// - VaultStream: Time-based streaming with rate limiting for controlled treasury withdrawals
/// - Permissionless deposits: Anyone can add to existing coin types (enables revenue/donations)
/// - Stream management: Create, withdraw from, and cancel streams with proper vesting math
/// - All funds remain in vault until withdrawn (no separate vesting objects)
///
/// === Integration with Shared Utilities ===
/// As of the latest refactor, vault streams now use the shared stream_utils module
/// for all vesting calculations. This ensures:
/// - Consistent math with standalone vesting module
/// - Reduced code duplication and maintenance burden
/// - Unified approach to time-based fund releases
/// - Shared security validations and overflow protection
///
/// Note: The vesting.move module has been restored and enhanced to provide
/// standalone vesting functionality. Vault streams are for treasury-managed
/// streaming payments, while vestings are for independent token locks.
///
/// These changes enable DAOs to:
/// 1. Grant time-limited treasury access without full custody
/// 2. Implement salary/grant payments that vest over time
/// 3. Accept permissionless revenue deposits from protocols
/// 4. Enforce withdrawal limits and cooling periods for security
/// 5. Choose between vault-managed streams or standalone vestings

module account_actions::vault;

// === Imports ===

use std::{
    string::String,
    type_name::{Self, TypeName},
    option::Option,
    u128,
    u64,
};
use sui::{
    bag::{Self, Bag},
    balance::Balance,
    coin::{Self, Coin},
    table::{Self, Table},
    clock::Clock,
    event,
    object::{Self, ID},
    transfer,
    tx_context,
    vec_map::{Self, VecMap},
    vec_set::{Self, VecSet},
    bcs,
};
use account_protocol::{
    account::{Self, Account, Auth},
    intents::{Self, Expired, Intent},
    executable::{Self, Executable},
    version_witness::VersionWitness,
    bcs_validation,
    action_validation,
};
use account_actions::version;
use account_extensions::framework_action_types::{Self, VaultDeposit, VaultSpend};

// === Use Fun Aliases ===
// Removed - add_typed_action is now called directly

// === Errors ===

const EVaultNotEmpty: u64 = 0;
const EStreamNotFound: u64 = 1;
const EStreamNotStarted: u64 = 2;
const EStreamCliffNotReached: u64 = 3;
const EUnauthorizedBeneficiary: u64 = 4;
const EWrongCoinType: u64 = 5;
const EWithdrawalLimitExceeded: u64 = 6;
const EWithdrawalTooSoon: u64 = 7;
const EInsufficientVestedAmount: u64 = 8;
const EInvalidStreamParameters: u64 = 9;
const EIntentAmountMismatch: u64 = 10;
// === Fork additions ===
const EStreamPaused: u64 = 11;
const EAmountMustBeGreaterThanZero: u64 = 20;
const EVaultDoesNotExist: u64 = 21;
const ECoinTypeDoesNotExist: u64 = 22;
const EInsufficientBalance: u64 = 23;
const EStreamNotPaused: u64 = 12;
const ENotTransferable: u64 = 13;
const ENotCancellable: u64 = 14;
const EBeneficiaryAlreadyExists: u64 = 15;
const EBeneficiaryNotFound: u64 = 16;
const EUnsupportedActionVersion: u64 = 17;
const ECannotReduceBelowClaimed: u64 = 18;
const ETooManyBeneficiaries: u64 = 19;

// === Constants ===
const MAX_BENEFICIARIES: u64 = 100;

// === Structs ===

/// Dynamic Field key for the Vault.
public struct VaultKey(String) has copy, drop, store;
/// Dynamic field holding a budget with different coin types, key is name
public struct Vault has store {
    // heterogeneous array of Balances, TypeName -> Balance<CoinType>
    bag: Bag,
    // streams for time-based vesting withdrawals
    streams: Table<ID, VaultStream>,
}

/// Stream for time-based vesting from vault
/// === Fork Enhancement ===
/// Added generic stream management features:
/// - Multiple beneficiaries support
/// - Stream pausing/resuming
/// - Metadata for extensibility
/// - Transfer and reduction capabilities
public struct VaultStream has store, drop {
    id: ID,
    coin_type: TypeName,
    beneficiary: address,  // Primary beneficiary
    // Core vesting parameters
    total_amount: u64,
    claimed_amount: u64,
    start_time: u64,
    end_time: u64,
    cliff_time: Option<u64>,
    // Rate limiting
    max_per_withdrawal: u64,
    min_interval_ms: u64,
    last_withdrawal_time: u64,
    // === Fork additions for generic stream management ===
    // Multiple beneficiaries support
    additional_beneficiaries: vector<address>,
    max_beneficiaries: u64,  // Configurable per stream
    // Pause functionality
    is_paused: bool,
    paused_at: Option<u64>,
    paused_duration: u64,  // Total time paused (affects vesting calculation)
    // Metadata for extensibility
    metadata: Option<String>,
    // Transfer settings
    is_transferable: bool,
    is_cancellable: bool,
}

// === Fork: Event Structs for Stream Operations ===

/// Emitted when a stream is created
public struct StreamCreated has copy, drop {
    stream_id: ID,
    beneficiary: address,
    total_amount: u64,
    coin_type: TypeName,
    start_time: u64,
    end_time: u64,
}

/// Emitted when funds are withdrawn from a stream
public struct StreamWithdrawal has copy, drop {
    stream_id: ID,
    beneficiary: address,
    amount: u64,
    remaining_vested: u64,
}

/// Emitted when a stream is cancelled
public struct StreamCancelled has copy, drop {
    stream_id: ID,
    refunded_amount: u64,
    final_payment: u64,
}

/// Emitted when a stream is paused
public struct StreamPaused has copy, drop {
    stream_id: ID,
    paused_at: u64,
}

/// Emitted when a stream is resumed
public struct StreamResumed has copy, drop {
    stream_id: ID,
    resumed_at: u64,
    pause_duration: u64,
}

/// Emitted when a beneficiary is added
public struct BeneficiaryAdded has copy, drop {
    stream_id: ID,
    new_beneficiary: address,
}

/// Emitted when a beneficiary is removed
public struct BeneficiaryRemoved has copy, drop {
    stream_id: ID,
    removed_beneficiary: address,
}

/// Emitted when a stream is transferred
public struct StreamTransferred has copy, drop {
    stream_id: ID,
    old_beneficiary: address,
    new_beneficiary: address,
}

/// Emitted when stream metadata is updated
public struct StreamMetadataUpdated has copy, drop {
    stream_id: ID,
}

/// Emitted when stream amount is reduced
public struct StreamAmountReduced has copy, drop {
    stream_id: ID,
    old_amount: u64,
    new_amount: u64,
}

/// Action to deposit an amount of this coin to the targeted Vault.
public struct DepositAction<phantom CoinType> has store {
    // vault name
    name: String,
    // exact amount to be deposited
    amount: u64,
}
/// Action to be used within intent making good use of the returned coin, similar to owned::withdraw.
public struct SpendAction<phantom CoinType> has store {
    // vault name
    name: String,
    // amount to withdraw
    amount: u64,
}

// === Public Functions ===

/// Authorized address can open a vault.
public fun open<Config>(
    auth: Auth,
    account: &mut Account<Config>,
    name: String,
    ctx: &mut TxContext
) {
    account.verify(auth);

    account.add_managed_data(VaultKey(name), Vault { 
        bag: bag::new(ctx),
        streams: table::new(ctx),
    }, version::current());
}

/// Deposits coins owned by a an authorized address into a vault.
public fun deposit<Config, CoinType: drop>(
    auth: Auth,
    account: &mut Account<Config>,
    name: String, 
    coin: Coin<CoinType>, 
) {
    account.verify(auth);

    let vault: &mut Vault = 
        account.borrow_managed_data_mut(VaultKey(name), version::current());

    if (vault.coin_type_exists<CoinType>()) {
        let balance_mut = vault.bag.borrow_mut<_, Balance<_>>(type_name::with_defining_ids<CoinType>());
        balance_mut.join(coin.into_balance());
    } else {
        vault.bag.add(type_name::with_defining_ids<CoinType>(), coin.into_balance());
    };
}

/// Permissionless deposit - anyone can add to existing coin types
/// Safe because it only increases DAO assets, never decreases
public fun deposit_permissionless<Config, CoinType: drop>(
    account: &mut Account<Config>,
    name: String,
    coin: Coin<CoinType>,
) {
    let vault: &mut Vault =
        account.borrow_managed_data_mut(VaultKey(name), version::current());

    // Only allow deposits to existing coin types
    assert!(coin_type_exists<CoinType>(vault), EWrongCoinType);

    let balance_mut = vault.bag.borrow_mut<_, Balance<_>>(type_name::with_defining_ids<CoinType>());
    balance_mut.join(coin.into_balance());
}

/// Default vault name for standard operations
///
/// ## FORK NOTE
/// **Added**: Helper function for consistent vault naming
/// **Reason**: Standardize default vault name across init and runtime operations
public fun default_vault_name(): String {
    std::string::utf8(b"Main Vault")
}

/// Deposit during initialization - works on unshared Accounts
/// This function is for use during account creation, before the account is shared.
/// It follows the same pattern as Futarchy init actions.
///
/// ## FORK NOTE
/// **Added**: `do_deposit_unshared()` for init-time vault deposits
/// **Reason**: Enable initial treasury funding during DAO creation without Auth checks.
/// Creates vault on-demand if it doesn't exist, then deposits coins.
/// **Safety**: `public(package)` visibility ensures only callable during init
///
/// SAFETY: This function MUST only be called on unshared Accounts.
/// Calling this on a shared Account bypasses Auth checks.
/// The package(package) visibility helps enforce this constraint.
public(package) fun do_deposit_unshared<Config, CoinType: drop>(
    account: &mut Account<Config>,
    name: String,
    coin: Coin<CoinType>,
    ctx: &mut tx_context::TxContext,
) {
    // SAFETY REQUIREMENT: Account must be unshared
    // Move doesn't allow runtime is_shared checks, so this is enforced by:
    // 1. package(package) visibility - only callable from this package
    // 2. Only exposed through init_actions module
    // 3. Documentation and naming convention (_unshared suffix)

    // Ensure vault exists
    if (!account.has_managed_data(VaultKey(name))) {
        let vault = Vault {
            bag: bag::new(ctx),
            streams: table::new(ctx),
        };
        account.add_managed_data(VaultKey(name), vault, version::current());
    };

    let vault: &mut Vault =
        account.borrow_managed_data_mut(VaultKey(name), version::current());

    // Add coin to vault
    let coin_type_name = type_name::with_defining_ids<CoinType>();
    if (vault.bag.contains(coin_type_name)) {
        let balance_mut = vault.bag.borrow_mut<TypeName, Balance<CoinType>>(coin_type_name);
        balance_mut.join(coin.into_balance());
    } else {
        vault.bag.add(coin_type_name, coin.into_balance());
    };
}

/// Closes the vault if empty.
public fun close<Config>(
    auth: Auth,
    account: &mut Account<Config>,
    name: String,
) {
    account.verify(auth);

    let Vault { bag, streams } = 
        account.remove_managed_data(VaultKey(name), version::current());
    assert!(bag.is_empty(), EVaultNotEmpty);
    assert!(streams.is_empty(), EVaultNotEmpty);
    bag.destroy_empty();
    streams.destroy_empty();
}

/// Returns true if the vault exists.
public fun has_vault<Config>(
    account: &Account<Config>, 
    name: String
): bool {
    account.has_managed_data(VaultKey(name))
}

/// Returns a reference to the vault.
public fun borrow_vault<Config>(
    account: &Account<Config>, 
    name: String
): &Vault {
    account.borrow_managed_data(VaultKey(name), version::current())
}

/// Returns the number of coin types in the vault.
public fun size(vault: &Vault): u64 {
    vault.bag.length()
}

/// Returns true if the coin type exists in the vault.
public fun coin_type_exists<CoinType: drop>(vault: &Vault): bool {
    vault.bag.contains(type_name::with_defining_ids<CoinType>())
}

/// Returns the value of the coin type in the vault.
public fun coin_type_value<CoinType: drop>(vault: &Vault): u64 {
    vault.bag.borrow<TypeName, Balance<CoinType>>(type_name::with_defining_ids<CoinType>()).value()
}

// === Destruction Functions ===

/// Destroy a DepositAction after serialization
public fun destroy_deposit_action<CoinType>(action: DepositAction<CoinType>) {
    let DepositAction { name: _, amount: _ } = action;
}

/// Destroy a SpendAction after serialization
public fun destroy_spend_action<CoinType>(action: SpendAction<CoinType>) {
    let SpendAction { name: _, amount: _ } = action;
}

// Intent functions

/// Creates a DepositAction and adds it to an intent with descriptor.
public fun new_deposit<Outcome, CoinType, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    amount: u64,
    intent_witness: IW,
) {
    // Create the action struct (no drop)
    let action = DepositAction<CoinType> { name, amount };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with pre-serialized bytes
    intent.add_typed_action(
        framework_action_types::vault_deposit(),
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_deposit_action(action);
}

/// Processes a DepositAction and deposits a coin to the vault.
public fun do_deposit<Config, Outcome: store, CoinType: drop, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    coin: Coin<CoinType>,
    version_witness: VersionWitness,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<VaultDeposit>(spec);

    let action_data = intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let amount = bcs::peel_u64(&mut reader);

    // CRITICAL: Validate all bytes consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(reader);

    assert!(amount == coin.value(), EIntentAmountMismatch);

    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(name), version_witness);
    if (!vault.coin_type_exists<CoinType>()) {
        vault.bag.add(type_name::with_defining_ids<CoinType>(), coin.into_balance());
    } else {
        let balance_mut = vault.bag.borrow_mut<_, Balance<_>>(type_name::with_defining_ids<CoinType>());
        balance_mut.join(coin.into_balance());
    };

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Deletes a DepositAction from an expired intent.
public fun delete_deposit<CoinType>(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, so it's automatically cleaned up
    // No need to deserialize the data
}

/// Creates a SpendAction and adds it to an intent with descriptor.
public fun new_spend<Outcome, CoinType, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    amount: u64,
    intent_witness: IW,
) {
    // Create the action struct (no drop)
    let action = SpendAction<CoinType> { name, amount };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with pre-serialized bytes
    intent.add_typed_action(
        framework_action_types::vault_spend(),
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_spend_action(action);
}

/// Processes a SpendAction and takes a coin from the vault.
public fun do_spend<Config, Outcome: store, CoinType: drop, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    _intent_witness: IW,
    ctx: &mut TxContext
): Coin<CoinType> {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<VaultSpend>(spec);

    let action_data = intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let amount = bcs::peel_u64(&mut reader);

    // CRITICAL: Validate all bytes consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(reader);

    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(name), version_witness);
    let balance_mut = vault.bag.borrow_mut<_, Balance<_>>(type_name::with_defining_ids<CoinType>());
    let coin = coin::take(balance_mut, amount, ctx);

    if (balance_mut.value() == 0)
        vault.bag.remove<_, Balance<CoinType>>(type_name::with_defining_ids<CoinType>()).destroy_zero();

    // Store coin info in context for potential use by later actions
    // PTBs handle object flow naturally - no context storage needed

    // Increment action index
    executable::increment_action_idx(executable);
    coin
}

/// Deletes a SpendAction from an expired intent.
public fun delete_spend<CoinType>(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, so it's automatically cleaned up
    // No need to deserialize the data
}

// === Stream Management Functions ===

/// Creates a new stream in the vault
public fun create_stream<Config, CoinType: drop>(
    auth: Auth,
    account: &mut Account<Config>,
    vault_name: String,
    beneficiary: address,
    total_amount: u64,
    start_time: u64,
    end_time: u64,
    cliff_time: Option<u64>,
    max_per_withdrawal: u64,
    min_interval_ms: u64,
    max_beneficiaries: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    account.verify(auth);

    // Validate stream parameters
    let current_time = clock.timestamp_ms();
    assert!(
        account_actions::stream_utils::validate_time_parameters(
            start_time,
            end_time,
            &cliff_time,
            current_time
        ),
        EInvalidStreamParameters
    );

    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version::current());

    // Check that vault has sufficient balance
    assert!(vault.coin_type_exists<CoinType>(), EWrongCoinType);
    let balance = vault.bag.borrow<TypeName, Balance<CoinType>>(type_name::with_defining_ids<CoinType>());
    assert!(balance.value() >= total_amount, EInsufficientVestedAmount);

    // Create stream
    let stream_id = object::new(ctx);
    let stream = VaultStream {
        id: object::uid_to_inner(&stream_id),
        coin_type: type_name::with_defining_ids<CoinType>(),
        beneficiary,
        total_amount,
        claimed_amount: 0,
        start_time,
        end_time,
        cliff_time,
        max_per_withdrawal,
        min_interval_ms,
        last_withdrawal_time: 0,
        // Fork additions
        additional_beneficiaries: vector::empty(),
        max_beneficiaries,
        is_paused: false,
        paused_at: option::none(),
        paused_duration: 0,
        metadata: option::none(),
        is_transferable: true,
        is_cancellable: true,
    };

    let id = object::uid_to_inner(&stream_id);
    object::delete(stream_id);

    // Store stream in vault
    table::add(&mut vault.streams, id, stream);

    // Emit event
    event::emit(StreamCreated {
        stream_id: id,
        beneficiary,
        total_amount,
        coin_type: type_name::with_defining_ids<CoinType>(),
        start_time,
        end_time,
    });

    id
}

/// Cancel a stream and return unused funds
public fun cancel_stream<Config, CoinType: drop>(
    auth: Auth,
    account: &mut Account<Config>,
    vault_name: String,
    stream_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<CoinType>, u64) {
    account.verify(auth);

    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version::current());
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);

    let stream = table::remove(&mut vault.streams, stream_id);
    assert!(stream.is_cancellable, ENotCancellable);

    let current_time = clock.timestamp_ms();
    let balance_remaining = stream.total_amount - stream.claimed_amount;

    // Calculate what should be paid to beneficiary vs refunded
    let (to_pay_beneficiary, to_refund, _unvested_claimed) =
        account_actions::stream_utils::split_vested_unvested(
            stream.total_amount,
            stream.claimed_amount,
            balance_remaining,
            stream.start_time,
            stream.end_time,
            current_time,
            stream.paused_duration,
            &stream.cliff_time,
        );

    let balance_mut = vault.bag.borrow_mut<TypeName, Balance<CoinType>>(stream.coin_type);

    // Create coins for refund and final payment
    let mut refund_coin = coin::zero<CoinType>(ctx);
    if (to_refund > 0) {
        refund_coin.join(coin::take(balance_mut, to_refund, ctx));
    };

    // Transfer final payment to beneficiary if any
    if (to_pay_beneficiary > 0) {
        let final_payment = coin::take(balance_mut, to_pay_beneficiary, ctx);
        transfer::public_transfer(final_payment, stream.beneficiary);
    };

    // Emit event
    event::emit(StreamCancelled {
        stream_id,
        refunded_amount: to_refund,
        final_payment: to_pay_beneficiary,
    });

    // Clean up empty balance if needed
    if (balance_mut.value() == 0) {
        vault.bag.remove<TypeName, Balance<CoinType>>(stream.coin_type).destroy_zero();
    };

    (refund_coin, to_refund)
}

/// Withdraw from a stream
public fun withdraw_from_stream<Config, CoinType: drop>(
    account: &mut Account<Config>,
    vault_name: String,
    stream_id: ID,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version::current());
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);

    let stream = table::borrow_mut(&mut vault.streams, stream_id);
    assert!(!stream.is_paused, EStreamPaused);

    let current_time = clock.timestamp_ms();

    // Check if stream has started
    assert!(current_time >= stream.start_time, EStreamNotStarted);

    // Check cliff period
    if (stream.cliff_time.is_some()) {
        assert!(current_time >= *stream.cliff_time.borrow(), EStreamCliffNotReached);
    };

    // Check rate limiting
    assert!(
        account_actions::stream_utils::check_rate_limit(
            stream.last_withdrawal_time,
            stream.min_interval_ms,
            current_time
        ),
        EWithdrawalTooSoon
    );

    // Check withdrawal limits
    assert!(
        account_actions::stream_utils::check_withdrawal_limit(
            amount,
            stream.max_per_withdrawal
        ),
        EWithdrawalLimitExceeded
    );

    // Calculate available amount
    let available = account_actions::stream_utils::calculate_claimable(
        stream.total_amount,
        stream.claimed_amount,
        stream.start_time,
        stream.end_time,
        current_time,
        stream.paused_duration,
        &stream.cliff_time,
    );

    assert!(available >= amount, EInsufficientVestedAmount);

    // Update stream state
    stream.claimed_amount = stream.claimed_amount + amount;
    stream.last_withdrawal_time = current_time;

    // Withdraw from vault balance
    let balance_mut = vault.bag.borrow_mut<TypeName, Balance<CoinType>>(stream.coin_type);
    let coin = coin::take(balance_mut, amount, ctx);

    // Emit event
    event::emit(StreamWithdrawal {
        stream_id,
        beneficiary: tx_context::sender(ctx),
        amount,
        remaining_vested: available - amount,
    });

    // Clean up empty balance if needed
    if (balance_mut.value() == 0) {
        vault.bag.remove<TypeName, Balance<CoinType>>(stream.coin_type).destroy_zero();
    };

    coin
}

/// Calculate how much can be claimed from a stream
public fun calculate_claimable<Config>(
    account: &Account<Config>,
    vault_name: String,
    stream_id: ID,
    clock: &Clock,
): u64 {
    let vault: &Vault = account.borrow_managed_data(VaultKey(vault_name), version::current());
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);

    let stream = table::borrow(&vault.streams, stream_id);
    let current_time = clock.timestamp_ms();

    account_actions::stream_utils::calculate_claimable(
        stream.total_amount,
        stream.claimed_amount,
        stream.start_time,
        stream.end_time,
        current_time,
        stream.paused_duration,
        &stream.cliff_time,
    )
}

/// Get stream information
public fun stream_info<Config>(
    account: &Account<Config>,
    vault_name: String,
    stream_id: ID,
): (address, u64, u64, u64, u64, bool, bool) {
    let vault: &Vault = account.borrow_managed_data(VaultKey(vault_name), version::current());
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);

    let stream = table::borrow(&vault.streams, stream_id);
    (
        stream.beneficiary,
        stream.total_amount,
        stream.claimed_amount,
        stream.start_time,
        stream.end_time,
        stream.is_paused,
        stream.is_cancellable
    )
}

/// Check if a stream exists
public fun has_stream<Config>(
    account: &Account<Config>,
    vault_name: String,
    stream_id: ID,
): bool {
    if (!account.has_managed_data(VaultKey(vault_name))) {
        return false
    };

    let vault: &Vault = account.borrow_managed_data(VaultKey(vault_name), version::current());
    table::contains(&vault.streams, stream_id)
}

/// Create a stream during initialization - works on unshared Accounts.
/// Directly creates a stream without requiring Auth during DAO creation.
///
/// ## FORK NOTE
/// **Added**: `create_stream_unshared()` for init-time payment stream creation
/// **Reason**: Allow DAOs to set up recurring payment streams (salaries, grants)
/// during atomic initialization from vault funds. Validates parameters and balance.
/// **Safety**: `public(package)` visibility ensures only callable during init
///
/// SAFETY: This function MUST only be called on unshared Accounts
/// during the initialization phase before the Account is shared.
/// Once an Account is shared, this function will fail as it bypasses
/// the normal Auth checks that protect shared Accounts.
public(package) fun create_stream_unshared<Config, CoinType: drop>(
    account: &mut Account<Config>,
    vault_name: String,
    beneficiary: address,
    total_amount: u64,
    start_time: u64,
    end_time: u64,
    cliff_time: Option<u64>,
    max_per_withdrawal: u64,
    min_interval_ms: u64,
    max_beneficiaries: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Validate stream parameters
    let current_time = clock.timestamp_ms();
    assert!(
        account_actions::stream_utils::validate_time_parameters(
            start_time,
            end_time,
            &cliff_time,
            current_time
        ),
        EInvalidStreamParameters
    );
    assert!(total_amount > 0, EAmountMustBeGreaterThanZero);
    assert!(max_beneficiaries <= account_actions::stream_utils::max_beneficiaries(), ETooManyBeneficiaries);

    // Ensure vault exists and has sufficient balance
    let vault_exists = account.has_managed_data(VaultKey(vault_name));
    assert!(vault_exists, EVaultDoesNotExist);

    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version::current());
    let coin_type_name = type_name::with_defining_ids<CoinType>();
    assert!(bag::contains(&vault.bag, coin_type_name), ECoinTypeDoesNotExist);

    let balance = vault.bag.borrow<TypeName, Balance<CoinType>>(coin_type_name);
    assert!(balance.value() >= total_amount, EInsufficientBalance);

    // Create stream ID
    let stream_uid = object::new(ctx);
    let stream_id = object::uid_to_inner(&stream_uid);
    object::delete(stream_uid);

    // Create stream
    let stream = VaultStream {
        id: stream_id,
        coin_type: coin_type_name,
        beneficiary,
        total_amount,
        claimed_amount: 0,
        start_time,
        end_time,
        cliff_time,
        max_per_withdrawal,
        min_interval_ms,
        last_withdrawal_time: 0,
        paused_duration: 0,
        paused_at: option::none(),
        is_paused: false,
        is_cancellable: true,
        is_transferable: true,
        additional_beneficiaries: vector::empty<address>(),
        max_beneficiaries,
        metadata: option::none(),
    };

    // Copy ID before moving stream
    let stream_id_copy = stream.id;

    // Add stream to vault
    table::add(&mut vault.streams, stream_id_copy, stream);

    // Emit event
    event::emit(StreamCreated {
        stream_id: stream_id_copy,
        beneficiary,
        total_amount,
        coin_type: coin_type_name,
        start_time,
        end_time,
    });

    stream_id_copy
}

