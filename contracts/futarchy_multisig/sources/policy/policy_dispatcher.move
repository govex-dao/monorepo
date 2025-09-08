/// Dispatcher for policy registry actions
module futarchy_multisig::policy_dispatcher;

// === Imports ===
use std::string;
use sui::{
    object,
    tx_context::TxContext,
};
use account_protocol::{
    account::Account,
    executable::{Self, Executable},
};
use futarchy_core::version;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_multisig::{
    policy_actions,
    policy_registry,
};

// === Constants ===
const ECriticalPolicyRequiresCouncil: u64 = 9;

// === Public(friend) Functions ===

/// Try to execute policy registry actions
public fun try_execute_policy_action<IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    _ctx: &mut TxContext,
): bool {
    // Check for set policy action
    if (executable::contains_action<Outcome, policy_actions::SetPolicyAction>(executable)) {
        let action: &policy_actions::SetPolicyAction = executable::next_action(executable, witness);
        let account_id = object::id(account);
        let (key, id, prefix) = policy_actions::get_set_policy_params(action);
        
        // TODO: Check if this is a critical policy that requires council co-approval
        // This check is temporarily disabled until futarchy package is published
        // if (policy_registry_coexec::is_critical_policy(key)) {
        //     abort ECriticalPolicyRequiresCouncil
        // };
        
        let registry = policy_registry::borrow_registry_mut(account, version::current());
        policy_registry::set_policy(registry, account_id, *key, id, *prefix);
        return true
    };

    // Check for remove policy action
    if (executable::contains_action<Outcome, policy_actions::RemovePolicyAction>(executable)) {
        let action: &policy_actions::RemovePolicyAction = executable::next_action(executable, witness);
        let account_id = object::id(account);
        let key = policy_actions::get_remove_policy_key(action);
        
        // TODO: Check if this is a critical policy that requires council co-approval
        // This check is temporarily disabled until futarchy package is published
        // if (policy_registry_coexec::is_critical_policy(key)) {
        //     abort ECriticalPolicyRequiresCouncil
        // };
        
        let registry = policy_registry::borrow_registry_mut(account, version::current());
        policy_registry::remove_policy(registry, account_id, *key);
        return true
    };

    false
}