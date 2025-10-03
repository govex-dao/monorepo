// ============================================================================
// FORK MODIFICATION - Owned Objects with BCS Serialization
// ============================================================================
// This module manages withdrawal and transfer of owned objects from Account.
//
// KEY FEATURES:
// - BCS serialization for all actions (type-safe storage as bytes)
// - Separate handling for objects vs coins:
//   * WithdrawObjectAction: Tracks specific object IDs
//   * WithdrawCoinAction: Tracks coin type + amount (flexible matching)
// - No pessimistic locking - conflicts resolved by blockchain ownership
// - Actions serialize via add_typed_action() with type markers
// - Manual BCS deserialization during execution
//
// ADVANTAGES OF BCS SERIALIZATION:
// - Explicit control over serialization format
// - Type markers provide compile-time safety
// - Can version action formats independently
// - Smaller on-chain storage footprint
// ============================================================================

/// This module allows objects owned by the account to be accessed through intents in a secure way.
/// The objects can be taken only via Actions which use Transfer to Object (TTO).
/// This action can't be proposed directly since it wouldn't make sense to withdraw an object without using it.

module account_protocol::owned;

// === Imports ===

use std::{
    string::String,
    type_name,
};
use sui::{
    coin::{Self, Coin},
    transfer::Receiving,
    bcs
};
use account_protocol::{
    action_validation,
    account::{Self, Account, Auth},
    intents::{Self, Expired, Intent},
    executable::Executable,
};
use account_extensions::framework_action_types;

use fun account_protocol::intents::add_typed_action as Intent.add_typed_action;

// === Errors ===

const EWrongObject: u64 = 0;
const EWrongAmount: u64 = 1;
const EWrongCoinType: u64 = 2;

// === Structs ===

/// Action guarding access to account owned objects which can only be received via this action
public struct WithdrawObjectAction has drop, store {
    // the owned object we want to access
    object_id: ID,
}

/// Action guarding access to account owned coins which can only be received via this action
public struct WithdrawCoinAction has drop, store {
    // the type of the coin we want to access
    coin_type: String,
    // the amount of the coin we want to access
    coin_amount: u64,
}

// === Destruction Functions ===

/// Destroy a WithdrawObjectAction after serialization
public fun destroy_withdraw_object_action(action: WithdrawObjectAction) {
    let WithdrawObjectAction { object_id: _ } = action;
}

/// Destroy a WithdrawCoinAction after serialization
public fun destroy_withdraw_coin_action(action: WithdrawCoinAction) {
    let WithdrawCoinAction { coin_type: _, coin_amount: _ } = action;
}

// === Public functions ===

/// Creates a new WithdrawObjectAction and add it to an intent
public fun new_withdraw_object<Config, Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    account: &Account<Config>,
    object_id: ID,
    intent_witness: IW,
) {
    intent.assert_is_account(account.addr());

    // Create the action struct
    let action = WithdrawObjectAction { object_id };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with pre-serialized bytes
    intent.add_typed_action(
        framework_action_types::owned_withdraw_object(),
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_withdraw_object_action(action);
}

/// Executes a WithdrawObjectAction and returns the object
public fun do_withdraw_object<Config, Outcome: store, T: key + store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    receiving: Receiving<T>,
    intent_witness: IW,
): T {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<framework_action_types::OwnedWithdrawObject>(spec);

    let action_data = intents::action_spec_data(spec);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let object_id = object::id_from_bytes(bcs::peel_vec_u8(&mut reader));

    assert!(receiving.receiving_object_id() == object_id, EWrongObject);

    // Receive the object and increment action index
    let obj = account::receive(account, receiving);
    account_protocol::executable::increment_action_idx(executable);

    obj
}

/// Deletes a WithdrawObjectAction from an expired intent
public fun delete_withdraw_object<Config>(expired: &mut Expired, account: &Account<Config>) {
    expired.assert_is_account(account.addr());

    let spec = intents::remove_action_spec(expired);
    let action_data = intents::action_spec_data(&spec);
    let mut reader = bcs::new(*action_data);

    // We don't need the value, but we must peel it to consume the bytes
    let WithdrawObjectAction { object_id: _ } = WithdrawObjectAction {
        object_id: object::id_from_bytes(bcs::peel_vec_u8(&mut reader))
    };
}

/// Creates a new WithdrawCoinAction and add it to an intent
public fun new_withdraw_coin<Config, Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    account: &Account<Config>,
    coin_type: String,
    coin_amount: u64,
    intent_witness: IW,
) {
    intent.assert_is_account(account.addr());

    // Create the action struct
    let action = WithdrawCoinAction { coin_type, coin_amount };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with pre-serialized bytes
    intent.add_typed_action(
        framework_action_types::owned_withdraw_coin(),
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_withdraw_coin_action(action);
}

/// Executes a WithdrawCoinAction and returns the coin
public fun do_withdraw_coin<Config, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    receiving: Receiving<Coin<CoinType>>,
    intent_witness: IW,
): Coin<CoinType> {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<framework_action_types::OwnedWithdrawCoin>(spec);

    let action_data = intents::action_spec_data(spec);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let coin_type = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let coin_amount = bcs::peel_u64(&mut reader);

    // Receive the coin
    let coin = account::receive(account, receiving);

    // Validate coin type and amount
    assert!(coin.value() == coin_amount, EWrongAmount);
    assert!(
        type_name::with_defining_ids<CoinType>().into_string().to_string() == coin_type,
        EWrongCoinType
    );

    // Increment action index
    account_protocol::executable::increment_action_idx(executable);

    coin
}

/// Deletes a WithdrawCoinAction from an expired intent
public fun delete_withdraw_coin<Config>(expired: &mut Expired, account: &Account<Config>) {
    expired.assert_is_account(account.addr());

    let spec = intents::remove_action_spec(expired);
    let action_data = intents::action_spec_data(&spec);
    let mut reader = bcs::new(*action_data);

    // We don't need the values, but we must peel them to consume the bytes
    let WithdrawCoinAction { coin_type: _, coin_amount: _ } = WithdrawCoinAction {
        coin_type: std::string::utf8(bcs::peel_vec_u8(&mut reader)),
        coin_amount: bcs::peel_u64(&mut reader)
    };
}

// Coin operations

/// Authorized addresses can merge and split coins.
/// Returns the IDs to use in a following intent, conserves the order.
public fun merge_and_split<Config, CoinType>(
    auth: Auth,
    account: &mut Account<Config>,
    to_merge: vector<Receiving<Coin<CoinType>>>, // there can be only one coin if we just want to split
    to_split: vector<u64>, // there can be no amount if we just want to merge
    ctx: &mut TxContext
): vector<ID> {
    account.verify(auth);
    // receive all coins
    let mut coins = vector::empty();
    to_merge.do!(|item| {
        let coin = account::receive(account, item);
        coins.push_back(coin);
    });

    let coin = merge(coins, ctx);
    let ids = split(account, coin, to_split, ctx);

    ids
}

fun merge<CoinType>(
    coins: vector<Coin<CoinType>>,
    ctx: &mut TxContext
): Coin<CoinType> {
    let mut merged = coin::zero<CoinType>(ctx);
    coins.do!(|coin| {
        merged.join(coin);
    });

    merged
}

fun split<Config, CoinType>(
    account: &mut Account<Config>,
    mut coin: Coin<CoinType>,
    amounts: vector<u64>,
    ctx: &mut TxContext
): vector<ID> {
    let ids = amounts.map!(|amount| {
        let split = coin.split(amount, ctx);
        let id = object::id(&split);
        account.keep(split, ctx);
        id
    });
    account.keep(coin, ctx);

    ids
}
