// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Intent creation functions for DAO Document Registry
/// Provides high-level API for building document management intents
module futarchy_legal_actions::dao_file_intents;

use account_protocol::account::Account;
use account_protocol::executable::Executable;
use account_protocol::intent_interface;
use account_protocol::intents::{Self, Intent, Params};
use futarchy_types::action_type_markers as action_types;
use futarchy_core::version;
use futarchy_legal_actions::dao_file_actions;
use std::string::String;
use sui::bcs;
use sui::clock::Clock;
use sui::object::{Self, ID};
use sui::tx_context::TxContext;
use walrus::blob::Blob;

use fun account_protocol::intents::add_typed_action as Intent.add_typed_action;

// === Aliases ===
use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

// === Single Witness ===
public struct DaoDocIntent has copy, drop {}

// === Registry Management Intents ===

/// Create intent to initialize a DAO document registry
public fun create_registry_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"dao_doc_create_registry".to_string(),
        version::current(),
        DaoDocIntent {},
        ctx,
        |intent, iw| {
            let action_data = vector::empty<u8>();
            intent.add_typed_action(
                action_types::create_dao_file_registry(),
                action_data,
                iw,
            );
        },
    );
}

/// Create intent to set entire registry as immutable (nuclear option)
public fun set_registry_immutable_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"dao_doc_set_registry_immutable".to_string(),
        version::current(),
        DaoDocIntent {},
        ctx,
        |intent, iw| {
            let action_data = vector::empty<u8>();
            intent.add_typed_action(
                action_types::set_registry_immutable(),
                action_data,
                iw,
            );
        },
    );
}

// === Document Creation Intents ===

/// Create intent to create a root document (bylaws, code of conduct, etc.)
public fun create_root_document_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    name: String,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"dao_doc_create_root".to_string(),
        version::current(),
        DaoDocIntent {},
        ctx,
        |intent, iw| {
            let action_data = bcs::to_bytes(&name.into_bytes());
            intent.add_typed_action(
                action_types::create_root_file(),
                action_data,
                iw,
            );
        },
    );
}

// create_child_document_intent removed - flat structure only
// create_document_version_intent removed - no versions needed

// === Chunk Management Intents ===

/// Create intent to add a permanent chunk with Walrus storage
public fun add_chunk_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    doc_id: ID,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"dao_doc_add_chunk".to_string(),
        version::current(),
        DaoDocIntent {},
        ctx,
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&object::id_to_address(&doc_id));
            intent.add_typed_action(
                action_types::add_chunk(),
                action_data,
                iw,
            );
        },
    );
}

/// Create intent to add chunk with text storage (for small content)
public fun add_chunk_with_text_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    doc_id: ID,
    text: String,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"dao_doc_add_chunk_text".to_string(),
        version::current(),
        DaoDocIntent {},
        ctx,
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&object::id_to_address(&doc_id));
            action_data.append(bcs::to_bytes(&text.into_bytes()));
            intent.add_typed_action(
                action_types::add_chunk(),
                action_data,
                iw,
            );
        },
    );
}

/// Create intent to add sunset chunk (auto-deactivates after expiry)
public fun add_sunset_chunk_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    doc_id: ID,
    expires_at_ms: u64,
    immutable: bool,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"dao_doc_add_sunset_chunk".to_string(),
        version::current(),
        DaoDocIntent {},
        ctx,
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&object::id_to_address(&doc_id));
            action_data.append(bcs::to_bytes(&expires_at_ms));
            action_data.append(bcs::to_bytes(&immutable));
            intent.add_typed_action(
                action_types::add_sunset_chunk(),
                action_data,
                iw,
            );
        },
    );
}

/// Create intent to add sunrise chunk (activates after effective_from)
public fun add_sunrise_chunk_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    doc_id: ID,
    effective_from_ms: u64,
    immutable: bool,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"dao_doc_add_sunrise_chunk".to_string(),
        version::current(),
        DaoDocIntent {},
        ctx,
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&object::id_to_address(&doc_id));
            action_data.append(bcs::to_bytes(&effective_from_ms));
            action_data.append(bcs::to_bytes(&immutable));
            intent.add_typed_action(
                action_types::add_sunrise_chunk(),
                action_data,
                iw,
            );
        },
    );
}

/// Create intent to add temporary chunk (active between two times)
public fun add_temporary_chunk_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    doc_id: ID,
    effective_from_ms: u64,
    expires_at_ms: u64,
    immutable: bool,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"dao_doc_add_temporary_chunk".to_string(),
        version::current(),
        DaoDocIntent {},
        ctx,
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&object::id_to_address(&doc_id));
            action_data.append(bcs::to_bytes(&effective_from_ms));
            action_data.append(bcs::to_bytes(&expires_at_ms));
            action_data.append(bcs::to_bytes(&immutable));
            intent.add_typed_action(
                action_types::add_temporary_chunk(),
                action_data,
                iw,
            );
        },
    );
}

/// Create intent to add chunk with scheduled immutability
public fun add_chunk_with_scheduled_immutability_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    doc_id: ID,
    immutable_from_ms: u64,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"dao_doc_add_scheduled_immutable_chunk".to_string(),
        version::current(),
        DaoDocIntent {},
        ctx,
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&object::id_to_address(&doc_id));
            action_data.append(bcs::to_bytes(&immutable_from_ms));
            intent.add_typed_action(
                action_types::add_chunk_with_scheduled_immutability(),
                action_data,
                iw,
            );
        },
    );
}

/// Create intent to update a chunk (returns hot potato for Walrus blob)
public fun update_chunk_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    doc_id: ID,
    chunk_id: ID,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"dao_doc_update_chunk".to_string(),
        version::current(),
        DaoDocIntent {},
        ctx,
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&object::id_to_address(&doc_id));
            action_data.append(bcs::to_bytes(&object::id_to_address(&chunk_id)));
            intent.add_typed_action(
                action_types::update_chunk(),
                action_data,
                iw,
            );
        },
    );
}

/// Create intent to remove a chunk
public fun remove_chunk_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    doc_id: ID,
    chunk_id: ID,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"dao_doc_remove_chunk".to_string(),
        version::current(),
        DaoDocIntent {},
        ctx,
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&object::id_to_address(&doc_id));
            action_data.append(bcs::to_bytes(&object::id_to_address(&chunk_id)));
            intent.add_typed_action(
                action_types::remove_chunk(),
                action_data,
                iw,
            );
        },
    );
}

// === Immutability Control Intents ===

/// Create intent to set a chunk as permanently immutable
public fun set_chunk_immutable_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    doc_id: ID,
    chunk_id: ID,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"dao_doc_set_chunk_immutable".to_string(),
        version::current(),
        DaoDocIntent {},
        ctx,
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&object::id_to_address(&doc_id));
            action_data.append(bcs::to_bytes(&object::id_to_address(&chunk_id)));
            intent.add_typed_action(
                action_types::set_chunk_immutable(),
                action_data,
                iw,
            );
        },
    );
}

/// Create intent to set a document as immutable
public fun set_document_immutable_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    doc_id: ID,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"dao_doc_set_document_immutable".to_string(),
        version::current(),
        DaoDocIntent {},
        ctx,
        |intent, iw| {
            let action_data = bcs::to_bytes(&object::id_to_address(&doc_id));
            intent.add_typed_action(
                action_types::set_file_immutable(),
                action_data,
                iw,
            );
        },
    );
}

// === Policy Control Intents ===

/// Create intent to set document insert policy
public fun set_document_insert_allowed_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    doc_id: ID,
    allowed: bool,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"dao_doc_set_insert_allowed".to_string(),
        version::current(),
        DaoDocIntent {},
        ctx,
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&object::id_to_address(&doc_id));
            action_data.append(bcs::to_bytes(&allowed));
            intent.add_typed_action(
                action_types::set_file_insert_allowed(),
                action_data,
                iw,
            );
        },
    );
}

/// Create intent to set document remove policy
public fun set_document_remove_allowed_intent<Config, Outcome: store>(
    account: &mut Account<Config>,
    params: Params,
    outcome: Outcome,
    doc_id: ID,
    allowed: bool,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"dao_doc_set_remove_allowed".to_string(),
        version::current(),
        DaoDocIntent {},
        ctx,
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&object::id_to_address(&doc_id));
            action_data.append(bcs::to_bytes(&allowed));
            intent.add_typed_action(
                action_types::set_file_remove_allowed(),
                action_data,
                iw,
            );
        },
    );
}

// Note: Execution of intents should be done through the account protocol's
// process_intent! macro in the calling module, not here. This module only
// provides intent creation functions.
