/// Actions specific to the role of a Security Council Account.
/// This enables the council to accept and manage critical capabilities like UpgradeCaps
/// through its own internal M-of-N governance process.
module futarchy::security_council_actions;

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

/// Council's approval of a specific OA change digest for a given DAO.
public struct ApproveOAChangeAction has store {
    dao_id: ID,
    digest: vector<u8>,
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

public fun new_approve_oa_change(dao_id: ID, digest: vector<u8>, expires_at: u64): ApproveOAChangeAction {
    ApproveOAChangeAction { dao_id, digest, expires_at }
}

public fun get_approve_oa_change_params(a: &ApproveOAChangeAction): (ID, &vector<u8>, u64) {
    (a.dao_id, &a.digest, a.expires_at)
}

public fun delete_approve_oa_change(expired: &mut Expired) {
    let ApproveOAChangeAction { dao_id: _, digest: _, expires_at: _ } = expired.remove_action();
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

/// Council's approval of a specific policy change for a given DAO.
/// Used for bilateral approval of critical policy modifications.
public struct ApprovePolicyChangeAction has store {
    dao_id: ID,
    resource_key: String,
    action_type: u8, // 0 = remove, 1 = set
    policy_account_id_opt: Option<ID>, // Some for set, None for remove
    intent_key_prefix_opt: Option<String>, // Some for set, None for remove
    expires_at: u64,
}

// --- Constructors, Getters, Cleanup ---
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

public fun new_approve_policy_change(
    dao_id: ID,
    resource_key: String,
    action_type: u8,
    policy_account_id_opt: Option<ID>,
    intent_key_prefix_opt: Option<String>,
    expires_at: u64,
): ApprovePolicyChangeAction {
    ApprovePolicyChangeAction {
        dao_id,
        resource_key,
        action_type,
        policy_account_id_opt,
        intent_key_prefix_opt,
        expires_at,
    }
}

public fun get_approve_policy_change_params(
    action: &ApprovePolicyChangeAction
): (ID, &String, u8, &Option<ID>, &Option<String>, u64) {
    (
        action.dao_id,
        &action.resource_key,
        action.action_type,
        &action.policy_account_id_opt,
        &action.intent_key_prefix_opt,
        action.expires_at,
    )
}

public fun delete_approve_policy_change(expired: &mut Expired) {
    let ApprovePolicyChangeAction {..} = expired.remove_action();
}

