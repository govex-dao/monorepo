/// Operating agreement intent creation using the CORRECT pattern with build_intent! macro
module futarchy::operating_agreement_intents;

// === Imports ===
use std::string::String;
use sui::{
    clock::Clock,
    object::ID,
    tx_context::TxContext,
};
use account_protocol::{
    account::Account,
    executable::Executable,
    intents::{Intent, Params},
    intent_interface,
};
use futarchy::{
    operating_agreement_actions,
    version,
};

// === Aliases ===
use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

// === Single Witness ===
public struct OperatingAgreementIntent has copy, drop {}

// === Intent Creation Functions ===

/// Create intent to update a line in the operating agreement
public fun create_update_line_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    line_id: ID,
    new_text: String,
    ctx: &mut TxContext
) {
    account.build_intent!(
        params,
        outcome,
        b"operating_agreement_update_line".to_string(),
        version::current(),
        OperatingAgreementIntent {},
        ctx,
        |intent, iw| {
            operating_agreement_actions::new_update_line<Outcome, OperatingAgreementIntent>(
                intent,
                line_id,
                new_text,
                iw
            );
        }
    );
}

/// Create intent to insert a line after another line
public fun create_insert_line_after_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    prev_line_id: ID,
    text: String,
    difficulty: u64,
    ctx: &mut TxContext
) {
    account.build_intent!(
        params,
        outcome,
        b"operating_agreement_insert_after".to_string(),
        version::current(),
        OperatingAgreementIntent {},
        ctx,
        |intent, iw| {
            operating_agreement_actions::new_insert_line_after<Outcome, OperatingAgreementIntent>(
                intent,
                prev_line_id,
                text,
                difficulty,
                iw
            );
        }
    );
}

/// Create intent to insert a line at the beginning
public fun create_insert_line_at_beginning_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    text: String,
    difficulty: u64,
    ctx: &mut TxContext
) {
    account.build_intent!(
        params,
        outcome,
        b"operating_agreement_insert_beginning".to_string(),
        version::current(),
        OperatingAgreementIntent {},
        ctx,
        |intent, iw| {
            operating_agreement_actions::new_insert_line_at_beginning<Outcome, OperatingAgreementIntent>(
                intent,
                text,
                difficulty,
                iw
            );
        }
    );
}

/// Create intent to remove a line from the operating agreement
public fun create_remove_line_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    line_id: ID,
    ctx: &mut TxContext
) {
    account.build_intent!(
        params,
        outcome,
        b"operating_agreement_remove_line".to_string(),
        version::current(),
        OperatingAgreementIntent {},
        ctx,
        |intent, iw| {
            operating_agreement_actions::new_remove_line<Outcome, OperatingAgreementIntent>(
                intent,
                line_id,
                iw
            );
        }
    );
}

/// Create intent for batch operating agreement changes
public fun create_batch_operating_agreement_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    actions: vector<operating_agreement_actions::OperatingAgreementAction>,
    ctx: &mut TxContext
) {
    account.build_intent!(
        params,
        outcome,
        b"operating_agreement_batch".to_string(),
        version::current(),
        OperatingAgreementIntent {},
        ctx,
        |intent, iw| {
            operating_agreement_actions::new_batch_operating_agreement<Outcome, OperatingAgreementIntent>(
                intent,
                actions,
                iw
            );
        }
    );
}

/// Create intent to initialize a brand-new Operating Agreement in the Account
/// Creates an empty OA (no lines). Use insert actions afterwards.
public fun create_create_agreement_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    allow_insert: bool,
    allow_remove: bool,
    ctx: &mut TxContext
) {
    account.build_intent!(
        params,
        outcome,
        b"operating_agreement_create".to_string(),
        version::current(),
        OperatingAgreementIntent {},
        ctx,
        |intent, iw| {
            let action = operating_agreement_actions::new_create_operating_agreement_action(
                allow_insert,
                allow_remove
            );
            intent.add_action(action, iw);
        }
    );
}

// Note: Execution of intents should be done through the account protocol's
// process_intent! macro in the calling module, not here. This module only
// provides intent creation functions.