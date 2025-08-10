/// Actions specific to the role of a Security Council Account.
/// This enables the council to accept and manage critical capabilities like UpgradeCaps
/// through its own internal M-of-N governance process.
module futarchy::security_council_actions;

use std::string::String;
use sui::object::ID;
use account_protocol::intents::Expired;

/// Action for the council to take an UpgradeCap from its owned objects ("inbox")
/// and formally lock it as a managed asset, making it governable.
public struct AcceptAndLockUpgradeCapAction has store {
    /// The ID of the UpgradeCap object to be accepted.
    cap_id: ID,
    /// The canonical name for the package (e.g., "futarchy_v1"). Used as the key.
    package_name: String,
    /// The timelock delay in milliseconds to enforce on future upgrades.
    delay_ms: u64,
}

// --- Constructors, Getters, Cleanup ---

public fun new_accept_and_lock_cap(
    cap_id: ID,
    package_name: String,
    delay_ms: u64,
): AcceptAndLockUpgradeCapAction {
    AcceptAndLockUpgradeCapAction { cap_id, package_name, delay_ms }
}

public fun get_accept_and_lock_cap_params(action: &AcceptAndLockUpgradeCapAction): (ID, &String, u64) {
    (action.cap_id, &action.package_name, action.delay_ms)
}

public fun delete_accept_and_lock_cap(expired: &mut Expired) {
    let AcceptAndLockUpgradeCapAction {..} = expired.remove_action();
}

/// Action to update the rules for an already-managed UpgradeCap.
public struct UpdateUpgradeRulesAction has store {
    package_name: String,
    new_delay_ms: u64,
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

 // --- Constructors, Getters, Cleanup ---
public fun new_update_upgrade_rules(package_name: String, new_delay_ms: u64): UpdateUpgradeRulesAction {
    UpdateUpgradeRulesAction { package_name, new_delay_ms }
}

public fun get_update_upgrade_rules_params(action: &UpdateUpgradeRulesAction): (&String, u64) {
    (&action.package_name, action.new_delay_ms)
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
