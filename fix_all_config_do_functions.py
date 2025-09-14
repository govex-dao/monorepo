#!/usr/bin/env python3

import re

# Map of function names to their action types
function_action_map = {
    "do_update_metadata": "MetadataUpdateAction",
    "do_update_twap_config": "TwapConfigUpdateAction",
    "do_update_governance": "GovernanceUpdateAction",
    "do_update_metadata_table": "MetadataTableUpdateAction",
    "do_update_queue_params": "QueueParamsUpdateAction",
    "do_update_slash_distribution": "SlashDistributionUpdateAction",
    "do_batch_config": "ConfigAction",
    "do_update_twap_params": "TradingParamsUpdateAction",  # Assuming this is related to trading params
    "do_update_fee_params": "TradingParamsUpdateAction",  # Assuming this is also trading params
}

template = """
The following functions need to be fixed to follow the PTB pattern:

1. Replace the line:
   let action: &{action_type} = executable.next_action(intent_witness);

   With:
   // Verify this is the current action
   assert!(executable::is_current_action<Outcome, {action_type}>(executable), EWrongAction);

   // Get BCS bytes from ActionSpec
   let specs = executable::intent(executable).action_specs();
   let spec = specs.borrow(executable::action_idx(executable));
   let action_data = protocol_intents::action_spec_data(spec);

   // Check version before deserialization
   let spec_version = protocol_intents::action_spec_version(spec);
   assert!(spec_version == 1, EUnsupportedActionVersion);

   // Deserialize the action
   let action: {action_type} = bcs::from_bytes(*action_data);

2. Add before the closing brace of each function:
   // Increment action index
   executable::increment_action_idx(executable);

Functions to fix:
"""

for func_name, action_type in function_action_map.items():
    template += f"- {func_name} (uses {action_type})\n"

print(template)

print("\nNote: do_batch_config might need special handling as it likely processes multiple ConfigActions.")
print("The internal functions (ending with _internal) don't take executable and should not be modified.")