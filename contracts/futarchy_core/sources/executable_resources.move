// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Minimal resource handling for intent execution
///
/// PATTERN:
/// 1. Create intent (actions are pure data)
/// 2. At execution: attach Bag of resources to Executable
/// 3. Actions take what they need from the Bag
/// 4. Bag must be empty when execution completes
///
/// This is the ONLY resource pattern you need.
module futarchy_core::executable_resources;

use std::string::String;
use std::type_name;
use sui::bag::{Self, Bag};
use sui::coin::Coin;
use sui::dynamic_field as df;
use sui::object::UID;
use sui::tx_context::TxContext;

// === Errors ===
const EResourceNotFound: u64 = 1;
const EResourcesNotEmpty: u64 = 2;

// === Key for attaching Bag to Executable ===
public struct ResourceBagKey has copy, drop, store {}

// === Resource Management (called by action executors) ===

/// Provision a coin into executable's resource bag
/// Call this before/during execution to provide resources
public fun provide_coin<T, CoinType>(
    executable_uid: &mut UID,
    name: String,
    coin: Coin<CoinType>,
    ctx: &mut TxContext,
) {
    let bag = get_or_create_bag(executable_uid, ctx);
    let key = coin_key<CoinType>(name);
    bag::add(bag, key, coin);
}

/// Take a coin from executable's resource bag
/// Actions call this to get resources they need
public fun take_coin<T, CoinType>(
    executable_uid: &mut UID,
    name: String,
): Coin<CoinType> {
    let bag = borrow_bag_mut(executable_uid);
    let key = coin_key<CoinType>(name);
    assert!(bag::contains(bag, key), EResourceNotFound);
    bag::remove(bag, key)
}

/// Check if a coin resource exists
public fun has_coin<T, CoinType>(
    executable_uid: &UID,
    name: String,
): bool {
    if (!df::exists_(executable_uid, ResourceBagKey {})) return false;
    let bag: &Bag = df::borrow(executable_uid, ResourceBagKey {});
    let key = coin_key<CoinType>(name);
    bag::contains(bag, key)
}

/// Destroy resource bag (must be empty)
/// Call this after execution completes
public fun destroy_resources(executable_uid: &mut UID) {
    if (!df::exists_(executable_uid, ResourceBagKey {})) return;
    let bag: Bag = df::remove(executable_uid, ResourceBagKey {});
    assert!(bag::is_empty(&bag), EResourcesNotEmpty);
    bag::destroy_empty(bag);
}

// === Internal Helpers ===

fun get_or_create_bag(executable_uid: &mut UID, ctx: &mut TxContext): &mut Bag {
    if (!df::exists_(executable_uid, ResourceBagKey {})) {
        let bag = bag::new(ctx);
        df::add(executable_uid, ResourceBagKey {}, bag);
    };
    df::borrow_mut(executable_uid, ResourceBagKey {})
}

fun borrow_bag_mut(executable_uid: &mut UID): &mut Bag {
    df::borrow_mut(executable_uid, ResourceBagKey {})
}

fun coin_key<CoinType>(name: String): String {
    let mut key = name;
    key.append(b"::".to_string());
    key.append(type_name::into_string(type_name::get<CoinType>()).to_string());
    key
}
