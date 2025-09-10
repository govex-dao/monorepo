// ============================================================================
// FORK MODIFICATION NOTICE - Complete Removal of Object Locking
// ============================================================================
// This module has been dramatically simplified by removing ALL locking logic.
// In DAO governance, multiple proposals competing for the same resources is 
// natural and expected. The blockchain's ownership model already prevents 
// double-spending - if an object is consumed by one intent, others will simply
// fail when they try to access it.
//
// Changes in this fork:
// - new_withdraw(): Just adds the action - no validation or locking
// - do_withdraw(): Just receives the object - no lock/unlock dance  
// - delete_withdraw(): Trivial cleanup - no unlocking needed
// - merge_and_split(): Works without any lock checks
// - REMOVED: EObjectLocked error entirely
//
// This eliminates ~50 lines of locking code and removes the critical footgun
// where objects could be permanently locked if cleanup wasn't performed 
// correctly. The system is now simpler, safer, and more suitable for DAOs.
// ============================================================================

/// This module allows objects owned by the account to be accessed through intents in a secure way.
/// The objects can be taken only via an WithdrawAction action which uses Transfer to Object (TTO).
/// This action can't be proposed directly since it wouldn't make sense to withdraw an object without using it.

module account_protocol::owned;

// === Imports ===

use sui::{
    coin::{Self, Coin},
    transfer::Receiving
};
use account_extensions::action_descriptor::{Self, ActionDescriptor};

// No use fun needed - add_action_with_descriptor is in intents module
use account_protocol::{
    account::{Account, Auth},
    intents::{Expired, Intent},
    executable::Executable,
};

// === Errors ===

const EWrongObject: u64 = 0;
// REMOVED: EObjectLocked - no locking in new design

// === Structs ===

/// Action guarding access to account owned objects which can only be received via this action
public struct WithdrawAction has store {
    // the owned object we want to access
    object_id: ID,
}

// === Public functions ===

/// Creates a new WithdrawAction and add it to an intent
public fun new_withdraw<Config, Outcome, IW: drop>(
    intent: &mut Intent<Outcome>, 
    account: &Account<Config>,
    object_id: ID,
    intent_witness: IW,
) {
    intent.assert_is_account(account.addr());
    // No validation needed - conflicts are natural in DAO governance
    let descriptor = action_descriptor::new(b"ownership", b"withdraw")
        .with_target(object_id);
    intent.add_action_with_descriptor(
        WithdrawAction { object_id },
        descriptor,
        intent_witness
    );
}

/// Executes a WithdrawAction and returns the object
public fun do_withdraw<Config, Outcome: store, T: key + store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,  
    receiving: Receiving<T>,
    intent_witness: IW,
): T {    
    executable.intent().assert_is_account(account.addr());

    let action: &WithdrawAction = executable.next_action(intent_witness);
    assert!(receiving.receiving_object_id() == action.object_id, EWrongObject);

    // Simply receive the object - no locking needed
    // If the object isn't available, this will naturally fail
    account.receive(receiving)
}

/// Deletes a WithdrawAction from an expired intent
/// Note: No unlocking needed since we now only lock during execution
public fun delete_withdraw<Config>(expired: &mut Expired, account: &Account<Config>) {
    expired.assert_is_account(account.addr());

    let WithdrawAction { object_id: _ } = expired.remove_action();
    // No unlock needed - objects are only locked during execution, not during intent creation
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
        let coin = account.receive(item);
        coins.push_back(coin);
    });

    let coin = merge(account, coins, ctx);
    let ids = split(account, coin, to_split, ctx);

    ids
}

fun merge<Config, CoinType>(
    account: &Account<Config>,
    coins: vector<Coin<CoinType>>, 
    ctx: &mut TxContext
): Coin<CoinType> {
    let mut merged = coin::zero<CoinType>(ctx);
    coins.do!(|coin| {
        // No lock check needed - conflicts are natural
        merged.join(coin);
    });

    merged
}

fun split<Config, CoinType>(
    account: &Account<Config>, 
    mut coin: Coin<CoinType>,
    amounts: vector<u64>, 
    ctx: &mut TxContext
): vector<ID> {
    // No lock check needed - conflicts are natural
    let ids = amounts.map!(|amount| {
        let split = coin.split(amount, ctx);
        let id = object::id(&split);
        account.keep(split);
        id
    });
    account.keep(coin);

    ids
}
