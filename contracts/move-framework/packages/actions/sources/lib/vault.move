/// Members can create multiple vaults with different balances and managers (using roles).
/// This allows for a more flexible and granular way to manage funds.
///
/// === Fork Modifications ===
/// Enhanced vault module with comprehensive streaming functionality:
/// - Consolidated streaming/vesting features from removed vesting.move
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
/// Note: Removed standalone vesting.move module - all time-based payment features
/// are now integrated here to ensure treasury unity and simpler accounting.
///
/// These changes enable DAOs to:
/// 1. Grant time-limited treasury access without full custody
/// 2. Implement salary/grant payments that vest over time
/// 3. Accept permissionless revenue deposits from protocols
/// 4. Enforce withdrawal limits and cooling periods for security

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
};
use account_protocol::{
    account::{Account, Auth},
    intents::{Expired, Intent},
    executable::Executable,
    version_witness::VersionWitness,
};
use account_actions::version;
use account_extensions::action_descriptor::{Self, ActionDescriptor};

// === Use Fun Aliases ===
use fun account_protocol::intents::add_action_with_descriptor as Intent.add_action_with_descriptor;

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
const ECannotReduceBelowClaimed: u64 = 17;
const ETooManyBeneficiaries: u64 = 18;

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

// Intent functions

/// Creates a DepositAction and adds it to an intent with descriptor.
public fun new_deposit<Outcome, CoinType, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    amount: u64,
    intent_witness: IW,
) {
    let descriptor = action_descriptor::new(b"treasury", b"deposit");
    intent.add_action_with_descriptor(
        DepositAction<CoinType> { name, amount },
        descriptor,
        intent_witness
    );
}

/// Processes a DepositAction and deposits a coin to the vault.
public fun do_deposit<Config, Outcome: store, CoinType: drop, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    coin: Coin<CoinType>,
    version_witness: VersionWitness,
    intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    let action: &DepositAction<CoinType> = executable.next_action(intent_witness);
    assert!(action.amount == coin.value(), EIntentAmountMismatch);
        
    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(action.name), version_witness);
    if (!vault.coin_type_exists<CoinType>()) {
        vault.bag.add(type_name::with_defining_ids<CoinType>(), coin.into_balance());
    } else {
        let balance_mut = vault.bag.borrow_mut<_, Balance<_>>(type_name::with_defining_ids<CoinType>());
        balance_mut.join(coin.into_balance());
    };
}

/// Deletes a DepositAction from an expired intent.
public fun delete_deposit<CoinType>(expired: &mut Expired) {
    let DepositAction<CoinType> { .. } = expired.remove_action();
}

/// Creates a SpendAction and adds it to an intent with descriptor.
public fun new_spend<Outcome, CoinType, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    amount: u64,
    intent_witness: IW,
) {
    let descriptor = action_descriptor::new(b"treasury", b"spend");
    intent.add_action_with_descriptor(
        SpendAction<CoinType> { name, amount },
        descriptor,
        intent_witness
    );
}

/// Processes a SpendAction and takes a coin from the vault.
public fun do_spend<Config, Outcome: store, CoinType: drop, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    intent_witness: IW,
    ctx: &mut TxContext
): Coin<CoinType> {
    executable.intent().assert_is_account(account.addr());
    
    let action: &SpendAction<CoinType> = executable.next_action(intent_witness);
        
    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(action.name), version_witness);
    let balance_mut = vault.bag.borrow_mut<_, Balance<_>>(type_name::with_defining_ids<CoinType>());
    let coin = coin::take(balance_mut, action.amount, ctx);

    if (balance_mut.value() == 0) 
        vault.bag.remove<_, Balance<CoinType>>(type_name::with_defining_ids<CoinType>()).destroy_zero();
        
    coin
}

/// Deletes a SpendAction from an expired intent.
public fun delete_spend<CoinType>(expired: &mut Expired) {
    let SpendAction<CoinType> { .. } = expired.remove_action();
}

// === Stream Functions ===

/// Create a stream for time-based vesting withdrawals (requires Auth)
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
    max_beneficiaries: u64,  // Configurable max beneficiaries for this stream
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    account.verify(auth);
    
    // Validate parameters
    assert!(total_amount > 0, EInvalidStreamParameters);
    assert!(end_time > start_time, EInvalidStreamParameters);
    assert!(start_time >= clock.timestamp_ms(), EInvalidStreamParameters);
    if (cliff_time.is_some()) {
        let cliff = *cliff_time.borrow();
        assert!(cliff >= start_time && cliff <= end_time, EInvalidStreamParameters);
    };
    
    let mut uid = object::new(ctx);
    let stream_id = uid.to_inner();
    uid.delete();
    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version::current());
    
    // Verify vault has sufficient balance
    assert!(vault.coin_type_exists<CoinType>(), EWrongCoinType);
    assert!(vault.coin_type_value<CoinType>() >= total_amount, EInsufficientVestedAmount);
    
    // Validate max_beneficiaries
    assert!(max_beneficiaries > 0 && max_beneficiaries <= MAX_BENEFICIARIES, EInvalidStreamParameters);
    
    let coin_type = type_name::with_defining_ids<CoinType>();
    
    table::add(&mut vault.streams, stream_id, VaultStream {
        id: stream_id,
        coin_type,
        beneficiary,
        total_amount,
        claimed_amount: 0,
        start_time,
        end_time,
        cliff_time,
        max_per_withdrawal,
        min_interval_ms,
        last_withdrawal_time: 0,
        // === Fork additions ===
        additional_beneficiaries: vector::empty(),
        max_beneficiaries,  // Set from parameter
        is_paused: false,
        paused_at: option::none(),
        paused_duration: 0,
        metadata: option::none(),
        is_transferable: true,  // Default to transferable
        is_cancellable: true,   // Default to cancellable
    });
    
    // Emit creation event
    event::emit(StreamCreated {
        stream_id,
        beneficiary,
        total_amount,
        coin_type,
        start_time,
        end_time,
    });
    
    stream_id
}

/// Withdraw from a stream (no Auth needed, just be an authorized beneficiary)
public fun withdraw_from_stream<Config, CoinType: drop>(
    account: &mut Account<Config>,
    vault_name: String,
    stream_id: ID,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version::current());
    
    // Get and validate stream
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);
    let stream = table::borrow_mut(&mut vault.streams, stream_id);
    
    // === Fork enhancement: Check if sender is authorized beneficiary ===
    let sender = tx_context::sender(ctx);
    let is_authorized = stream.beneficiary == sender || 
                       stream.additional_beneficiaries.contains(&sender);
    assert!(is_authorized, EUnauthorizedBeneficiary);
    assert!(stream.coin_type == type_name::with_defining_ids<CoinType>(), EWrongCoinType);
    
    // === Fork enhancement: Check if stream is paused ===
    assert!(!stream.is_paused, EStreamPaused);
    
    let current_time = clock.timestamp_ms();
    
    // Check timing constraints
    assert!(current_time >= stream.start_time, EStreamNotStarted);
    if (stream.cliff_time.is_some()) {
        assert!(current_time >= *stream.cliff_time.borrow(), EStreamCliffNotReached);
    };
    // Allow first withdrawal unconditionally, then enforce interval
    let first_withdrawal = stream.last_withdrawal_time == 0;
    assert!(first_withdrawal || current_time >= stream.last_withdrawal_time + stream.min_interval_ms, EWithdrawalTooSoon);
    
    // Calculate vested amount safely
    let elapsed = if (current_time >= stream.end_time) {
        stream.end_time - stream.start_time
    } else {
        current_time - stream.start_time
    };
    let duration = stream.end_time - stream.start_time;
    let vested_amount = mul_div_safe(stream.total_amount, elapsed, duration);
    let available = vested_amount - stream.claimed_amount;
    
    // Validate withdrawal amount
    assert!(amount <= available, EInsufficientVestedAmount);
    assert!(amount <= stream.max_per_withdrawal, EWithdrawalLimitExceeded);
    
    // Update stream state
    stream.claimed_amount = stream.claimed_amount + amount;
    stream.last_withdrawal_time = current_time;
    
    // Calculate remaining vested for event
    let remaining_vested = vested_amount - stream.claimed_amount;
    
    // Emit withdrawal event
    event::emit(StreamWithdrawal {
        stream_id,
        beneficiary: tx_context::sender(ctx),
        amount,
        remaining_vested,
    });
    
    // Withdraw from vault
    let balance_mut = vault.bag.borrow_mut<_, Balance<_>>(type_name::with_defining_ids<CoinType>());
    let coin = coin::take(balance_mut, amount, ctx);
    
    // Clean up zero balance if needed
    if (balance_mut.value() == 0) {
        vault.bag.remove<_, Balance<CoinType>>(type_name::with_defining_ids<CoinType>()).destroy_zero();
    };
    
    coin
}

/// Cancel a stream and return unvested funds (requires Auth)
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
    let VaultStream {
        id: _,
        coin_type,
        beneficiary,
        total_amount,
        claimed_amount,
        start_time,
        end_time,
        cliff_time,
        max_per_withdrawal: _,
        min_interval_ms: _,
        last_withdrawal_time: _,
        // === Fork additions ===
        additional_beneficiaries: _,
        max_beneficiaries: _,
        is_paused: _,
        paused_at: _,
        paused_duration: _,
        metadata: _,
        is_transferable: _,
        is_cancellable,
    } = table::remove(&mut vault.streams, stream_id);
    
    // Check if stream is cancellable
    assert!(is_cancellable, ENotCancellable);
    
    assert!(coin_type == type_name::with_defining_ids<CoinType>(), EWrongCoinType);
    
    // Calculate final vested amount (respecting cliff)
    let current_time = clock.timestamp_ms();
    let mut vested_amount = if (current_time >= end_time) {
        total_amount
    } else if (current_time <= start_time) {
        0
    } else {
        let elapsed = current_time - start_time;
        let duration = end_time - start_time;
        mul_div_safe(total_amount, elapsed, duration)
    };
    
    // Apply cliff restriction
    if (cliff_time.is_some() && current_time < *cliff_time.borrow()) {
        vested_amount = 0;
    };
    
    // Calculate final claimable and refundable amounts
    let final_claimable = if (vested_amount > claimed_amount) {
        vested_amount - claimed_amount
    } else {
        0
    };
    
    let unvested = total_amount - vested_amount;
    
    // Create coin for final claim to beneficiary
    let balance_mut = vault.bag.borrow_mut<_, Balance<_>>(type_name::with_defining_ids<CoinType>());
    let final_payment = if (final_claimable > 0) {
        coin::take(balance_mut, final_claimable, ctx)
    } else {
        coin::zero<CoinType>(ctx)
    };
    
    // Transfer final payment to beneficiary
    if (final_claimable > 0) {
        transfer::public_transfer(final_payment, beneficiary);
    } else {
        final_payment.destroy_zero();
    };
    
    // Return unvested amount as coin (caller decides what to do with it)
    let refund = if (unvested > 0) {
        coin::take(balance_mut, unvested, ctx)
    } else {
        coin::zero<CoinType>(ctx)
    };
    
    // Clean up zero balance if needed
    if (balance_mut.value() == 0) {
        vault.bag.remove<_, Balance<CoinType>>(type_name::with_defining_ids<CoinType>()).destroy_zero();
    };
    
    // Emit cancellation event
    event::emit(StreamCancelled {
        stream_id,
        refunded_amount: unvested,
        final_payment: final_claimable,
    });
    
    (refund, unvested)
}

/// Get stream info
public fun stream_info<Config>(
    account: &Account<Config>,
    vault_name: String,
    stream_id: ID,
): (address, u64, u64, u64, u64, u64, Option<u64>) {
    let vault: &Vault = account.borrow_managed_data(VaultKey(vault_name), version::current());
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);
    let stream = table::borrow(&vault.streams, stream_id);
    
    (
        stream.beneficiary,
        stream.total_amount,
        stream.claimed_amount,
        stream.start_time,
        stream.end_time,
        stream.max_per_withdrawal,
        stream.cliff_time,
    )
}

/// Calculate claimable amount for a stream
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
    
    // Check if started and cliff passed
    if (current_time < stream.start_time) return 0;
    if (stream.cliff_time.is_some() && current_time < *stream.cliff_time.borrow()) return 0;
    
    // Calculate vested amount safely
    let elapsed = if (current_time >= stream.end_time) {
        stream.end_time - stream.start_time
    } else {
        current_time - stream.start_time
    };
    let duration = stream.end_time - stream.start_time;
    let vested_amount = mul_div_safe(stream.total_amount, elapsed, duration);
    
    if (vested_amount > stream.claimed_amount) {
        vested_amount - stream.claimed_amount
    } else {
        0
    }
}

// === Stream Management Functions ===

/// Remove a fully-claimed stream from the vault (requires Auth)
/// This helps clean up completed streams and allows vault closure
public fun prune_stream<Config>(
    auth: Auth,
    account: &mut Account<Config>,
    vault_name: String,
    stream_id: ID,
): bool {
    account.verify(auth);
    
    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version::current());
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);
    
    // Only allow pruning if fully claimed
    let stream = table::borrow(&vault.streams, stream_id);
    if (stream.claimed_amount == stream.total_amount) {
        let VaultStream { 
            id: _,
            coin_type: _,
            beneficiary: _,
            total_amount: _,
            claimed_amount: _,
            start_time: _,
            end_time: _,
            cliff_time: _,
            max_per_withdrawal: _,
            min_interval_ms: _,
            last_withdrawal_time: _,
            // === Fork additions ===
            additional_beneficiaries: _,
            max_beneficiaries: _,
            is_paused: _,
            paused_at: _,
            paused_duration: _,
            metadata: _,
            is_transferable: _,
            is_cancellable: _,
        } = table::remove(&mut vault.streams, stream_id);
        true
    } else {
        false
    }
}

/// Batch prune multiple fully-claimed streams
public fun prune_streams<Config>(
    auth: Auth,
    account: &mut Account<Config>,
    vault_name: String,
    stream_ids: vector<ID>,
): u64 {
    account.verify(auth);
    
    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version::current());
    let mut pruned = 0;
    let mut i = 0;
    
    while (i < stream_ids.length()) {
        let stream_id = *stream_ids.borrow(i);
        if (table::contains(&vault.streams, stream_id)) {
            let stream = table::borrow(&vault.streams, stream_id);
            if (stream.claimed_amount == stream.total_amount) {
                let VaultStream { 
                    id: _,
                    coin_type: _,
                    beneficiary: _,
                    total_amount: _,
                    claimed_amount: _,
                    start_time: _,
                    end_time: _,
                    cliff_time: _,
                    max_per_withdrawal: _,
                    min_interval_ms: _,
                    last_withdrawal_time: _,
                    // === Fork additions ===
                    additional_beneficiaries: _,
                    max_beneficiaries: _,
                    is_paused: _,
                    paused_at: _,
                    paused_duration: _,
                    metadata: _,
                    is_transferable: _,
                    is_cancellable: _,
                } = table::remove(&mut vault.streams, stream_id);
                pruned = pruned + 1;
            };
        };
        i = i + 1;
    };
    
    pruned
}

// === Safe Math Helpers ===

/// Safe multiplication and division to avoid overflow
/// Calculates (a * b) / c with intermediate overflow protection
/// Uses u128 internally to prevent overflow during multiplication
fun mul_div_safe(a: u64, b: u64, c: u64): u64 {
    assert!(c != 0, 0); // Division by zero
    
    // Cast to u128 to prevent overflow during multiplication
    // SAFE: Product of two u64s always fits in u128 (max is (2^64-1)^2 < 2^128)
    let a_128 = (a as u128);
    let b_128 = (b as u128);
    let c_128 = (c as u128);
    
    // Perform the multiplication and division
    let result = (a_128 * b_128) / c_128;
    
    // Ensure the result fits back into u64
    // In vesting context, result should always fit since we're calculating portions
    assert!(result <= (u64::max_value!() as u128), 0);
    (result as u64)
}

// === Fork Enhancement: Stream Management Functions ===

/// Pause a stream (requires Auth)
public fun pause_stream<Config>(
    auth: Auth,
    account: &mut Account<Config>,
    vault_name: String,
    stream_id: ID,
    clock: &Clock,
) {
    account.verify(auth);
    
    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version::current());
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);
    
    let stream = table::borrow_mut(&mut vault.streams, stream_id);
    assert!(!stream.is_paused, EStreamNotPaused);
    
    stream.is_paused = true;
    stream.paused_at = option::some(clock.timestamp_ms());
    
    // Emit pause event
    event::emit(StreamPaused {
        stream_id,
        paused_at: clock.timestamp_ms(),
    });
}

/// Resume a paused stream (requires Auth)
public fun resume_stream<Config>(
    auth: Auth,
    account: &mut Account<Config>,
    vault_name: String,
    stream_id: ID,
    clock: &Clock,
) {
    account.verify(auth);
    
    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version::current());
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);
    
    let stream = table::borrow_mut(&mut vault.streams, stream_id);
    assert!(stream.is_paused, EStreamNotPaused);
    
    // Calculate pause duration and add to total
    if (stream.paused_at.is_some()) {
        let pause_start = *stream.paused_at.borrow();
        let pause_duration = clock.timestamp_ms() - pause_start;
        stream.paused_duration = stream.paused_duration + pause_duration;
        
        // Adjust end time to account for pause
        stream.end_time = stream.end_time + pause_duration;
        if (stream.cliff_time.is_some()) {
            let cliff = *stream.cliff_time.borrow();
            stream.cliff_time = option::some(cliff + pause_duration);
        };
    };
    
    stream.is_paused = false;
    stream.paused_at = option::none();
    
    // Emit resume event
    event::emit(StreamResumed {
        stream_id,
        resumed_at: clock.timestamp_ms(),
        pause_duration: stream.paused_duration,
    });
}

/// Add an additional beneficiary to a stream (requires Auth)
public fun add_stream_beneficiary<Config>(
    auth: Auth,
    account: &mut Account<Config>,
    vault_name: String,
    stream_id: ID,
    new_beneficiary: address,
) {
    account.verify(auth);
    
    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version::current());
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);
    
    let stream = table::borrow_mut(&mut vault.streams, stream_id);
    assert!(stream.additional_beneficiaries.length() < stream.max_beneficiaries, ETooManyBeneficiaries);
    assert!(!stream.additional_beneficiaries.contains(&new_beneficiary), EBeneficiaryAlreadyExists);
    assert!(stream.beneficiary != new_beneficiary, EBeneficiaryAlreadyExists);
    
    stream.additional_beneficiaries.push_back(new_beneficiary);
    
    // Emit beneficiary added event
    event::emit(BeneficiaryAdded {
        stream_id,
        new_beneficiary,
    });
}

/// Remove an additional beneficiary from a stream (requires Auth)
public fun remove_stream_beneficiary<Config>(
    auth: Auth,
    account: &mut Account<Config>,
    vault_name: String,
    stream_id: ID,
    beneficiary_to_remove: address,
) {
    account.verify(auth);
    
    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version::current());
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);
    
    let stream = table::borrow_mut(&mut vault.streams, stream_id);
    let (found, index) = stream.additional_beneficiaries.index_of(&beneficiary_to_remove);
    assert!(found, EBeneficiaryNotFound);
    
    stream.additional_beneficiaries.remove(index);
    
    // Emit beneficiary removed event
    event::emit(BeneficiaryRemoved {
        stream_id,
        removed_beneficiary: beneficiary_to_remove,
    });
}

/// Transfer stream to a new primary beneficiary (requires Auth and stream must be transferable)
public fun transfer_stream<Config>(
    auth: Auth,
    account: &mut Account<Config>,
    vault_name: String,
    stream_id: ID,
    new_beneficiary: address,
) {
    account.verify(auth);
    
    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version::current());
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);
    
    let stream = table::borrow_mut(&mut vault.streams, stream_id);
    assert!(stream.is_transferable, ENotTransferable);
    
    // Remove new beneficiary from additional if present
    let (found, index) = stream.additional_beneficiaries.index_of(&new_beneficiary);
    if (found) {
        stream.additional_beneficiaries.remove(index);
    };
    
    // Add old beneficiary to additional beneficiaries if not already there
    let old_beneficiary = stream.beneficiary;
    if (!stream.additional_beneficiaries.contains(&old_beneficiary)) {
        if (stream.additional_beneficiaries.length() < stream.max_beneficiaries) {
            stream.additional_beneficiaries.push_back(old_beneficiary);
        };
    };
    
    stream.beneficiary = new_beneficiary;
    
    // Emit transfer event
    event::emit(StreamTransferred {
        stream_id,
        old_beneficiary,
        new_beneficiary,
    });
}

/// Update stream metadata (requires Auth)
public fun update_stream_metadata<Config>(
    auth: Auth,
    account: &mut Account<Config>,
    vault_name: String,
    stream_id: ID,
    metadata: String,
) {
    account.verify(auth);
    
    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version::current());
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);
    
    let stream = table::borrow_mut(&mut vault.streams, stream_id);
    stream.metadata = option::some(metadata);
    
    // Emit metadata update event
    event::emit(StreamMetadataUpdated {
        stream_id,
    });
}

/// Reduce stream total amount (must be greater than already claimed)
public fun reduce_stream_amount<Config>(
    auth: Auth,
    account: &mut Account<Config>,
    vault_name: String,
    stream_id: ID,
    new_total_amount: u64,
) {
    account.verify(auth);
    
    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version::current());
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);
    
    let stream = table::borrow_mut(&mut vault.streams, stream_id);
    assert!(new_total_amount >= stream.claimed_amount, ECannotReduceBelowClaimed);
    assert!(new_total_amount < stream.total_amount, EInvalidStreamParameters);
    
    let old_amount = stream.total_amount;
    stream.total_amount = new_total_amount;
    
    // Emit amount reduced event
    event::emit(StreamAmountReduced {
        stream_id,
        old_amount,
        new_amount: new_total_amount,
    });
}

/// Set stream transferability (requires Auth)
public fun set_stream_transferable<Config>(
    auth: Auth,
    account: &mut Account<Config>,
    vault_name: String,
    stream_id: ID,
    is_transferable: bool,
) {
    account.verify(auth);
    
    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version::current());
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);
    
    let stream = table::borrow_mut(&mut vault.streams, stream_id);
    stream.is_transferable = is_transferable;
}

/// Set stream cancellability (requires Auth)
public fun set_stream_cancellable<Config>(
    auth: Auth,
    account: &mut Account<Config>,
    vault_name: String,
    stream_id: ID,
    is_cancellable: bool,
) {
    account.verify(auth);
    
    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version::current());
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);
    
    let stream = table::borrow_mut(&mut vault.streams, stream_id);
    stream.is_cancellable = is_cancellable;
}

/// Check if a beneficiary is authorized for a stream
public fun is_authorized_beneficiary<Config>(
    account: &Account<Config>,
    vault_name: String,
    stream_id: ID,
    beneficiary: address,
): bool {
    let vault: &Vault = account.borrow_managed_data(VaultKey(vault_name), version::current());
    if (!table::contains(&vault.streams, stream_id)) {
        return false
    };
    
    let stream = table::borrow(&vault.streams, stream_id);
    stream.beneficiary == beneficiary || stream.additional_beneficiaries.contains(&beneficiary)
}

/// Get all beneficiaries for a stream
public fun get_stream_beneficiaries<Config>(
    account: &Account<Config>,
    vault_name: String,
    stream_id: ID,
): (address, vector<address>) {
    let vault: &Vault = account.borrow_managed_data(VaultKey(vault_name), version::current());
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);
    
    let stream = table::borrow(&vault.streams, stream_id);
    (stream.beneficiary, stream.additional_beneficiaries)
}

/// Check if a stream is active (not paused and within time bounds)
public fun is_stream_active<Config>(
    account: &Account<Config>,
    vault_name: String,
    stream_id: ID,
    clock: &Clock,
): bool {
    let vault: &Vault = account.borrow_managed_data(VaultKey(vault_name), version::current());
    if (!table::contains(&vault.streams, stream_id)) {
        return false
    };
    
    let stream = table::borrow(&vault.streams, stream_id);
    let current_time = clock.timestamp_ms();
    
    !stream.is_paused && 
    current_time >= stream.start_time && 
    current_time <= stream.end_time &&
    stream.claimed_amount < stream.total_amount
}

/// Get stream metadata
public fun get_stream_metadata<Config>(
    account: &Account<Config>,
    vault_name: String,
    stream_id: ID,
): Option<String> {
    let vault: &Vault = account.borrow_managed_data(VaultKey(vault_name), version::current());
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);
    
    let stream = table::borrow(&vault.streams, stream_id);
    stream.metadata
}

