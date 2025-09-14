/// Security council actions dispatcher - processes council-related actions
/// This dispatcher uses ExecutionContext for placeholder-based data passing
module futarchy_multisig::security_council_dispatcher;

use std::type_name;
use sui::bcs;
use sui::clock::Clock;
use account_protocol::account::Account;
use account_protocol::executable::{Self, Executable, ExecutionContext};
use account_protocol::intents;
use account_extensions::extensions::Extensions;
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_dao::proposal::ProposalOutcome;
use futarchy_utils::{action_types, version};

// Import security council action types
use futarchy_multisig::security_council_actions_with_placeholders::{
    Self,
    CreateSecurityCouncilAction,
    SetPolicyFromPlaceholderAction,
};

/// Process security council actions sequentially with ExecutionContext
public fun execute_council_actions(
    executable: &mut Executable<ProposalOutcome>,
    account: &mut Account<FutarchyConfig>,
    extensions: &Extensions,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get mutable reference to context for placeholder operations
    let context = executable::context_mut(executable);
    let specs = executable::intent(executable).action_specs();
    let total = specs.length();

    // Process actions sequentially from current index
    while (executable::action_idx(executable) < total) {
        let current_idx = executable::action_idx(executable);
        let spec = specs.borrow(current_idx);
        let action_type = intents::action_spec_type(spec);

        // Check if this is a council action
        if (is_council_action(action_type)) {
            let action_data = intents::action_spec_data(spec);

            if (action_type == type_name::get<action_types::CreateSecurityCouncil>()) {
                let params: CreateSecurityCouncilAction = bcs::from_bytes(*action_data);

                // This handler writes to placeholder
                security_council_actions_with_placeholders::do_create_council(
                    context,
                    params,
                    extensions,
                    clock,
                    ctx,
                );
            }
            else if (action_type == type_name::get<action_types::SetTypePolicy>()) {
                let params: SetPolicyFromPlaceholderAction = bcs::from_bytes(*action_data);

                // This handler reads from placeholder
                security_council_actions_with_placeholders::do_set_policy_with_context(
                    context,
                    params,
                    account,
                    version::current(),
                );
            };

            // Advance the cursor after processing
            executable::increment_action_idx(executable);
        } else {
            // Not a council action, stop and let next dispatcher handle it
            break
        }
    }
}

/// Helper to check if an action type is a council action
fun is_council_action(action_type: TypeName): bool {
    action_type == type_name::get<action_types::CreateSecurityCouncil>() ||
    action_type == type_name::get<action_types::SetTypePolicy>() ||
    action_type == type_name::get<action_types::UpdateCouncilMembership>() ||
    action_type == type_name::get<action_types::ApproveGeneric>()
}