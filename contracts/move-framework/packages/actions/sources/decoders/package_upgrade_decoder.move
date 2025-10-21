// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Decoder for package upgrade actions
module account_actions::package_upgrade_decoder;

use account_actions::package_upgrade::{UpgradeAction, CommitAction, RestrictAction};
use account_protocol::schema::{Self as schema, ActionDecoderRegistry};
use std::type_name;
use sui::dynamic_object_field;
use sui::object::{Self, UID};

// === Decoder Objects ===

/// Decoder for UpgradeAction
public struct UpgradeActionDecoder has key, store {
    id: UID,
}

/// Decoder for CommitAction
public struct CommitActionDecoder has key, store {
    id: UID,
}

/// Decoder for RestrictAction
public struct RestrictActionDecoder has key, store {
    id: UID,
}

// === Registration Functions ===

/// Register all package upgrade decoders
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    register_upgrade_decoder(registry, ctx);
    register_commit_decoder(registry, ctx);
    register_restrict_decoder(registry, ctx);
}

fun register_upgrade_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = UpgradeActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<UpgradeAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_commit_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = CommitActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CommitAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_restrict_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = RestrictActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<RestrictAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
