/// DAO-side helper to approve accepting/locking an UpgradeCap (2-of-2 flow).
module futarchy::upgrade_cap_intents;

use account_protocol::{
    account::{Self, Account},
    intents::{Intent, Params},
    intent_interface,
};
use fun intent_interface::build_intent as Account.build_intent;
use sui::{
    object::{Self, ID},
    tx_context::TxContext,
};
use std::string::{Self, String};
use futarchy::{
    version,
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome},
    security_council_actions,
};

/// Intent witness for upgrade-cap approvals
public struct UpgradeCapIntent has copy, drop {}

/// Create an intent that approves accepting/locking an UpgradeCap (2-of-2 co-exec).
public fun create_approve_accept_upgrade_cap_intent(
    dao: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: FutarchyOutcome,
    cap_id: ID,
    package_name: String,
    expires_at: u64,
    ctx: &mut TxContext
) {
    let dao_id = object::id(dao); // Get ID before the macro
    
    // Use typed approval (cap_id, package_name)
    dao.build_intent!(
        params,
        outcome,
        b"approve_accept_upgrade_cap".to_string(),
        version::current(),
        UpgradeCapIntent{},
        ctx,
        |intent, iw| {
            let action = security_council_actions::new_approve_upgrade_cap(
                dao_id,
                cap_id,
                package_name,
                expires_at
            );
            intent.add_action(action, iw);
        }
    );
}