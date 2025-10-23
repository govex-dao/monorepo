// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Init wrappers for Move Framework actions during DAO creation
///
/// This module provides entry functions for Futarchy DAO initialization.
/// - Works on unshared Accounts
/// - No Auth required
/// - Atomic through PTB composition
module futarchy_factory::init_framework_actions;

use account_actions::init_actions;
use account_protocol::account::Account;
use futarchy_core::futarchy_config::FutarchyConfig;
use std::string;
use sui::coin::{Coin, TreasuryCap};
use sui::transfer;
use sui::tx_context::TxContext;

// === Vault Actions ===

/// Deposit initial funds into DAO vault during creation
public entry fun init_vault_deposit<CoinType: drop>(
    account: &mut Account,
    coin: Coin<CoinType>,
    ctx: &mut TxContext,
) {
    init_actions::init_vault_deposit<FutarchyConfig, CoinType>(
        account,
        string::utf8(b"treasury"),
        coin,
        ctx,
    );
}

/// Deposit with custom vault name
public entry fun init_vault_deposit_named<CoinType: drop>(
    account: &mut Account,
    coin: Coin<CoinType>,
    vault_name: vector<u8>,
    ctx: &mut TxContext,
) {
    init_actions::init_vault_deposit<FutarchyConfig, CoinType>(
        account,
        string::utf8(vault_name),
        coin,
        ctx,
    );
}

// === Currency Actions ===

/// Lock treasury cap in DAO during creation
public entry fun init_lock_treasury_cap<CoinType>(
    account: &mut Account,
    cap: TreasuryCap<CoinType>,
) {
    init_actions::init_lock_treasury_cap<FutarchyConfig, CoinType>(account, cap);
}

/// Mint initial tokens during creation
public entry fun init_mint<CoinType>(
    account: &mut Account,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    init_actions::init_mint<FutarchyConfig, CoinType>(account, amount, recipient, ctx);
}

/// Mint and deposit to vault during creation
public entry fun init_mint_and_deposit<CoinType: drop>(
    account: &mut Account,
    amount: u64,
    vault_name: vector<u8>,
    ctx: &mut TxContext,
) {
    let coin = init_actions::init_mint_to_coin<FutarchyConfig, CoinType>(account, amount, ctx);
    init_actions::init_vault_deposit<FutarchyConfig, CoinType>(account, string::utf8(vault_name), coin, ctx);
}

// === Access Control Actions ===

/// Lock generic capability during DAO creation
public entry fun init_lock_capability<Cap: key + store>(
    account: &mut Account,
    cap: Cap,
) {
    init_actions::init_lock_cap<FutarchyConfig, Cap>(account, cap);
}

// === Owned Actions ===

/// Store owned object during DAO creation
public entry fun init_store_object<Key: copy + drop + store, T: key + store>(
    account: &mut Account,
    key: Key,
    object: T,
    _ctx: &mut TxContext,
) {
    init_actions::init_store_object<FutarchyConfig, Key, T>(account, key, object);
}

// === Transfer Actions ===

/// Transfer object during DAO initialization
public entry fun init_transfer_object<T: key + store>(object: T, recipient: address) {
    transfer::public_transfer(object, recipient);
}

/// Transfer multiple objects during DAO initialization
public entry fun init_transfer_objects<T: key + store>(
    objects: vector<T>,
    recipients: vector<address>,
) {
    assert!(objects.length() == recipients.length(), 0);
    objects.zip_do!(recipients, |object, recipient| {
        transfer::public_transfer(object, recipient);
    });
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
