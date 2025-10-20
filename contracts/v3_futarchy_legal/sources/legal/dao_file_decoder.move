// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Decoder for DAO Document Registry actions
/// Provides BCS deserialization and human-readable field extraction
module futarchy_legal_actions::dao_file_decoder;

use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use std::string::String;
use std::type_name;
use sui::bcs::{Self, BCS};
use sui::dynamic_object_field;
use sui::object::{Self, UID, ID};

// === Decoder Objects ===

/// Decoder for CreateRegistry action
public struct CreateRegistryDecoder has key, store {
    id: UID,
}

/// Decoder for SetRegistryImmutable action
public struct SetRegistryImmutableDecoder has key, store {
    id: UID,
}

/// Decoder for CreateRootDocument action
public struct CreateRootDocumentDecoder has key, store {
    id: UID,
}

/// Decoder for CreateChildDocument action
public struct CreateChildDocumentDecoder has key, store {
    id: UID,
}

/// Decoder for CreateDocumentVersion action
public struct CreateDocumentVersionDecoder has key, store {
    id: UID,
}

/// Decoder for DeleteDocument action
public struct DeleteDocumentDecoder has key, store {
    id: UID,
}

/// Decoder for AddChunk action
public struct AddChunkDecoder has key, store {
    id: UID,
}

/// Decoder for AddChunkWithText action
public struct AddChunkWithTextDecoder has key, store {
    id: UID,
}

/// Decoder for AddSunsetChunk action
public struct AddSunsetChunkDecoder has key, store {
    id: UID,
}

/// Decoder for AddSunriseChunk action
public struct AddSunriseChunkDecoder has key, store {
    id: UID,
}

/// Decoder for AddTemporaryChunk action
public struct AddTemporaryChunkDecoder has key, store {
    id: UID,
}

/// Decoder for AddChunkWithScheduledImmutability action
public struct AddChunkWithScheduledImmutabilityDecoder has key, store {
    id: UID,
}

/// Decoder for UpdateChunk action
public struct UpdateChunkDecoder has key, store {
    id: UID,
}

/// Decoder for RemoveChunk action
public struct RemoveChunkDecoder has key, store {
    id: UID,
}

/// Decoder for SetChunkImmutable action
public struct SetChunkImmutableDecoder has key, store {
    id: UID,
}

/// Decoder for SetDocumentImmutable action
public struct SetDocumentImmutableDecoder has key, store {
    id: UID,
}

/// Decoder for SetDocumentInsertAllowed action
public struct SetDocumentInsertAllowedDecoder has key, store {
    id: UID,
}

/// Decoder for SetDocumentRemoveAllowed action
public struct SetDocumentRemoveAllowedDecoder has key, store {
    id: UID,
}

// === Decoder Functions ===

/// Decode CreateRegistry action (no parameters)
public fun decode_create_registry(
    _decoder: &CreateRegistryDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let bcs_data = bcs::new(action_data);
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"action".to_string(),
            b"CreateRegistry".to_string(),
            b"String".to_string(),
        ),
    ]
}

/// Decode SetRegistryImmutable action (no parameters)
public fun decode_set_registry_immutable(
    _decoder: &SetRegistryImmutableDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let bcs_data = bcs::new(action_data);
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"action".to_string(),
            b"SetRegistryImmutable".to_string(),
            b"String".to_string(),
        ),
    ]
}

/// Decode CreateRootDocument action
public fun decode_create_root_document(
    _decoder: &CreateRootDocumentDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let name = bcs::peel_vec_u8(&mut bcs_data).to_string();

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"name".to_string(),
            name,
            b"String".to_string(),
        ),
    ]
}

/// Decode CreateChildDocument action
public fun decode_create_child_document(
    _decoder: &CreateChildDocumentDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let parent_id = object::id_from_address(bcs::peel_address(&mut bcs_data));
    let name = bcs::peel_vec_u8(&mut bcs_data).to_string();

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"parent_id".to_string(),
            object::id_to_bytes(&parent_id).to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"name".to_string(),
            name,
            b"String".to_string(),
        ),
    ]
}

/// Decode CreateDocumentVersion action
public fun decode_create_document_version(
    _decoder: &CreateDocumentVersionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let previous_doc_id = object::id_from_address(bcs::peel_address(&mut bcs_data));
    let new_name = bcs::peel_vec_u8(&mut bcs_data).to_string();

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"previous_doc_id".to_string(),
            object::id_to_bytes(&previous_doc_id).to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"new_name".to_string(),
            new_name,
            b"String".to_string(),
        ),
    ]
}

/// Decode DeleteDocument action
public fun decode_delete_document(
    _decoder: &DeleteDocumentDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let doc_id = object::id_from_address(bcs::peel_address(&mut bcs_data));

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"doc_id".to_string(),
            object::id_to_bytes(&doc_id).to_string(),
            b"ID".to_string(),
        ),
    ]
}

/// Decode AddChunk action
public fun decode_add_chunk(
    _decoder: &AddChunkDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let doc_id = object::id_from_address(bcs::peel_address(&mut bcs_data));
    let expected_sequence = bcs::peel_u64(&mut bcs_data);
    let chunk_type = bcs::peel_u8(&mut bcs_data);
    let expires_at = bcs::peel_option_u64(&mut bcs_data);
    let effective_from = bcs::peel_option_u64(&mut bcs_data);
    let immutable = bcs::peel_bool(&mut bcs_data);
    let immutable_from = bcs::peel_option_u64(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    let mut fields = vector[
        schema::new_field(
            b"doc_id".to_string(),
            object::id_to_bytes(&doc_id).to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"expected_sequence".to_string(),
            expected_sequence.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"chunk_type".to_string(),
            chunk_type.to_string(),
            b"u8".to_string(),
        ),
        schema::new_field(
            b"immutable".to_string(),
            if (immutable) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
    ];

    // Add optional fields if present
    if (option::is_some(&expires_at)) {
        vector::push_back(
            &mut fields,
            schema::new_field(
                b"expires_at".to_string(),
                (*option::borrow(&expires_at)).to_string(),
                b"Option<u64>".to_string(),
            ),
        );
    };
    if (option::is_some(&effective_from)) {
        vector::push_back(
            &mut fields,
            schema::new_field(
                b"effective_from".to_string(),
                (*option::borrow(&effective_from)).to_string(),
                b"Option<u64>".to_string(),
            ),
        );
    };
    if (option::is_some(&immutable_from)) {
        vector::push_back(
            &mut fields,
            schema::new_field(
                b"immutable_from".to_string(),
                (*option::borrow(&immutable_from)).to_string(),
                b"Option<u64>".to_string(),
            ),
        );
    };

    fields
}

/// Decode AddChunkWithText action
public fun decode_add_chunk_with_text(
    _decoder: &AddChunkWithTextDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let doc_id = object::id_from_address(bcs::peel_address(&mut bcs_data));
    let text = bcs::peel_vec_u8(&mut bcs_data).to_string();

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"doc_id".to_string(),
            object::id_to_bytes(&doc_id).to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"text".to_string(),
            text,
            b"String".to_string(),
        ),
    ]
}

/// Decode AddSunsetChunk action
public fun decode_add_sunset_chunk(
    _decoder: &AddSunsetChunkDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let doc_id = object::id_from_address(bcs::peel_address(&mut bcs_data));
    let expected_sequence = bcs::peel_u64(&mut bcs_data);
    let expires_at_ms = bcs::peel_u64(&mut bcs_data);
    let immutable = bcs::peel_bool(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"doc_id".to_string(),
            object::id_to_bytes(&doc_id).to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"expected_sequence".to_string(),
            expected_sequence.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"expires_at_ms".to_string(),
            expires_at_ms.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"immutable".to_string(),
            if (immutable) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
    ]
}

/// Decode AddSunriseChunk action
public fun decode_add_sunrise_chunk(
    _decoder: &AddSunriseChunkDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let doc_id = object::id_from_address(bcs::peel_address(&mut bcs_data));
    let expected_sequence = bcs::peel_u64(&mut bcs_data);
    let effective_from_ms = bcs::peel_u64(&mut bcs_data);
    let immutable = bcs::peel_bool(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"doc_id".to_string(),
            object::id_to_bytes(&doc_id).to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"expected_sequence".to_string(),
            expected_sequence.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"effective_from_ms".to_string(),
            effective_from_ms.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"immutable".to_string(),
            if (immutable) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
    ]
}

/// Decode AddTemporaryChunk action
public fun decode_add_temporary_chunk(
    _decoder: &AddTemporaryChunkDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let doc_id = object::id_from_address(bcs::peel_address(&mut bcs_data));
    let expected_sequence = bcs::peel_u64(&mut bcs_data);
    let effective_from_ms = bcs::peel_u64(&mut bcs_data);
    let expires_at_ms = bcs::peel_u64(&mut bcs_data);
    let immutable = bcs::peel_bool(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"doc_id".to_string(),
            object::id_to_bytes(&doc_id).to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"expected_sequence".to_string(),
            expected_sequence.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"effective_from_ms".to_string(),
            effective_from_ms.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"expires_at_ms".to_string(),
            expires_at_ms.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"immutable".to_string(),
            if (immutable) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
    ]
}

/// Decode AddChunkWithScheduledImmutability action
public fun decode_add_chunk_with_scheduled_immutability(
    _decoder: &AddChunkWithScheduledImmutabilityDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let doc_id = object::id_from_address(bcs::peel_address(&mut bcs_data));
    let expected_sequence = bcs::peel_u64(&mut bcs_data);
    let immutable_from_ms = bcs::peel_u64(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"doc_id".to_string(),
            object::id_to_bytes(&doc_id).to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"expected_sequence".to_string(),
            expected_sequence.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"immutable_from_ms".to_string(),
            immutable_from_ms.to_string(),
            b"u64".to_string(),
        ),
    ]
}

/// Decode UpdateChunk action
public fun decode_update_chunk(
    _decoder: &UpdateChunkDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let doc_id = object::id_from_address(bcs::peel_address(&mut bcs_data));
    let expected_sequence = bcs::peel_u64(&mut bcs_data);
    let chunk_id = object::id_from_address(bcs::peel_address(&mut bcs_data));

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"doc_id".to_string(),
            object::id_to_bytes(&doc_id).to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"expected_sequence".to_string(),
            expected_sequence.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"chunk_id".to_string(),
            object::id_to_bytes(&chunk_id).to_string(),
            b"ID".to_string(),
        ),
    ]
}

/// Decode RemoveChunk action
public fun decode_remove_chunk(
    _decoder: &RemoveChunkDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let doc_id = object::id_from_address(bcs::peel_address(&mut bcs_data));
    let expected_sequence = bcs::peel_u64(&mut bcs_data);
    let chunk_id = object::id_from_address(bcs::peel_address(&mut bcs_data));

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"doc_id".to_string(),
            object::id_to_bytes(&doc_id).to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"expected_sequence".to_string(),
            expected_sequence.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"chunk_id".to_string(),
            object::id_to_bytes(&chunk_id).to_string(),
            b"ID".to_string(),
        ),
    ]
}

/// Decode SetChunkImmutable action
public fun decode_set_chunk_immutable(
    _decoder: &SetChunkImmutableDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let doc_id = object::id_from_address(bcs::peel_address(&mut bcs_data));
    let expected_sequence = bcs::peel_u64(&mut bcs_data);
    let chunk_id = object::id_from_address(bcs::peel_address(&mut bcs_data));

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"doc_id".to_string(),
            object::id_to_bytes(&doc_id).to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"expected_sequence".to_string(),
            expected_sequence.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"chunk_id".to_string(),
            object::id_to_bytes(&chunk_id).to_string(),
            b"ID".to_string(),
        ),
    ]
}

/// Decode SetDocumentImmutable action
public fun decode_set_document_immutable(
    _decoder: &SetDocumentImmutableDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let doc_id = object::id_from_address(bcs::peel_address(&mut bcs_data));
    let expected_sequence = bcs::peel_u64(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"doc_id".to_string(),
            object::id_to_bytes(&doc_id).to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"expected_sequence".to_string(),
            expected_sequence.to_string(),
            b"u64".to_string(),
        ),
    ]
}

/// Decode SetDocumentInsertAllowed action
public fun decode_set_document_insert_allowed(
    _decoder: &SetDocumentInsertAllowedDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let doc_id = object::id_from_address(bcs::peel_address(&mut bcs_data));
    let expected_sequence = bcs::peel_u64(&mut bcs_data);
    let allowed = bcs::peel_bool(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"doc_id".to_string(),
            object::id_to_bytes(&doc_id).to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"expected_sequence".to_string(),
            expected_sequence.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"allowed".to_string(),
            if (allowed) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
    ]
}

/// Decode SetDocumentRemoveAllowed action
public fun decode_set_document_remove_allowed(
    _decoder: &SetDocumentRemoveAllowedDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let doc_id = object::id_from_address(bcs::peel_address(&mut bcs_data));
    let expected_sequence = bcs::peel_u64(&mut bcs_data);
    let allowed = bcs::peel_bool(&mut bcs_data);

    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"doc_id".to_string(),
            object::id_to_bytes(&doc_id).to_string(),
            b"ID".to_string(),
        ),
        schema::new_field(
            b"expected_sequence".to_string(),
            expected_sequence.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"allowed".to_string(),
            if (allowed) { b"true" } else { b"false" }.to_string(),
            b"bool".to_string(),
        ),
    ]
}

// === Registration Functions ===

/// Register all DAO document decoders (placeholder types)
/// Note: These use placeholder type names since the actual action types
/// are defined inline in dao_doc_actions.move
public fun register_decoders(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    // Registry management
    register_create_registry_decoder(registry, ctx);
    register_set_registry_immutable_decoder(registry, ctx);

    // Document creation
    register_create_root_document_decoder(registry, ctx);
    register_create_child_document_decoder(registry, ctx);
    register_create_document_version_decoder(registry, ctx);
    register_delete_document_decoder(registry, ctx);

    // Chunk management
    register_add_chunk_decoder(registry, ctx);
    register_add_chunk_with_text_decoder(registry, ctx);
    register_add_sunset_chunk_decoder(registry, ctx);
    register_add_sunrise_chunk_decoder(registry, ctx);
    register_add_temporary_chunk_decoder(registry, ctx);
    register_add_chunk_with_scheduled_immutability_decoder(registry, ctx);
    register_update_chunk_decoder(registry, ctx);
    register_remove_chunk_decoder(registry, ctx);

    // Immutability controls
    register_set_chunk_immutable_decoder(registry, ctx);
    register_set_document_immutable_decoder(registry, ctx);

    // Policy controls
    register_set_document_insert_allowed_decoder(registry, ctx);
    register_set_document_remove_allowed_decoder(registry, ctx);
}

// === Individual Registration Functions ===

fun register_create_registry_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = CreateRegistryDecoder { id: object::new(ctx) };
    let type_key = type_name::get<CreateRegistryDecoder>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_set_registry_immutable_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = SetRegistryImmutableDecoder { id: object::new(ctx) };
    let type_key = type_name::get<SetRegistryImmutableDecoder>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_create_root_document_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CreateRootDocumentDecoder { id: object::new(ctx) };
    let type_key = type_name::get<CreateRootDocumentDecoder>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_create_child_document_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CreateChildDocumentDecoder { id: object::new(ctx) };
    let type_key = type_name::get<CreateChildDocumentDecoder>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_create_document_version_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CreateDocumentVersionDecoder { id: object::new(ctx) };
    let type_key = type_name::get<CreateDocumentVersionDecoder>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_delete_document_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = DeleteDocumentDecoder { id: object::new(ctx) };
    let type_key = type_name::get<DeleteDocumentDecoder>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_add_chunk_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = AddChunkDecoder { id: object::new(ctx) };
    let type_key = type_name::get<AddChunkDecoder>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_add_chunk_with_text_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = AddChunkWithTextDecoder { id: object::new(ctx) };
    let type_key = type_name::get<AddChunkWithTextDecoder>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_add_sunset_chunk_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = AddSunsetChunkDecoder { id: object::new(ctx) };
    let type_key = type_name::get<AddSunsetChunkDecoder>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_add_sunrise_chunk_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = AddSunriseChunkDecoder { id: object::new(ctx) };
    let type_key = type_name::get<AddSunriseChunkDecoder>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_add_temporary_chunk_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = AddTemporaryChunkDecoder { id: object::new(ctx) };
    let type_key = type_name::get<AddTemporaryChunkDecoder>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_add_chunk_with_scheduled_immutability_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = AddChunkWithScheduledImmutabilityDecoder { id: object::new(ctx) };
    let type_key = type_name::get<AddChunkWithScheduledImmutabilityDecoder>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_update_chunk_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = UpdateChunkDecoder { id: object::new(ctx) };
    let type_key = type_name::get<UpdateChunkDecoder>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_remove_chunk_decoder(registry: &mut ActionDecoderRegistry, ctx: &mut TxContext) {
    let decoder = RemoveChunkDecoder { id: object::new(ctx) };
    let type_key = type_name::get<RemoveChunkDecoder>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_set_chunk_immutable_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = SetChunkImmutableDecoder { id: object::new(ctx) };
    let type_key = type_name::get<SetChunkImmutableDecoder>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_set_document_immutable_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = SetDocumentImmutableDecoder { id: object::new(ctx) };
    let type_key = type_name::get<SetDocumentImmutableDecoder>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_set_document_insert_allowed_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = SetDocumentInsertAllowedDecoder { id: object::new(ctx) };
    let type_key = type_name::get<SetDocumentInsertAllowedDecoder>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_set_document_remove_allowed_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = SetDocumentRemoveAllowedDecoder { id: object::new(ctx) };
    let type_key = type_name::get<SetDocumentRemoveAllowedDecoder>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}
