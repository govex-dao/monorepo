// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Init wrappers for Move Framework actions during DAO creation
///
/// This module provides public functions for init actions.
/// These functions need to be in the account_actions package to access
/// package-visibility functions like do_*_unshared().
module account_actions::init_actions;

use account_actions::{currency, vault, access_control, version};
use account_protocol::account::Account;
use account_protocol::package_registry::PackageRegistry;
use std::string;
use sui::coin::{Coin, TreasuryCap};
use sui::tx_context::TxContext;

// === Vault Actions ===

public fun init_vault_deposit<Config: store, CoinType: drop>(
    account: &mut Account,
    registry: &PackageRegistry,
    vault_name: string::String,
    coin: Coin<CoinType>,
    ctx: &mut TxContext,
) {
    vault::do_deposit_unshared(account, registry, vault_name, coin, ctx);
}

// === Currency Actions ===

public fun init_lock_treasury_cap<Config: store, CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    cap: TreasuryCap<CoinType>,
) {
    currency::do_lock_cap_unshared(account, registry, cap);
}

public fun init_mint<Config: store, CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    currency::do_mint_unshared<CoinType>(account, registry, amount, recipient, ctx);
}

public fun init_mint_to_coin<Config: store, CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    amount: u64,
    ctx: &mut TxContext,
): Coin<CoinType> {
    currency::do_mint_to_coin_unshared<CoinType>(account, registry, amount, ctx)
}

// === Access Control Actions ===

public fun init_lock_cap<Config: store, Cap: key + store>(
    account: &mut Account,
    registry: &PackageRegistry,
    cap: Cap,
) {
    access_control::do_lock_cap_unshared(account, registry, cap);
}

// === Owned Actions ===

public fun init_store_object<Config: store, Key: copy + drop + store, T: key + store>(
    account: &mut Account,
    registry: &PackageRegistry,
    key: Key,
    object: T,
) {
    account.add_managed_asset(registry, key, object, version::current());
}

