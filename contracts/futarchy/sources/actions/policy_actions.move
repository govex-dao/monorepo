/// Actions for managing the Policy Registry.
module futarchy::policy_actions;

use std::string::String;
use sui::object::ID;
use account_protocol::intents::Expired;

public struct SetPolicyAction has store {
    resource_key: String, // e.g., "UpgradeCap:futarchy"
    policy_account_id: ID,
    intent_key_prefix: String,
}

public struct RemovePolicyAction has store {
    resource_key: String,
}

// --- Constructors, Getters, Cleanup ---

public fun new_set_policy(
    resource_key: String,
    policy_account_id: ID,
    intent_key_prefix: String,
): SetPolicyAction {
    SetPolicyAction { resource_key, policy_account_id, intent_key_prefix }
}

public fun new_remove_policy(resource_key: String): RemovePolicyAction {
    RemovePolicyAction { resource_key }
}

public fun get_set_policy_params(action: &SetPolicyAction): (&String, ID, &String) {
    (&action.resource_key, action.policy_account_id, &action.intent_key_prefix)
}

public fun get_remove_policy_key(action: &RemovePolicyAction): &String {
    &action.resource_key
}

public fun delete_set_policy(expired: &mut Expired) {
    let SetPolicyAction {..} = expired.remove_action();
}

public fun delete_remove_policy(expired: &mut Expired) {
    let RemovePolicyAction {..} = expired.remove_action();
}