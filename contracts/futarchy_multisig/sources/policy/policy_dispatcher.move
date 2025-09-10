/// Dispatcher for policy management actions
module futarchy_multisig::policy_dispatcher;

use sui::tx_context::TxContext;
use account_protocol::executable::{Self, Executable};
use account_protocol::account::Account;
use futarchy_multisig::policy_actions::{
    Self,
    SetPatternPolicyAction,
    SetObjectPolicyAction,
    RegisterCouncilAction,
    RemovePatternPolicyAction,
    RemoveObjectPolicyAction,
};
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_core::version;

/// Try to execute policy actions
public fun try_execute_policy_action<IW: copy + drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    _ctx: &mut TxContext,
): bool {
    // Check for set pattern policy action
    if (executable::contains_action<Outcome, SetPatternPolicyAction>(executable)) {
        policy_actions::do_set_pattern_policy(
            executable,
            account,
            version::current(),
            witness
        );
        return true
    };
    
    // Check for set object policy action
    if (executable::contains_action<Outcome, SetObjectPolicyAction>(executable)) {
        policy_actions::do_set_object_policy(
            executable,
            account,
            version::current(),
            witness
        );
        return true
    };
    
    // Check for register council action
    if (executable::contains_action<Outcome, RegisterCouncilAction>(executable)) {
        policy_actions::do_register_council(
            executable,
            account,
            version::current(),
            witness
        );
        return true
    };
    
    // Check for remove pattern policy action
    if (executable::contains_action<Outcome, RemovePatternPolicyAction>(executable)) {
        policy_actions::do_remove_pattern_policy(
            executable,
            account,
            version::current(),
            witness
        );
        return true
    };
    
    // Check for remove object policy action
    if (executable::contains_action<Outcome, RemoveObjectPolicyAction>(executable)) {
        policy_actions::do_remove_object_policy(
            executable,
            account,
            version::current(),
            witness
        );
        return true
    };
    
    false // No policy action found
}