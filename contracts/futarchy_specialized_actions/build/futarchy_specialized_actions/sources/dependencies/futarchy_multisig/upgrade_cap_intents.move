/// DAO-side helper to approve accepting/locking an UpgradeCap (2-of-2 flow).
module futarchy_multisig::upgrade_cap_intents;

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
use sui::package::UpgradeCap;
use futarchy_core::version;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_vault::custody_actions;

/// Intent witness for upgrade-cap approvals
public struct UpgradeCapIntent has copy, drop {}

/// Create an intent that approves accepting/locking an UpgradeCap (2-of-2 co-exec).
public fun create_approve_accept_upgrade_cap_intent<Outcome: store + drop + copy>(
    dao: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: Outcome,
    cap_id: ID,
    package_name: String, // resource_key
    expires_at: u64,
    ctx: &mut TxContext
) {
    let dao_id = object::id(dao); // Get ID before the macro
    
    dao.build_intent!(
        params,
        outcome,
        b"approve_accept_upgrade_cap".to_string(),
        version::current(),
        UpgradeCapIntent{},
        ctx,
        |intent, iw| {
            // Typed DAO-side approve custody for UpgradeCap
            let action = custody_actions::new_approve_custody<UpgradeCap>(
                dao_id,
                cap_id,
                package_name,
                b"".to_string(),
                expires_at
            );
            intent.add_action(action, iw);
        }
    );
}