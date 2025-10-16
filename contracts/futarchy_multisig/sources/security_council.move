module futarchy_multisig::security_council;

use account_extensions::extensions::Extensions;
use account_protocol::account::{Self, Account, Auth};
use account_protocol::deps;
use account_protocol::executable::Executable;
use account_protocol::user::User;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_core::version;
use futarchy_multisig::weighted_multisig::{Self, WeightedMultisig, Approvals};
use std::string::String;
use sui::clock::Clock;
use sui::tx_context::TxContext;

// === Imports ===

// === Errors ===

const EDaoPaused: u64 = 0;
const EDaoMismatch: u64 = 1;
const EDaoRequired: u64 = 2;
const EDaoNotAllowed: u64 = 3;
const EDeadManSwitchTriggered: u64 = 4;
const EDeadManSwitchNotEligible: u64 = 5;
const ENoDeadManSwitch: u64 = 6;

// === Witness ===

/// Unique witness for this config module
public struct Witness has drop {}

public fun witness(): Witness {
    Witness {}
}

// === Security Council factory and governance helpers ===

/// Create a new DAO-linked Security Council with REQUIRED dao_id.
/// This is the primary constructor for security councils that belong to a DAO.
/// Automatically sets the dead-man switch recipient to the parent DAO.
///
/// Internal helper: Create multisig account with common initialization
/// Shared by new_dao_council() and new_standalone()
fun create_multisig_account(
    extensions: &Extensions,
    config: WeightedMultisig,
    clock: &Clock,
    ctx: &mut TxContext,
): Account<WeightedMultisig> {
    let mut account = account_protocol::account_interface::create_account!(
        config,
        version::current(),
        Witness {},
        ctx,
        || deps::new_latest_extensions(
            extensions,
            vector[
                b"AccountProtocol".to_string(),
                b"Futarchy".to_string(),
                b"AccountActions".to_string(),
            ],
        ),
    );

    account
}

/// Parameters:
/// - dao_id: REQUIRED - The ID of the parent DAO that owns this council
/// - members: Council member addresses
/// - weights: Voting weights for each member
/// - threshold: Total weight required to approve actions
/// - clock: Clock for timestamp initialization
public fun new_dao_council(
    extensions: &Extensions,
    dao_id: ID, // REQUIRED, not Option
    members: vector<address>,
    weights: vector<u64>,
    threshold: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Account<WeightedMultisig> {
    // Build multisig config
    let mut config = weighted_multisig::new(members, weights, threshold, clock);

    // Set the required DAO ID
    weighted_multisig::set_dao_id(&mut config, dao_id);

    // Automatically set dead-man switch recipient to the DAO
    // recipient_dao_id = None means the recipient IS the DAO itself
    weighted_multisig::set_dead_man_switch_recipient(&mut config, dao_id, option::none());

    create_multisig_account(extensions, config, clock, ctx)
}

/// Create a standalone multisig (NO DAO link).
/// Use this for independent multisigs that don't belong to any DAO.
/// For DAO security councils, use new_dao_council() instead.
public fun new_standalone(
    extensions: &Extensions,
    members: vector<address>,
    weights: vector<u64>,
    threshold: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Account<WeightedMultisig> {
    // Build multisig config WITHOUT dao_id
    let config = weighted_multisig::new(members, weights, threshold, clock);

    create_multisig_account(extensions, config, clock, ctx)
}

/// DEPRECATED: Use new_dao_council() or new_standalone() instead.
/// Kept for backward compatibility only.
public fun new(
    extensions: &Extensions,
    members: vector<address>,
    weights: vector<u64>,
    threshold: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Account<WeightedMultisig> {
    new_standalone(extensions, members, weights, threshold, clock, ctx)
}

/// Authenticate a sender as a council member. Returns an Auth usable for gated calls.
public fun authenticate(account: &Account<WeightedMultisig>, ctx: &TxContext): Auth {
    account_protocol::account_interface::create_auth!(
        account,
        version::current(),
        Witness {},
        || weighted_multisig::assert_is_member(account.config(), ctx.sender()),
    )
}

/// A council member approves a pending intent (standalone multisig, no DAO).
/// The council MUST NOT have a dao_id set.
/// For DAO-linked councils, use approve_intent_with_dao().
public fun approve_intent(
    account: &mut Account<WeightedMultisig>,
    key: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let config = account.config();

    // Assert this is a standalone multisig (no DAO)
    assert!(weighted_multisig::dao_id(config).is_none(), EDaoNotAllowed);

    // Verify membership before the macro (this borrow ends at return)
    weighted_multisig::assert_is_member(config, ctx.sender());

    account_protocol::account_interface::resolve_intent!(
        account,
        key,
        version::current(),
        Witness {},
        |outcome_mut: &mut Approvals| {
            // Insert approver without borrowing config in this closure
            weighted_multisig::approve_sender_verified(outcome_mut, ctx.sender());
        },
    );

    // Bump activity after successful approval
    let config = account::config_mut(account, version::current(), Witness {});
    weighted_multisig::bump_last_activity(config, clock);
}

/// A council member approves a pending intent (DAO-linked security council).
/// Validates that:
/// 1. The council belongs to the provided DAO (dao_id matches)
/// 2. The DAO is not paused
/// 3. Multisig fees are current
public fun approve_intent_with_dao(
    account: &mut Account<WeightedMultisig>,
    dao_account: &Account<FutarchyConfig>,
    key: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate DAO relationship and pause state
    let config = account.config();
    let council_dao_id = weighted_multisig::dao_id(config);

    // Council MUST have a parent DAO
    assert!(council_dao_id.is_some(), EDaoRequired);
    let expected_dao_id = *council_dao_id.borrow();
    assert!(object::id(dao_account) == expected_dao_id, EDaoMismatch);

    // Check DAO operational state via dynamic field
    let dao_state = account_protocol::account::borrow_managed_data<
        FutarchyConfig,
        futarchy_config::DaoStateKey,
        futarchy_config::DaoState,
    >(
        dao_account,
        futarchy_config::new_dao_state_key(),
        version::current(),
    );
    assert!(
        futarchy_config::operational_state(dao_state) != futarchy_config::state_paused(),
        EDaoPaused,
    );

    // Verify membership before the macro (this borrow ends at return)
    weighted_multisig::assert_is_member(config, ctx.sender());

    account_protocol::account_interface::resolve_intent!(
        account,
        key,
        version::current(),
        Witness {},
        |outcome_mut: &mut Approvals| {
            // Insert approver without borrowing config in this closure
            weighted_multisig::approve_sender_verified(outcome_mut, ctx.sender());
        },
    );

    // Bump activity after successful approval
    let config = account::config_mut(account, version::current(), Witness {});
    weighted_multisig::bump_last_activity(config, clock);
}

/// Execute an already-approved intent (standalone multisig, no DAO).
/// The council MUST NOT have a dao_id set.
/// For DAO-linked councils, use execute_intent_with_dao().
public fun execute_intent(
    account: &mut Account<WeightedMultisig>,
    key: String,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<Approvals> {
    let config = account.config();

    // Assert this is a standalone multisig (no DAO)
    assert!(weighted_multisig::dao_id(config).is_none(), EDaoNotAllowed);

    let executable = account_protocol::account_interface::execute_intent!(
        account,
        key,
        clock,
        version::current(),
        Witness {},
        ctx,
        |outcome: Approvals| {
            // final check before allowing execution
            weighted_multisig::validate_outcome(outcome, account.config(), b"".to_string(), clock);
        },
    );

    // Bump activity after successful execution
    let config = account::config_mut(account, version::current(), Witness {});
    weighted_multisig::bump_last_activity(config, clock);

    executable
}

/// Execute an already-approved intent (DAO-linked security council).
/// Validates that:
/// 1. The council belongs to the provided DAO (dao_id matches)
/// 2. The DAO is not paused
/// 3. The dead man switch has not been triggered
public fun execute_intent_with_dao(
    account: &mut Account<WeightedMultisig>,
    dao_account: &Account<FutarchyConfig>,
    key: String,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<Approvals> {
    // Validate DAO relationship and pause state
    let config = account.config();
    let council_dao_id = weighted_multisig::dao_id(config);

    // Council MUST have a parent DAO
    assert!(council_dao_id.is_some(), EDaoRequired);
    let expected_dao_id = *council_dao_id.borrow();
    assert!(object::id(dao_account) == expected_dao_id, EDaoMismatch);

    // Check if dead man switch has been triggered
    assert!(
        !weighted_multisig::is_dead_man_switch_triggered(config),
        EDeadManSwitchTriggered,
    );

    // Check DAO operational state via dynamic field
    let dao_state = account_protocol::account::borrow_managed_data<
        FutarchyConfig,
        futarchy_config::DaoStateKey,
        futarchy_config::DaoState,
    >(
        dao_account,
        futarchy_config::new_dao_state_key(),
        version::current(),
    );
    assert!(
        futarchy_config::operational_state(dao_state) != futarchy_config::state_paused(),
        EDaoPaused,
    );

    let executable = account_protocol::account_interface::execute_intent!(
        account,
        key,
        clock,
        version::current(),
        Witness {},
        ctx,
        |outcome: Approvals| {
            // final check before allowing execution
            weighted_multisig::validate_outcome(outcome, account.config(), b"".to_string(), clock);
        },
    );

    // Bump activity after successful execution
    let config = account::config_mut(account, version::current(), Witness {});
    weighted_multisig::bump_last_activity(config, clock);

    executable
}

/// Optional explicit heartbeat to signal council is still active
public entry fun heartbeat(
    account: &mut Account<WeightedMultisig>,
    clock: &Clock,
    ctx: &TxContext,
) {
    // Verify membership
    weighted_multisig::assert_is_member(account.config(), ctx.sender());

    // Bump activity
    let config = account::config_mut(account, version::current(), Witness {});
    weighted_multisig::bump_last_activity(config, clock);
}

// === User Invitation System ===

/// A council member sends an invitation to a user to join the security council.
/// The recipient must already be a member of the council (added via membership update).
/// This creates an explicit opt-in flow where users acknowledge their membership.
///
/// Security:
/// - Sender must be a council member
/// - Recipient must already be a council member (can't invite outsiders)
/// - Prevents phishing attacks (only legitimate members can be invited)
public entry fun send_invite(
    account: &Account<WeightedMultisig>,
    recipient: address,
    ctx: &mut TxContext,
) {
    // Validate sender is a member
    weighted_multisig::assert_is_member(account.config(), ctx.sender());

    // Validate recipient is already a member (can't invite non-members)
    weighted_multisig::assert_is_member(account.config(), recipient);

    // Send invite through Account Protocol's user module
    account_protocol::user::send_invite(account, recipient, Witness {}, ctx);
}

/// User accepts an invitation and joins the security council.
/// This adds the council to the user's tracked accounts for easy discovery.
///
/// UX Benefits:
/// - User's wallet shows all councils they belong to
/// - Single source of truth for "which councils am I a member of?"
/// - Explicit opt-in creates accountability
public entry fun join(user: &mut User, account: &Account<WeightedMultisig>, ctx: &TxContext) {
    // Verify the user is actually a council member
    weighted_multisig::assert_is_member(account.config(), ctx.sender());

    // Add council to user's tracked accounts
    user.add_account(account, Witness {});
}

/// User leaves the security council tracking.
/// This removes the council from the user's tracked accounts.
///
/// Note: This doesn't remove their actual council membership - only removes
/// the council from their personal account tracking. They remain a member
/// with voting power until removed via update_membership().
public entry fun leave(user: &mut User, account: &Account<WeightedMultisig>) {
    // Remove council from user's tracked accounts
    user.remove_account(account, Witness {});
}

// === Dead Man Switch Failover & Recovery ===

/// Trigger the Dead Man Switch failover to parent DAO.
/// This is a PERMISSIONLESS function - anyone can call when eligibility conditions are met.
///
/// ## What This Does:
/// 1. Validates eligibility (inactivity timeout exceeded, correct recipient, etc.)
/// 2. Marks the council as inactive (sets `dead_man_switch.triggered = true`)
/// 3. Blocks all future council-initiated intent execution
/// 4. Enables DAO-controlled recovery intents
///
/// ## What Happens Next:
/// The parent DAO can now create and execute recovery intents on the council:
/// - Use `create_dao_recovery_intent()` to create intents (requires DAO governance approval)
/// - Use `execute_dao_recovery_intent()` to execute them (permissionless cranking)
/// - Recovery intents can:
///   - Cancel streams/vesting
///   - Transfer coins/objects to DAO or new council
///   - Clean up any council resources
///
/// ## Why Permissionless?
/// Dead man switches should be triggerable by anyone when conditions are met.
/// This prevents situations where the council is inactive AND no one can trigger recovery.
///
/// ## Security:
/// - Can only be triggered ONCE (subsequent calls fail)
/// - Requires strict validation (timeout exceeded, correct recipient, DAO relationship)
/// - Does NOT automatically transfer assets (DAO controls recovery via governance)
///
/// ## Eligibility Requirements:
/// 1. Council has a dead man switch configured
/// 2. Timeout is enabled (> 0)
/// 3. Inactivity period exceeds timeout
/// 4. Council belongs to a DAO (not standalone)
/// 5. Recipient is the parent DAO
/// 6. Dead man switch has not already been triggered
///
/// Parameters:
/// - inactive_council: The council that has been inactive
/// - dao_id: The ID of the parent DAO (used for validation)
/// - clock: Clock for timestamp validation
public entry fun trigger_dead_man_switch_to_dao(
    inactive_council: &mut Account<WeightedMultisig>,
    dao_id: ID,
    clock: &Clock,
) {
    let config = inactive_council.config();

    // Validate eligibility (this checks all 6 requirements above)
    assert!(
        weighted_multisig::can_trigger_dead_man_switch_for_dao(config, dao_id, clock),
        EDeadManSwitchNotEligible,
    );

    // Mark the council as inactive (blocks council-initiated intents, enables DAO recovery)
    let config_mut = account::config_mut(inactive_council, version::current(), Witness {});
    weighted_multisig::mark_dead_man_switch_triggered(config_mut);

    // TODO: Emit event for off-chain monitoring
    // Example: emit DeadManSwitchTriggered { council_id, dao_id, triggered_at }
}

/// Create a recovery intent on an inactive council (recipient account control).
///
/// ## Purpose:
/// After dead man switch triggers, the recipient account needs a way to clean up council assets.
/// This function allows the recipient to create intents on the inactive council account.
///
/// ## Use Cases:
/// - Cancel streams/vesting from the council
/// - Transfer coins/objects from council → recipient or new council
/// - Execute any cleanup actions using existing action system
///
/// ## Generic Design:
/// - Works with ANY recipient account type (FutarchyConfig, WeightedMultisig, custom configs)
/// - Recipient just needs to match the council's configured dead_man_switch_recipient
///
/// ## Security Model:
/// - Can ONLY be called after dead man switch triggered
/// - Recipient account ID must match council's dead_man_switch_recipient
/// - Intent is stored in council's intents bag (like normal intents)
/// - Execution is permissionless (anyone can crank via `execute_dao_recovery_intent`)
///
/// ## Parameters:
/// - inactive_council: The council marked as inactive
/// - recipient_account_id: The ID of the recipient account (for validation)
/// - params: Intent parameters (key, description, execution time, etc.)
/// - clock: Clock for timestamp validation
///
/// ## Returns:
/// - Intent that can be filled with actions by the caller
public fun create_recovery_intent(
    inactive_council: &Account<WeightedMultisig>,
    recipient_account_id: ID,
    params: account_protocol::intents::Params,
    clock: &Clock,
    ctx: &mut TxContext,
): account_protocol::intents::Intent<Approvals> {
    let config = inactive_council.config();

    // Validate dead man switch was triggered
    assert!(
        weighted_multisig::is_dead_man_switch_triggered(config),
        EDeadManSwitchNotEligible,
    );

    // Validate recipient account ID matches configured recipient
    assert!(weighted_multisig::dead_man_switch_recipient(config).is_some(), ENoDeadManSwitch);
    let expected_recipient_id = *weighted_multisig::dead_man_switch_recipient(config).borrow();
    assert!(recipient_account_id == expected_recipient_id, EDaoMismatch);

    // Create intent with empty Approvals (no approval needed for recovery)
    account::create_intent(
        inactive_council,
        params,
        weighted_multisig::new_approvals(config), // Empty approvals - instant execution
        b"recovery".to_string(),
        version::current(),
        Witness {},
        ctx,
    )
}

/// Execute a recovery intent on an inactive council (permissionless cranking).
///
/// ## Purpose:
/// Anyone can execute recovery intents once they're ready.
/// This enables permissionless "cranking" of the recovery process.
///
/// ## Generic Design:
/// - No account type restrictions - validates via ID only
/// - Works for any recipient account type (DAO, multisig, custom)
///
/// ## Security:
/// - Intent must have been created via `create_recovery_intent()`
/// - Dead man switch must still be triggered
/// - Recipient account ID validated
/// - Returns Executable hot potato that MUST be processed
///
/// ## Parameters:
/// - inactive_council: The council marked as inactive
/// - recipient_account_id: The ID of the recipient account (for validation)
/// - key: The intent key (from create_recovery_intent)
/// - clock: Clock for execution time validation
///
/// ## Returns:
/// - Executable hot potato that must be processed by action handlers
public fun execute_recovery_intent(
    inactive_council: &mut Account<WeightedMultisig>,
    recipient_account_id: ID,
    key: String,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<Approvals> {
    let config = inactive_council.config();

    // Validate dead man switch is still triggered
    assert!(
        weighted_multisig::is_dead_man_switch_triggered(config),
        EDeadManSwitchNotEligible,
    );

    // Validate recipient account ID matches configured recipient
    assert!(weighted_multisig::dead_man_switch_recipient(config).is_some(), ENoDeadManSwitch);
    let expected_recipient_id = *weighted_multisig::dead_man_switch_recipient(config).borrow();
    assert!(recipient_account_id == expected_recipient_id, EDaoMismatch);

    // Create executable (no outcome validation needed - already validated during creation)
    let (outcome, executable) = account::create_executable(
        inactive_council,
        key,
        clock,
        version::current(),
        Witness {},
        ctx,
    );

    // No validation needed - recovery intents have empty approvals
    let Approvals { approvers: _, created_at_nonce: _, created_at_ms: _, earliest_execution_ms: _ } = outcome;

    executable
}
