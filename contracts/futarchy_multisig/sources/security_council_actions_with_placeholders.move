/// Security council actions upgraded to support placeholder-based data passing
module futarchy_multisig::security_council_actions_with_placeholders;

use sui::object::{Self, ID};
use sui::clock::Clock;
use sui::transfer;
use account_extensions::extensions::Extensions;
use account_protocol::executable::{Self, ExecutionContext};
use futarchy_multisig::security_council::{Self, SecurityCouncil};

// === Action Structs with Placeholders ===

/// Creates a security council and registers its ID in a placeholder
public struct CreateSecurityCouncilAction has store, drop, copy {
    members: vector<address>,
    weights: vector<u64>,
    threshold: u64,
    placeholder_out: u64,  // Where to write the new council's ID
}

/// Sets a policy using a council ID from a placeholder
public struct SetPolicyFromPlaceholderAction has store, drop, copy {
    policy_key: String,
    council_placeholder_in: u64,  // Read council ID from this placeholder
    mode: u8,
}

// === Constructor Functions ===

public fun new_create_council_with_placeholder(
    members: vector<address>,
    weights: vector<u64>,
    threshold: u64,
    placeholder_out: u64,
): CreateSecurityCouncilAction {
    CreateSecurityCouncilAction {
        members,
        weights,
        threshold,
        placeholder_out,
    }
}

public fun new_set_policy_from_placeholder(
    policy_key: String,
    council_placeholder_in: u64,
    mode: u8,
): SetPolicyFromPlaceholderAction {
    SetPolicyFromPlaceholderAction {
        policy_key,
        council_placeholder_in,
        mode,
    }
}

// === Execution Handlers ===

/// Handler that creates council and writes ID to placeholder
public fun do_create_council(
    context: &mut ExecutionContext,
    params: CreateSecurityCouncilAction,
    extensions: &Extensions,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Create the new security council
    let new_council = security_council::new(
        extensions,
        params.members,
        params.weights,
        params.threshold,
        clock,
        ctx,
    );

    // Get the ID before sharing
    let real_id = object::id(&new_council);

    // Write the real ID to the context at the specified placeholder
    executable::register_placeholder(context, params.placeholder_out, real_id);

    // Share the council object
    transfer::public_share_object(new_council);
}

/// Handler that reads council ID from placeholder
public fun do_set_policy_with_context<Config>(
    context: &ExecutionContext,
    params: SetPolicyFromPlaceholderAction,
    account: &mut Account<Config>,
    version: VersionWitness,
) {
    // Read the real council ID from the context using the placeholder
    let council_id = executable::resolve_placeholder(context, params.council_placeholder_in);

    // Now proceed with the resolved ID
    let registry = policy_registry::borrow_registry_mut(account, version);
    policy_registry::set_type_policy_by_name(
        registry,
        object::id(account),
        params.policy_key,
        option::some(council_id),
        params.mode,
    );
}