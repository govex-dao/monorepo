// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Enhanced auditable upgrade proposal with source verification
module account_actions::package_upgrade_auditable;

use std::string::String;
use sui::clock::Clock;
use account_protocol::account::{Account, Auth};
use account_protocol::package_registry::PackageRegistry;
use account_actions::{version, package_upgrade};

// === Structs ===

/// Comprehensive audit metadata for upgrade proposals
public struct AuditMetadata has store, copy, drop {
    // Source code verification
    source_code_hash: vector<u8>,      // SHA256 of all source files
    move_toml_hash: vector<u8>,        // SHA256 of Move.toml

    // Build verification
    compiler_version: String,          // e.g., "sui-move 1.18.0"
    build_timestamp_ms: u64,           // When built
    dependencies_hash: vector<u8>,     // Hash of all dependency versions

    // Audit trail
    git_commit_hash: String,           // Git SHA of source
    github_release_tag: String,        // e.g., "v3.0.0"
    audit_report_url: String,          // Link to audit report

    // Verifier attestations (optional)
    verifier_signatures: vector<vector<u8>>, // Independent verifiers who checked
}

/// Enhanced proposal with full audit metadata
public struct AuditableUpgradeProposal has store {
    package_name: String,
    bytecode_digest: vector<u8>,       // What Sui runtime validates
    audit_metadata: AuditMetadata,     // All verification data
    proposed_time_ms: u64,
    execution_time_ms: u64,
    approved: bool,
}

/// Dynamic field key for auditable proposals
public struct AuditableProposalKey has copy, drop, store {
    package_name: String,
    digest_hash: address,
}

// === Events ===

/// Emitted when auditable proposal is created
public struct AuditableUpgradeProposed has copy, drop {
    package_name: String,
    bytecode_digest: vector<u8>,
    source_code_hash: vector<u8>,
    git_commit: String,
    audit_report_url: String,
    proposed_at_ms: u64,
}

/// Emitted when verifier adds attestation
public struct VerifierAttestationAdded has copy, drop {
    package_name: String,
    bytecode_digest: vector<u8>,
    verifier: address,
    signature: vector<u8>,
    timestamp_ms: u64,
}

// === Public Functions ===

/// Propose upgrade with full audit trail
public fun propose_auditable_upgrade<Config: store>(
    auth: Auth,
    account: &mut Account,
    registry: &PackageRegistry,
    package_name: String,
    bytecode_digest: vector<u8>,
    audit_metadata: AuditMetadata,
    execution_time_ms: u64,
    clock: &Clock,
) {
    // Delegate to standard upgrade system for UpgradeCap validation
    // (this will verify auth internally)
    package_upgrade::propose_upgrade_digest(
        auth,
        account,
        registry,
        package_name,
        bytecode_digest,
        execution_time_ms,
        clock,
    );

    // Store enhanced metadata separately
    let key = auditable_key(package_name, bytecode_digest);
    let proposal = AuditableUpgradeProposal {
        package_name,
        bytecode_digest,
        audit_metadata,
        proposed_time_ms: clock.timestamp_ms(),
        execution_time_ms,
        approved: false,
    };

    account.add_managed_data(registry, key, proposal, version::current());

    // Emit detailed event
    sui::event::emit(AuditableUpgradeProposed {
        package_name,
        bytecode_digest,
        source_code_hash: audit_metadata.source_code_hash,
        git_commit: audit_metadata.git_commit_hash,
        audit_report_url: audit_metadata.audit_report_url,
        proposed_at_ms: clock.timestamp_ms(),
    });
}

/// Add independent verifier attestation
public fun add_verifier_attestation<Config: store>(
    auth: Auth,
    account: &mut Account,
    registry: &PackageRegistry,
    package_name: String,
    bytecode_digest: vector<u8>,
    signature: vector<u8>,  // Verifier's signature over digest
    clock: &Clock,
) {
    use account_protocol::account as acc;
    let verifier = acc::auth_account_addr(&auth);
    account.verify(auth);

    let proposal: &mut AuditableUpgradeProposal = account.borrow_managed_data_mut(
        registry,
        auditable_key(package_name, bytecode_digest),
        version::current()
    );

    proposal.audit_metadata.verifier_signatures.push_back(signature);

    sui::event::emit(VerifierAttestationAdded {
        package_name,
        bytecode_digest,
        verifier,
        signature,
        timestamp_ms: clock.timestamp_ms(),
    });
}

/// Get full audit metadata for proposal
public fun get_audit_metadata<Config: store>(
    account: &Account,
    registry: &PackageRegistry,
    package_name: String,
    bytecode_digest: vector<u8>,
): AuditMetadata {
    let proposal: &AuditableUpgradeProposal = account.borrow_managed_data(
        registry,
        auditable_key(package_name, bytecode_digest),
        version::current()
    );
    proposal.audit_metadata
}

/// Helper to create key
fun auditable_key(package_name: String, digest: vector<u8>): AuditableProposalKey {
    use sui::hash;
    let digest_hash = object::id_from_bytes(hash::blake2b256(&digest)).to_address();
    AuditableProposalKey { package_name, digest_hash }
}

/// Create audit metadata (helper for testing/scripts)
public fun new_audit_metadata(
    source_code_hash: vector<u8>,
    move_toml_hash: vector<u8>,
    compiler_version: String,
    build_timestamp_ms: u64,
    dependencies_hash: vector<u8>,
    git_commit_hash: String,
    github_release_tag: String,
    audit_report_url: String,
): AuditMetadata {
    AuditMetadata {
        source_code_hash,
        move_toml_hash,
        compiler_version,
        build_timestamp_ms,
        dependencies_hash,
        git_commit_hash,
        github_release_tag,
        audit_report_url,
        verifier_signatures: vector::empty(),
    }
}
