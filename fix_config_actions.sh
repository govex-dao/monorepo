#!/bin/bash

# Script to fix all do_* functions in config_actions.move to use proper PTB pattern

# This script will:
# 1. Add type checking with is_current_action
# 2. Replace executable.next_action() with proper BCS deserialization
# 3. Add increment_action_idx at the end of each function

cat << 'EOF'
The config_actions.move file needs to be updated to follow the PTB pattern properly.

Each do_* function should:
1. Check the action type with assert!(executable::is_current_action<Outcome, ActionType>(executable), EWrongAction);
2. Get the action spec and deserialize BCS data manually
3. Execute the action logic
4. Call executable::increment_action_idx(executable) at the end

The functions using executable.next_action() need to be rewritten to:
- Get specs from executable::intent(executable).action_specs()
- Get current spec with specs.borrow(executable::action_idx(executable))
- Get action data with protocol_intents::action_spec_data(spec)
- Check version with protocol_intents::action_spec_version(spec)
- Deserialize with bcs::from_bytes(*action_data)

This follows the same pattern as the move-framework actions in:
/Users/admin/monorepo/contracts/move-framework/packages/actions/sources/lib/

Manual intervention required for each function to determine the correct ActionType struct name.
EOF