/// Bilateral approval mechanism for critical policy changes.
/// Requires both DAO and Security Council approval for modifying critical policies.
module futarchy::policy_registry_coexec;

use std::{string::String, option};
use sui::{clock::Clock, object::{Self, ID}};
use account_protocol::{
    account::{Self, Account},
    executable::Executable,
};
use futarchy::{
    version,
    policy_registry,
    policy_actions,
    coexec_common,
    futarchy_config::{FutarchyConfig, FutarchyOutcome},
    weighted_multisig::{WeightedMultisig, Approvals},
    security_council_actions,
};

// === Errors ===
const EPolicyActionMissing: u64 = 1;
const EApprovalActionMissing: u64 = 2;
const EKeyMismatch: u64 = 4;
const EActionTypeMismatch: u64 = 5;
const EPolicyMismatch: u64 = 8;
const ENotCriticalPolicy: u64 = 9;

// === Constants ===
const ACTION_TYPE_REMOVE: u8 = 0;
const ACTION_TYPE_SET: u8 = 1;

/// Critical policies that require bilateral approval to modify
public fun is_critical_policy(resource_key: &String): bool {
    let key_bytes = resource_key.bytes();
    
    // OA:Custodian - protects Operating Agreement
    if (key_bytes == b"OA:Custodian") return true;
    
    // UpgradeCap:* - protects package upgrades
    if (key_bytes.length() >= 11) {
        let prefix = vector[85, 112, 103, 114, 97, 100, 101, 67, 97, 112, 58]; // "UpgradeCap:"
        let mut i = 0;
        let mut matches = true;
        while (i < 11) {
            if (*key_bytes.borrow(i) != *prefix.borrow(i)) {
                matches = false;
                break
            };
            i = i + 1;
        };
        if (matches) return true;
    };
    
    // Vault:AllowedCoinTypes - protects treasury asset types
    if (key_bytes == b"Vault:AllowedCoinTypes") return true;
    
    // PolicyRegistry:Admin - protects the policy registry itself
    if (key_bytes == b"PolicyRegistry:Admin") return true;
    
    false
}

/// Execute policy changes requiring 2-of-2: futarchy + council.
/// For removing a critical policy:
/// - DAO must have the policy currently set
/// - Futarchy executable must contain RemovePolicyAction
/// - Council executable must contain ApprovePolicyChangeAction with matching params
/// Both executables are confirmed atomically.
public fun execute_remove_policy_with_council(
    dao: &mut Account<FutarchyConfig>,
    council: &mut Account<WeightedMultisig>,
    mut futarchy_exec: Executable<FutarchyOutcome>,
    mut council_exec: Executable<Approvals>,
    clock: &Clock,
) {
    // Extract futarchy RemovePolicyAction
    let remove_action: &policy_actions::RemovePolicyAction = 
        coexec_common::extract_action_with_check(&mut futarchy_exec, version::current(), EPolicyActionMissing);
    let resource_key = policy_actions::get_remove_policy_key(remove_action);
    
    // Verify this is a critical policy
    assert!(is_critical_policy(resource_key), ENotCriticalPolicy);
    
    // Extract council ApprovePolicyChangeAction
    let approval: &security_council_actions::ApprovePolicyChangeAction = 
        coexec_common::extract_action_with_check(&mut council_exec, version::current(), EApprovalActionMissing);
    
    let (dao_id, approved_key, action_type, policy_id_opt, prefix_opt, expires_at) = 
        security_council_actions::get_approve_policy_change_params(approval);
    
    // Validate approval matches the remove action
    coexec_common::validate_dao_id(dao_id, object::id(dao));
    assert!(*approved_key == *resource_key, EKeyMismatch);
    assert!(action_type == ACTION_TYPE_REMOVE, EActionTypeMismatch);
    assert!(policy_id_opt.is_none(), EActionTypeMismatch);
    assert!(prefix_opt.is_none(), EActionTypeMismatch);
    coexec_common::validate_expiry(clock, expires_at);
    
    // Verify the policy exists and is for this council
    let registry = policy_registry::borrow_registry(dao, version::current());
    assert!(policy_registry::has_policy(registry, *resource_key), coexec_common::error_no_policy());
    let policy = policy_registry::get_policy(registry, *resource_key);
    assert!(policy_registry::policy_account_id(policy) == object::id(council), EPolicyMismatch);
    
    // Execute the removal
    let dao_id = object::id(dao);
    let registry_mut = policy_registry::borrow_registry_mut(dao, version::current());
    policy_registry::remove_policy(registry_mut, dao_id, *resource_key);
    
    // Confirm both executables atomically
    coexec_common::confirm_both_executables(dao, council, futarchy_exec, council_exec);
}

/// Execute policy set/update requiring 2-of-2: futarchy + council.
/// For setting a critical policy:
/// - Futarchy executable must contain SetPolicyAction
/// - Council executable must contain ApprovePolicyChangeAction with matching params
/// Both executables are confirmed atomically.
public fun execute_set_policy_with_council(
    dao: &mut Account<FutarchyConfig>,
    council: &mut Account<WeightedMultisig>,
    mut futarchy_exec: Executable<FutarchyOutcome>,
    mut council_exec: Executable<Approvals>,
    clock: &Clock,
) {
    // Extract futarchy SetPolicyAction
    let set_action: &policy_actions::SetPolicyAction = 
        coexec_common::extract_action_with_check(&mut futarchy_exec, version::current(), EPolicyActionMissing);
    let (resource_key, policy_account_id, intent_key_prefix) = 
        policy_actions::get_set_policy_params(set_action);
    
    // Verify this is a critical policy
    assert!(is_critical_policy(resource_key), ENotCriticalPolicy);
    
    // Extract council ApprovePolicyChangeAction
    let approval: &security_council_actions::ApprovePolicyChangeAction = 
        coexec_common::extract_action_with_check(&mut council_exec, version::current(), EApprovalActionMissing);
    
    let (dao_id, approved_key, action_type, policy_id_opt, prefix_opt, expires_at) = 
        security_council_actions::get_approve_policy_change_params(approval);
    
    // Validate approval matches the set action
    coexec_common::validate_dao_id(dao_id, object::id(dao));
    assert!(*approved_key == *resource_key, EKeyMismatch);
    assert!(action_type == ACTION_TYPE_SET, EActionTypeMismatch);
    assert!(policy_id_opt.is_some(), EActionTypeMismatch);
    assert!(prefix_opt.is_some(), EActionTypeMismatch);
    assert!(*option::borrow(policy_id_opt) == policy_account_id, EPolicyMismatch);
    assert!(*option::borrow(prefix_opt) == *intent_key_prefix, EPolicyMismatch);
    coexec_common::validate_expiry(clock, expires_at);
    
    // Execute the set operation
    let dao_id = object::id(dao);
    let registry_mut = policy_registry::borrow_registry_mut(dao, version::current());
    policy_registry::set_policy(
        registry_mut,
        dao_id,
        *resource_key,
        policy_account_id,
        *intent_key_prefix
    );
    
    // Confirm both executables atomically
    coexec_common::confirm_both_executables(dao, council, futarchy_exec, council_exec);
}