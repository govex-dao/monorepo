// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Init actions for Move framework - mirrors Futarchy pattern
/// These work on unshared Accounts during initialization
module account_actions::init_actions;

use account_actions::access_control;
use account_actions::currency;
use account_actions::package_upgrade;
use account_actions::transfer;
use account_actions::vault;
use account_actions::version;
use account_actions::vesting;
use account_protocol::account::{Self, Account};
use std::option::{Self, Option};
use std::string::{Self, String};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::object;
use sui::package::UpgradeCap;
use sui::tx_context::TxContext;

// === Error Codes ===

/// Error when vectors have mismatched lengths
const ELengthMismatch: u64 = 1000;

/// Error when trying to init on a shared account (if we could detect it)
const EInitOnSharedAccount: u64 = 1001;

/// Error when initialization is called after finalization
const EInitAfterFinalization: u64 = 1002;

/// Error when vault name already exists
const EVaultAlreadyExists: u64 = 1003;

/// Error when capability already locked
const ECapabilityAlreadyLocked: u64 = 1004;

/// Error when treasury cap already locked
const ETreasuryCapAlreadyLocked: u64 = 1005;

/// Error when upgrade cap already locked
const EUpgradeCapAlreadyLocked: u64 = 1006;

/// Error when object key already exists
const EObjectKeyAlreadyExists: u64 = 1007;

// === Init Vault Actions ===

/// Deposit initial funds during account creation
public fun init_vault_deposit<Config: store, CoinType: drop>(
    account: &mut Account,
    coin: Coin<CoinType>,
    vault_name: vector<u8>,
    ctx: &mut TxContext,
) {
    vault::do_deposit_unshared(
        account,
        string::utf8(vault_name),
        coin,
        ctx,
    );
}

/// Deposit with default vault name
public fun init_vault_deposit_default<Config: store, CoinType: drop>(
    account: &mut Account,
    coin: Coin<CoinType>,
    ctx: &mut TxContext,
) {
    vault::do_deposit_unshared(
        account,
        vault::default_vault_name(),
        coin,
        ctx,
    );
}

// === Init Currency Actions ===

/// Lock treasury cap during initialization
public fun init_lock_treasury_cap<Config: store, CoinType>(
    account: &mut Account,
    cap: TreasuryCap<CoinType>,
) {
    currency::do_lock_cap_unshared(account, cap);
}

/// Mint coins during initialization
public fun init_mint<Config: store, CoinType>(
    account: &mut Account,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    currency::do_mint_unshared<CoinType>(account, amount, recipient, ctx);
}

/// Mint and deposit during initialization
public fun init_mint_and_deposit<Config: store, CoinType: drop>(
    account: &mut Account,
    amount: u64,
    vault_name: vector<u8>,
    ctx: &mut TxContext,
) {
    let coin = currency::do_mint_to_coin_unshared<CoinType>(
        account,
        amount,
        ctx,
    );
    vault::do_deposit_unshared(
        account,
        string::utf8(vault_name),
        coin,
        ctx,
    );
}

// === Init Vesting Actions ===

/// Create vesting during initialization
/// Creates a vesting schedule with coins and transfers ClaimCap to recipient
/// Returns the vesting ID for reference
public fun init_create_vesting<Config: store, CoinType>(
    _account: &mut Account, // For consistency, though not used
    coin: Coin<CoinType>,
    recipient: address,
    start_timestamp: u64,
    duration_ms: u64,
    cliff_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): object::ID {
    vesting::do_create_vesting_unshared(
        coin,
        recipient,
        start_timestamp,
        duration_ms,
        cliff_ms,
        clock,
        ctx,
    )
}

/// Create founder vesting with standard parameters
/// Convenience function with preset duration for founder vesting
/// Returns the vesting ID for reference
public fun init_create_founder_vesting<Config: store, CoinType>(
    _account: &mut Account,
    coin: Coin<CoinType>,
    founder: address,
    cliff_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): object::ID {
    // Standard 4-year vesting for founders
    let duration_ms = 4 * 365 * 24 * 60 * 60 * 1000; // 4 years in milliseconds
    let start_timestamp = clock.timestamp_ms();

    vesting::do_create_vesting_unshared(
        coin,
        founder,
        start_timestamp,
        duration_ms,
        cliff_ms,
        clock,
        ctx,
    )
}

/// Create team vesting with custom duration
/// Returns the vesting ID for reference
public fun init_create_team_vesting<Config: store, CoinType>(
    _account: &mut Account,
    coin: Coin<CoinType>,
    team_member: address,
    duration_ms: u64,
    cliff_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): object::ID {
    let start_timestamp = clock.timestamp_ms();

    vesting::do_create_vesting_unshared(
        coin,
        team_member,
        start_timestamp,
        duration_ms,
        cliff_ms,
        clock,
        ctx,
    )
}

// === Init Package Upgrade Actions ===

/// Lock upgrade cap during initialization
/// Stores UpgradeCap in the Account for controlled package upgrades
/// reclaim_delay_ms: Time before DAO can reclaim externally-held commit cap (e.g., 6 months)
public fun init_lock_upgrade_cap<Config: store>(
    account: &mut Account,
    cap: UpgradeCap,
    package_name: vector<u8>,
    delay_ms: u64,
    reclaim_delay_ms: u64,
) {
    package_upgrade::do_lock_cap_unshared(
        account,
        cap,
        string::utf8(package_name),
        delay_ms,
        reclaim_delay_ms,
    );
}

/// Lock commit cap during initialization
/// Creates and stores an UpgradeCommitCap in the Account
/// This cap grants authority to commit package upgrades (finalize with UpgradeReceipt)
public fun init_lock_commit_cap<Config: store>(
    account: &mut Account,
    package_name: vector<u8>,
    ctx: &mut TxContext,
) {
    package_upgrade::do_lock_commit_cap_unshared(
        account,
        string::utf8(package_name),
        ctx,
    );
}

/// Create commit cap and transfer to recipient during initialization
/// Use this to give commit authority to an external multisig
/// while the DAO Account holds the UpgradeCap
public fun init_create_and_transfer_commit_cap<Config: store>(
    package_name: vector<u8>,
    recipient: address,
    ctx: &mut TxContext,
) {
    let commit_cap = package_upgrade::create_commit_cap_for_transfer(
        string::utf8(package_name),
        ctx,
    );
    package_upgrade::transfer_commit_cap(commit_cap, recipient);
}

// === Init Access Control Actions ===

/// Lock generic capability during initialization
/// Stores any capability object in the Account
public fun init_lock_capability<Config: store, Cap: key + store>(account: &mut Account, cap: Cap) {
    access_control::do_lock_cap_unshared(account, cap);
}

// === Init Owned Actions ===

/// Store owned object during initialization
/// Directly stores an object in the Account's owned storage
public fun init_store_object<Config: store, Key: copy + drop + store, T: key + store>(
    account: &mut Account,
    key: Key,
    object: T,
    _ctx: &mut TxContext,
) {
    // Store the object in the Account's owned storage using add_managed_asset
    account.add_managed_asset(key, object, version::current());
}

// === Init Transfer Actions ===

/// Transfer object during initialization
/// Useful for transferring objects created during DAO setup
public fun init_transfer_object<T: key + store>(object: T, recipient: address) {
    transfer::do_transfer_unshared(object, recipient);
}

/// Transfer multiple objects during initialization
public fun init_transfer_objects<T: key + store>(
    mut objects: vector<T>,
    mut recipients: vector<address>,
) {
    assert!(vector::length(&objects) == vector::length(&recipients), ELengthMismatch);

    while (!vector::is_empty(&objects)) {
        let object = vector::pop_back(&mut objects);
        let recipient = vector::pop_back(&mut recipients);
        transfer::do_transfer_unshared(object, recipient);
    };

    vector::destroy_empty(objects);
    vector::destroy_empty(recipients);
}

// === Init Stream Actions ===

/// Create a vault stream during initialization
/// Creates a time-based payment stream for salaries, grants, etc.
/// Returns the stream ID for reference
public fun init_create_vault_stream<Config: store, CoinType: drop>(
    account: &mut Account,
    vault_name: vector<u8>,
    beneficiary: address,
    total_amount: u64,
    start_time: u64,
    end_time: u64,
    cliff_time: Option<u64>,
    max_per_withdrawal: u64,
    min_interval_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): object::ID {
    vault::create_stream_unshared<Config, CoinType>(
        account,
        string::utf8(vault_name),
        beneficiary,
        total_amount,
        start_time,
        end_time,
        cliff_time,
        max_per_withdrawal,
        min_interval_ms,
        100, // Default max beneficiaries
        clock,
        ctx,
    )
}

/// Create a simple salary stream with monthly payments
/// Convenience function for common use case
/// Returns the stream ID for reference
public fun init_create_salary_stream<Config: store, CoinType: drop>(
    account: &mut Account,
    employee: address,
    monthly_amount: u64,
    num_months: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): object::ID {
    let current_time = clock.timestamp_ms();
    let month_ms = 30 * 24 * 60 * 60 * 1000; // Approximately 30 days
    let total_amount = monthly_amount * num_months;
    let start_time = current_time;
    let end_time = current_time + (month_ms * num_months);

    vault::create_stream_unshared<Config, CoinType>(
        account,
        vault::default_vault_name(),
        employee,
        total_amount,
        start_time,
        end_time,
        option::none(), // No cliff
        monthly_amount, // Max per withdrawal = monthly amount
        month_ms, // Min interval = 1 month
        1, // Single beneficiary
        clock,
        ctx,
    )
}
