module futarchy_actions::memo_intents;

// === Imports ===
use std::string::String;
use std::option::Option;
use sui::{object::ID, tx_context::TxContext};
use account_protocol::{
    account::Account,
    intents::{Intent, Params},
    intent_interface,
};
use futarchy_actions::memo_actions;
use futarchy_core::version;
use futarchy_core::action_types;

// === Use Fun Aliases ===
use fun account_protocol::intents::add_typed_action as Intent.add_typed_action;

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
    ctx: &mut TxContext
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
            intent.add_typed_action(action, action_types::emit_memo(), iw);
        }
    );
}

/// Create intent to emit a decision (accept/reject)
public fun create_emit_decision_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    accept: bool,
    reference_id: Option<ID>,
    ctx: &mut TxContext
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
                reference_id
            );
            intent.add_typed_action(action, action_types::emit_decision(), iw);
        }
    );
}