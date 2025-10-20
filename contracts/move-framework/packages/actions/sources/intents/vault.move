// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

module account_actions::vault_intents;

use account_actions::transfer as acc_transfer;
use account_actions::vault;
use account_actions::version;
use account_protocol::account::{Account, Auth};
use account_protocol::executable::Executable;
use account_protocol::intent_interface;
use account_protocol::intents::Params;
use std::string::String;

// === Imports ===

// === Aliases ===

use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

// === Errors ===

const ENotSameLength: u64 = 0;
const EInsufficientFunds: u64 = 1;
const ECoinTypeDoesntExist: u64 = 2;

// === Structs ===

/// Intent Witness defining the vault spend and transfer intent, and associated role.
public struct SpendAndTransferIntent() has copy, drop;

// === Public Functions ===

/// Creates a SpendAndTransferIntent and adds it to an Account.
public fun request_spend_and_transfer<Config: store, Outcome: store, CoinType: drop>(
    auth: Auth,
    account: &mut Account,
    params: Params,
    outcome: Outcome,
    vault_name: String,
    amounts: vector<u64>,
    recipients: vector<address>,
    ctx: &mut TxContext,
) {
    account.verify(auth);
    assert!(amounts.length() == recipients.length(), ENotSameLength);

    let vault = vault::borrow_vault(account, vault_name);
    assert!(vault.coin_type_exists<CoinType>(), ECoinTypeDoesntExist);
    assert!(
        amounts.fold!(0u64, |sum, amount| sum + amount) <= vault.coin_type_value<CoinType>(),
        EInsufficientFunds,
    );

    account.build_intent!(
        params,
        outcome,
        vault_name,
        version::current(),
        SpendAndTransferIntent(),
        ctx,
        |intent, iw| amounts.zip_do!(recipients, |amount, recipient| {
            vault::new_spend<_, CoinType, _>(intent, vault_name, amount, iw);
            acc_transfer::new_transfer(intent, recipient, iw);
        }),
    );
}

/// Executes a SpendAndTransferIntent, transfers coins from the vault to the recipients. Can be looped over.
public fun execute_spend_and_transfer<Config: store, Outcome: store, CoinType: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    ctx: &mut TxContext,
) {
    account.process_intent!(
        executable,
        version::current(),
        SpendAndTransferIntent(),
        |executable, iw| {
            let coin = vault::do_spend<Config, Outcome, CoinType, _>(
                executable,
                account,
                version::current(),
                iw,
                ctx,
            );
            acc_transfer::do_transfer(executable, coin, iw);
        },
    );
}

// === Stream Control Actions ===

/// Request to toggle stream pause (pause or resume)
public fun request_toggle_stream_pause<Config: store, Outcome: store>(
    auth: Auth,
    account: &mut Account,
    params: Params,
    outcome: Outcome,
    vault_name: String,
    stream_id: ID,
    pause_duration_ms: u64, // 0 = unpause, >0 = pause for duration
    ctx: &mut TxContext,
) {
    account.verify(auth);

    account.build_intent!(
        params,
        outcome,
        vault_name,
        version::current(),
        SpendAndTransferIntent(), // TODO: Should this be a different witness?
        ctx,
        |intent, iw| {
            vault::new_toggle_stream_pause(intent, vault_name, stream_id, pause_duration_ms, iw);
        },
    );
}

/// Request to toggle stream emergency freeze
public fun request_toggle_stream_freeze<Config: store, Outcome: store>(
    auth: Auth,
    account: &mut Account,
    params: Params,
    outcome: Outcome,
    vault_name: String,
    stream_id: ID,
    freeze: bool, // true = freeze, false = unfreeze
    ctx: &mut TxContext,
) {
    account.verify(auth);

    account.build_intent!(
        params,
        outcome,
        vault_name,
        version::current(),
        SpendAndTransferIntent(), // TODO: Should this be a different witness?
        ctx,
        |intent, iw| {
            vault::new_toggle_stream_freeze(intent, vault_name, stream_id, freeze, iw);
        },
    );
}

/// Request to cancel a stream
public fun request_cancel_stream<Config: store, Outcome: store>(
    auth: Auth,
    account: &mut Account,
    params: Params,
    outcome: Outcome,
    vault_name: String,
    stream_id: ID,
    ctx: &mut TxContext,
) {
    account.verify(auth);

    account.build_intent!(
        params,
        outcome,
        vault_name,
        version::current(),
        SpendAndTransferIntent(),
        ctx,
        |intent, iw| {
            vault::new_cancel_stream(intent, vault_name, stream_id, iw);
        },
    );
}

// === Execution Functions ===

/// Executes toggle stream pause action
public fun execute_toggle_stream_pause<Config: store, Outcome: store, CoinType>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    vault_name: String,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
) {
    account.process_intent!(
        executable,
        version::current(),
        SpendAndTransferIntent(),
        |executable, iw| {
            vault::do_toggle_stream_pause<Config, Outcome, CoinType, _>(
                executable,
                account,
                vault_name,
                clock,
                version::current(),
                iw,
                ctx,
            );
        },
    );
}

/// Executes toggle stream freeze action
public fun execute_toggle_stream_freeze<Config: store, Outcome: store, CoinType>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    vault_name: String,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
) {
    account.process_intent!(
        executable,
        version::current(),
        SpendAndTransferIntent(),
        |executable, iw| {
            vault::do_toggle_stream_freeze<Config, Outcome, CoinType, _>(
                executable,
                account,
                vault_name,
                clock,
                version::current(),
                iw,
            );
        },
    );
}

/// Executes cancel stream action
public fun execute_cancel_stream<Config: store, Outcome: store, CoinType: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    vault_name: String,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
): (sui::coin::Coin<CoinType>, u64) {
    let mut refund_coin = sui::coin::zero<CoinType>(ctx);
    let mut total_refund = 0u64;

    account.process_intent!(
        executable,
        version::current(),
        SpendAndTransferIntent(),
        |executable, iw| {
            let (coin, amount) = vault::do_cancel_stream<Config, Outcome, CoinType, _>(
                executable,
                account,
                vault_name,
                clock,
                version::current(),
                iw,
                ctx,
            );
            refund_coin.join(coin);
            total_refund = amount;
        },
    );

    (refund_coin, total_refund)
}
