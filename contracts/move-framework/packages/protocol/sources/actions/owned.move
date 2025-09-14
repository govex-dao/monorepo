// ============================================================================
// FORK MODIFICATION NOTICE - Owned Objects with Serialize-Then-Destroy Pattern
// ============================================================================
// This module manages withdrawal and transfer of owned objects from Account.
//
// CHANGES IN THIS FORK:
// - REMOVED: ALL pessimistic locking logic from original implementation
// - Multiple proposals can now reference the same objects
// - First-to-execute wins, others fail naturally via blockchain ownership
// - Implemented serialize-then-destroy pattern for WithdrawAction
// - Added destroy_withdraw_action function for explicit destruction
// - Actions serialize to bytes before adding to intent via add_typed_action()
// - OwnedWithdraw action uses type marker from framework_action_types
// - Compile-time type safety replaces string-based descriptors
//
// RATIONALE:
// Eliminates ~100 lines of locking code and removes the critical footgun
// where objects could become permanently locked from incomplete cleanup.
// ============================================================================
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
    transfer::Receiving,
    bcs::{Self, BCS}
};

use account_protocol::{
    account::{Self, Account, Auth},
    intents::{Self, Expired, Intent},
    executable::Executable,
};
use account_extensions::framework_action_types;

use fun account_protocol::intents::add_typed_action as Intent.add_typed_action;

// === Errors ===

const EWrongObject: u64 = 0;
// REMOVED: EObjectLocked - no locking in new design

// === Structs ===

/// Action guarding access to account owned objects which can only be received via this action
public struct WithdrawAction has drop, store {
    // the owned object we want to access
    object_id: ID,
}

// === Destruction Functions ===

/// Destroy a WithdrawAction after serialization
public fun destroy_withdraw_action(action: WithdrawAction) {
    let WithdrawAction { object_id: _ } = action;
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

    // Create the action struct
    let action = WithdrawAction { object_id };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with pre-serialized bytes
    intent.add_typed_action(
        framework_action_types::owned_withdraw(),
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_withdraw_action(action);
}

/// Executes a WithdrawAction and returns the object
public fun do_withdraw<Config, Outcome: store, T: key + store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    receiving: Receiving<T>,
    intent_witness: IW,
): T {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());
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

/// Deletes a WithdrawAction from an expired intent
/// Note: No unlocking needed since we now only lock during execution
public fun delete_withdraw<Config>(expired: &mut Expired, account: &Account<Config>) {
    expired.assert_is_account(account.addr());

    let spec = intents::remove_action_spec(expired);
    let action_data = intents::action_spec_data(&spec);
    let mut reader = bcs::new(*action_data);

    // We don't need the value, but we must peel it to consume the bytes
    let WithdrawAction { object_id: _ } = WithdrawAction {
        object_id: object::id_from_bytes(bcs::peel_vec_u8(&mut reader))
    };
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
        let coin = account::receive(account, item);
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
    account: &mut Account<Config>, 
    mut coin: Coin<CoinType>,
    amounts: vector<u64>, 
    ctx: &mut TxContext
): vector<ID> {
    // No lock check needed - conflicts are natural
    let ids = amounts.map!(|amount| {
        let split = coin.split(amount, ctx);
        let id = object::id(&split);
        account.keep(split, ctx);
        id
    });
    account.keep(coin, ctx);

    ids
}
