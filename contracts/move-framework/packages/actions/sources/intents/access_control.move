// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

module account_actions::access_control_intents;

use account_actions::access_control as ac;
use account_actions::version;
use account_protocol::account::{Account, Auth};
use account_protocol::executable::Executable;
use account_protocol::intent_interface;
use account_protocol::intents::Params;
use account_protocol::package_registry::PackageRegistry;
use std::string::String;
use std::type_name;

// === Imports ===

// === Aliases ===

use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

// === Errors ===

const ENoLock: u64 = 0;

// === Structs ===

/// Intent Witness defining the intent to borrow an access cap.
public struct BorrowCapIntent() has copy, drop;

// === Public functions ===

/// Creates a BorrowCapIntent and adds it to an Account.
public fun request_borrow_cap<Config: store, Outcome: store, Cap>(
    auth: Auth,
    account: &mut Account,
    registry: &PackageRegistry,
    params: Params,
    outcome: Outcome,
    ctx: &mut TxContext,
) {
    account.verify(auth);
    assert!(ac::has_lock<Config, Cap>(account), ENoLock);

    account.build_intent!(
        registry,
        params,
        outcome,
        type_name_to_string<Cap>(),
        version::current(),
        BorrowCapIntent(),
        ctx,
        |intent, iw| {
            ac::new_borrow<_, Cap, _>(intent, iw);
            ac::new_return<_, Cap, _>(intent, iw);
        },
    );
}

/// Executes a BorrowCapIntent, returns a cap and a hot potato.
public fun execute_borrow_cap<Config: store, Outcome: store, Cap: key + store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
): Cap {
    account.process_intent!(
        registry,
        executable,
        version::current(),
        BorrowCapIntent(),
        |executable, iw| ac::do_borrow<Config, Outcome, Cap, _>(executable, account, registry, version::current(), iw),
    )
}

/// Completes a BorrowCapIntent, destroys the executable and returns the cap to the account if the matching hot potato is returned.
public fun execute_return_cap<Config: store, Outcome: store, Cap: key + store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    cap: Cap,
) {
    account.process_intent!(
        registry,
        executable,
        version::current(),
        BorrowCapIntent(),
        |executable, iw| ac::do_return<Config, Outcome, Cap, _>(executable, account, registry, cap, version::current(), iw),
    )
}

// === Private functions ===

fun type_name_to_string<T>(): String {
    type_name::with_defining_ids<T>().into_string().to_string()
}
