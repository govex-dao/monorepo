// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

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
use account_actions::{version, stream_utils};

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
// Additional error codes
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
const ETimeCalculationOverflow: u64 = 24;
const EVestingPaused: u64 = 25;  // Reusing vesting error code for stream pause
const EEmergencyFrozen: u64 = 26;
const EVestingNotPaused: u64 = 27;

// === Action Type Markers ===

/// Deposit coins into vault
public struct VaultDeposit has drop {}

/// Spend coins from vault
public struct VaultSpend has drop {}

/// Approve coin type for permissionless deposits
public struct VaultApproveCoinType has drop {}

/// Remove coin type approval
public struct VaultRemoveApprovedCoinType has drop {}

/// Toggle stream pause (pause/resume)
public struct ToggleStreamPause has drop {}

/// Toggle stream emergency freeze
public struct ToggleStreamFreeze has drop {}

/// Cancel stream
public struct CancelStream has drop {}

// === Structs ===

/// Dynamic Field key for the Vault.
public struct VaultKey(String) has copy, drop, store;
/// Dynamic field holding a budget with different coin types, key is name
public struct Vault has store {
    // heterogeneous array of Balances, TypeName -> Balance<CoinType>
    bag: Bag,
    // streams for time-based vesting withdrawals
    streams: Table<ID, VaultStream>,
    // approved coin types for permissionless deposits (enables revenue/donations)
    approved_types: VecSet<TypeName>,
}

/// Stream for time-based vesting from vault
/// Stream enhancements:
/// Added features include:
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
    // Additional data for stream management
    // Multiple beneficiaries support
    additional_beneficiaries: vector<address>,
    max_beneficiaries: u64,  // Configurable per stream
    // Pause functionality
    is_paused: bool,
    paused_at: Option<u64>,
    paused_until: Option<u64>,  // None = indefinite, Some(ts) = pause until timestamp
    paused_duration: u64,  // Total time paused (affects vesting calculation)
    emergency_frozen: bool,  // If true, even unpause won't work
    // Expiry
    expiry_timestamp: Option<u64>,  // Stream becomes invalid after this time
    // Metadata for extensibility
    metadata: Option<String>,
    // Transfer settings
    is_transferable: bool,
    is_cancellable: bool,
}

// Event structures for stream operations

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

/// Emitted when a stream is emergency frozen
public struct StreamFrozen has copy, drop {
    stream_id: ID,
    timestamp: u64,
}

/// Emitted when emergency freeze is removed
public struct StreamUnfrozen has copy, drop {
    stream_id: ID,
    timestamp: u64,
}

/// Action to deposit an amount of this coin to the targeted Vault.
public struct DepositAction<phantom CoinType> has store, drop {
    // vault name
    name: String,
    // exact amount to be deposited
    amount: u64,
}
/// Action to be used within intent making good use of the returned coin, similar to owned::withdraw.
public struct SpendAction<phantom CoinType> has store, drop {
    // vault name
    name: String,
    // amount to withdraw
    amount: u64,
}

/// Action to approve a coin type for permissionless deposits
public struct ApproveCoinTypeAction<phantom CoinType> has store, drop {
    // vault name
    name: String,
}

/// Action to remove approval for a coin type
public struct RemoveApprovedCoinTypeAction<phantom CoinType> has store, drop {
    // vault name
    name: String,
}

/// Action for toggling stream pause (combines pause/resume)
public struct ToggleStreamPauseAction has store {
    vault_name: String,
    stream_id: ID,
    pause_duration_ms: u64, // 0 = unpause, >0 = pause for duration
}

/// Action for toggling emergency freeze (combines freeze/unfreeze)
public struct ToggleStreamFreezeAction has store {
    vault_name: String,
    stream_id: ID,
    freeze: bool, // true = freeze, false = unfreeze
}

/// Action for canceling a stream
public struct CancelStreamAction has store {
    vault_name: String,
    stream_id: ID,
}

// === Public Functions ===

/// Authorized address can open a vault.
public fun open<Config: store>(
    auth: Auth,
    account: &mut Account,
    name: String,
    ctx: &mut TxContext
) {
    account.verify(auth);

    account.add_managed_data(VaultKey(name), Vault {
        bag: bag::new(ctx),
        streams: table::new(ctx),
        approved_types: vec_set::empty(),
    }, version::current());
}

/// Deposits coins owned by a an authorized address into a vault.
public fun deposit<Config: store, CoinType: drop>(
    auth: Auth,
    account: &mut Account,
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

/// Permissionless deposit for approved coin types
/// Anyone can deposit coins of types that have been approved by governance
/// This enables revenue/donations for common tokens (SUI, USDC, etc.)
/// Safe because:
/// 1. Only approved types can be deposited
/// 2. Deposits increase DAO assets, never decrease
/// 3. Creates balance entry on first deposit if needed
public fun deposit_approved<Config: store, CoinType: drop>(
    account: &mut Account,
    name: String,
    coin: Coin<CoinType>,
) {
    let vault: &mut Vault =
        account.borrow_managed_data_mut(VaultKey(name), version::current());

    // Only allow deposits of approved coin types
    let type_key = type_name::with_defining_ids<CoinType>();
    assert!(vault.approved_types.contains(&type_key), EWrongCoinType);

    // Add to existing balance or create new one
    if (vault.coin_type_exists<CoinType>()) {
        let balance_mut = vault.bag.borrow_mut<_, Balance<_>>(type_key);
        balance_mut.join(coin.into_balance());
    } else {
        vault.bag.add(type_key, coin.into_balance());
    }
}

/// Approve a coin type for permissionless deposits (requires Auth)
/// After approval, anyone can deposit this coin type to the vault
public fun approve_coin_type<Config: store, CoinType>(
    auth: Auth,
    account: &mut Account,
    name: String,
) {
    account.verify(auth);

    let vault: &mut Vault =
        account.borrow_managed_data_mut(VaultKey(name), version::current());

    let type_key = type_name::with_defining_ids<CoinType>();
    if (!vault.approved_types.contains(&type_key)) {
        vault.approved_types.insert(type_key);
    }
}

/// Remove approval for a coin type (requires Auth)
/// Prevents future permissionless deposits of this type
/// Does not affect existing balances
public fun remove_approved_coin_type<Config: store, CoinType>(
    auth: Auth,
    account: &mut Account,
    name: String,
) {
    account.verify(auth);

    let vault: &mut Vault =
        account.borrow_managed_data_mut(VaultKey(name), version::current());

    let type_key = type_name::with_defining_ids<CoinType>();
    if (vault.approved_types.contains(&type_key)) {
        vault.approved_types.remove(&type_key);
    }
}

/// Check if a coin type is approved for permissionless deposits
public fun is_coin_type_approved<Config: store, CoinType>(
    account: &Account,
    name: String,
): bool {
    if (!has_vault(account, name)) {
        return false
    };

    let vault: &Vault = account.borrow_managed_data(VaultKey(name), version::current());
    let type_key = type_name::with_defining_ids<CoinType>();
    vault.approved_types.contains(&type_key)
}

/// Withdraws coins from a vault with authorization.
/// This is the Auth-based counterpart to `deposit`, used for direct withdrawals
/// outside of intent execution (e.g., for liquidity subsidy escrow funding).
public fun spend<Config: store, CoinType: drop>(
    auth: Auth,
    account: &mut Account,
    name: String,
    amount: u64,
    ctx: &mut TxContext,
): Coin<CoinType> {
    account.verify(auth);

    let vault: &mut Vault =
        account.borrow_managed_data_mut(VaultKey(name), version::current());

    // Ensure coin type exists in vault
    assert!(vault.coin_type_exists<CoinType>(), EWrongCoinType);

    // Withdraw from balance
    let balance_mut = vault.bag.borrow_mut<_, Balance<_>>(type_name::with_defining_ids<CoinType>());
    assert!(balance_mut.value() >= amount, EInsufficientBalance);

    let coin = coin::take(balance_mut, amount, ctx);

    // Clean up empty balance if needed
    if (balance_mut.value() == 0) {
        vault.bag.remove<_, Balance<CoinType>>(type_name::with_defining_ids<CoinType>()).destroy_zero();
    };

    coin
}

/// Returns the balance of a specific coin type in a vault.
/// Convenience function that combines vault existence check with balance lookup.
public fun balance<Config: store, CoinType: drop>(
    account: &Account,
    name: String,
): u64 {
    if (!has_vault(account, name)) {
        return 0
    };

    let vault: &Vault = account.borrow_managed_data(VaultKey(name), version::current());

    if (!coin_type_exists<CoinType>(vault)) {
        return 0
    };

    coin_type_value<CoinType>(vault)
}

/// Default vault name for standard operations
public fun default_vault_name(): String {
    std::string::utf8(b"Main Vault")
}

/// Deposit during initialization - works on unshared Accounts
/// This function is for use during account creation, before the account is shared.
/// It follows the same pattern as Futarchy init actions.
/// SAFETY: This function MUST only be called on unshared Accounts.
/// Calling this on a shared Account bypasses Auth checks.
/// The package(package) visibility helps enforce this constraint.
public(package) fun do_deposit_unshared< CoinType: drop>(
    account: &mut Account,
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
            approved_types: vec_set::empty(),
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
public fun close<Config: store>(
    auth: Auth,
    account: &mut Account,
    name: String,
) {
    account.verify(auth);

    let Vault { bag, streams, approved_types: _ } =
        account.remove_managed_data(VaultKey(name), version::current());
    assert!(bag.is_empty(), EVaultNotEmpty);
    assert!(streams.is_empty(), EVaultNotEmpty);
    bag.destroy_empty();
    streams.destroy_empty();
}

/// Returns true if the vault exists.
public fun has_vault(
    account: &Account, 
    name: String
): bool {
    account.has_managed_data(VaultKey(name))
}

/// Returns a reference to the vault.
public fun borrow_vault(
    account: &Account,
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

/// Destroy an ApproveCoinTypeAction after serialization
public fun destroy_approve_coin_type_action<CoinType>(action: ApproveCoinTypeAction<CoinType>) {
    let ApproveCoinTypeAction { name: _ } = action;
}

/// Destroy a RemoveApprovedCoinTypeAction after serialization
public fun destroy_remove_approved_coin_type_action<CoinType>(action: RemoveApprovedCoinTypeAction<CoinType>) {
    let RemoveApprovedCoinTypeAction { name: _ } = action;
}

/// Destroy a ToggleStreamPauseAction after serialization
public fun destroy_toggle_stream_pause_action(action: ToggleStreamPauseAction) {
    let ToggleStreamPauseAction { vault_name: _, stream_id: _, pause_duration_ms: _ } = action;
}

/// Destroy a ToggleStreamFreezeAction after serialization
public fun destroy_toggle_stream_freeze_action(action: ToggleStreamFreezeAction) {
    let ToggleStreamFreezeAction { vault_name: _, stream_id: _, freeze: _ } = action;
}

/// Destroy a CancelStreamAction after serialization
public fun destroy_cancel_stream_action(action: CancelStreamAction) {
    let CancelStreamAction { vault_name: _, stream_id: _ } = action;
}

// Intent functions

/// Creates a DepositAction and adds it to an intent with descriptor.
public fun new_deposit<Outcome, CoinType, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    amount: u64,
    intent_witness: IW,
) {
    // Create action struct
    let action = DepositAction<CoinType> {
        name,
        amount,
    };

    // Serialize the entire struct directly
    let action_data = bcs::to_bytes(&action);

    // Add to intent with parameterized type witness
    // The action struct itself serves as the type witness, preserving CoinType parameter
    intent.add_typed_action(
        action,  // Action moved here, TypeName becomes DepositAction<CoinType>
        action_data,
        intent_witness
    );

    // Action already consumed by add_typed_action - no need to destroy
}

/// Processes a DepositAction and deposits a coin to the vault.
public fun do_deposit<Config: store, Outcome: store, CoinType: drop, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
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

    // Deserialize the entire action struct directly
    let mut reader = bcs::new(*action_data);
    let name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let amount = bcs::peel_u64(&mut reader);

    // Validate all bytes consumed
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
    // Create action struct
    let action = SpendAction<CoinType> {
        name,
        amount,
    };

    // Serialize the entire struct directly
    let action_data = bcs::to_bytes(&action);

    // Add to intent with parameterized type witness
    // The action struct itself serves as the type witness, preserving CoinType parameter
    intent.add_typed_action(
        action,  // Action moved here, TypeName becomes SpendAction<CoinType>
        action_data,
        intent_witness
    );

    // Action already consumed by add_typed_action - no need to destroy
}

/// Creates an ApproveCoinTypeAction and adds it to an intent with descriptor.
public fun new_approve_coin_type<Outcome, CoinType, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    intent_witness: IW,
) {
    // Create action struct
    let action = ApproveCoinTypeAction<CoinType> {
        name,
    };

    // Serialize the entire struct directly
    let action_data = bcs::to_bytes(&action);

    // Add to intent with parameterized type witness
    intent.add_typed_action(
        action,  // Action moved here, TypeName becomes ApproveCoinTypeAction<CoinType>
        action_data,
        intent_witness
    );

    // Action already consumed by add_typed_action - no need to destroy
}

/// Creates a RemoveApprovedCoinTypeAction and adds it to an intent with descriptor.
public fun new_remove_approved_coin_type<Outcome, CoinType, IW: drop>(
    intent: &mut Intent<Outcome>,
    name: String,
    intent_witness: IW,
) {
    // Create action struct
    let action = RemoveApprovedCoinTypeAction<CoinType> {
        name,
    };

    // Serialize the entire struct directly
    let action_data = bcs::to_bytes(&action);

    // Add to intent with parameterized type witness
    intent.add_typed_action(
        action,  // Action moved here, TypeName becomes RemoveApprovedCoinTypeAction<CoinType>
        action_data,
        intent_witness
    );

    // Action already consumed by add_typed_action - no need to destroy
}

/// Creates a ToggleStreamPauseAction and adds it to an intent
public fun new_toggle_stream_pause<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    vault_name: String,
    stream_id: ID,
    pause_duration_ms: u64, // 0 = unpause, >0 = pause for duration
    intent_witness: IW,
) {
    let action = ToggleStreamPauseAction { vault_name, stream_id, pause_duration_ms };
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        ToggleStreamPause {},
        action_data,
        intent_witness
    );
    destroy_toggle_stream_pause_action(action);
}

/// Creates a ToggleStreamFreezeAction and adds it to an intent
public fun new_toggle_stream_freeze<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    vault_name: String,
    stream_id: ID,
    freeze: bool, // true = freeze, false = unfreeze
    intent_witness: IW,
) {
    let action = ToggleStreamFreezeAction { vault_name, stream_id, freeze };
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        ToggleStreamFreeze {},
        action_data,
        intent_witness
    );
    destroy_toggle_stream_freeze_action(action);
}

/// Creates a CancelStreamAction and adds it to an intent
public fun new_cancel_stream<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    vault_name: String,
    stream_id: ID,
    intent_witness: IW,
) {
    let action = CancelStreamAction { vault_name, stream_id };
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        CancelStream {},
        action_data,
        intent_witness
    );
    destroy_cancel_stream_action(action);
}

// === Execution Functions ===

/// Execute toggle stream pause action
public fun do_toggle_stream_pause<Config: store, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    vault_name: String,
    clock: &Clock,
    version_witness: VersionWitness,
    witness: IW,
    ctx: &mut TxContext,
) {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<ToggleStreamPause>(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(spec);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let deserialized_vault_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let stream_id = bcs::peel_address(&mut reader).to_id();
    let pause_duration_ms = bcs::peel_u64(&mut reader);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(reader);

    // Validate vault name matches
    assert!(vault_name == deserialized_vault_name, EVaultDoesNotExist);

    // Get vault
    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version_witness);
    assert!(vault.streams.contains(stream_id), EStreamNotFound);

    // Execute pause/unpause logic
    if (pause_duration_ms == 0) {
        // Unpause
        check_and_unpause_stream(vault, stream_id, clock);
    } else {
        // Pause
        pause_stream<CoinType>(vault, stream_id, pause_duration_ms, clock, ctx);
    };

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute toggle stream freeze action
public fun do_toggle_stream_freeze<Config: store, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    vault_name: String,
    clock: &Clock,
    version_witness: VersionWitness,
    witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<ToggleStreamFreeze>(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(spec);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let deserialized_vault_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let stream_id = bcs::peel_address(&mut reader).to_id();
    let freeze = bcs::peel_bool(&mut reader);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(reader);

    // Validate vault name matches
    assert!(vault_name == deserialized_vault_name, EVaultDoesNotExist);

    // Get vault
    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version_witness);
    assert!(vault.streams.contains(stream_id), EStreamNotFound);

    // Execute freeze/unfreeze logic
    if (freeze) {
        emergency_freeze_stream(vault, stream_id, clock);
    } else {
        emergency_unfreeze_stream(vault, stream_id, clock);
    };

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute cancel stream action
public fun do_cancel_stream<Config: store, Outcome: store, CoinType: drop, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    vault_name: String,
    clock: &Clock,
    version_witness: VersionWitness,
    witness: IW,
    ctx: &mut TxContext,
): (Coin<CoinType>, u64) {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<CancelStream>(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(spec);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let deserialized_vault_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let stream_id = bcs::peel_address(&mut reader).to_id();

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(reader);

    // Validate vault name matches
    assert!(vault_name == deserialized_vault_name, EVaultDoesNotExist);

    // Get vault
    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(vault_name), version_witness);
    assert!(vault.streams.contains(stream_id), EStreamNotFound);

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

    // Increment action index
    executable::increment_action_idx(executable);

    (refund_coin, to_refund)
}

/// Processes a SpendAction and takes a coin from the vault.
public fun do_spend<Config: store, Outcome: store, CoinType: drop, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
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

    // Deserialize the entire action struct directly
    let mut reader = bcs::new(*action_data);
    let name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let amount = bcs::peel_u64(&mut reader);

    // Validate all bytes consumed
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

/// Processes an ApproveCoinTypeAction and approves the coin type.
public fun do_approve_coin_type<Config: store, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    version_witness: VersionWitness,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<VaultApproveCoinType>(spec);

    let action_data = intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize the entire action struct directly
    let mut reader = bcs::new(*action_data);
    let name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(name), version_witness);

    let type_key = type_name::with_defining_ids<CoinType>();
    if (!vault.approved_types.contains(&type_key)) {
        vault.approved_types.insert(type_key);
    };

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Processes a RemoveApprovedCoinTypeAction and removes the coin type approval.
public fun do_remove_approved_coin_type<Config: store, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    version_witness: VersionWitness,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<VaultRemoveApprovedCoinType>(spec);

    let action_data = intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize the entire action struct directly
    let mut reader = bcs::new(*action_data);
    let name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    let vault: &mut Vault = account.borrow_managed_data_mut(VaultKey(name), version_witness);

    let type_key = type_name::with_defining_ids<CoinType>();
    if (vault.approved_types.contains(&type_key)) {
        vault.approved_types.remove(&type_key);
    };

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Deletes an ApproveCoinTypeAction from an expired intent.
public fun delete_approve_coin_type<CoinType>(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, so it's automatically cleaned up
    // No need to deserialize the data
}

/// Deletes a RemoveApprovedCoinTypeAction from an expired intent.
public fun delete_remove_approved_coin_type<CoinType>(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, so it's automatically cleaned up
    // No need to deserialize the data
}

/// Deletes a CancelStreamAction from an expired intent.
public fun delete_cancel_stream(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, so it's automatically cleaned up
    // No need to deserialize the data
}

/// Deletes a ToggleStreamPauseAction from an expired intent.
public fun delete_toggle_stream_pause(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, so it's automatically cleaned up
    // No need to deserialize the data
}

/// Deletes a ToggleStreamFreezeAction from an expired intent.
public fun delete_toggle_stream_freeze(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, so it's automatically cleaned up
    // No need to deserialize the data
}

// === Stream Management Functions ===

/// Creates a new stream in the vault
public fun create_stream<Config: store, CoinType: drop>(
    auth: Auth,
    account: &mut Account,
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
        // additional checks
        additional_beneficiaries: vector::empty(),
        max_beneficiaries,
        is_paused: false,
        paused_at: option::none(),
        paused_until: option::none(),
        paused_duration: 0,
        emergency_frozen: false,
        expiry_timestamp: option::none(),
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
public fun cancel_stream<Config: store, CoinType: drop>(
    auth: Auth,
    account: &mut Account,
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
public fun withdraw_from_stream<Config: store, CoinType: drop>(
    account: &mut Account,
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
public fun calculate_claimable<Config: store>(
    account: &Account,
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
public fun stream_info<Config: store>(
    account: &Account,
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
public fun has_stream(
    account: &Account,
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
/// SAFETY: This function MUST only be called on unshared Accounts
/// during the initialization phase before the Account is shared.
/// Once an Account is shared, this function will fail as it bypasses
/// the normal Auth checks that protect shared Accounts.
public(package) fun create_stream_unshared<Config: store, CoinType: drop>(
    account: &mut Account,
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
        paused_until: option::none(),
        is_paused: false,
        emergency_frozen: false,
        expiry_timestamp: option::none(),
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

// === Stream Pause Control ===

/// Pause a stream for a specific duration (in milliseconds)
/// Pass 0 for pause_duration_ms to pause indefinitely
public fun pause_stream<CoinType>(
    vault: &mut Vault,
    stream_id: ID,
    pause_duration_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let stream = table::borrow_mut(&mut vault.streams, stream_id);

    // Only beneficiary can pause
    let sender = tx_context::sender(ctx);
    assert!(stream.beneficiary == sender || stream.additional_beneficiaries.contains(&sender), EUnauthorizedBeneficiary);
    assert!(!stream.is_paused, EVestingPaused);
    assert!(!stream.emergency_frozen, EEmergencyFrozen);

    let current_time = clock.timestamp_ms();

    // Use stream_utils for validation and calculation
    assert!(stream_utils::validate_pause_duration(current_time, pause_duration_ms), ETimeCalculationOverflow);

    stream.is_paused = true;
    stream.paused_at = option::some(current_time);
    stream.paused_until = stream_utils::calculate_pause_until(current_time, pause_duration_ms);

    event::emit(StreamPaused {
        stream_id,
        paused_at: current_time,
    });
}

/// Resume a paused stream
public fun resume_stream<CoinType>(
    vault: &mut Vault,
    stream_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let stream = table::borrow_mut(&mut vault.streams, stream_id);

    // Only beneficiary can resume
    let sender = tx_context::sender(ctx);
    assert!(stream.beneficiary == sender || stream.additional_beneficiaries.contains(&sender), EUnauthorizedBeneficiary);
    assert!(stream.is_paused, EVestingNotPaused);
    assert!(!stream.emergency_frozen, EEmergencyFrozen);

    let current_time = clock.timestamp_ms();

    // Calculate pause duration
    if (stream.paused_at.is_some()) {
        let pause_start = *stream.paused_at.borrow();
        let pause_duration = stream_utils::calculate_pause_duration(pause_start, current_time);
        stream.paused_duration = stream.paused_duration + pause_duration;
    };

    stream.is_paused = false;
    stream.paused_at = option::none();
    stream.paused_until = option::none();

    event::emit(StreamResumed {
        stream_id,
        resumed_at: current_time,
        pause_duration: stream.paused_duration,
    });
}

/// Check if pause has expired and auto-unpause if needed
/// Can be called by anyone
public fun check_and_unpause_stream(
    vault: &mut Vault,
    stream_id: ID,
    clock: &Clock,
) {
    let stream = table::borrow_mut(&mut vault.streams, stream_id);

    if (!stream.is_paused) {
        return
    };

    let current_time = clock.timestamp_ms();

    // Use stream_utils to check if pause expired
    if (stream_utils::is_pause_expired(&stream.paused_until, current_time)) {
        // Calculate pause duration
        if (stream.paused_at.is_some()) {
            let pause_start = *stream.paused_at.borrow();
            let pause_duration = stream_utils::calculate_pause_duration(pause_start, current_time);
            stream.paused_duration = stream.paused_duration + pause_duration;
        };

        stream.is_paused = false;
        stream.paused_at = option::none();
        stream.paused_until = option::none();

        event::emit(StreamResumed {
            stream_id,
            resumed_at: current_time,
            pause_duration: stream.paused_duration,
        });
    };
}

// === Emergency Controls ===

/// Emergency freeze a stream - prevents all claims and unpause
/// Only callable by governance/authority
public fun emergency_freeze_stream(
    vault: &mut Vault,
    stream_id: ID,
    clock: &Clock,
) {
    let stream = table::borrow_mut(&mut vault.streams, stream_id);
    assert!(!stream.emergency_frozen, EEmergencyFrozen);

    stream.emergency_frozen = true;
    if (!stream.is_paused) {
        stream.is_paused = true;
        stream.paused_at = option::some(clock.timestamp_ms());
        stream.paused_until = option::none(); // Indefinite
    };

    event::emit(StreamFrozen {
        stream_id,
        timestamp: clock.timestamp_ms(),
    });
}

/// Remove emergency freeze
/// Only callable by governance/authority
public fun emergency_unfreeze_stream(
    vault: &mut Vault,
    stream_id: ID,
    clock: &Clock,
) {
    let stream = table::borrow_mut(&mut vault.streams, stream_id);
    assert!(stream.emergency_frozen, EVestingNotPaused);

    stream.emergency_frozen = false;

    event::emit(StreamUnfrozen {
        stream_id,
        timestamp: clock.timestamp_ms(),
    });

    // Note: Does NOT auto-unpause - beneficiary must explicitly unpause after unfreezing
}

// === Preview Functions ===

/// Calculate currently claimable amount from a stream
public fun stream_claimable_now(
    vault: &Vault,
    stream_id: ID,
    clock: &Clock,
): u64 {
    let stream = table::borrow(&vault.streams, stream_id);
    let current_time = clock.timestamp_ms();

    // Use stream_utils to check if claiming is allowed
    if (!stream_utils::can_claim(
        stream.is_paused,
        stream.emergency_frozen,
        &stream.expiry_timestamp,
        current_time
    )) {
        return 0
    };

    // Check cliff
    if (stream.cliff_time.is_some()) {
        let cliff = *stream.cliff_time.borrow();
        if (current_time < cliff) {
            return 0
        };
    } else if (current_time < stream.start_time) {
        return 0
    };

    // Calculate claimable using stream_utils
    stream_utils::calculate_claimable(
        stream.total_amount,
        stream.claimed_amount,
        stream.start_time,
        stream.end_time,
        current_time,
        stream.paused_duration,
        &stream.cliff_time
    )
}

/// Get next vesting time for a stream
public fun stream_next_vest_time(
    vault: &Vault,
    stream_id: ID,
    clock: &Clock,
): Option<u64> {
    let stream = table::borrow(&vault.streams, stream_id);
    let current_time = clock.timestamp_ms();

    // Use stream_utils for calculation
    stream_utils::next_vesting_time(
        stream.start_time,
        stream.end_time,
        &stream.cliff_time,
        &stream.expiry_timestamp,
        current_time
    )
}

// NOTE: Expiry management removed - doesn't make sense for beneficiary to set their own expiry
