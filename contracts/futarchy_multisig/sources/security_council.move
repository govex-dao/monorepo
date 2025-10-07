module futarchy_multisig::security_council;

// === Imports ===

use std::string::String;
use sui::clock::Clock;
use sui::tx_context::TxContext;

use account_extensions::extensions::Extensions;

use account_protocol::{
    account::{Self, Account, Auth},
    deps,
    executable::Executable,
    user::User,
};

use futarchy_core::{version, futarchy_config::{Self, FutarchyConfig}};
use futarchy_multisig::weighted_multisig::{Self, WeightedMultisig, Approvals};
use futarchy_multisig::fee_state;

// === Errors ===

const EDaoPaused: u64 = 0;
const EDaoMismatch: u64 = 1;
const EDaoRequired: u64 = 2;
const EDaoNotAllowed: u64 = 3;

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
        Witness{},
        ctx,
        || deps::new_latest_extensions(
            extensions,
            vector[
                b"AccountProtocol".to_string(),
                b"Futarchy".to_string(),
                b"AccountActions".to_string(),
            ]
        )
    );

    // Initialize fee state
    fee_state::init_fee_state(&mut account, clock);

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
    dao_id: ID,  // REQUIRED, not Option
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
public fun authenticate(
    account: &Account<WeightedMultisig>,
    ctx: &TxContext
): Auth {
    account_protocol::account_interface::create_auth!(
        account,
        version::current(),
        Witness{},
        || weighted_multisig::assert_is_member(account.config(), ctx.sender())
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

    // CRITICAL: Check fees are current (ZERO shared object access!)
    fee_state::assert_fees_current(account, clock);

    // Verify membership before the macro (this borrow ends at return)
    weighted_multisig::assert_is_member(config, ctx.sender());

    account_protocol::account_interface::resolve_intent!(
        account,
        key,
        version::current(),
        Witness{},
        |outcome_mut: &mut Approvals| {
            // Insert approver without borrowing config in this closure
            weighted_multisig::approve_sender_verified(outcome_mut, ctx.sender());
        }
    );

    // Bump activity after successful approval
    let config = account::config_mut(account, version::current(), Witness{});
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
    let dao_state = account_protocol::account::borrow_managed_data<FutarchyConfig, futarchy_config::DaoStateKey, futarchy_config::DaoState>(
        dao_account,
        futarchy_config::new_dao_state_key(),
        version::current()
    );
    assert!(
        futarchy_config::operational_state(dao_state) != futarchy_config::state_paused(),
        EDaoPaused
    );

    // CRITICAL: Check fees are current (ZERO shared object access!)
    fee_state::assert_fees_current(account, clock);

    // Verify membership before the macro (this borrow ends at return)
    weighted_multisig::assert_is_member(config, ctx.sender());

    account_protocol::account_interface::resolve_intent!(
        account,
        key,
        version::current(),
        Witness{},
        |outcome_mut: &mut Approvals| {
            // Insert approver without borrowing config in this closure
            weighted_multisig::approve_sender_verified(outcome_mut, ctx.sender());
        }
    );

    // Bump activity after successful approval
    let config = account::config_mut(account, version::current(), Witness{});
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
        Witness{},
        ctx,
        |outcome: Approvals| {
            // final check before allowing execution
            weighted_multisig::validate_outcome(outcome, account.config(), b"".to_string(), clock);
        }
    );

    // Bump activity after successful execution
    let config = account::config_mut(account, version::current(), Witness{});
    weighted_multisig::bump_last_activity(config, clock);

    executable
}

/// Execute an already-approved intent (DAO-linked security council).
/// Validates that:
/// 1. The council belongs to the provided DAO (dao_id matches)
/// 2. The DAO is not paused
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

    // Check DAO operational state via dynamic field
    let dao_state = account_protocol::account::borrow_managed_data<FutarchyConfig, futarchy_config::DaoStateKey, futarchy_config::DaoState>(
        dao_account,
        futarchy_config::new_dao_state_key(),
        version::current()
    );
    assert!(
        futarchy_config::operational_state(dao_state) != futarchy_config::state_paused(),
        EDaoPaused
    );

    let executable = account_protocol::account_interface::execute_intent!(
        account,
        key,
        clock,
        version::current(),
        Witness{},
        ctx,
        |outcome: Approvals| {
            // final check before allowing execution
            weighted_multisig::validate_outcome(outcome, account.config(), b"".to_string(), clock);
        }
    );

    // Bump activity after successful execution
    let config = account::config_mut(account, version::current(), Witness{});
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
    let config = account::config_mut(account, version::current(), Witness{});
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
    account_protocol::user::send_invite(account, recipient, Witness{}, ctx);
}

/// User accepts an invitation and joins the security council.
/// This adds the council to the user's tracked accounts for easy discovery.
///
/// UX Benefits:
/// - User's wallet shows all councils they belong to
/// - Single source of truth for "which councils am I a member of?"
/// - Explicit opt-in creates accountability
public entry fun join(
    user: &mut User,
    account: &Account<WeightedMultisig>,
    ctx: &TxContext,
) {
    // Verify the user is actually a council member
    weighted_multisig::assert_is_member(account.config(), ctx.sender());

    // Add council to user's tracked accounts
    user.add_account(account, Witness{});
}

/// User leaves the security council tracking.
/// This removes the council from the user's tracked accounts.
///
/// Note: This doesn't remove their actual council membership - only removes
/// the council from their personal account tracking. They remain a member
/// with voting power until removed via update_membership().
public entry fun leave(
    user: &mut User,
    account: &Account<WeightedMultisig>,
) {
    // Remove council from user's tracked accounts
    user.remove_account(account, Witness{});
}