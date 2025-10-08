/// Shared object representing a security council's approval of an IntentSpec
///
/// Flow:
/// 1. Council creates ApprovedIntentSpec via multisig → shares object
/// 2. User references object ID when creating proposal
/// 3. System validates object exists, matches DAO, not expired
module futarchy_multisig::approved_intent_spec;

use std::string::String;
use sui::{
    clock::Clock,
    event,
    object::{Self, ID, UID},
    transfer,
    tx_context::TxContext,
};
use futarchy_types::action_specs::InitActionSpecs;

// === Errors ===
const EApprovalExpired: u64 = 1;
const EInvalidDAO: u64 = 2;
const EInvalidCouncil: u64 = 3;
const EApprovalRevoked: u64 = 4;

// === Shared Object ===

/// A council-approved IntentSpec that users can reference when creating proposals
/// This is a SHARED OBJECT - anyone can read it, only council can create it
///
/// SECURITY: Approval is bound to specific DAO (dao_id) to prevent reuse across DAOs
/// SECURITY: Can be revoked by council before expiration if needed
public struct ApprovedIntentSpec has key {
    id: UID,
    /// The IntentSpec serialized as bytes (includes InitActionSpecs)
    /// Users deserialize off-chain to inspect and use
    intent_spec_bytes: vector<u8>,
    /// Which DAO this approval is for (BINDING - cannot be used for other DAOs)
    dao_id: ID,
    /// Which council approved this
    council_id: ID,
    /// When it was approved
    approved_at_ms: u64,
    /// When it expires
    expires_at_ms: u64,
    /// Optional metadata about what this approves
    metadata: String,
    /// How many times this approval has been used
    used_count: u64,
    /// Whether this approval has been revoked by the council
    revoked: bool,
    /// When it was revoked (if revoked)
    revoked_at_ms: Option<u64>,
}

// === Events ===

public struct IntentSpecApproved has copy, drop {
    approval_id: ID,
    dao_id: ID,
    council_id: ID,
    expires_at_ms: u64,
    metadata: String,
    timestamp: u64,
}

public struct IntentSpecApprovalUsed has copy, drop {
    approval_id: ID,
    dao_id: ID,
    used_count: u64,
    timestamp: u64,
}

public struct IntentSpecApprovalDeleted has copy, drop {
    approval_id: ID,
    dao_id: ID,
    council_id: ID,
    timestamp: u64,
}

public struct IntentSpecApprovalRevoked has copy, drop {
    approval_id: ID,
    dao_id: ID,
    council_id: ID,
    timestamp: u64,
}

// === Public Functions ===

/// Create and share an approval (called from council action)
public fun create_and_share(
    intent_spec_bytes: vector<u8>,
    dao_id: ID,
    council_id: ID,
    expiration_period_ms: u64,
    metadata: String,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let current_time = clock.timestamp_ms();
    let expires_at_ms = current_time + expiration_period_ms;

    let mut approved = ApprovedIntentSpec {
        id: object::new(ctx),
        intent_spec_bytes,
        dao_id,
        council_id,
        approved_at_ms: current_time,
        expires_at_ms,
        metadata,
        used_count: 0,
        revoked: false,
        revoked_at_ms: std::option::none(),
    };

    let approval_id = object::id(&approved);

    event::emit(IntentSpecApproved {
        approval_id,
        dao_id,
        council_id,
        expires_at_ms,
        metadata,
        timestamp: current_time,
    });

    transfer::share_object(approved);

    approval_id
}

/// Validate that an approval is valid for a given DAO and council
/// Returns the IntentSpec bytes if valid (user deserializes off-chain)
public fun validate_and_get_intent_spec_bytes(
    approved: &ApprovedIntentSpec,
    expected_dao_id: ID,
    expected_council_id: Option<ID>,
    clock: &Clock,
): &vector<u8> {
    // Check not revoked (FIRST - fail fast)
    assert!(!approved.revoked, EApprovalRevoked);

    // Check DAO matches (prevents cross-DAO approval reuse)
    assert!(approved.dao_id == expected_dao_id, EInvalidDAO);

    // Check council matches if specified
    if (expected_council_id.is_some()) {
        let required_council = *expected_council_id.borrow();
        assert!(approved.council_id == required_council, EInvalidCouncil);
    };

    // Check not expired
    let current_time = clock.timestamp_ms();
    assert!(current_time < approved.expires_at_ms, EApprovalExpired);

    &approved.intent_spec_bytes
}

/// Revoke an approval (callable via council governance action)
/// SECURITY: Once revoked, approval cannot be used for new proposals
/// NOTE: Does not affect proposals already created with this approval
public fun revoke_approval(
    approved: &mut ApprovedIntentSpec,
    clock: &Clock,
) {
    // Don't fail if already revoked (idempotent)
    if (approved.revoked) {
        return
    };

    let current_time = clock.timestamp_ms();
    approved.revoked = true;
    approved.revoked_at_ms = std::option::some(current_time);

    event::emit(IntentSpecApprovalRevoked {
        approval_id: object::id(approved),
        dao_id: approved.dao_id,
        council_id: approved.council_id,
        timestamp: current_time,
    });
}

/// Increment usage counter (mutable access to shared object)
public fun increment_usage(
    approved: &mut ApprovedIntentSpec,
    clock: &Clock,
) {
    approved.used_count = approved.used_count + 1;

    event::emit(IntentSpecApprovalUsed {
        approval_id: object::id(approved),
        dao_id: approved.dao_id,
        used_count: approved.used_count,
        timestamp: clock.timestamp_ms(),
    });
}

/// Delete an approval (only callable by DAO or council governance)
/// Takes ownership of the shared object and deletes it
public fun delete_approval(
    approved: ApprovedIntentSpec,
    clock: &Clock,
) {
    let ApprovedIntentSpec {
        id,
        intent_spec_bytes: _,
        dao_id,
        council_id,
        approved_at_ms: _,
        expires_at_ms: _,
        metadata: _,
        used_count: _,
        revoked: _,
        revoked_at_ms: _,
    } = approved;

    let approval_id = object::uid_to_inner(&id);

    event::emit(IntentSpecApprovalDeleted {
        approval_id,
        dao_id,
        council_id,
        timestamp: clock.timestamp_ms(),
    });

    object::delete(id);
}

// === View Functions ===

/// Get the IntentSpec bytes (immutable reference)
public fun intent_spec_bytes(approved: &ApprovedIntentSpec): &vector<u8> {
    &approved.intent_spec_bytes
}

/// Get approval metadata
public fun get_metadata(
    approved: &ApprovedIntentSpec
): (ID, ID, ID, u64, u64, String, u64) {
    (
        object::id(approved),
        approved.dao_id,
        approved.council_id,
        approved.approved_at_ms,
        approved.expires_at_ms,
        approved.metadata,
        approved.used_count,
    )
}

/// Check if approval is expired
public fun is_expired(approved: &ApprovedIntentSpec, clock: &Clock): bool {
    clock.timestamp_ms() >= approved.expires_at_ms
}

/// Get DAO ID
public fun dao_id(approved: &ApprovedIntentSpec): ID {
    approved.dao_id
}

/// Get council ID
public fun council_id(approved: &ApprovedIntentSpec): ID {
    approved.council_id
}

/// Get used count
public fun used_count(approved: &ApprovedIntentSpec): u64 {
    approved.used_count
}

/// Check if approval is revoked
public fun is_revoked(approved: &ApprovedIntentSpec): bool {
    approved.revoked
}

/// Get revocation timestamp (if revoked)
public fun revoked_at_ms(approved: &ApprovedIntentSpec): Option<u64> {
    approved.revoked_at_ms
}
