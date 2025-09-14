/// Security council intent creation with placeholder wiring
module futarchy_multisig::security_council_intents_with_placeholders;

use std::string::String;
use std::type_name;
use account_protocol::intents::{Self, Intent};
use account_protocol::account::Account;
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_multisig::security_council_actions_with_placeholders::{
    Self,
    CreateSecurityCouncilAction,
    SetPolicyFromPlaceholderAction,
};
use futarchy_core::action_types;
use futarchy_utils::policy_registry;

/// Intent witness for security council operations
public struct CreateAndRegisterCouncilIntent has drop {}

/// Creates a council and immediately registers it as a policy custodian.
/// This demonstrates the power of placeholders - actions can depend on outputs of previous actions.
public fun request_create_and_register_council<Outcome: store + drop + copy>(
    dao: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: Outcome,
    members: vector<address>,
    weights: vector<u64>,
    threshold: u64,
    policy_key: String,
    policy_mode: u8,
    ctx: &mut TxContext,
) {
    dao.build_intent!(
        params,
        outcome,
        b"create_and_register_council".to_string(),
        version::current(),
        CreateAndRegisterCouncilIntent {},
        ctx,
        |intent, iw| {
            // STEP 1: Reserve a placeholder for the council we are about to create.
            // This returns a unique ID (e.g., 0) that we'll use to wire actions together
            let council_placeholder = intents::reserve_placeholder_id(&mut intent);

            // STEP 2: Create the "Create Council" action.
            // Tell it to write its output (the new council's ID) to our reserved placeholder.
            let create_action = security_council_actions_with_placeholders::new_create_council_with_placeholder(
                members,
                weights,
                threshold,
                council_placeholder, // placeholder_out: 0
            );

            // Add the action to the intent with its type witness
            intents::add_action_spec(
                &mut intent,
                create_action,
                action_types::CreateSecurityCouncil {},
                iw,
            );

            // STEP 3: Create the "Set Policy" action.
            // Tell it to read the council ID from our reserved placeholder.
            let policy_action = security_council_actions_with_placeholders::new_set_policy_from_placeholder(
                policy_key,
                council_placeholder, // placeholder_in: 0 (same placeholder - read what was written)
                policy_mode,
            );

            // Add the policy action to the intent
            intents::add_action_spec(
                &mut intent,
                policy_action,
                action_types::SetTypePolicy {},
                iw,
            );

            // The result: When executed, action 1 creates a council and stores its ID in placeholder 0.
            // Action 2 then reads from placeholder 0 to get the council ID and sets it as a policy.
            // This all happens atomically in a single transaction!
        }
    );
}

/// Example of a more complex workflow: Create multiple councils and link them
public fun request_create_parent_child_councils<Outcome: store + drop + copy>(
    dao: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: Outcome,
    parent_members: vector<address>,
    parent_weights: vector<u64>,
    parent_threshold: u64,
    child_members: vector<address>,
    child_weights: vector<u64>,
    child_threshold: u64,
    ctx: &mut TxContext,
) {
    dao.build_intent!(
        params,
        outcome,
        b"create_parent_child_councils".to_string(),
        version::current(),
        CreateAndRegisterCouncilIntent {},
        ctx,
        |intent, iw| {
            // Reserve placeholders for both councils
            let parent_placeholder = intents::reserve_placeholder_id(&mut intent);  // 0
            let child_placeholder = intents::reserve_placeholder_id(&mut intent);   // 1

            // Create parent council
            let create_parent = security_council_actions_with_placeholders::new_create_council_with_placeholder(
                parent_members,
                parent_weights,
                parent_threshold,
                parent_placeholder,
            );
            intents::add_action_spec(&mut intent, create_parent, action_types::CreateSecurityCouncil {}, iw);

            // Create child council
            let create_child = security_council_actions_with_placeholders::new_create_council_with_placeholder(
                child_members,
                child_weights,
                child_threshold,
                child_placeholder,
            );
            intents::add_action_spec(&mut intent, create_child, action_types::CreateSecurityCouncil {}, iw);

            // Set parent as policy for upgrades
            let set_parent_policy = security_council_actions_with_placeholders::new_set_policy_from_placeholder(
                b"package_upgrade".to_string(),
                parent_placeholder,
                policy_registry::MODE_COUNCIL_ONLY(),
            );
            intents::add_action_spec(&mut intent, set_parent_policy, action_types::SetTypePolicy {}, iw);

            // Set child as policy for treasury operations
            let set_child_policy = security_council_actions_with_placeholders::new_set_policy_from_placeholder(
                b"treasury_spend".to_string(),
                child_placeholder,
                policy_registry::MODE_DAO_AND_COUNCIL(),
            );
            intents::add_action_spec(&mut intent, set_child_policy, action_types::SetTypePolicy {}, iw);
        }
    );
}