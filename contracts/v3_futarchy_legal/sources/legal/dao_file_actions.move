// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// DAO Document Registry actions with BCS serialization support
/// Provides action structs and execution logic for multi-document management
module futarchy_legal_actions::dao_file_actions;

// === Imports ===
use std::{
    string::String,
    option::{Self, Option}
};
use sui::{
    object::{Self, ID},
    clock::Clock,
    tx_context::TxContext,
    bcs::{Self, BCS}
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents::{Self as protocol_intents, Intent, Expired},
    version_witness::VersionWitness,
    bcs_validation
};
use futarchy_types::action_type_markers as action_types;
use futarchy_core::{
    futarchy_config::{Self, FutarchyConfig},
    version,
    // action_types moved to futarchy_types
    dao_config
};
use futarchy_legal_actions::{
    dao_file_registry::{Self, DaoFileRegistry, File, RegistryKey}
};
use futarchy_core::resource_requests::{Self, ResourceRequest, ResourceReceipt};
use walrus::blob::{Self, Blob};

// === Errors ===
const EInvalidDocId: u64 = 1;
const EEmptyWalrusBlobId: u64 = 2;
const EInvalidDifficulty: u64 = 3;
const EInvalidActionType: u64 = 4;
const EUnsupportedActionVersion: u64 = 5;
const EEmptyDocName: u64 = 6;
const EInvalidChunkIndex: u64 = 7;
const EUnauthorizedDocument: u64 = 8;
const EWalrusBlobsNotAllowed: u64 = 9;

// === Helper Functions ===

/// Check if Walrus blobs are allowed for this DAO
fun assert_walrus_blobs_allowed(account: &Account<FutarchyConfig>) {
    let config = account::config<FutarchyConfig>(account);
    let dao_cfg = futarchy_config::dao_config(config);
    let storage_cfg = dao_config::storage_config(dao_cfg);
    assert!(dao_config::allow_walrus_blobs(storage_cfg), EWalrusBlobsNotAllowed);
}

// === Witness Types ===

public struct CreateRegistryWitness has drop {}
public struct CreateRootDocumentWitness has drop {}
// CreateChildDocumentWitness removed - flat structure only
// CreateDocumentVersionWitness removed - no versions
public struct DeleteDocumentWitness has drop {}
public struct AddChunkWitness has drop {}
public struct AddSunsetChunkWitness has drop {}
public struct AddSunriseChunkWitness has drop {}
public struct AddTemporaryChunkWitness has drop {}
public struct AddChunkWithScheduledImmutabilityWitness has drop {}
public struct UpdateChunkWitness has drop {}
public struct RemoveChunkWitness has drop {}
public struct SetChunkImmutableWitness has drop {}
public struct SetDocumentImmutableWitness has drop {}
public struct SetRegistryImmutableWitness has drop {}

// === Resource Request Data Structures ===

/// Data for AddChunk hot potato - needs Walrus Blob from caller
public struct AddChunkRequest has store, drop {
    doc_id: ID,
    expected_sequence: u64,
    chunk_type: u8,
    expires_at: Option<u64>,
    effective_from: Option<u64>,
    immutable: bool,
    immutable_from: Option<u64>,
    max_renewal_advance_epochs: Option<u64>,
}

/// Data for AddSunsetChunk hot potato
public struct AddSunsetChunkRequest has store, drop {
    doc_id: ID,
    expected_sequence: u64,
    expires_at_ms: u64,
    immutable: bool,
    max_renewal_advance_epochs: Option<u64>,
}

/// Data for AddSunriseChunk hot potato
public struct AddSunriseChunkRequest has store, drop {
    doc_id: ID,
    expected_sequence: u64,
    effective_from_ms: u64,
    immutable: bool,
    max_renewal_advance_epochs: Option<u64>,
}

/// Data for AddTemporaryChunk hot potato
public struct AddTemporaryChunkRequest has store, drop {
    doc_id: ID,
    expected_sequence: u64,
    effective_from_ms: u64,
    expires_at_ms: u64,
    immutable: bool,
    max_renewal_advance_epochs: Option<u64>,
}

/// Data for AddChunkWithScheduledImmutability hot potato
public struct AddChunkWithScheduledImmutabilityRequest has store, drop {
    doc_id: ID,
    expected_sequence: u64,
    immutable_from_ms: u64,
    max_renewal_advance_epochs: Option<u64>,
}

/// Data for CreateDocumentVersion hot potato
public struct CreateDocumentVersionRequest has store, drop {
    previous_doc_id: ID,
    new_name: String
}

/// Data for UpdateChunk hot potato - stores what chunk to update
public struct UpdateChunkRequest has store, drop {
    doc_id: ID,
    expected_sequence: u64,
    chunk_id: ID
}

/// Data for RemoveChunk hot potato - stores what chunk to remove
public struct RemoveChunkRequest has store, drop {
    doc_id: ID,
    expected_sequence: u64,
    chunk_id: ID
}

public struct SetDocumentInsertAllowedWitness has drop {}
public struct SetDocumentRemoveAllowedWitness has drop {}

// === Registry Actions ===

/// Create registry for DAO
public fun do_create_registry<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    let expected_type = action_types::create_dao_file_registry();
    assert!(protocol_intents::action_spec_type(spec) == expected_type, EInvalidActionType);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // No parameters for this action
    let reader = bcs::new(*action_data);
    bcs_validation::validate_all_bytes_consumed(reader);

    // Create registry if it doesn't exist
    if (!dao_file_registry::has_registry(account)) {
        let registry = dao_file_registry::create_registry(object::id(account), clock, ctx);
        dao_file_registry::store_in_account(account, registry, version::current());
    };

    executable::increment_action_idx(executable);
}

/// Set registry as immutable (nuclear option)
public fun do_set_registry_immutable<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    let expected_type = action_types::set_registry_immutable();
    assert!(protocol_intents::action_spec_type(spec) == expected_type, EInvalidActionType);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let reader = bcs::new(*action_data);
    bcs_validation::validate_all_bytes_consumed(reader);

    let registry = dao_file_registry::get_registry_mut(account, version::current());
    dao_file_registry::set_registry_immutable(registry, clock);

    executable::increment_action_idx(executable);
}

// === Document Creation Actions ===

/// Create root document
public fun do_create_root_document<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    let expected_type = action_types::create_root_file();
    assert!(protocol_intents::action_spec_type(spec) == expected_type, EInvalidActionType);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let mut reader = bcs::new(*action_data);
    let name_bytes = bcs::peel_vec_u8(&mut reader);
    let doc_name = name_bytes.to_string();
    bcs_validation::validate_all_bytes_consumed(reader);

    assert!(doc_name.length() > 0, EEmptyDocName);

    let registry = dao_file_registry::get_registry_mut(account, version::current());
    dao_file_registry::create_root_document(registry, doc_name, clock, ctx);

    executable::increment_action_idx(executable);
}

/// Create child document
// create_child_document removed - no longer needed with simplified flat document structure

/// Delete document (NEW - your request)
public fun do_delete_document<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    let expected_type = action_types::delete_file();
    assert!(protocol_intents::action_spec_type(spec) == expected_type, EInvalidActionType);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let mut reader = bcs::new(*action_data);
    let doc_id = object::id_from_address(bcs::peel_address(&mut reader));
    bcs_validation::validate_all_bytes_consumed(reader);

    let registry = dao_file_registry::get_registry_mut(account, version::current());
    dao_file_registry::delete_document(registry, doc_id, clock);

    executable::increment_action_idx(executable);
}

// === Chunk Actions ===

/// Add permanent chunk - returns ResourceRequest for Walrus Blob
public fun do_add_chunk<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
): ResourceRequest<AddChunkRequest> {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    let expected_type = action_types::add_chunk();
    assert!(protocol_intents::action_spec_type(spec) == expected_type, EInvalidActionType);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let mut reader = bcs::new(*action_data);
    let doc_id = object::id_from_address(bcs::peel_address(&mut reader));
    let expected_sequence = bcs::peel_u64(&mut reader);
    let chunk_type = bcs::peel_u8(&mut reader);
    let expires_at = bcs::peel_option_u64(&mut reader);
    let effective_from = bcs::peel_option_u64(&mut reader);
    let immutable = bcs::peel_bool(&mut reader);
    let immutable_from = bcs::peel_option_u64(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    // Check if Walrus blobs are allowed
    assert_walrus_blobs_allowed(account);

    executable::increment_action_idx(executable);

    // Return hot potato - caller must provide Walrus Blob
    resource_requests::new_resource_request(
        AddChunkRequest { doc_id, expected_sequence, chunk_type, expires_at, effective_from, immutable, immutable_from, max_renewal_advance_epochs: option::none() },
        ctx
    )
}

/// Fulfill add_chunk request with Walrus Blob
public fun fulfill_add_chunk(
    request: ResourceRequest<AddChunkRequest>,
    account: &Account<FutarchyConfig>,
    doc: &mut File,
    walrus_blob: Blob,
    clock: &Clock,
    ctx: &mut TxContext,
): ResourceReceipt<AddChunkRequest> {
    let data = resource_requests::extract_action(request);
    assert!(dao_file_registry::get_file_id(doc) == data.doc_id, EInvalidDocId);

    // Verify account owns this document
    let doc_dao_id = dao_file_registry::get_document_dao_id(doc);
    assert!(doc_dao_id == object::id(account), EUnauthorizedDocument);

    dao_file_registry::add_chunk(
        doc,
        data.expected_sequence,
        walrus_blob,
        data.chunk_type,
        data.expires_at,
        data.effective_from,
        data.immutable,
        data.immutable_from,
        data.max_renewal_advance_epochs,
        clock,
        ctx
    );

    resource_requests::create_receipt(data)
}

/// Add sunset chunk - returns ResourceRequest for Walrus Blob
public fun do_add_sunset_chunk<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
): ResourceRequest<AddSunsetChunkRequest> {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    let expected_type = action_types::add_sunset_chunk();
    assert!(protocol_intents::action_spec_type(spec) == expected_type, EInvalidActionType);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let mut reader = bcs::new(*action_data);
    let doc_id = object::id_from_address(bcs::peel_address(&mut reader));
    let expected_sequence = bcs::peel_u64(&mut reader);
    let expires_at_ms = bcs::peel_u64(&mut reader);
    let immutable = bcs::peel_bool(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    // Check if Walrus blobs are allowed
    assert_walrus_blobs_allowed(account);

    executable::increment_action_idx(executable);

    resource_requests::new_resource_request(
        AddSunsetChunkRequest { doc_id, expected_sequence, expires_at_ms, immutable, max_renewal_advance_epochs: option::none() },
        ctx
    )
}

/// Fulfill add_sunset_chunk request
public fun fulfill_add_sunset_chunk(
    request: ResourceRequest<AddSunsetChunkRequest>,
    account: &Account<FutarchyConfig>,
    doc: &mut File,
    walrus_blob: Blob,
    clock: &Clock,
    ctx: &mut TxContext,
): ResourceReceipt<AddSunsetChunkRequest> {
    let data = resource_requests::extract_action(request);
    assert!(dao_file_registry::get_file_id(doc) == data.doc_id, EInvalidDocId);

    // Verify account owns this document
    let doc_dao_id = dao_file_registry::get_document_dao_id(doc);
    assert!(doc_dao_id == object::id(account), EUnauthorizedDocument);

    // Use add_chunk with sunset parameters
    dao_file_registry::add_chunk(
        doc,
        data.expected_sequence,
        walrus_blob,
        1, // CHUNK_TYPE_SUNSET
        option::some(data.expires_at_ms),
        option::none(),
        data.immutable,
        option::none(),
        data.max_renewal_advance_epochs,
        clock,
        ctx
    );

    resource_requests::create_receipt(data)
}

/// Add sunrise chunk - returns ResourceRequest for Walrus Blob
public fun do_add_sunrise_chunk<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
): ResourceRequest<AddSunriseChunkRequest> {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    let expected_type = action_types::add_sunrise_chunk();
    assert!(protocol_intents::action_spec_type(spec) == expected_type, EInvalidActionType);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let mut reader = bcs::new(*action_data);
    let doc_id = object::id_from_address(bcs::peel_address(&mut reader));
    let expected_sequence = bcs::peel_u64(&mut reader);
    let effective_from_ms = bcs::peel_u64(&mut reader);
    let immutable = bcs::peel_bool(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    // Check if Walrus blobs are allowed
    assert_walrus_blobs_allowed(account);

    executable::increment_action_idx(executable);

    resource_requests::new_resource_request(
        AddSunriseChunkRequest { doc_id, expected_sequence, effective_from_ms, immutable, max_renewal_advance_epochs: option::none() },
        ctx
    )
}

/// Fulfill add_sunrise_chunk request
public fun fulfill_add_sunrise_chunk(
    request: ResourceRequest<AddSunriseChunkRequest>,
    account: &Account<FutarchyConfig>,
    doc: &mut File,
    walrus_blob: Blob,
    clock: &Clock,
    ctx: &mut TxContext,
): ResourceReceipt<AddSunriseChunkRequest> {
    let data = resource_requests::extract_action(request);
    assert!(dao_file_registry::get_file_id(doc) == data.doc_id, EInvalidDocId);

    // Verify account owns this document
    let doc_dao_id = dao_file_registry::get_document_dao_id(doc);
    assert!(doc_dao_id == object::id(account), EUnauthorizedDocument);

    // Use add_chunk with sunrise parameters
    dao_file_registry::add_chunk(
        doc,
        data.expected_sequence,
        walrus_blob,
        2, // CHUNK_TYPE_SUNRISE
        option::none(),
        option::some(data.effective_from_ms),
        data.immutable,
        option::none(),
        data.max_renewal_advance_epochs,
        clock,
        ctx
    );

    resource_requests::create_receipt(data)
}

/// Add temporary chunk - returns ResourceRequest for Walrus Blob
public fun do_add_temporary_chunk<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
): ResourceRequest<AddTemporaryChunkRequest> {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    let expected_type = action_types::add_temporary_chunk();
    assert!(protocol_intents::action_spec_type(spec) == expected_type, EInvalidActionType);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let mut reader = bcs::new(*action_data);
    let doc_id = object::id_from_address(bcs::peel_address(&mut reader));
    let expected_sequence = bcs::peel_u64(&mut reader);
    let effective_from_ms = bcs::peel_u64(&mut reader);
    let expires_at_ms = bcs::peel_u64(&mut reader);
    let immutable = bcs::peel_bool(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    // Check if Walrus blobs are allowed
    assert_walrus_blobs_allowed(account);

    executable::increment_action_idx(executable);

    resource_requests::new_resource_request(
        AddTemporaryChunkRequest { doc_id, expected_sequence, effective_from_ms, expires_at_ms, immutable, max_renewal_advance_epochs: option::none() },
        ctx
    )
}

/// Fulfill add_temporary_chunk request
public fun fulfill_add_temporary_chunk(
    request: ResourceRequest<AddTemporaryChunkRequest>,
    account: &Account<FutarchyConfig>,
    doc: &mut File,
    walrus_blob: Blob,
    clock: &Clock,
    ctx: &mut TxContext,
): ResourceReceipt<AddTemporaryChunkRequest> {
    let data = resource_requests::extract_action(request);
    assert!(dao_file_registry::get_file_id(doc) == data.doc_id, EInvalidDocId);

    // Verify account owns this document
    let doc_dao_id = dao_file_registry::get_document_dao_id(doc);
    assert!(doc_dao_id == object::id(account), EUnauthorizedDocument);

    // Use add_chunk with temporary parameters
    dao_file_registry::add_chunk(
        doc,
        data.expected_sequence,
        walrus_blob,
        3, // CHUNK_TYPE_TEMPORARY
        option::some(data.expires_at_ms),
        option::some(data.effective_from_ms),
        data.immutable,
        option::none(),
        data.max_renewal_advance_epochs,
        clock,
        ctx
    );

    resource_requests::create_receipt(data)
}

/// Add chunk with scheduled immutability - returns ResourceRequest for Walrus Blob
public fun do_add_chunk_with_scheduled_immutability<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
): ResourceRequest<AddChunkWithScheduledImmutabilityRequest> {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    let expected_type = action_types::add_chunk_with_scheduled_immutability();
    assert!(protocol_intents::action_spec_type(spec) == expected_type, EInvalidActionType);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let mut reader = bcs::new(*action_data);
    let doc_id = object::id_from_address(bcs::peel_address(&mut reader));
    let expected_sequence = bcs::peel_u64(&mut reader);
    let immutable_from_ms = bcs::peel_u64(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    // Check if Walrus blobs are allowed
    assert_walrus_blobs_allowed(account);

    executable::increment_action_idx(executable);

    resource_requests::new_resource_request(
        AddChunkWithScheduledImmutabilityRequest { doc_id, expected_sequence, immutable_from_ms, max_renewal_advance_epochs: option::none() },
        ctx
    )
}

/// Fulfill add_chunk_with_scheduled_immutability request
public fun fulfill_add_chunk_with_scheduled_immutability(
    request: ResourceRequest<AddChunkWithScheduledImmutabilityRequest>,
    account: &Account<FutarchyConfig>,
    doc: &mut File,
    walrus_blob: Blob,
    clock: &Clock,
    ctx: &mut TxContext,
): ResourceReceipt<AddChunkWithScheduledImmutabilityRequest> {
    let data = resource_requests::extract_action(request);
    assert!(dao_file_registry::get_file_id(doc) == data.doc_id, EInvalidDocId);

    // Verify account owns this document
    let doc_dao_id = dao_file_registry::get_document_dao_id(doc);
    assert!(doc_dao_id == object::id(account), EUnauthorizedDocument);

    // Use add_chunk with scheduled immutability parameters
    dao_file_registry::add_chunk(
        doc,
        data.expected_sequence,
        walrus_blob,
        0, // CHUNK_TYPE_PERMANENT
        option::none(),
        option::none(),
        false,
        option::some(data.immutable_from_ms),
        data.max_renewal_advance_epochs,
        clock,
        ctx
    );

    resource_requests::create_receipt(data)
}

// create_document_version removed - version system not needed

/// Update chunk - returns ResourceRequest requiring caller to provide new Blob
/// Action data: doc_id (address), chunk_id (address)
/// No blob data in action - caller must provide via fulfill_update_chunk
public fun do_update_chunk<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    ctx: &mut TxContext,
): ResourceRequest<UpdateChunkRequest> {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    let expected_type = action_types::update_chunk();
    assert!(protocol_intents::action_spec_type(spec) == expected_type, EInvalidActionType);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let mut reader = bcs::new(*action_data);
    let doc_id = object::id_from_address(bcs::peel_address(&mut reader));
    let expected_sequence = bcs::peel_u64(&mut reader);
    let chunk_id = object::id_from_address(bcs::peel_address(&mut reader));
    bcs_validation::validate_all_bytes_consumed(reader);

    // Check if Walrus blobs are allowed
    assert_walrus_blobs_allowed(account);

    executable::increment_action_idx(executable);

    // Create hot potato with request data
    let request_data = UpdateChunkRequest {
        doc_id,
        expected_sequence,
        chunk_id
    };

    resource_requests::new_resource_request(request_data, ctx)
}

/// Fulfill update chunk request by providing the new Blob
/// Returns the old Blob for caller to handle (transfer, delete, etc.)
public fun fulfill_update_chunk(
    request: ResourceRequest<UpdateChunkRequest>,
    account: &Account<FutarchyConfig>,
    doc: &mut File,
    new_blob: Blob,
    clock: &Clock,
    ctx: &TxContext,
): (Blob, ResourceReceipt<UpdateChunkRequest>) {
    let request_data = resource_requests::extract_action(request);

    // Verify doc ID matches
    assert!(dao_file_registry::get_file_id(doc) == request_data.doc_id, EInvalidDocId);

    // Verify account owns this document
    let doc_dao_id = dao_file_registry::get_document_dao_id(doc);
    assert!(doc_dao_id == object::id(account), EUnauthorizedDocument);

    // Update chunk and get old blob
    let old_blob = dao_file_registry::update_chunk(
        doc,
        request_data.expected_sequence,
        request_data.chunk_id,
        new_blob,
        clock,
        ctx
    );

    let receipt = resource_requests::create_receipt(request_data);
    (old_blob, receipt)
}

/// Remove chunk - returns ResourceRequest requiring fulfillment
/// Action data: doc_id (address), chunk_id (address)
/// Caller must call fulfill_remove_chunk to complete the removal
public fun do_remove_chunk<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    ctx: &mut TxContext,
): ResourceRequest<RemoveChunkRequest> {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    let expected_type = action_types::remove_chunk();
    assert!(protocol_intents::action_spec_type(spec) == expected_type, EInvalidActionType);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let mut reader = bcs::new(*action_data);
    let doc_id = object::id_from_address(bcs::peel_address(&mut reader));
    let expected_sequence = bcs::peel_u64(&mut reader);
    let chunk_id = object::id_from_address(bcs::peel_address(&mut reader));
    bcs_validation::validate_all_bytes_consumed(reader);

    executable::increment_action_idx(executable);

    // Create hot potato with request data
    let request_data = RemoveChunkRequest {
        doc_id,
        expected_sequence,
        chunk_id
    };

    resource_requests::new_resource_request(request_data, ctx)
}

/// Fulfill remove chunk request
/// Returns the removed Blob for caller to handle (transfer, delete, etc.)
public fun fulfill_remove_chunk(
    request: ResourceRequest<RemoveChunkRequest>,
    account: &Account<FutarchyConfig>,
    doc: &mut File,
    clock: &Clock,
): (Blob, ResourceReceipt<RemoveChunkRequest>) {
    let request_data = resource_requests::extract_action(request);

    // Verify doc ID matches
    assert!(dao_file_registry::get_file_id(doc) == request_data.doc_id, EInvalidDocId);

    // Verify account owns this document
    let doc_dao_id = dao_file_registry::get_document_dao_id(doc);
    assert!(doc_dao_id == object::id(account), EUnauthorizedDocument);

    // Remove chunk and get blob
    let blob = dao_file_registry::remove_chunk(
        doc,
        request_data.expected_sequence,
        request_data.chunk_id,
        clock
    );

    let receipt = resource_requests::create_receipt(request_data);
    (blob, receipt)
}

// === Immutability Actions ===

/// Set chunk immutable
public fun do_set_chunk_immutable<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    doc: &mut File,
    _version_witness: VersionWitness,
    _witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    let expected_type = action_types::set_chunk_immutable();
    assert!(protocol_intents::action_spec_type(spec) == expected_type, EInvalidActionType);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let mut reader = bcs::new(*action_data);
    let doc_id = object::id_from_address(bcs::peel_address(&mut reader));
    let expected_sequence = bcs::peel_u64(&mut reader);
    let chunk_id = object::id_from_address(bcs::peel_address(&mut reader));
    bcs_validation::validate_all_bytes_consumed(reader);

    assert!(dao_file_registry::get_file_id(doc) == doc_id, EInvalidDocId);

    dao_file_registry::set_chunk_immutable(doc, expected_sequence, chunk_id, clock);

    executable::increment_action_idx(executable);
}

/// Set document immutable (NEW - third-level immutability)
public fun do_set_document_immutable<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    doc: &mut File,
    _version_witness: VersionWitness,
    _witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    let expected_type = action_types::set_file_immutable();
    assert!(protocol_intents::action_spec_type(spec) == expected_type, EInvalidActionType);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let mut reader = bcs::new(*action_data);
    let doc_id = object::id_from_address(bcs::peel_address(&mut reader));
    let expected_sequence = bcs::peel_u64(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    assert!(dao_file_registry::get_file_id(doc) == doc_id, EInvalidDocId);

    dao_file_registry::set_document_immutable(doc, expected_sequence, clock);

    executable::increment_action_idx(executable);
}

/// Set document insert allowed
public fun do_set_document_insert_allowed<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    doc: &mut File,
    _version_witness: VersionWitness,
    _witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    let expected_type = action_types::set_file_insert_allowed();
    assert!(protocol_intents::action_spec_type(spec) == expected_type, EInvalidActionType);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let mut reader = bcs::new(*action_data);
    let doc_id = object::id_from_address(bcs::peel_address(&mut reader));
    let expected_sequence = bcs::peel_u64(&mut reader);
    let allowed = bcs::peel_bool(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    assert!(dao_file_registry::get_file_id(doc) == doc_id, EInvalidDocId);

    dao_file_registry::set_insert_allowed(doc, expected_sequence, allowed, clock);

    executable::increment_action_idx(executable);
}

/// Set document remove allowed
public fun do_set_document_remove_allowed<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    doc: &mut File,
    _version_witness: VersionWitness,
    _witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    let expected_type = action_types::set_file_remove_allowed();
    assert!(protocol_intents::action_spec_type(spec) == expected_type, EInvalidActionType);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let mut reader = bcs::new(*action_data);
    let doc_id = object::id_from_address(bcs::peel_address(&mut reader));
    let expected_sequence = bcs::peel_u64(&mut reader);
    let allowed = bcs::peel_bool(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    assert!(dao_file_registry::get_file_id(doc) == doc_id, EInvalidDocId);

    dao_file_registry::set_remove_allowed(doc, expected_sequence, allowed, clock);

    executable::increment_action_idx(executable);
}

// === Intent Builder Functions ===

/// Create registry intent
public fun new_create_registry<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    intent_witness: IW,
) {
    let data = vector[];
    protocol_intents::add_action_spec(
        intent,
        CreateRegistryWitness {},
        data,
        intent_witness,
    );
}

/// Create root document intent
public fun new_create_root_document<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    doc_name: String,
    intent_witness: IW,
) {
    assert!(doc_name.length() > 0, EEmptyDocName);

    let mut data = vector[];
    data.append(bcs::to_bytes(&doc_name.into_bytes()));

    protocol_intents::add_action_spec(
        intent,
        CreateRootDocumentWitness {},
        data,
        intent_witness,
    );
}

/// Create child document intent
// new_create_child_document removed - flat document structure only

/// Delete document intent (NEW)
public fun new_delete_document<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    doc_id: ID,
    intent_witness: IW,
) {
    let data = bcs::to_bytes(&object::id_to_address(&doc_id));

    protocol_intents::add_action_spec(
        intent,
        DeleteDocumentWitness {},
        data,
        intent_witness,
    );
}

/// Add chunk intent - encodes control fields only (blob provided at fulfill time)
public fun new_add_chunk<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    doc_id: ID,
    expected_sequence: u64,
    chunk_type: u8,
    expires_at: Option<u64>,
    effective_from: Option<u64>,
    immutable: bool,
    immutable_from: Option<u64>,
    intent_witness: IW,
) {
    let mut data = vector[];
    data.append(bcs::to_bytes(&object::id_to_address(&doc_id)));
    data.append(bcs::to_bytes(&expected_sequence));
    data.append(bcs::to_bytes(&chunk_type));
    data.append(bcs::to_bytes(&expires_at));
    data.append(bcs::to_bytes(&effective_from));
    data.append(bcs::to_bytes(&immutable));
    data.append(bcs::to_bytes(&immutable_from));

    protocol_intents::add_action_spec(
        intent,
        AddChunkWitness {},
        data,
        intent_witness,
    );
}

/// Add sunset chunk intent (expires at specified time) - blob provided at fulfill time
public fun new_add_sunset_chunk<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    doc_id: ID,
    expected_sequence: u64,
    expires_at_ms: u64,
    immutable: bool,
    intent_witness: IW,
) {
    let mut data = vector[];
    data.append(bcs::to_bytes(&object::id_to_address(&doc_id)));
    data.append(bcs::to_bytes(&expected_sequence));
    data.append(bcs::to_bytes(&expires_at_ms));
    data.append(bcs::to_bytes(&immutable));

    protocol_intents::add_action_spec(
        intent,
        AddSunsetChunkWitness {},
        data,
        intent_witness,
    );
}

/// Add sunrise chunk intent (activates after effective_from) - blob provided at fulfill time
public fun new_add_sunrise_chunk<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    doc_id: ID,
    expected_sequence: u64,
    effective_from_ms: u64,
    immutable: bool,
    intent_witness: IW,
) {
    let mut data = vector[];
    data.append(bcs::to_bytes(&object::id_to_address(&doc_id)));
    data.append(bcs::to_bytes(&expected_sequence));
    data.append(bcs::to_bytes(&effective_from_ms));
    data.append(bcs::to_bytes(&immutable));

    protocol_intents::add_action_spec(
        intent,
        AddSunriseChunkWitness {},
        data,
        intent_witness,
    );
}

/// Add temporary chunk intent (active between effective_from and expires_at) - blob provided at fulfill time
public fun new_add_temporary_chunk<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    doc_id: ID,
    expected_sequence: u64,
    effective_from_ms: u64,
    expires_at_ms: u64,
    immutable: bool,
    intent_witness: IW,
) {
    let mut data = vector[];
    data.append(bcs::to_bytes(&object::id_to_address(&doc_id)));
    data.append(bcs::to_bytes(&expected_sequence));
    data.append(bcs::to_bytes(&effective_from_ms));
    data.append(bcs::to_bytes(&expires_at_ms));
    data.append(bcs::to_bytes(&immutable));

    protocol_intents::add_action_spec(
        intent,
        AddTemporaryChunkWitness {},
        data,
        intent_witness,
    );
}

/// Add chunk with scheduled immutability intent - blob provided at fulfill time
public fun new_add_chunk_with_scheduled_immutability<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    doc_id: ID,
    expected_sequence: u64,
    immutable_from_ms: u64,
    intent_witness: IW,
) {
    let mut data = vector[];
    data.append(bcs::to_bytes(&object::id_to_address(&doc_id)));
    data.append(bcs::to_bytes(&expected_sequence));
    data.append(bcs::to_bytes(&immutable_from_ms));

    protocol_intents::add_action_spec(
        intent,
        AddChunkWithScheduledImmutabilityWitness {},
        data,
        intent_witness,
    );
}

/// Create document version intent
// new_create_document_version removed - version system not needed

/// Update chunk intent - new blob provided at fulfill time
public fun new_update_chunk<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    doc_id: ID,
    expected_sequence: u64,
    chunk_id: ID,
    intent_witness: IW,
) {
    let mut data = vector[];
    data.append(bcs::to_bytes(&object::id_to_address(&doc_id)));
    data.append(bcs::to_bytes(&expected_sequence));
    data.append(bcs::to_bytes(&object::id_to_address(&chunk_id)));

    protocol_intents::add_action_spec(
        intent,
        UpdateChunkWitness {},
        data,
        intent_witness,
    );
}

/// Remove chunk intent
public fun new_remove_chunk<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    doc_id: ID,
    expected_sequence: u64,
    chunk_id: ID,
    intent_witness: IW,
) {
    let mut data = vector[];
    data.append(bcs::to_bytes(&object::id_to_address(&doc_id)));
    data.append(bcs::to_bytes(&expected_sequence));
    data.append(bcs::to_bytes(&object::id_to_address(&chunk_id)));

    protocol_intents::add_action_spec(
        intent,
        RemoveChunkWitness {},
        data,
        intent_witness,
    );
}

/// Set chunk immutable intent
public fun new_set_chunk_immutable<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    doc_id: ID,
    expected_sequence: u64,
    chunk_id: ID,
    intent_witness: IW,
) {
    let mut data = vector[];
    data.append(bcs::to_bytes(&object::id_to_address(&doc_id)));
    data.append(bcs::to_bytes(&expected_sequence));
    data.append(bcs::to_bytes(&object::id_to_address(&chunk_id)));

    protocol_intents::add_action_spec(
        intent,
        SetChunkImmutableWitness {},
        data,
        intent_witness,
    );
}

/// Set document immutable intent
public fun new_set_document_immutable<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    doc_id: ID,
    expected_sequence: u64,
    intent_witness: IW,
) {
    let mut data = vector[];
    data.append(bcs::to_bytes(&object::id_to_address(&doc_id)));
    data.append(bcs::to_bytes(&expected_sequence));

    protocol_intents::add_action_spec(
        intent,
        SetDocumentImmutableWitness {},
        data,
        intent_witness,
    );
}

/// Set registry immutable intent
public fun new_set_registry_immutable<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    intent_witness: IW,
) {
    let data = vector[];

    protocol_intents::add_action_spec(
        intent,
        SetRegistryImmutableWitness {},
        data,
        intent_witness,
    );
}

/// Set document insert allowed intent
public fun new_set_document_insert_allowed<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    doc_id: ID,
    expected_sequence: u64,
    allowed: bool,
    intent_witness: IW,
) {
    let mut data = vector[];
    data.append(bcs::to_bytes(&object::id_to_address(&doc_id)));
    data.append(bcs::to_bytes(&expected_sequence));
    data.append(bcs::to_bytes(&allowed));

    protocol_intents::add_action_spec(
        intent,
        SetDocumentInsertAllowedWitness {},
        data,
        intent_witness,
    );
}

/// Set document remove allowed intent
public fun new_set_document_remove_allowed<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    doc_id: ID,
    expected_sequence: u64,
    allowed: bool,
    intent_witness: IW,
) {
    let mut data = vector[];
    data.append(bcs::to_bytes(&object::id_to_address(&doc_id)));
    data.append(bcs::to_bytes(&expected_sequence));
    data.append(bcs::to_bytes(&allowed));

    protocol_intents::add_action_spec(
        intent,
        SetDocumentRemoveAllowedWitness {},
        data,
        intent_witness,
    );
}

// === Cleanup Functions ===

public fun delete_create_registry(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

public fun delete_create_root_document(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

// delete_create_child_document removed - function no longer exists

public fun delete_delete_document(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

public fun delete_add_chunk(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

public fun delete_update_chunk(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

public fun delete_remove_chunk(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

public fun delete_set_chunk_immutable(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

public fun delete_set_document_immutable(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

public fun delete_set_registry_immutable(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

public fun delete_set_document_insert_allowed(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

public fun delete_set_document_remove_allowed(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}
