/// A generic, weighted M-of-N multisig configuration for an Account.
/// Each member has an assigned weight, and an intent is approved when
/// the sum of approving members' weights meets a given threshold.
/// This module is designed to be used as the `Config` for an `account_protocol::account::Account`.
module futarchy_multisig::weighted_multisig;

use std::string::String;
use std::option::{Self, Option};
use sui::{vec_set::{Self, VecSet}, clock::Clock, object::ID};
use futarchy_multisig::weighted_list::{Self, WeightedList};

// === Errors ===
const EThresholdNotMet: u64 = 1;
const EAlreadyApproved: u64 = 2;
const ENotMember: u64 = 3;
const EThresholdUnreachable: u64 = 4;
const EInvalidArguments: u64 = 5;
const EInvariantThresholdZero: u64 = 6;
const EInvariantThresholdTooHigh: u64 = 7;
const EInvariantInvalidTimestamp: u64 = 8;
const EProposalStale: u64 = 9;

// === Structs ===

/// Witness for this config module, required by the account protocol.
public struct Witness has drop {}
/// Get the witness for this module.
public fun witness(): Witness { Witness {} }

/// The configuration for a weighted multisig account.
public struct WeightedMultisig has store {
    /// The list of members and their voting weights.
    members: WeightedList,
    /// The sum of weights required for an intent to be approved.
    threshold: u64,
    /// Configuration nonce - incremented on any membership/threshold change
    /// Used to invalidate stale proposals automatically (same pattern as Gnosis Safe)
    nonce: u64,
    /// Last activity timestamp for dead-man switch tracking
    last_activity_ms: u64,
    /// The DAO that owns this security council (optional for backwards compatibility)
    dao_id: Option<ID>,
}

/// The outcome object for a weighted multisig. Tracks approvals for a specific intent.
/// Uses nonce-based staleness detection (same pattern as Gnosis Safe and Squads Protocol)
public struct Approvals has store, drop, copy {
    /// The set of addresses that have approved. The weight is looked up from the config.
    approvers: VecSet<address>,
    /// The config nonce when this proposal was created
    /// If this doesn't match current nonce, the proposal is stale
    created_at_nonce: u64,
}

// === Public Functions ===

/// Create a new mutable weighted multisig configuration with current time from clock.
/// Properly initializes the dead-man switch tracking.
public fun new(members: vector<address>, weights: vector<u64>, threshold: u64, clock: &Clock): WeightedMultisig {
    new_with_immutability(members, weights, threshold, false, clock)
}

/// Create a new immutable weighted multisig configuration that cannot change its membership.
/// Useful for fixed governance structures or permanent payment distributions.
public fun new_immutable(members: vector<address>, weights: vector<u64>, threshold: u64, clock: &Clock): WeightedMultisig {
    new_with_immutability(members, weights, threshold, true, clock)
}

/// Create a new weighted multisig with specified mutability.
fun new_with_immutability(
    members: vector<address>, 
    weights: vector<u64>, 
    threshold: u64, 
    is_immutable: bool,
    clock: &Clock
): WeightedMultisig {
    assert!(threshold > 0, EInvalidArguments);
    
    // Use the weighted_list module to create and validate the member list with specified mutability
    let member_list = weighted_list::new_with_immutability(members, weights, is_immutable);
    let total_weight = weighted_list::total_weight(&member_list);
    
    // Validate threshold is achievable
    assert!(threshold <= total_weight, EThresholdUnreachable);
    
    // Initialize with current timestamp for proper dead-man switch tracking
    let multisig = WeightedMultisig { 
        members: member_list,
        threshold,
        nonce: 0,  // Start at 0 like Gnosis Safe
        last_activity_ms: clock.timestamp_ms(),
        dao_id: option::none(), // Can be set later with set_dao_id
    };
    
    // Verify multisig-specific invariants before returning
    // Note: WeightedList invariants are already checked by weighted_list::new_with_immutability
    check_multisig_invariants(&multisig);
    multisig
}


/// Create a fresh, empty Approvals outcome for a new intent.
public fun new_approvals(config: &WeightedMultisig): Approvals {
    Approvals { 
        approvers: vec_set::empty(),
        created_at_nonce: config.nonce,
    }
}

/// A member approves an intent, modifying its outcome.
public fun approve_intent(
    outcome: &mut Approvals,
    config: &WeightedMultisig,
    sender: address,
) {
    // Check if proposal is still valid (not stale)
    assert!(outcome.created_at_nonce == config.nonce, EProposalStale);
    
    assert!(weighted_list::contains(&config.members, &sender), ENotMember);
    assert!(!outcome.approvers.contains(&sender), EAlreadyApproved);
    outcome.approvers.insert(sender);
}

/// Validate if the threshold has been met. This is called by `account_interface::execute_intent!`.
public fun validate_outcome(
    outcome: Approvals,
    config: &WeightedMultisig,
    _role: String,
) {
    // Check if proposal is stale
    assert!(outcome.created_at_nonce == config.nonce, EProposalStale);
    
    let mut current_weight = 0u64;
    // FIX: Use `into_keys()` which correctly returns a `vector<address>` for iteration.
    let approvers_vector = outcome.approvers.into_keys();
    
    let mut i = 0;
    while (i < approvers_vector.length()) {
        let approver = *vector::borrow(&approvers_vector, i);
        let weight = weighted_list::get_weight(&config.members, &approver);
        current_weight = current_weight + weight;
        i = i + 1;
    };

    assert!(current_weight >= config.threshold, EThresholdNotMet);
}

/// Check if a given address is a member of the multisig.
public fun is_member(config: &WeightedMultisig, addr: address): bool {
    weighted_list::contains(&config.members, &addr)
}

/// Asserts that a given address is a member, aborting if not.
public fun assert_is_member(config: &WeightedMultisig, addr: address) {
    assert!(is_member(config, addr), ENotMember);
}

/// Insert approver address after membership has been verified.
/// IMPORTANT: This function assumes membership has already been verified by the caller.
/// Only call this from within trusted module functions that have already checked membership.
/// This pattern avoids borrowing conflicts with account.config() inside resolve_intent! closures.
public(package) fun approve_sender_verified(outcome: &mut Approvals, sender: address) {
    assert!(!outcome.approvers.contains(&sender), EAlreadyApproved);
    outcome.approvers.insert(sender);
}

/// Update the multisig configuration with new members, weights, and threshold.
/// This is used by the security council to update its own membership.
/// IMPORTANT: This increments config_version, invalidating all pending proposals!
/// Aborts if the multisig was created as immutable.
public fun update_membership(
    config: &mut WeightedMultisig,
    new_members: vector<address>,
    new_weights: vector<u64>,
    new_threshold: u64,
    clock: &Clock,
) {
    // Create a new member list and update the existing one
    weighted_list::update(&mut config.members, new_members, new_weights);
    let new_total_weight = weighted_list::total_weight(&config.members);
    
    assert!(new_threshold > 0 && new_threshold <= new_total_weight, EThresholdUnreachable);
    
    // Update the threshold
    config.threshold = new_threshold;
    
    // INCREMENT NONCE - This invalidates all pending proposals!
    config.nonce = config.nonce + 1;
    
    // Set activity to current time on membership update
    config.last_activity_ms = clock.timestamp_ms();
    
    // Verify multisig-specific invariants after modification
    check_multisig_invariants(config);
}

// === Dead-man switch helpers ===

/// Get the last activity timestamp
public fun last_activity_ms(config: &WeightedMultisig): u64 {
    config.last_activity_ms
}

/// Bump the last activity timestamp to the current time
public fun bump_last_activity(config: &mut WeightedMultisig, clock: &Clock) {
    config.last_activity_ms = clock.timestamp_ms();
    // Verify timestamp invariant
    assert!(config.last_activity_ms > 0, EInvariantInvalidTimestamp);
}

// === DAO ownership ===

/// Set the DAO ID that owns this security council
public fun set_dao_id(config: &mut WeightedMultisig, dao_id: ID) {
    config.dao_id = option::some(dao_id);
    // Note: No need to check invariants here as DAO ID doesn't affect core multisig logic
}

/// Get the DAO ID that owns this security council
public fun dao_id(config: &WeightedMultisig): Option<ID> {
    config.dao_id
}

/// Check if this council belongs to a specific DAO
public fun belongs_to_dao(config: &WeightedMultisig, dao_id: ID): bool {
    if (option::is_some(&config.dao_id)) {
        *option::borrow(&config.dao_id) == dao_id
    } else {
        false // No DAO set
    }
}

// === Accessor Functions ===

/// Get the total weight of all members
public fun total_weight(config: &WeightedMultisig): u64 {
    weighted_list::total_weight(&config.members)
}

/// Get the weight of a specific member
public fun get_member_weight(config: &WeightedMultisig, addr: address): u64 {
    weighted_list::get_weight_or_zero(&config.members, &addr)
}

/// Get the threshold required for approval
public fun threshold(config: &WeightedMultisig): u64 {
    config.threshold
}

/// Get the number of members
public fun member_count(config: &WeightedMultisig): u64 {
    weighted_list::size(&config.members)
}

/// Check if the multisig membership is immutable
public fun is_immutable(config: &WeightedMultisig): bool {
    weighted_list::is_immutable(&config.members)
}

/// Get the current config nonce
public fun nonce(config: &WeightedMultisig): u64 {
    config.nonce
}

// === Invariant Checking ===

/// Check multisig-specific invariants.
/// The WeightedList maintains its own invariants internally.
/// This function only checks invariants specific to the multisig logic:
/// 1. Threshold must be > 0
/// 2. Threshold must be <= total weight of all members
/// 3. Last activity timestamp must be > 0 (initialized)
/// 
/// Note: The members list validity is guaranteed by the weighted_list module's
/// own invariant checks, which are automatically called during list operations.
public fun check_multisig_invariants(config: &WeightedMultisig) {
    // Invariant 1: Threshold must be greater than zero
    assert!(config.threshold > 0, EInvariantThresholdZero);
    
    // Invariant 2: Threshold must be achievable (not greater than total weight)
    // The weighted_list module ensures total_weight is always valid
    let total_weight = weighted_list::total_weight(&config.members);
    assert!(config.threshold <= total_weight, EInvariantThresholdTooHigh);
    
    // Invariant 3: Last activity timestamp must be valid (> 0 means initialized)
    assert!(config.last_activity_ms > 0, EInvariantInvalidTimestamp);
    
    // Note: We don't need to check members list validity here because:
    // - weighted_list::new() checks invariants during creation
    // - weighted_list::update() checks invariants during updates
    // - The WeightedList can never be in an invalid state
}

/// Additional validation that can be called to ensure approval state is valid
public fun validate_approvals(
    outcome: &Approvals,
    config: &WeightedMultisig
) {
    // All approvers must be members
    let approvers = outcome.approvers.into_keys();
    let mut i = 0;
    while (i < approvers.length()) {
        let approver = *vector::borrow(&approvers, i);
        assert!(weighted_list::contains(&config.members, &approver), ENotMember);
        i = i + 1;
    };
}

/// Check if the multisig is in a healthy state (for monitoring)
/// Returns true if all invariants pass, false otherwise
#[test_only]
public fun is_healthy(config: &WeightedMultisig): bool {
    // Check multisig-specific invariants without aborting
    if (config.threshold == 0) return false;
    
    let total_weight = weighted_list::total_weight(&config.members);
    if (config.threshold > total_weight) return false;
    
    if (config.last_activity_ms == 0) return false;
    
    // The weighted list is guaranteed to be valid by its own invariants,
    // but we can double-check for monitoring purposes
    weighted_list::verify_invariants(&config.members)
}