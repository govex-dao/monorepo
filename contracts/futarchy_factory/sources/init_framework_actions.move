// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Init wrappers for Move Framework actions during DAO creation
///
/// This module provides simple wrappers around Move framework init functions
/// for use during Futarchy DAO initialization. It follows the same pattern:
/// - Works on unshared Accounts
/// - No Auth required
/// - Atomic through PTB composition
module futarchy_factory::init_framework_actions;

use account_actions::init_actions;
use account_protocol::account::Account;
use futarchy_core::futarchy_config::FutarchyConfig;
use std::option;
use sui::clock::Clock;
use sui::coin::{Coin, TreasuryCap};
use sui::object::ID;
use sui::package::UpgradeCap;
use sui::tx_context::TxContext;

// === Vault Actions ===

/// Deposit initial funds into DAO vault during creation
public entry fun init_vault_deposit<CoinType: drop>(
    account: &mut Account<FutarchyConfig>,
    coin: Coin<CoinType>,
    ctx: &mut TxContext,
) {
    // Use the default "treasury" vault name
    init_actions::init_vault_deposit(
        account,
        coin,
        b"treasury",
        ctx,
    );
}

/// Deposit with custom vault name
public entry fun init_vault_deposit_named<CoinType: drop>(
    account: &mut Account<FutarchyConfig>,
    coin: Coin<CoinType>,
    vault_name: vector<u8>,
    ctx: &mut TxContext,
) {
    init_actions::init_vault_deposit(
        account,
        coin,
        vault_name,
        ctx,
    );
}

// === Currency Actions ===

/// Lock treasury cap in DAO during creation
public entry fun init_lock_treasury_cap<CoinType>(
    account: &mut Account<FutarchyConfig>,
    cap: TreasuryCap<CoinType>,
) {
    init_actions::init_lock_treasury_cap(account, cap);
}

/// Mint initial tokens during creation
public entry fun init_mint<CoinType>(
    account: &mut Account<FutarchyConfig>,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    init_actions::init_mint<FutarchyConfig, CoinType>(account, amount, recipient, ctx);
}

/// Mint and deposit to vault during creation
public entry fun init_mint_and_deposit<CoinType: drop>(
    account: &mut Account<FutarchyConfig>,
    amount: u64,
    vault_name: vector<u8>,
    ctx: &mut TxContext,
) {
    init_actions::init_mint_and_deposit<FutarchyConfig, CoinType>(account, amount, vault_name, ctx);
}

// === Vesting Actions ===

/// Create vesting schedule during DAO creation
public entry fun init_create_vesting<CoinType>(
    account: &mut Account<FutarchyConfig>,
    coin: Coin<CoinType>,
    recipient: address,
    start_timestamp: u64,
    duration_ms: u64,
    cliff_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    init_actions::init_create_vesting(
        account,
        coin,
        recipient,
        start_timestamp,
        duration_ms,
        cliff_ms,
        clock,
        ctx,
    );
}

/// Create founder vesting with standard 4-year schedule
public entry fun init_create_founder_vesting<CoinType>(
    account: &mut Account<FutarchyConfig>,
    coin: Coin<CoinType>,
    founder: address,
    cliff_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    init_actions::init_create_founder_vesting(
        account,
        coin,
        founder,
        cliff_ms,
        clock,
        ctx,
    );
}

/// Create team member vesting
public entry fun init_create_team_vesting<CoinType>(
    account: &mut Account<FutarchyConfig>,
    coin: Coin<CoinType>,
    team_member: address,
    duration_ms: u64,
    cliff_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    init_actions::init_create_team_vesting(
        account,
        coin,
        team_member,
        duration_ms,
        cliff_ms,
        clock,
        ctx,
    );
}

// === Package Upgrade Actions ===

/// Lock upgrade cap for controlled package upgrades
public entry fun init_lock_upgrade_cap(
    account: &mut Account<FutarchyConfig>,
    cap: UpgradeCap,
    package_name: vector<u8>,
    delay_ms: u64,
    reclaim_delay_ms: u64,
) {
    init_actions::init_lock_upgrade_cap(account, cap, package_name, delay_ms, reclaim_delay_ms);
}

// === Access Control Actions ===

/// Lock generic capability during DAO creation
public entry fun init_lock_capability<Cap: key + store>(
    account: &mut Account<FutarchyConfig>,
    cap: Cap,
) {
    init_actions::init_lock_capability(account, cap);
}

// === Owned Actions ===

/// Store owned object during DAO creation
public entry fun init_store_object<Key: copy + drop + store, T: key + store>(
    account: &mut Account<FutarchyConfig>,
    key: Key,
    object: T,
    ctx: &mut TxContext,
) {
    init_actions::init_store_object(account, key, object, ctx);
}

// === Transfer Actions ===

/// Transfer object during DAO initialization
public entry fun init_transfer_object<T: key + store>(object: T, recipient: address) {
    init_actions::init_transfer_object(object, recipient);
}

/// Transfer multiple objects during DAO initialization
public entry fun init_transfer_objects<T: key + store>(
    objects: vector<T>,
    recipients: vector<address>,
) {
    init_actions::init_transfer_objects(objects, recipients);
}

// === Stream Actions ===

/// Create a vault stream during DAO initialization
/// Creates a time-based payment stream for salaries, grants, etc.
public entry fun init_create_vault_stream<CoinType: drop>(
    account: &mut Account<FutarchyConfig>,
    vault_name: vector<u8>,
    beneficiary: address,
    total_amount: u64,
    start_time: u64,
    end_time: u64,
    cliff_ms: u64,
    max_per_withdrawal: u64,
    min_interval_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let cliff_time = if (cliff_ms > 0) {
        option::some(start_time + cliff_ms)
    } else {
        option::none()
    };

    init_actions::init_create_vault_stream<FutarchyConfig, CoinType>(
        account,
        vault_name,
        beneficiary,
        total_amount,
        start_time,
        end_time,
        cliff_time,
        max_per_withdrawal,
        min_interval_ms,
        clock,
        ctx,
    );
}

/// Create a simple salary stream with monthly payments
public entry fun init_create_salary_stream<CoinType: drop>(
    account: &mut Account<FutarchyConfig>,
    employee: address,
    monthly_amount: u64,
    num_months: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    init_actions::init_create_salary_stream<FutarchyConfig, CoinType>(
        account,
        employee,
        monthly_amount,
        num_months,
        clock,
        ctx,
    );
}

// === Usage Example ===
// PTB Composition:
// ```typescript
// // 1. Create unshared DAO
// const [account, queue, pool] = tx.moveCall({
//   target: 'factory::create_dao_unshared',
//   ...
// });
//
// // 2. Lock treasury cap
// tx.moveCall({
//   target: 'init_framework_actions::init_lock_treasury_cap',
//   arguments: [account, treasuryCap],
// });
//
// // 3. Deposit initial funds
// tx.moveCall({
//   target: 'init_framework_actions::init_vault_deposit',
//   arguments: [account, treasuryFunds, ctx],
// });
//
// // 4. Create founder vesting
// tx.moveCall({
//   target: 'init_framework_actions::init_create_founder_vesting',
//   arguments: [account, founderCoins, founderAddr, cliffMs, clock, ctx],
// });
//
// // 5. Create team vestings
// tx.moveCall({
//   target: 'init_framework_actions::init_create_team_vesting',
//   arguments: [account, teamCoins, teamAddr, durationMs, cliffMs, clock, ctx],
// });
//
// // 6. Add liquidity (Futarchy action)
// tx.moveCall({
//   target: 'init_actions::init_add_liquidity',
//   arguments: [pool, assetCoin, stableCoin, minLp, clock],
// });
//
// // 7. Share the DAO
// tx.moveCall({
//   target: 'factory::finalize_and_share_dao',
//   arguments: [account, queue, pool],
// });
// ```
