// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module account_actions::memo_intents;

use account_actions::memo;
use account_actions::version;
use account_protocol::account::Account;
use account_protocol::intent_interface;
use account_protocol::intents::Params;
use std::option::Option;
use std::string::String;
use sui::object::ID;

// === Aliases ===

use fun intent_interface::build_intent as Account.build_intent;

// === Structs ===

/// Intent Witness for memo emission
public struct MemoIntent() has copy, drop;

// === Public Functions ===

/// Create intent to emit a memo with optional reference
/// Can be used for:
/// - Simple text memos: memo="This is important", reference_id=None
/// - Accept decisions: memo="Accept", reference_id=Some(proposal_id)
/// - Reject decisions: memo="Reject", reference_id=Some(proposal_id)
/// - Comments on objects: memo="Looks good!", reference_id=Some(object_id)
public fun request_emit_memo<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    memo_text: String,
    reference_id: Option<ID>,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"emit_memo".to_string(),
        version::current(),
        MemoIntent(),
        ctx,
        |intent, iw| {
            memo::new_emit_memo(intent, memo_text, reference_id, iw);
        },
    );
}
