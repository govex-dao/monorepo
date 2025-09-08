module futarchy_multisig::security_council_intents;

use std::{string::String, option::{Self, Option}};
use sui::{
    package::{UpgradeCap, UpgradeTicket, UpgradeReceipt},
    clock::Clock,
    object::{Self, ID},
    transfer::{Self, Receiving},
    tx_context::TxContext,
};
use account_protocol::{
    account::{Self, Account, Auth},
    intents::{Self, Intent, Params, Expired},
    executable::Executable,
    intent_interface, // macros
    owned,            // withdraw/delete_withdraw
    account as account_protocol_account,
};
use fun intent_interface::build_intent as Account.build_intent;

use futarchy_core::version;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_multisig::{
    security_council,
    security_council_actions::{Self, UpdateCouncilMembershipAction, CreateSecurityCouncilAction},
    weighted_multisig::{Self as multisig, WeightedMultisig, Approvals},
    optimistic_intents,
};
use futarchy_vault::custody_actions;
use futarchy_multisig::policy_registry;
use account_actions::package_upgrade;
use account_extensions::extensions::Extensions;

// witnesses
public struct RequestPackageUpgradeIntent has copy, drop {}
public struct AcceptUpgradeCapIntent has copy, drop {}
public struct RequestOAPolicyChangeIntent has copy, drop {}
public struct UpdateCouncilMembershipIntent has copy, drop {}
public struct CreateSecurityCouncilIntent has copy, drop {}
public struct ApprovePolicyChangeIntent has copy, drop {}

// Constructor functions for witnesses
public fun new_request_package_upgrade_intent(): RequestPackageUpgradeIntent {
    RequestPackageUpgradeIntent{}
}

public fun new_request_oa_policy_change_intent(): RequestOAPolicyChangeIntent {
    RequestOAPolicyChangeIntent{}
}

public fun new_update_council_membership_intent(): UpdateCouncilMembershipIntent {
    UpdateCouncilMembershipIntent{}
}

public fun new_create_security_council_intent(): CreateSecurityCouncilIntent {
    CreateSecurityCouncilIntent{}
}

public fun new_approve_policy_change_intent(): ApprovePolicyChangeIntent {
    ApprovePolicyChangeIntent{}
}

// Named errors
const ERequiresCoExecution: u64 = 100;

// Public constructor for AcceptUpgradeCapIntent witness
public fun new_accept_upgrade_cap_intent(): AcceptUpgradeCapIntent {
    AcceptUpgradeCapIntent{}
}

public fun request_package_upgrade(
    security_council: &mut Account<WeightedMultisig>,
    auth_from_futarchy_dao: Auth,
    params: Params,
    package_name: String,
    digest: vector<u8>,
    ctx: &mut TxContext
) {
    security_council.verify(auth_from_futarchy_dao);
    let outcome: Approvals = multisig::new_approvals(security_council.config());

    security_council.build_intent!(
        params,
        outcome,
        b"package_upgrade".to_string(),
        version::current(),
        RequestPackageUpgradeIntent{}, // <-- braces
        ctx,
        |intent, iw| {
            package_upgrade::new_upgrade(intent, package_name, digest, iw);
            package_upgrade::new_commit(intent, package_name, iw);
        }
    );
}

public fun execute_upgrade_request(
    executable: &mut Executable<Approvals>,
    security_council: &mut Account<WeightedMultisig>,
    clock: &Clock,
): UpgradeTicket {
    package_upgrade::do_upgrade(
        executable,
        security_council,
        clock,
        version::current(),
        RequestPackageUpgradeIntent{} // <-- braces
    )
}

public fun execute_commit_request(
    mut executable: Executable<Approvals>,
    security_council: &mut Account<WeightedMultisig>,
    receipt: UpgradeReceipt,
) {
    package_upgrade::do_commit(
        &mut executable,
        security_council,
        receipt,
        version::current(),
        RequestPackageUpgradeIntent{} // <-- braces
    );
    security_council.confirm_execution(executable);
}

/// A council member proposes an intent to accept an UpgradeCap into custody.
/// The object will be delivered as Receiving<UpgradeCap> at execution time.
public fun request_accept_and_lock_cap(
    security_council: &mut Account<WeightedMultisig>,
    auth_from_member: Auth,
    params: Params,
    cap_id: ID,
    package_name: String, // used as resource_key
    ctx: &mut TxContext
) {
    use account_protocol::account;

    security_council.verify(auth_from_member);
    let outcome: Approvals = multisig::new_approvals(security_council.config());

    // Manual intent creation to avoid borrow conflict with owned::new_withdraw
    let mut intent = account::create_intent(
        security_council,           // &Account
        params,
        outcome,
        b"accept_custody".to_string(),
        version::current(),
        AcceptUpgradeCapIntent{},    // witness
        ctx
    );

    // now it's safe to borrow &mut security_council to lock the object
    owned::new_withdraw(&mut intent, security_council, cap_id, AcceptUpgradeCapIntent{});
    
    // Use generic custody accept action
    {
        let resource_key = package_name; // resource identifier
        let action = custody_actions::new_accept_into_custody<UpgradeCap>(
            cap_id,
            resource_key,
            b"".to_string()   // optional context
        );
        intent.add_action(
            action,
            AcceptUpgradeCapIntent{}
        );
    };

    // insert it back
    account::insert_intent(security_council, intent, version::current(), AcceptUpgradeCapIntent{});
}

/// Execute accept and lock cap with optional DAO enforcement
public fun execute_accept_and_lock_cap(
    mut executable: Executable<Approvals>,
    security_council: &mut Account<WeightedMultisig>,
    cap_receipt: Receiving<UpgradeCap>,
    ctx: &mut TxContext
) {
    // Keep this for non-coexec single-side accept+lock (no DAO policy enforced).
    // It now expects the new custody action instead of the legacy one.
    let cap = owned::do_withdraw(&mut executable, security_council, cap_receipt, AcceptUpgradeCapIntent{});
    let action: &custody_actions::AcceptIntoCustodyAction<UpgradeCap> =
        executable.next_action(AcceptUpgradeCapIntent{});
    let (_cap_id, pkg_name_ref, _ctx_ref) = custody_actions::get_accept_params(action);
    let auth = security_council::authenticate(security_council, ctx);
    package_upgrade::lock_cap(auth, security_council, cap, *pkg_name_ref, 0);
    security_council.confirm_execution(executable);
}

/// Execute accept and lock cap with DAO enforcement
/// Checks if "UpgradeCap:Custodian" policy is set and enforces co-execution
public fun execute_accept_and_lock_cap_with_dao_check(
    dao: &Account<FutarchyConfig>,
    mut executable: Executable<Approvals>,
    security_council: &mut Account<WeightedMultisig>,
    cap_receipt: Receiving<UpgradeCap>,
    ctx: &mut TxContext
) {
    // Check if DAO has UpgradeCap:Custodian policy set
    let reg = policy_registry::borrow_registry(dao, version::current());
    let key = b"UpgradeCap:Custodian".to_string();
    
    // Always require co-execution if policy exists
    assert!(!policy_registry::has_policy(reg, key), ERequiresCoExecution);
    
    // If no policy, proceed with regular execution
    execute_accept_and_lock_cap(executable, security_council, cap_receipt, ctx)
}

// Cleanup for “accept and lock cap” (must unlock the object via the Account)
public fun delete_accept_upgrade_cap(
    expired: &mut Expired,
    security_council: &mut Account<WeightedMultisig>
) {
    owned::delete_withdraw(expired, security_council); // <-- pass account too
    custody_actions::delete_accept_into_custody<UpgradeCap>(expired);
}

/// A council member proposes an intent to update the council's own membership.
public fun request_update_council_membership(
    security_council: &mut Account<WeightedMultisig>,
    auth_from_member: Auth,
    params: Params,
    new_members: vector<address>,
    new_weights: vector<u64>,
    new_threshold: u64,
    ctx: &mut TxContext
) {
    security_council.verify(auth_from_member);
    let outcome: Approvals = multisig::new_approvals(security_council.config());

    security_council.build_intent!(
        params,
        outcome,
        b"update_council_membership".to_string(),
        version::current(),
        UpdateCouncilMembershipIntent{},
        ctx,
        |intent, iw| {
            let action = security_council_actions::new_update_council_membership(
                new_members,
                new_weights,
                new_threshold
            );
            intent.add_action(action, iw);
        }
    );
}

/// After council approval, this executes the membership update.
public fun execute_update_council_membership(
    mut executable: Executable<Approvals>,
    security_council: &mut Account<WeightedMultisig>,
    clock: &Clock,
) {
    let action: &UpdateCouncilMembershipAction = executable.next_action(UpdateCouncilMembershipIntent{});
    let (new_members, new_weights, new_threshold) =
        security_council_actions::get_update_council_membership_params(action);

    // Get mutable access to the account's config
    let config_mut = account_protocol_account::config_mut(
        security_council,
        version::current(),
        security_council::witness()
    );

    // Use the weighted_multisig's update_membership function (now requires clock)
    multisig::update_membership(
        config_mut,
        *new_members,
        *new_weights,
        new_threshold,
        clock
    );

    security_council.confirm_execution(executable);
}

// === Create Security Council (DAO-side intent) ===

/// DAO proposes creation of a Security Council.
public fun request_create_security_council<Outcome: store + drop + copy>(
    dao: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: Outcome,
    members: vector<address>,
    weights: vector<u64>,
    threshold: u64,
    ctx: &mut TxContext
) {
    dao.build_intent!(
        params,
        outcome,
        b"create_security_council".to_string(),
        version::current(),
        CreateSecurityCouncilIntent{},
        ctx,
        |intent, iw| {
            let action = security_council_actions::new_create_council(
                members,
                weights,
                threshold
            );
            intent.add_action(action, iw);
        }
    );
}

/// Execute the council creation with a provided Extensions registry.
/// Creates the council, shares it, and optionally sets OA:Custodian policy.
#[allow(lint(share_owned))]
public fun execute_create_security_council<Outcome: store + drop + copy>(
    dao: &mut Account<FutarchyConfig>,
    extensions: &Extensions,
    mut executable: Executable<Outcome>,
    ctx: &mut TxContext
) {
    let action: &CreateSecurityCouncilAction = executable.next_action(CreateSecurityCouncilIntent{});
    let (members, weights, threshold) =
        security_council_actions::get_create_council_params(action);

    // Build council account
    let council = security_council::new(
        extensions,
        *members,
        *weights,
        threshold,
        ctx
    );
    let council_id = object::id(&council);
    transfer::public_share_object(council);

    // Confirm DAO-side execution
    dao.confirm_execution(executable);
}

// === Policy Change Approval (Council-side intent) ===

/// Council member proposes approval of a critical policy removal
public fun request_approve_policy_removal(
    security_council: &mut Account<WeightedMultisig>,
    auth_from_member: Auth,
    params: Params,
    dao_id: ID,
    resource_key: String,
    expires_at: u64,
    ctx: &mut TxContext
) {
    security_council.verify(auth_from_member);
    let outcome: Approvals = multisig::new_approvals(security_council.config());
    
    security_council.build_intent!(
        params,
        outcome,
        b"approve_policy_removal".to_string(),
        version::current(),
        ApprovePolicyChangeIntent{},
        ctx,
        |intent, iw| {
            // Create metadata for the policy removal approval
            let metadata = vector::empty<String>();
            
            let action = security_council_actions::new_approve_generic(
                dao_id,
                b"policy_remove".to_string(),
                resource_key,
                metadata,
                expires_at
            );
            intent.add_action(action, iw);
        }
    );
}

/// Council member proposes approval of a critical policy set/update
public fun request_approve_policy_set(
    security_council: &mut Account<WeightedMultisig>,
    auth_from_member: Auth,
    params: Params,
    dao_id: ID,
    resource_key: String,
    policy_account_id: ID,
    intent_key_prefix: String,
    expires_at: u64,
    ctx: &mut TxContext
) {
    security_council.verify(auth_from_member);
    let outcome: Approvals = multisig::new_approvals(security_council.config());
    
    security_council.build_intent!(
        params,
        outcome,
        b"approve_policy_set".to_string(),
        version::current(),
        ApprovePolicyChangeIntent{},
        ctx,
        |intent, iw| {
            // Create metadata for the policy set approval
            let mut metadata = vector::empty<String>();
            metadata.push_back(b"policy_account_id".to_string());
            // Convert ID to hex string
            let id_bytes = object::id_to_bytes(&policy_account_id);
            let id_hex = sui::hex::encode(id_bytes);
            metadata.push_back(std::string::utf8(id_hex));
            metadata.push_back(b"intent_key_prefix".to_string());
            metadata.push_back(intent_key_prefix);
            
            let action = security_council_actions::new_approve_generic(
                dao_id,
                b"policy_set".to_string(),
                resource_key,
                metadata,
                expires_at
            );
            intent.add_action(action, iw);
        }
    );
}

/// Execute the approved policy change intent
public fun execute_approve_policy_change(
    mut executable: Executable<Approvals>,
    security_council: &mut Account<WeightedMultisig>,
) {
    // The action is consumed when used with policy_registry_coexec
    // This just confirms the executable was properly used
    security_council.confirm_execution(executable);
}

// === Intent Cleanup Functions ===

/// Security Council can clean up specific expired intents by key
/// This is a hot path - council members can execute this without needing a proposal
/// 
/// Note: Due to Sui's Bag limitations, we cannot iterate through all intents.
/// Callers must provide the specific intent keys to clean up.
public fun cleanup_expired_council_intents(
    security_council: &mut Account<WeightedMultisig>,
    auth_from_member: Auth,
    intent_keys: vector<String>,
    clock: &Clock,
) {
    // Verify the caller is a council member
    security_council.verify(auth_from_member);
    
    // Clean up each specified intent if it's expired
    let mut i = 0;
    let len = intent_keys.length();
    
    while (i < len) {
        let key = *intent_keys.borrow(i);
        
        // Check if the intent exists and is expired
        let intents_store = account::intents(security_council);
        if (intents::contains(intents_store, key)) {
            // Get the intent to check expiration
            let intent = intents::get<Approvals>(intents_store, key);
            
            // If expired, delete it
            if (clock.timestamp_ms() >= intents::expiration_time(intent)) {
                let mut expired = account::delete_expired_intent<WeightedMultisig, Approvals>(
                    security_council,
                    key,
                    clock
                );
                
                // Drain the expired intent's actions
                drain_council_expired(&mut expired, security_council);
                
                // Destroy the empty expired object
                intents::destroy_empty_expired(expired);
            };
        };
        
        i = i + 1;
    };
}

/// Helper function to drain expired Security Council intent actions
fun drain_council_expired(expired: &mut Expired, security_council: &mut Account<WeightedMultisig>) {
    // Delete all possible Security Council action types
    security_council_actions::delete_update_council_membership(expired);
    security_council_actions::delete_create_council(expired);
    security_council_actions::delete_approve_generic(expired);
    security_council_actions::delete_sweep_intents(expired);
    security_council_actions::delete_council_create_optimistic_intent(expired);
    
    // Delete optimistic intent actions
    optimistic_intents::delete_execute_optimistic_intent_action(expired);
    optimistic_intents::delete_cancel_optimistic_intent_action(expired);
    optimistic_intents::delete_create_optimistic_intent_action(expired);
    optimistic_intents::delete_challenge_optimistic_intents_action(expired);
    optimistic_intents::delete_cleanup_expired_intents_action(expired);
    
    // Delete package upgrade actions
    package_upgrade::delete_upgrade(expired);
    package_upgrade::delete_commit(expired);
    
    // Delete owned withdraw if present
    owned::delete_withdraw(expired, security_council);
    
    // Delete custody actions
    custody_actions::delete_accept_into_custody<UpgradeCap>(expired);
}

/// Security Council can propose a sweep of specific expired intents
/// This requires multisig approval but can clean up many intents at once
/// 
/// Note: The intent_keys must be stored in the action since we need them
/// at execution time to identify which intents to clean.
public fun request_sweep_expired_intents(
    security_council: &mut Account<WeightedMultisig>,
    auth_from_member: Auth,
    params: Params,
    intent_keys: vector<String>,
    ctx: &mut TxContext
) {
    security_council.verify(auth_from_member);
    let outcome: Approvals = multisig::new_approvals(security_council.config());
    
    security_council.build_intent!(
        params,
        outcome,
        b"sweep_expired_intents".to_string(),
        version::current(),
        SweepExpiredIntentsIntent{},
        ctx,
        |intent, iw| {
            // Store the keys in the action so we know what to clean at execution
            let action = security_council_actions::new_sweep_intents_with_keys(intent_keys);
            intent.add_action(action, iw);
        }
    );
}

/// Execute the sweep of expired intents
/// This will clean up all the intents specified in the approved action
public fun execute_sweep_expired_intents(
    mut executable: Executable<Approvals>,
    security_council: &mut Account<WeightedMultisig>,
    clock: &Clock,
) {
    let action: &security_council_actions::SweepIntentsAction = 
        executable.next_action(SweepExpiredIntentsIntent{});
    let intent_keys = security_council_actions::get_sweep_keys(action);
    
    // Clean up the specified expired intents
    cleanup_expired_council_intents_internal(security_council, intent_keys, clock);
    
    security_council.confirm_execution(executable);
}

// Internal helper for cleaning up expired intents
fun cleanup_expired_council_intents_internal(
    security_council: &mut Account<WeightedMultisig>,
    intent_keys: &vector<String>,
    clock: &Clock,
) {
    // Process each intent key
    let mut i = 0;
    let len = intent_keys.length();
    
    while (i < len) {
        let key = *intent_keys.borrow(i);
        
        // Check if the intent exists and is expired
        let intents_store = account::intents(security_council);
        if (intents::contains(intents_store, key)) {
            // Get the intent to check expiration
            let intent = intents::get<Approvals>(intents_store, key);
            
            // If expired, delete it
            if (clock.timestamp_ms() >= intents::expiration_time(intent)) {
                let mut expired = account::delete_expired_intent<WeightedMultisig, Approvals>(
                    security_council,
                    key,
                    clock
                );
                
                // Drain the expired intent's actions
                drain_council_expired(&mut expired, security_council);
                
                // Destroy the empty expired object
                intents::destroy_empty_expired(expired);
            };
        };
        
        i = i + 1;
    };
}

// Optional no-ops for symmetry
public fun delete_request_package_upgrade(_expired: &mut Expired) {}
public fun delete_request_oa_policy_change(_expired: &mut Expired) {}
public fun delete_update_council_membership(expired: &mut Expired) {
    security_council_actions::delete_update_council_membership(expired);
}
public fun delete_create_council(expired: &mut Expired) {
    security_council_actions::delete_create_council(expired);
}
public fun delete_approve_policy_change(expired: &mut Expired) {
    security_council_actions::delete_approve_generic(expired);
}
public fun delete_sweep_expired_intents(expired: &mut Expired) {
    security_council_actions::delete_sweep_intents(expired);
}

// Witness for sweep intents
public struct SweepExpiredIntentsIntent has copy, drop {}

// Witness for optimistic intents
public struct CreateOptimisticIntent has copy, drop {}
public struct ExecuteOptimisticIntent has copy, drop {}
public struct CancelOptimisticIntent has copy, drop {}
public struct ChallengeOptimisticIntents has copy, drop {}

// Constructor functions for additional witnesses
public fun new_sweep_expired_intents_intent(): SweepExpiredIntentsIntent {
    SweepExpiredIntentsIntent{}
}

public fun new_create_optimistic_intent(): CreateOptimisticIntent {
    CreateOptimisticIntent{}
}

public fun new_execute_optimistic_intent(): ExecuteOptimisticIntent {
    ExecuteOptimisticIntent{}
}

public fun new_cancel_optimistic_intent(): CancelOptimisticIntent {
    CancelOptimisticIntent{}
}

public fun new_challenge_optimistic_intents(): ChallengeOptimisticIntents {
    ChallengeOptimisticIntents{}
}

// === Optimistic Intent Functions ===

/// Security council creates an optimistic intent that can be executed after waiting period
public fun request_create_optimistic_intent(
    security_council: &mut Account<WeightedMultisig>,
    auth_from_member: Auth,
    params: Params,
    dao_id: ID,
    intent_key_for_execution: String,  // The actual intent to execute after delay
    title: String,
    description: String,
    ctx: &mut TxContext
) {
    security_council.verify(auth_from_member);
    let outcome: Approvals = multisig::new_approvals(security_council.config());
    
    security_council.build_intent!(
        params,
        outcome,
        b"create_optimistic_intent".to_string(),
        version::current(),
        CreateOptimisticIntent{},
        ctx,
        |intent, iw| {
            // Create the optimistic intent action
            let action = security_council_actions::new_council_create_optimistic_intent(
                dao_id,
                intent_key_for_execution,
                title,
                description
            );
            intent.add_action(action, iw);
        }
    );
}

/// Execute a matured optimistic intent (after 10-day waiting period)
public fun request_execute_optimistic_intent(
    security_council: &mut Account<WeightedMultisig>, 
    auth_from_member: Auth,
    params: Params,
    dao_id: ID,
    optimistic_intent_id: ID,
    ctx: &mut TxContext
) {
    security_council.verify(auth_from_member);
    let outcome: Approvals = multisig::new_approvals(security_council.config());
    
    security_council.build_intent!(
        params,
        outcome,
        b"execute_optimistic_intent".to_string(),
        version::current(),
        ExecuteOptimisticIntent{},
        ctx,
        |intent, iw| {
            // Create action to execute the optimistic intent
            use futarchy_multisig::optimistic_intents;
            let action = optimistic_intents::new_execute_optimistic_intent_action(
                optimistic_intent_id
            );
            intent.add_action(action, iw);
        }
    );
}

/// Security council member cancels their own optimistic intent
public fun request_cancel_optimistic_intent(
    security_council: &mut Account<WeightedMultisig>,
    auth_from_member: Auth,
    params: Params,
    dao_id: ID,
    optimistic_intent_id: ID,
    reason: String,
    ctx: &mut TxContext
) {
    security_council.verify(auth_from_member);
    let outcome: Approvals = multisig::new_approvals(security_council.config());
    
    security_council.build_intent!(
        params,
        outcome,
        b"cancel_optimistic_intent".to_string(),
        version::current(),
        CancelOptimisticIntent{},
        ctx,
        |intent, iw| {
            use futarchy_multisig::optimistic_intents;
            let action = optimistic_intents::new_cancel_optimistic_intent_action(
                optimistic_intent_id,
                reason
            );
            intent.add_action(action, iw);
        }
    );
}

// Delete functions for expired intents
public fun delete_create_optimistic_intent(expired: &mut Expired) {
    security_council_actions::delete_council_create_optimistic_intent(expired);
}

public fun delete_execute_optimistic_intent(expired: &mut Expired) {
    use futarchy_multisig::optimistic_intents;
    optimistic_intents::delete_execute_optimistic_intent_action(expired);
}

public fun delete_cancel_optimistic_intent(expired: &mut Expired) {
    use futarchy_multisig::optimistic_intents;
    optimistic_intents::delete_cancel_optimistic_intent_action(expired);
}