module futarchy_actions::memo_intents;

use account_protocol::account::Account;
use account_protocol::intent_interface;
use account_protocol::intents::{Intent, Params};
use futarchy_actions::memo_actions;
use futarchy_core::action_type_markers;
use futarchy_core::version;
use std::option::Option;
use std::string::String;
use sui::bcs;
use sui::object::ID;
use sui::tx_context::TxContext;

// === Aliases ===
use fun intent_interface::build_intent as Account.build_intent;

// === Intent Witness ===
public struct MemoIntent has copy, drop {}

// === Intent Creation Functions ===

/// Create intent to emit a simple memo
public fun create_emit_memo_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    memo: String,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"emit_memo".to_string(),
        version::current(),
        MemoIntent {},
        ctx,
        |intent, iw| {
            let action = memo_actions::new_emit_memo_action(memo);
            let action_bytes = bcs::to_bytes(&action);
            intent.add_typed_action(action_types::memo(), action_bytes, iw);
        },
    );
}

/// Create intent to emit a decision (accept/reject)
public fun create_emit_decision_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    accept: bool,
    reference_id: Option<ID>,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"emit_decision".to_string(),
        version::current(),
        MemoIntent {},
        ctx,
        |intent, iw| {
            let action = memo_actions::new_emit_decision_action(
                accept,
                reference_id,
            );
            let action_bytes = bcs::to_bytes(&action);
            intent.add_typed_action(action_types::memo(), action_bytes, iw);
        },
    );
}
