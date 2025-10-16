/// Init actions for Move framework - mirrors Futarchy pattern
/// These work on unshared Accounts during initialization
///
/// ## FORK NOTE
/// **Added**: Complete init_actions module for atomic DAO initialization
/// **Reason**: Allow intents (vault deposits, minting, vesting, etc.) to be called
/// during the init process of unshared Accounts before they are publicly shared.
/// This enables atomic DAO bootstrapping via PTBs without requiring proposal approval.
/// **Pattern**: Entry functions call `do_*_unshared()` functions in action modules
/// **Safety**: Functions use `public(package)` visibility to prevent misuse on shared Accounts
module account_actions::init_actions;

use account_actions::access_control;
use account_actions::currency;
use account_actions::kiosk;
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

/// Error when kiosk name already exists
const EKioskAlreadyExists: u64 = 1004;

/// Error when capability already locked
const ECapabilityAlreadyLocked: u64 = 1005;

/// Error when treasury cap already locked
const ETreasuryCapAlreadyLocked: u64 = 1006;

/// Error when upgrade cap already locked
const EUpgradeCapAlreadyLocked: u64 = 1007;

/// Error when object key already exists
const EObjectKeyAlreadyExists: u64 = 1008;

// === Init Vault Actions ===

/// Deposit initial funds during account creation
public fun init_vault_deposit<Config, CoinType: drop>(
    account: &mut Account<Config>,
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
public fun init_vault_deposit_default<Config, CoinType: drop>(
    account: &mut Account<Config>,
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
public fun init_lock_treasury_cap<Config, CoinType>(
    account: &mut Account<Config>,
    cap: TreasuryCap<CoinType>,
) {
    currency::do_lock_cap_unshared(account, cap);
}

/// Mint coins during initialization
public fun init_mint<Config, CoinType>(
    account: &mut Account<Config>,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    currency::do_mint_unshared<Config, CoinType>(account, amount, recipient, ctx);
}

/// Mint and deposit during initialization
public fun init_mint_and_deposit<Config, CoinType: drop>(
    account: &mut Account<Config>,
    amount: u64,
    vault_name: vector<u8>,
    ctx: &mut TxContext,
) {
    let coin = currency::do_mint_to_coin_unshared<Config, CoinType>(
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
public fun init_create_vesting<Config, CoinType>(
    _account: &mut Account<Config>, // For consistency, though not used
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
public fun init_create_founder_vesting<Config, CoinType>(
    _account: &mut Account<Config>,
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
public fun init_create_team_vesting<Config, CoinType>(
    _account: &mut Account<Config>,
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
public fun init_lock_upgrade_cap<Config>(
    account: &mut Account<Config>,
    cap: UpgradeCap,
    package_name: vector<u8>,
    delay_ms: u64,
) {
    package_upgrade::do_lock_cap_unshared(
        account,
        cap,
        string::utf8(package_name),
        delay_ms,
    );
}

// === Init Kiosk Actions ===

/// Open kiosk during initialization
/// Creates a kiosk for NFT management
/// Returns the kiosk ID for subsequent operations
public fun init_open_kiosk<Config>(account: &mut Account<Config>, ctx: &mut TxContext): object::ID {
    kiosk::do_open_unshared(account, ctx)
}

// Note: init_place_in_kiosk removed - PTBs should use the returned
// kiosk ID directly with standard kiosk functions

// === Init Access Control Actions ===

/// Lock generic capability during initialization
/// Stores any capability object in the Account
public fun init_lock_capability<Config, Cap: key + store>(account: &mut Account<Config>, cap: Cap) {
    access_control::do_lock_cap_unshared(account, cap);
}

// === Init Owned Actions ===

/// Store owned object during initialization
/// Directly stores an object in the Account's owned storage
public fun init_store_object<Config, Key: copy + drop + store, T: key + store>(
    account: &mut Account<Config>,
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
public fun init_create_vault_stream<Config, CoinType: drop>(
    account: &mut Account<Config>,
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
public fun init_create_salary_stream<Config, CoinType: drop>(
    account: &mut Account<Config>,
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
