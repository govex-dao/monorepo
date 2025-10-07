/// Generic custody actions for Account Protocol
/// Works with any Account<Config> type (DAOs, multisigs, etc.)
module futarchy_vault::custody_actions;

use std::{string::{Self, String}, type_name};
use sui::{
    object::{Self, ID},
    clock::Clock,
    tx_context::TxContext,
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents::{Self as protocol_intents, Expired, Intent},
    version_witness::VersionWitness,
    bcs_validation,
};
use futarchy_core::{
    futarchy_config::FutarchyConfig,
    version,
    action_validation,
    action_types,
};
use sui::bcs::{Self, BCS};

// === Witness Types ===

/// Witness for ApproveCustody action
public struct ApproveCustodyWitness has drop {}

/// Witness for AcceptIntoCustody action
public struct AcceptIntoCustodyWitness has drop {}

/// DAO-side approval to accept an object R into council custody.
public struct ApproveCustodyAction<phantom R> has store, drop, copy {
    dao_id: ID,
    object_id: ID,
    resource_key: String,
    context: String,
    expires_at: u64,
}

/// Council action to accept an object R into custody.
public struct AcceptIntoCustodyAction<phantom R> has store, drop, copy {
    object_id: ID,
    resource_key: String,
    context: String,
}

// === New Functions (Serialize-Then-Destroy Pattern) ===

public fun new_approve_custody<Outcome, R, IW: drop>(
    intent: &mut Intent<Outcome>,
    dao_id: ID,
    object_id: ID,
    resource_key: String,
    context: String,
    expires_at: u64,
    intent_witness: IW,
) {
    // Create the action
    let action = ApproveCustodyAction<R> { dao_id, object_id, resource_key, context, expires_at };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with type marker
    protocol_intents::add_typed_action(
        intent,
        type_name::get<ApproveCustodyWitness>(),
        action_data,
        intent_witness
    );

    // Destroy the action
    destroy_approve_custody(action);
}

public fun new_accept_into_custody<Outcome, R, IW: drop>(
    intent: &mut Intent<Outcome>,
    object_id: ID,
    resource_key: String,
    context: String,
    intent_witness: IW,
) {
    // Create the action
    let action = AcceptIntoCustodyAction<R> { object_id, resource_key, context };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with type marker
    protocol_intents::add_typed_action(
        intent,
        type_name::get<AcceptIntoCustodyWitness>(),
        action_data,
        intent_witness
    );

    // Destroy the action
    destroy_accept_into_custody(action);
}

// === Legacy Constructors (for backward compatibility) ===

public fun create_approve_custody<R>(
    dao_id: ID,
    object_id: ID,
    resource_key: String,
    context: String,
    expires_at: u64,
): ApproveCustodyAction<R> {
    ApproveCustodyAction<R> { dao_id, object_id, resource_key, context, expires_at }
}

public fun create_accept_into_custody<R>(
    object_id: ID,
    resource_key: String,
    context: String,
): AcceptIntoCustodyAction<R> {
    AcceptIntoCustodyAction<R> { object_id, resource_key, context }
}

// Getters

public fun get_approve_custody_params<R>(
    a: &ApproveCustodyAction<R>
): (ID, ID, &String, &String, u64) {
    (a.dao_id, a.object_id, &a.resource_key, &a.context, a.expires_at)
}

public fun get_accept_params<R>(
    a: &AcceptIntoCustodyAction<R>
): (ID, &String, &String) {
    (a.object_id, &a.resource_key, &a.context)
}

// === Execution Functions (PTB Pattern) ===

/// Execute approve custody action
/// This creates a custody approval that can be used by the council
public fun do_approve_custody<Config: store, Outcome: store, R: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    _version_witness: VersionWitness,
    _witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // CRITICAL: Assert action type before deserialization
    action_validation::assert_action_type<ApproveCustodyWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);

    // Check version
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);
    let dao_id = bcs::peel_address(&mut reader).to_id();
    let object_id = bcs::peel_address(&mut reader).to_id();
    let resource_key = bcs::peel_vec_u8(&mut reader).to_string();
    let context = bcs::peel_vec_u8(&mut reader).to_string();
    let expires_at = bcs::peel_u64(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Store custody approval in account's managed data
    // The actual custody transfer happens when council calls accept
    let approval_key = CustodyApprovalKey<R> { object_id };

    if (!account::has_managed_data(account, approval_key)) {
        account::add_managed_data(
            account,
            approval_key,
            CustodyApproval {
                dao_id,
                object_id,
                resource_key,
                context,
                expires_at,
                approved_at: clock.timestamp_ms(),
            },
            version::current()
        );
    };

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute accept into custody action
/// This accepts an object into council custody after DAO approval
public fun do_accept_into_custody<Config: store, Outcome: store, R: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    _version_witness: VersionWitness,
    _witness: IW,
    clock: &Clock,
    _ctx: &mut TxContext,
): ResourceRequest<R> {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // CRITICAL: Assert action type before deserialization
    action_validation::assert_action_type<AcceptIntoCustodyWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);

    // Check version
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);
    let object_id = bcs::peel_address(&mut reader).to_id();
    let resource_key = bcs::peel_vec_u8(&mut reader).to_string();
    let context = bcs::peel_vec_u8(&mut reader).to_string();

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Check if DAO has approved this custody transfer
    let approval_key = CustodyApprovalKey<R> { object_id };
    assert!(account::has_managed_data(account, approval_key), ECustodyNotApproved);

    let approval: &CustodyApproval = account::borrow_managed_data(
        account,
        approval_key,
        version::current()
    );

    // Check if approval hasn't expired
    assert!(clock.timestamp_ms() <= approval.expires_at, ECustodyApprovalExpired);

    // Increment action index
    executable::increment_action_idx(executable);

    // Return a resource request that must be fulfilled by providing the object
    ResourceRequest<R> {
        object_id,
        resource_key,
        context,
    }
}

// === Helper Structs ===

/// Key for storing custody approvals
public struct CustodyApprovalKey<phantom R> has copy, drop, store {
    object_id: ID,
}

/// Custody approval data
public struct CustodyApproval has store {
    dao_id: ID,
    object_id: ID,
    resource_key: String,
    context: String,
    expires_at: u64,
    approved_at: u64,
}

/// Resource request for custody (hot potato pattern)
public struct ResourceRequest<phantom R> {
    object_id: ID,
    resource_key: String,
    context: String,
}

/// Fulfill a custody resource request
public fun fulfill_custody_request<Config: store, R: key + store>(
    request: ResourceRequest<R>,
    object: R,
    account: &mut Account<Config>,
    ctx: &mut TxContext,
) {
    let ResourceRequest { object_id, resource_key, context } = request;

    // Verify the object ID matches
    assert!(object::id(&object) == object_id, EObjectMismatch);

    // Store the object in account's managed data
    account::add_managed_data(
        account,
        resource_key,
        object,
        version::current()
    );
}

// === Errors ===
const ECustodyNotApproved: u64 = 1;
const ECustodyApprovalExpired: u64 = 2;
const EObjectMismatch: u64 = 3;
const EUnsupportedActionVersion: u64 = 4;
const EWrongAction: u64 = 5;

// === Destruction Functions ===

public fun destroy_approve_custody<R>(action: ApproveCustodyAction<R>) {
    let ApproveCustodyAction<R> {
        dao_id: _,
        object_id: _,
        resource_key: _,
        context: _,
        expires_at: _
    } = action;
}

public fun destroy_accept_into_custody<R>(action: AcceptIntoCustodyAction<R>) {
    let AcceptIntoCustodyAction<R> {
        object_id: _,
        resource_key: _,
        context: _
    } = action;
}

// === Cleanup Functions ===

public fun delete_approve_custody<R>(expired: &mut Expired) {
    let _spec = protocol_intents::remove_action_spec(expired);
    // ActionSpec has drop, automatically cleaned up
}

public fun delete_accept_into_custody<R>(expired: &mut Expired) {
    let _spec = protocol_intents::remove_action_spec(expired);
    // ActionSpec has drop, automatically cleaned up
}

// === Deserialization Functions ===

/// Deserialize ApproveCustodyAction from bytes
public fun approve_custody_action_from_bytes<R>(bytes: vector<u8>): ApproveCustodyAction<R> {
    let mut bcs = bcs::new(bytes);

    ApproveCustodyAction<R> {
        dao_id: object::id_from_address(bcs.peel_address()),
        object_id: object::id_from_address(bcs.peel_address()),
        resource_key: string::utf8(bcs.peel_vec_u8()),
        context: string::utf8(bcs.peel_vec_u8()),
        expires_at: bcs.peel_u64(),
    }
}

/// Deserialize AcceptIntoCustodyAction from bytes
public fun accept_into_custody_action_from_bytes<R>(bytes: vector<u8>): AcceptIntoCustodyAction<R> {
    let mut bcs = bcs::new(bytes);

    AcceptIntoCustodyAction<R> {
        object_id: object::id_from_address(bcs.peel_address()),
        resource_key: string::utf8(bcs.peel_vec_u8()),
        context: string::utf8(bcs.peel_vec_u8()),
    }
}