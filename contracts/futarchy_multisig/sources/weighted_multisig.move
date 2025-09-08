/// A generic, weighted M-of-N multisig configuration for an Account.
/// Each member has an assigned weight, and an intent is approved when
/// the sum of approving members' weights meets a given threshold.
/// This module is designed to be used as the `Config` for an `account_protocol::account::Account`.
module futarchy_multisig::weighted_multisig;

use std::string::String;
use sui::{vec_map::{Self, VecMap}, vec_set::{Self, VecSet}, clock::Clock};

// === Errors ===
const EThresholdNotMet: u64 = 1;
const EAlreadyApproved: u64 = 2;
const ENotMember: u64 = 3;
const EThresholdUnreachable: u64 = 4;
const EInvalidArguments: u64 = 5;

// === Structs ===

/// Witness for this config module, required by the account protocol.
public struct Witness has drop {}
/// Get the witness for this module.
public fun witness(): Witness { Witness {} }

/// The configuration for a weighted multisig account.
public struct WeightedMultisig has store {
    /// Maps member addresses to their voting weight.
    members: VecMap<address, u64>,
    /// The sum of weights required for an intent to be approved.
    threshold: u64,
    /// Total voting power in the council.
    total_weight: u64,
    /// Last activity timestamp for dead-man switch tracking
    last_activity_ms: u64,
}

/// The outcome object for a weighted multisig. Tracks approvals for a specific intent.
public struct Approvals has store, drop, copy {
    /// The set of addresses that have approved. The weight is looked up from the config.
    approvers: VecSet<address>,
}

// === Public Functions ===

/// Create a new weighted multisig configuration.
public fun new(members: vector<address>, weights: vector<u64>, threshold: u64): WeightedMultisig {
    assert!(members.length() == weights.length(), EInvalidArguments);
    let mut member_map = vec_map::empty();
    let mut total_weight = 0u64;

    let mut i = 0;
    while (i < members.length()) {
        let member = *vector::borrow(&members, i);
        let weight = *vector::borrow(&weights, i);
        assert!(weight > 0, EInvalidArguments);
        member_map.insert(member, weight);
        total_weight = total_weight + weight;
        i = i + 1;
    };

    assert!(threshold > 0 && threshold <= total_weight, EThresholdUnreachable);
    WeightedMultisig { members: member_map, threshold, total_weight, last_activity_ms: 0 }
}

/// Create a fresh, empty Approvals outcome for a new intent.
public fun new_approvals(_config: &WeightedMultisig): Approvals {
    Approvals { approvers: vec_set::empty() }
}

/// A member approves an intent, modifying its outcome.
public fun approve_intent(
    outcome: &mut Approvals,
    config: &WeightedMultisig,
    sender: address,
) {
    assert!(config.members.contains(&sender), ENotMember);
    assert!(!outcome.approvers.contains(&sender), EAlreadyApproved);
    outcome.approvers.insert(sender);
}

/// Validate if the threshold has been met. This is called by `account_interface::execute_intent!`.
public fun validate_outcome(
    outcome: Approvals,
    config: &WeightedMultisig,
    _role: String,
) {
    let mut current_weight = 0u64;
    // FIX: Use `into_keys()` which correctly returns a `vector<address>` for iteration.
    let approvers_vector = outcome.approvers.into_keys();
    
    let mut i = 0;
    while (i < approvers_vector.length()) {
        let approver = *vector::borrow(&approvers_vector, i);
        let weight = *config.members.get(&approver);
        current_weight = current_weight + weight;
        i = i + 1;
    };

    assert!(current_weight >= config.threshold, EThresholdNotMet);
}

/// Check if a given address is a member of the multisig.
public fun is_member(config: &WeightedMultisig, addr: address): bool {
    config.members.contains(&addr)
}

/// Asserts that a given address is a member, aborting if not.
public fun assert_is_member(config: &WeightedMultisig, addr: address) {
    assert!(is_member(config, addr), ENotMember);
}

/// Insert approver address without borrowing the config inside the resolve_intent! closure.
/// Call weighted_multisig::assert_is_member(config, sender) BEFORE calling this to ensure membership.
/// This avoids borrowing account.config() inside the closure (which conflicts with the mutable borrow held by resolve_intent!).
public fun approve_sender_unchecked(outcome: &mut Approvals, sender: address) {
    assert!(!outcome.approvers.contains(&sender), EAlreadyApproved);
    outcome.approvers.insert(sender);
}

/// Update the multisig configuration with new members, weights, and threshold.
/// This is used by the security council to update its own membership.
public fun update_membership(
    config: &mut WeightedMultisig,
    new_members: vector<address>,
    new_weights: vector<u64>,
    new_threshold: u64,
) {
    assert!(new_members.length() == new_weights.length(), EInvalidArguments);
    
    let mut new_member_map = vec_map::empty();
    let mut new_total_weight = 0u64;
    
    let mut i = 0;
    while (i < new_members.length()) {
        let member = *vector::borrow(&new_members, i);
        let weight = *vector::borrow(&new_weights, i);
        assert!(weight > 0, EInvalidArguments);
        new_member_map.insert(member, weight);
        new_total_weight = new_total_weight + weight;
        i = i + 1;
    };
    
    assert!(new_threshold > 0 && new_threshold <= new_total_weight, EThresholdUnreachable);
    
    // Update the config
    config.members = new_member_map;
    config.threshold = new_threshold;
    config.total_weight = new_total_weight;
    // Reset activity on membership update
    config.last_activity_ms = 0;
}

// === Dead-man switch helpers ===

/// Get the last activity timestamp
public fun last_activity_ms(config: &WeightedMultisig): u64 {
    config.last_activity_ms
}

/// Bump the last activity timestamp to the current time
public fun bump_last_activity(config: &mut WeightedMultisig, clock: &Clock) {
    config.last_activity_ms = clock.timestamp_ms();
}