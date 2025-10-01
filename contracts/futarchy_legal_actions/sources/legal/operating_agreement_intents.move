module futarchy_legal_actions::operating_agreement_intents;

// === Imports ===
use std::string::String;
use sui::{
    clock::Clock,
    object::{Self, ID},
    tx_context::TxContext,
    bcs,
};
use account_protocol::{
    account::Account,
    executable::Executable,
    intents::{Self, Intent, Params},
    intent_interface,
};
use futarchy_legal_actions::{
    operating_agreement_actions,
    operating_agreement::{Self, OperatingAgreementAction},
};
use futarchy_core::version;
use futarchy_core::action_types;

use fun account_protocol::intents::add_typed_action as Intent.add_typed_action;

// === Use Fun Aliases === (removed, using add_action_spec directly)

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
            let action = operating_agreement_actions::new_update_line_action(line_id, new_text);
            let action_data = bcs::to_bytes(&action);
            intent.add_typed_action(
                action_types::update_line(),
                action_data,
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
            let action = operating_agreement_actions::new_insert_line_after_action(
                prev_line_id,
                text,
                difficulty
            );
            let action_data = bcs::to_bytes(&action);
            intent.add_typed_action(
                action_types::insert_line_after(),
                action_data,
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
            let action = operating_agreement_actions::new_insert_line_at_beginning_action(
                text,
                difficulty
            );
            let action_data = bcs::to_bytes(&action);
            intent.add_typed_action(
                action_types::insert_line_at_beginning(),
                action_data,
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
            let action = operating_agreement_actions::new_remove_line_action(line_id);
            let action_data = bcs::to_bytes(&action);
            intent.add_typed_action(
                action_types::remove_line(),
                action_data,
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
    actions: vector<OperatingAgreementAction>,
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
            // Generate a unique batch ID for this set of operations  
            let batch_uid = object::new(ctx);
            let batch_id = object::uid_to_inner(&batch_uid);
            object::delete(batch_uid);
            let action = operating_agreement_actions::new_batch_operating_agreement_action(
                batch_id,
                actions
            );
            let action_data = bcs::to_bytes(&action);
            intent.add_typed_action(
                action_types::batch_operating_agreement(),
                action_data,
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
            let action_data = bcs::to_bytes(&action);
            intent.add_typed_action(
                action_types::create_operating_agreement(),
                action_data,
                iw
            );
        }
    );
}

// Note: Execution of intents should be done through the account protocol's
// process_intent! macro in the calling module, not here. This module only
// provides intent creation functions.