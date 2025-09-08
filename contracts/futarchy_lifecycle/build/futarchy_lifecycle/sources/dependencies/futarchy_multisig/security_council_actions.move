/// Actions specific to the role of a Security Council Account.
/// This enables the council to accept and manage critical capabilities like UpgradeCaps
/// through its own internal M-of-N governance process.
module futarchy_multisig::security_council_actions;

use std::{string::String, option::Option};
use sui::object::ID;
use account_protocol::intents::Expired;

/// Create a new Security Council (WeightedMultisig) for the DAO.
/// Optionally register it as the OA custodian.
public struct CreateSecurityCouncilAction has store {
    members: vector<address>,
    weights: vector<u64>,
    threshold: u64,
    set_as_oa_custodian: bool,
}

/// Council's approval for an Operating Agreement change
public struct ApproveOAChangeAction has store {
    dao_id: ID,
    batch_id: ID,  // ID of the BatchOperatingAgreementAction
    expires_at: u64,
}

// --- Constructors, Getters, Cleanup ---

public fun new_create_council(
    members: vector<address>,
    weights: vector<u64>,
    threshold: u64,
    set_as_oa_custodian: bool,
): CreateSecurityCouncilAction {
    CreateSecurityCouncilAction { members, weights, threshold, set_as_oa_custodian }
}

public fun get_create_council_params(
    action: &CreateSecurityCouncilAction
): (&vector<address>, &vector<u64>, u64, bool) {
    (&action.members, &action.weights, action.threshold, action.set_as_oa_custodian)
}

public fun delete_create_council(expired: &mut Expired) {
    let CreateSecurityCouncilAction {..} = expired.remove_action();
}

public fun new_approve_oa_change(dao_id: ID, batch_id: ID, expires_at: u64): ApproveOAChangeAction {
    ApproveOAChangeAction { dao_id, batch_id, expires_at }
}

public fun get_approve_oa_change_params(a: &ApproveOAChangeAction): (ID, ID, u64) {
    (a.dao_id, a.batch_id, a.expires_at)
}

public fun delete_approve_oa_change(expired: &mut Expired) {
    let ApproveOAChangeAction { dao_id: _, batch_id: _, expires_at: _ } = expired.remove_action();
}

/// Action to update the rules for an already-managed UpgradeCap.
public struct UpdateUpgradeRulesAction has store {
    package_name: String,
}

/// Action to update the council's own membership, weights, and threshold.
public struct UpdateCouncilMembershipAction has store {
    new_members: vector<address>,
    new_weights: vector<u64>,
    new_threshold: u64,
}

/// Action to unlock an UpgradeCap and return it to the main DAO.
public struct UnlockAndReturnUpgradeCapAction has store {
    package_name: String,
    /// The address of the main DAO's treasury vault.
    return_vault_name: String,
}

/// Generic approval action for any non-OA council approval
/// This replaces ApprovePolicyChangeAction, ApproveUpgradeCapAction, etc.
public struct ApproveGenericAction has store {
    dao_id: ID,
    action_type: String,  // "policy_remove", "policy_set", "custody_accept", etc.
    resource_key: String,  // The resource being acted upon
    metadata: vector<String>,  // Pairs of key-value strings [k1, v1, k2, v2, ...]
    expires_at: u64,
}

/// Action to sweep/cleanup expired intents from the Security Council account
public struct SweepIntentsAction has store {
    intent_keys: vector<String>,  // Specific intent keys to clean up
}

/// Action for security council to create an optimistic intent
public struct CouncilCreateOptimisticIntentAction has store {
    dao_id: ID,
    intent_key: String,
    title: String,
    description: String,
}

/// Action for security council to execute a matured optimistic intent
public struct CouncilExecuteOptimisticIntentAction has store {
    dao_id: ID,
    intent_id: ID,
}

/// Action for security council to cancel their own optimistic intent
public struct CouncilCancelOptimisticIntentAction has store {
    dao_id: ID,
    intent_id: ID,
    reason: String,
}

// --- Constructors, Getters, Cleanup ---

// Optimistic Intent Constructors
public fun new_council_create_optimistic_intent(
    dao_id: ID,
    intent_key: String,
    title: String,
    description: String,
): CouncilCreateOptimisticIntentAction {
    CouncilCreateOptimisticIntentAction { dao_id, intent_key, title, description }
}

public fun get_council_create_optimistic_intent_params(
    action: &CouncilCreateOptimisticIntentAction
): (ID, &String, &String, &String) {
    (action.dao_id, &action.intent_key, &action.title, &action.description)
}

public fun delete_council_create_optimistic_intent(expired: &mut Expired) {
    let CouncilCreateOptimisticIntentAction {..} = expired.remove_action();
}

public fun new_council_execute_optimistic_intent(
    dao_id: ID,
    intent_id: ID,
): CouncilExecuteOptimisticIntentAction {
    CouncilExecuteOptimisticIntentAction { dao_id, intent_id }
}

public fun get_council_execute_optimistic_intent_params(
    action: &CouncilExecuteOptimisticIntentAction
): (ID, ID) {
    (action.dao_id, action.intent_id)
}

public fun delete_council_execute_optimistic_intent(expired: &mut Expired) {
    let CouncilExecuteOptimisticIntentAction {..} = expired.remove_action();
}

public fun new_council_cancel_optimistic_intent(
    dao_id: ID,
    intent_id: ID,
    reason: String,
): CouncilCancelOptimisticIntentAction {
    CouncilCancelOptimisticIntentAction { dao_id, intent_id, reason }
}

public fun get_council_cancel_optimistic_intent_params(
    action: &CouncilCancelOptimisticIntentAction
): (ID, ID, &String) {
    (action.dao_id, action.intent_id, &action.reason)
}

public fun delete_council_cancel_optimistic_intent(expired: &mut Expired) {
    let CouncilCancelOptimisticIntentAction {..} = expired.remove_action();
}

// Other Constructors
public fun new_update_upgrade_rules(package_name: String): UpdateUpgradeRulesAction {
    UpdateUpgradeRulesAction { package_name }
}

public fun get_update_upgrade_rules_params(action: &UpdateUpgradeRulesAction): &String {
    &action.package_name
}

public fun new_update_council_membership(
    new_members: vector<address>,
    new_weights: vector<u64>,
    new_threshold: u64,
): UpdateCouncilMembershipAction {
    UpdateCouncilMembershipAction { new_members, new_weights, new_threshold }
}

public fun get_update_council_membership_params(
    action: &UpdateCouncilMembershipAction
): (&vector<address>, &vector<u64>, u64) {
    (&action.new_members, &action.new_weights, action.new_threshold)
}

public fun new_unlock_and_return_cap(package_name: String, return_vault_name: String): UnlockAndReturnUpgradeCapAction {
    UnlockAndReturnUpgradeCapAction { package_name, return_vault_name }
}

public fun get_unlock_and_return_cap_params(action: &UnlockAndReturnUpgradeCapAction): (&String, &String) {
    (&action.package_name, &action.return_vault_name)
}

public fun delete_update_upgrade_rules(expired: &mut Expired) {
    let UpdateUpgradeRulesAction {..} = expired.remove_action();
}

public fun delete_update_council_membership(expired: &mut Expired) {
    let UpdateCouncilMembershipAction {..} = expired.remove_action();
}

public fun delete_unlock_and_return_cap(expired: &mut Expired) {
    let UnlockAndReturnUpgradeCapAction {..} = expired.remove_action();
}

// --- Generic Approval Functions ---

public fun new_approve_generic(
    dao_id: ID,
    action_type: String,
    resource_key: String,
    metadata: vector<String>,
    expires_at: u64,
): ApproveGenericAction {
    ApproveGenericAction {
        dao_id,
        action_type,
        resource_key,
        metadata,
        expires_at,
    }
}

public fun get_approve_generic_params(
    action: &ApproveGenericAction
): (ID, &String, &String, &vector<String>, u64) {
    (
        action.dao_id,
        &action.action_type,
        &action.resource_key,
        &action.metadata,
        action.expires_at,
    )
}

public fun delete_approve_generic(expired: &mut Expired) {
    let ApproveGenericAction {..} = expired.remove_action();
}

// --- Sweep Intents Functions ---

public fun new_sweep_intents_with_keys(intent_keys: vector<String>): SweepIntentsAction {
    SweepIntentsAction { intent_keys }
}

public fun get_sweep_keys(action: &SweepIntentsAction): &vector<String> {
    &action.intent_keys
}

public fun delete_sweep_intents(expired: &mut Expired) {
    let SweepIntentsAction {..} = expired.remove_action();
}

