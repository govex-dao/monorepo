// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module account_actions::vesting_intents;

use account_actions::version;
use account_actions::vesting;
use account_protocol::account::{Account, Auth};
use account_protocol::executable::Executable;
use account_protocol::intent_interface;
use account_protocol::intents::Params;
use std::string::String;
use sui::object::ID;

// === Imports ===

// === Aliases ===

use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

// === Structs ===

/// Intent Witness defining the vesting control intent
public struct VestingControlIntent() has copy, drop;

// === Public Functions ===

/// Request to cancel a vesting
public fun request_cancel_vesting<Config: store, Outcome: store>(
    auth: Auth,
    account: &mut Account,
    params: Params,
    outcome: Outcome,
    vesting_id: ID,
    ctx: &mut TxContext,
) {
    account.verify(auth);

    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        VestingControlIntent(),
        ctx,
        |intent, iw| {
            vesting::new_cancel_vesting(intent, vesting_id, iw);
        },
    );
}

/// Executes cancel vesting action
public fun execute_cancel_vesting<Config: store, Outcome: store, CoinType: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    vesting: vesting::Vesting<CoinType>,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
) {
    account.process_intent!(
        executable,
        version::current(),
        VestingControlIntent(),
        |executable, iw| {
            vesting::cancel_vesting<Config, Outcome, CoinType, _>(
                executable,
                account,
                vesting,
                clock,
                iw,
                ctx,
            );
        },
    );
}
