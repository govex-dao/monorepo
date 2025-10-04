/// A generic, weighted M-of-N multisig configuration for an Account.
/// Each member has an assigned weight, and an intent is approved when
/// the sum of approving members' weights meets a given threshold.
/// This module is designed to be used as the `Config` for an `account_protocol::account::Account`.
///
/// ## Feature Organization
///
/// This module provides CORE voting logic plus OPTIONAL security features:
///
/// **CORE (Always Active):**
/// - Weighted member voting
/// - Threshold-based approval
///
/// **OPTIONAL SECURITY (Configurable per multisig):**
/// - Stale Proposal Prevention: Nonce-based invalidation (Gnosis Safe pattern)
/// - Time Lock: Mandatory delay between approval and execution
/// - Dead Man Switch: Inactivity failover to recovery account
///
/// **INTEGRATION:**
/// - DAO Relationship: Optional parent DAO tracking
///
/// All optional features are disabled by default and can be enabled per multisig.
///
/// ## Security Features
///
/// ### 1. Stale Proposal Invalidation (Nonce-Based)
/// - Every membership or threshold change increments a `nonce`
/// - Proposals created at old nonces are automatically rejected
/// - Prevents attacks from removed/compromised members
/// - Same pattern as Gnosis Safe and Squads Protocol
///
/// ### 2. Optional Time Lock (Configurable Delay)
/// - Enforces mandatory delay between approval and execution
/// - Configurable per multisig (default: 0 = disabled)
/// - Provides detection window for malicious proposals
/// - Recommended for high-value multisigs (billions in assets)
///
/// ## Time Lock Usage
///
/// **Default (No Time Lock):**
/// ```move
/// let multisig = weighted_multisig::new(members, weights, threshold, &clock);
/// // Proposals execute immediately after approval threshold is met
/// ```
///
/// **With Time Lock:**
/// ```move
/// // 24 hour delay (86400000 ms)
/// let multisig = weighted_multisig::new_with_time_lock(
///     members,
///     weights,
///     threshold,
///     86400000, // 24 hours in milliseconds
///     &clock
/// );
/// // Proposals must wait 24h after creation before execution
/// ```
///
/// **Update Time Lock Later:**
/// ```move
/// weighted_multisig::set_time_lock_delay(&mut multisig, 172800000); // Change to 48h
/// weighted_multisig::set_time_lock_delay(&mut multisig, 0); // Disable time lock
/// ```
///
/// ## Recommended Time Lock Settings
///
/// - **No assets / testing:** 0ms (disabled)
/// - **Small multisig (<$100k):** 1-6 hours
/// - **Medium multisig ($100k-$1M):** 24 hours
/// - **Large multisig ($1M-$10M):** 48 hours
/// - **Critical multisig (>$10M):** 72 hours
///
/// Note: Time lock only delays execution, not approval. Members can approve immediately,
/// but execution is blocked until the delay expires.
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
const ETimeLockNotExpired: u64 = 10;
const EInvalidDeadManSwitchRecipient: u64 = 11;
const ENotInactive: u64 = 12;
const ENoDeadManSwitch: u64 = 13;
const ERecipientDaoMismatch: u64 = 14;

// === Structs ===

/// Witness for this config module, required by the account protocol.
public struct Witness has drop {}
/// Get the witness for this module.
public fun witness(): Witness { Witness {} }

/// Optional time lock configuration for proposals
/// Set delay_ms to 0 to disable time lock (immediate execution)
public struct TimeLockConfig has store, copy, drop {
    /// Default delay in milliseconds (0 = disabled)
    default_delay_ms: u64,
}

/// Dead man switch configuration
/// Tracks inactivity timeout for failover mechanism
public struct DeadManSwitchConfig has store, copy, drop {
    /// Inactivity threshold in milliseconds before switch activates (e.g., 30 days = 2592000000)
    /// 0 = disabled
    timeout_ms: u64,
}

/// The configuration for a weighted multisig account.
public struct WeightedMultisig has store {
    // === CORE: Voting Logic ===
    /// The list of members and their voting weights.
    members: WeightedList,
    /// The sum of weights required for an intent to be approved.
    threshold: u64,

    // === SECURITY: Stale Proposal Prevention ===
    /// Configuration nonce - incremented on any membership/threshold change
    /// Used to invalidate stale proposals automatically (same pattern as Gnosis Safe)
    nonce: u64,

    // === SECURITY: Time Lock ===
    /// Optional time lock configuration (default: no delay)
    time_lock: TimeLockConfig,

    // === SECURITY: Dead Man Switch ===
    /// Dead man switch configuration
    dead_man_switch: DeadManSwitchConfig,
    /// Dead man switch recipient - must be the DAO's futarchy account or another multisig with same dao_id
    dead_man_switch_recipient: Option<ID>,
    /// Last activity timestamp for dead-man switch tracking
    last_activity_ms: u64,

    // === INTEGRATION: DAO Relationship ===
    /// The DAO that owns this security council (optional for backwards compatibility)
    dao_id: Option<ID>,
}

/// The outcome object for a weighted multisig. Tracks approvals for a specific intent.
/// Uses nonce-based staleness detection (same pattern as Gnosis Safe and Squads Protocol)
public struct Approvals has store, drop, copy {
    // === CORE: Approval Tracking ===
    /// The set of addresses that have approved. The weight is looked up from the config.
    approvers: VecSet<address>,

    // === SECURITY: Stale Proposal Prevention ===
    /// The config nonce when this proposal was created
    /// If this doesn't match current nonce, the proposal is stale
    created_at_nonce: u64,

    // === SECURITY: Time Lock ===
    /// Timestamp when this proposal was created (for time lock calculation)
    created_at_ms: u64,
    /// Earliest time this proposal can be executed (created_at_ms + time_lock_delay)
    earliest_execution_ms: u64,
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
        time_lock: TimeLockConfig { default_delay_ms: 0 }, // Default: no time lock
        dead_man_switch: DeadManSwitchConfig { timeout_ms: 0 }, // Default: disabled
        dead_man_switch_recipient: option::none(), // Can be set later with set_dead_man_switch_recipient
    };

    // Verify multisig-specific invariants before returning
    // Note: WeightedList invariants are already checked by weighted_list::new_with_immutability
    check_multisig_invariants(&multisig);
    multisig
}

/// Create a new weighted multisig with a time lock delay
/// delay_ms = 0 means no time lock (immediate execution)
/// delay_ms > 0 enforces a mandatory delay between approval and execution
public fun new_with_time_lock(
    members: vector<address>,
    weights: vector<u64>,
    threshold: u64,
    time_lock_delay_ms: u64,
    clock: &Clock
): WeightedMultisig {
    let mut multisig = new_with_immutability(members, weights, threshold, false, clock);
    multisig.time_lock.default_delay_ms = time_lock_delay_ms;
    multisig
}


/// Create a fresh, empty Approvals outcome for a new intent.
/// Note: If time lock is configured, you must call this from a function that has Clock parameter.
/// The creation time is captured at this moment, and earliest execution time is calculated.
public fun new_approvals_with_clock(config: &WeightedMultisig, clock: &Clock): Approvals {
    let created_at_ms = clock.timestamp_ms();
    let earliest_execution_ms = created_at_ms + config.time_lock.default_delay_ms;

    Approvals {
        approvers: vec_set::empty(),
        created_at_nonce: config.nonce,
        created_at_ms,
        earliest_execution_ms,
    }
}

/// Create a fresh, empty Approvals outcome for a new intent.
/// SAFETY: Aborts if time lock is configured - use new_approvals_with_clock instead.
/// This ensures time locks cannot be bypassed by accident.
public fun new_approvals(config: &WeightedMultisig): Approvals {
    // Prevent time lock bypass - require clock if time lock is enabled
    assert!(config.time_lock.default_delay_ms == 0, EInvalidArguments);

    Approvals {
        approvers: vec_set::empty(),
        created_at_nonce: config.nonce,
        created_at_ms: 0,
        earliest_execution_ms: 0,  // Safe: time lock is disabled (asserted above)
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
    clock: &Clock,
) {
    // Check if proposal is stale
    assert!(outcome.created_at_nonce == config.nonce, EProposalStale);

    // Check if time lock has expired (if configured)
    if (config.time_lock.default_delay_ms > 0) {
        assert!(
            clock.timestamp_ms() >= outcome.earliest_execution_ms,
            ETimeLockNotExpired
        );
    };

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

// === Dead Man Switch Recipient ===

/// Set the dead man switch recipient ID.
///
/// SECURITY: The recipient MUST be either:
/// 1. The DAO's futarchy account (if this multisig has a parent DAO)
/// 2. Another multisig account that belongs to the same DAO
///
/// This prevents a rogue multisig from setting up a dead man switch that transfers
/// control to an attacker-controlled account.
///
/// Parameters:
/// - recipient_id: The ID of the account that will receive control
/// - recipient_dao_id: The dao_id field of the recipient (None if recipient is the DAO itself)
public fun set_dead_man_switch_recipient(
    config: &mut WeightedMultisig,
    recipient_id: ID,
    recipient_dao_id: Option<ID>,
) {
    // If this multisig has a parent DAO, validate the recipient belongs to the same DAO
    if (option::is_some(&config.dao_id)) {
        let our_dao_id = *option::borrow(&config.dao_id);

        // Recipient must either:
        // 1. Be the DAO itself (recipient_dao_id is None and recipient_id == our_dao_id), OR
        // 2. Be another multisig owned by the same DAO (recipient_dao_id == our_dao_id)
        let valid_recipient = if (option::is_none(&recipient_dao_id)) {
            // Recipient has no dao_id, so it must be the DAO itself
            recipient_id == our_dao_id
        } else {
            // Recipient has a dao_id, so it must match ours
            *option::borrow(&recipient_dao_id) == our_dao_id
        };

        assert!(valid_recipient, EInvalidDeadManSwitchRecipient);
    };

    config.dead_man_switch_recipient = option::some(recipient_id);
}

/// Get the dead man switch recipient ID
public fun dead_man_switch_recipient(config: &WeightedMultisig): Option<ID> {
    config.dead_man_switch_recipient
}

/// Check if a dead man switch recipient is configured
public fun has_dead_man_switch(config: &WeightedMultisig): bool {
    option::is_some(&config.dead_man_switch_recipient)
}

/// Set the dead man switch timeout
/// timeout_ms = 0 disables the dead man switch
/// timeout_ms > 0 sets the inactivity threshold (e.g., 30 days = 2592000000 ms)
///
/// IMPORTANT: This is package-only to enforce governance.
/// Only callable from security_council_intents module after multisig approval.
public(package) fun set_dead_man_switch_timeout(config: &mut WeightedMultisig, timeout_ms: u64) {
    config.dead_man_switch.timeout_ms = timeout_ms;
}

/// Get the dead man switch timeout in milliseconds
public fun dead_man_switch_timeout_ms(config: &WeightedMultisig): u64 {
    config.dead_man_switch.timeout_ms
}

/// Check if the multisig is inactive and dead man switch should trigger
/// Returns true if:
/// 1. Dead man switch is configured (has recipient and timeout > 0)
/// 2. Inactivity period exceeds the timeout threshold
public fun is_inactive(config: &WeightedMultisig, clock: &Clock): bool {
    // Dead man switch must be configured
    if (option::is_none(&config.dead_man_switch_recipient)) {
        return false
    };
    if (config.dead_man_switch.timeout_ms == 0) {
        return false
    };

    // Check if inactivity exceeds timeout
    let inactive_duration = clock.timestamp_ms() - config.last_activity_ms;
    inactive_duration >= config.dead_man_switch.timeout_ms
}

/// Validate that a recipient still belongs to the same DAO at execution time.
/// This re-validates the relationship that was checked at setup time.
///
/// CRITICAL: This prevents TOCTOU (Time-Of-Check-Time-Of-Use) attacks where:
/// 1. Multisig A sets recipient = Multisig B (both same DAO, validated)
/// 2. Multisig B's dao_id changes to different DAO
/// 3. Dead man switch triggers -> would give control to wrong DAO!
///
/// Parameters:
/// - inactive_config: The config of the inactive multisig triggering the switch
/// - recipient_config: The config of the recipient (must be provided for validation)
///
/// Aborts if recipient no longer belongs to the same DAO.
public fun validate_recipient_at_execution(
    inactive_config: &WeightedMultisig,
    recipient_config: &WeightedMultisig,
) {
    // Get the recipient ID from inactive multisig
    assert!(option::is_some(&inactive_config.dead_man_switch_recipient), ENoDeadManSwitch);
    let recipient_id = *option::borrow(&inactive_config.dead_man_switch_recipient);

    // If inactive multisig has a parent DAO, validate recipient still belongs to same DAO
    if (option::is_some(&inactive_config.dao_id)) {
        let our_dao_id = *option::borrow(&inactive_config.dao_id);

        // Recipient must STILL belong to same DAO (re-validation at execution time)
        let valid_recipient = if (option::is_none(&recipient_config.dao_id)) {
            // Recipient has no dao_id - this is only valid if recipient IS the DAO itself
            // In this case, we can't validate further without the DAO object
            // The caller must ensure recipient_id == our_dao_id
            false // Require explicit DAO validation by caller
        } else {
            // Recipient is another multisig - must still have same dao_id
            *option::borrow(&recipient_config.dao_id) == our_dao_id
        };

        assert!(valid_recipient, ERecipientDaoMismatch);
    };

    // Note: Additional validation that recipient_config actually belongs to recipient_id
    // is the caller's responsibility (by providing the correct config object)
}

/// Check if dead man switch can be triggered for a specific recipient
/// This is the main validation function that should be called before any failover.
///
/// Validates:
/// 1. Inactive multisig has a dead man switch configured
/// 2. Timeout is enabled (> 0)
/// 3. Inactivity period exceeds timeout
/// 4. Recipient still belongs to same DAO (TOCTOU protection)
///
/// Returns true only if ALL conditions are met.
public fun can_trigger_dead_man_switch(
    inactive_config: &WeightedMultisig,
    recipient_config: &WeightedMultisig,
    clock: &Clock,
): bool {
    // Must have recipient configured
    if (option::is_none(&inactive_config.dead_man_switch_recipient)) {
        return false
    };

    // Must have timeout enabled
    if (inactive_config.dead_man_switch.timeout_ms == 0) {
        return false
    };

    // Must be inactive long enough
    let inactive_duration = clock.timestamp_ms() - inactive_config.last_activity_ms;
    if (inactive_duration < inactive_config.dead_man_switch.timeout_ms) {
        return false
    };

    // Recipient must still be valid (DAO relationship unchanged)
    // This is a non-aborting check - return false if validation would fail
    if (option::is_some(&inactive_config.dao_id)) {
        let our_dao_id = *option::borrow(&inactive_config.dao_id);

        if (option::is_none(&recipient_config.dao_id)) {
            return false // Can't validate without DAO context
        };

        if (*option::borrow(&recipient_config.dao_id) != our_dao_id) {
            return false // DAO mismatch
        };
    };

    true
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

/// Get the time lock delay in milliseconds
public fun time_lock_delay_ms(config: &WeightedMultisig): u64 {
    config.time_lock.default_delay_ms
}

/// Update the time lock delay
/// Set to 0 to disable time lock (immediate execution)
/// Set to > 0 to enforce a mandatory delay between approval and execution
///
/// IMPORTANT: This is package-only to enforce governance.
/// Only callable from security_council_intents module after multisig approval.
public(package) fun set_time_lock_delay(config: &mut WeightedMultisig, delay_ms: u64) {
    config.time_lock.default_delay_ms = delay_ms;
}


/// Check if a proposal can be executed (time lock expired and threshold met)
public fun can_execute(
    outcome: &Approvals,
    config: &WeightedMultisig,
    clock: &Clock,
): bool {
    // Check if stale
    if (outcome.created_at_nonce != config.nonce) {
        return false
    };

    // Check time lock
    if (config.time_lock.default_delay_ms > 0) {
        if (clock.timestamp_ms() < outcome.earliest_execution_ms) {
            return false
        };
    };

    // Check threshold
    let approvers_vector = outcome.approvers.into_keys();
    let mut current_weight = 0u64;
    let mut i = 0;
    while (i < approvers_vector.length()) {
        let approver = *vector::borrow(&approvers_vector, i);
        let weight = weighted_list::get_weight(&config.members, &approver);
        current_weight = current_weight + weight;
        i = i + 1;
    };

    current_weight >= config.threshold
}

/// Get the time remaining until a proposal can be executed (0 if executable now)
public fun time_until_executable(
    outcome: &Approvals,
    clock: &Clock,
): u64 {
    let now = clock.timestamp_ms();
    if (now >= outcome.earliest_execution_ms) {
        0
    } else {
        outcome.earliest_execution_ms - now
    }
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