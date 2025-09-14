/// Config actions dispatcher - processes configuration-related actions
/// Uses Executable with embedded ExecutionContext for sequential processing
module futarchy_actions::config_dispatcher;

use std::type_name;
use sui::bcs;
use account_protocol::account::Account;
use account_protocol::executable::{Self, Executable};
use account_protocol::intents;
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_core::futarchy_config::FutarchyOutcome as ProposalOutcome;
use futarchy_utils::{action_types, version};

// Import config action types
use futarchy_actions::config_actions::{
    Self,
    UpdateNameAction,
    SetProposalsEnabledAction,
    UpdateTradingConfigAction,
    SetMetadataAction,
};

/// Process config-related actions sequentially using action_idx cursor
public fun execute_config_actions(
    executable: &mut Executable<ProposalOutcome>,
    account: &mut Account<FutarchyConfig>,
) {
    let specs = executable::intent(executable).action_specs();
    let total = specs.length();

    // Process actions sequentially from current index
    while (executable::action_idx(executable) < total) {
        let current_idx = executable::action_idx(executable);
        let spec = specs.borrow(current_idx);
        let action_type = intents::action_spec_type(spec);

        // Check if this is a config action
        if (is_config_action(action_type)) {
            // Process the action
            let action_data = intents::action_spec_data(spec);

            if (action_type == type_name::get<action_types::UpdateName>()) {
                let params: UpdateNameAction = bcs::from_bytes(*action_data);
                config_actions::do_update_name(
                    account,
                    params,
                    version::current(),
                );
            }
            else if (action_type == type_name::get<action_types::SetProposalsEnabled>()) {
                let params: SetProposalsEnabledAction = bcs::from_bytes(*action_data);
                config_actions::do_set_proposals_enabled(
                    account,
                    params,
                    version::current(),
                );
            }
            else if (action_type == type_name::get<action_types::UpdateTradingConfig>()) {
                let params: UpdateTradingConfigAction = bcs::from_bytes(*action_data);
                config_actions::do_update_trading_config(
                    account,
                    params,
                    version::current(),
                );
            }
            else if (action_type == type_name::get<action_types::SetMetadata>()) {
                let params: SetMetadataAction = bcs::from_bytes(*action_data);
                config_actions::do_set_metadata(
                    account,
                    params,
                    version::current(),
                );
            };

            // Advance the cursor after processing
            executable::increment_action_idx(executable);
        } else {
            // Not a config action, stop and let next dispatcher handle it
            break
        }
    }
}

/// Helper to check if an action type is a config action
fun is_config_action(action_type: TypeName): bool {
    action_type == type_name::get<action_types::UpdateName>() ||
    action_type == type_name::get<action_types::SetProposalsEnabled>() ||
    action_type == type_name::get<action_types::UpdateTradingConfig>() ||
    action_type == type_name::get<action_types::SetMetadata>()
}