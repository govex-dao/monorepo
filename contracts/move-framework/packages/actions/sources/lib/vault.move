// ============================================================================
// FORK MODIFICATION NOTICE - Vault Management with Serialize-Then-Destroy Pattern
// ============================================================================
// This module manages multi-vault treasury operations with streaming support.
//
// CHANGES IN THIS FORK:
// - Actions use type markers: VaultDeposit, VaultSpend
// - Added hot potato result types (SpendResult) for zero-cost action chaining
// - Implemented serialize-then-destroy pattern for resource safety
// - Added destruction functions for all action structs
// - Actions serialize to bytes before adding to intent via add_typed_action()
// - Enhanced BCS validation: version checks + validate_all_bytes_consumed
// - Type-safe action validation through compile-time TypeName comparison
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
    type_name::TypeName,
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
use account_protocol::action_results::{Self, SpendResult};

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
public struct VaultStream has store {
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
): (Coin<CoinType>, SpendResult) {
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

    // Create result for hot potato chaining
    let result = action_results::new_spend_result(
        object::id(&coin),
        amount,
        name
    );

    // Increment action index
    executable::increment_action_idx(executable);
    (coin, result)
}

/// Deletes a SpendAction from an expired intent.
public fun delete_spend<CoinType>(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, so it's automatically cleaned up
    // No need to deserialize the data
}

