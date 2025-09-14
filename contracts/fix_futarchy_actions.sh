#!/bin/bash

# Script to fix all Futarchy actions to match the secure Move Framework pattern
# This implements the serialize-then-destroy pattern and type validation

echo "======================================="
echo "Fixing Futarchy Actions Security Pattern"
echo "======================================="

# Fix config_actions.move
echo "Fixing config_actions.move..."
FILE="/Users/admin/monorepo/contracts/futarchy_actions/sources/config/config_actions.move"

# Add imports for action_validation and action_types
sed -i '' '/use futarchy_core::{/a\
\    action_validation,\
\    action_types,
' "$FILE"

# Replace is_current_action with action_validation::assert_action_type
sed -i '' 's/assert!(executable::is_current_action<Outcome, SetProposalsEnabledAction>(executable), EWrongAction);/\/\/ Get the action spec\
    let specs = executable::intent(executable).action_specs();\
    let spec = specs.borrow(executable::action_idx(executable));\
    \
    \/\/ CRITICAL: Assert action type before deserialization\
    action_validation::assert_action_type<action_types::SetProposalsEnabled>(spec);/' "$FILE"

sed -i '' 's/assert!(executable::is_current_action<Outcome, UpdateNameAction>(executable), EWrongAction);/\/\/ Get the action spec\
    let specs = executable::intent(executable).action_specs();\
    let spec = specs.borrow(executable::action_idx(executable));\
    \
    \/\/ CRITICAL: Assert action type before deserialization\
    action_validation::assert_action_type<action_types::UpdateName>(spec);/' "$FILE"

# Add destruction functions for each action type
cat >> "$FILE" << 'EOF'

// === Destruction Functions ===

public fun destroy_set_proposals_enabled(action: SetProposalsEnabledAction) {
    let SetProposalsEnabledAction { enabled: _ } = action;
}

public fun destroy_update_name(action: UpdateNameAction) {
    let UpdateNameAction { new_name: _ } = action;
}

public fun destroy_trading_params_update(action: TradingParamsUpdateAction) {
    let TradingParamsUpdateAction {
        min_asset_amount: _,
        min_stable_amount: _,
        review_period_ms: _,
        trading_period_ms: _,
        amm_total_fee_bps: _
    } = action;
}

public fun destroy_metadata_update(action: MetadataUpdateAction) {
    let MetadataUpdateAction {
        dao_name: _,
        icon_url: _,
        description: _
    } = action;
}

public fun destroy_twap_config_update(action: TwapConfigUpdateAction) {
    let TwapConfigUpdateAction {
        start_delay: _,
        step_max: _,
        initial_observation: _,
        threshold: _
    } = action;
}

public fun destroy_governance_update(action: GovernanceUpdateAction) {
    let GovernanceUpdateAction {
        proposal_creation_enabled: _,
        max_outcomes: _,
        max_actions_per_outcome: _,
        required_bond_amount: _,
        max_intents_per_outcome: _,
        proposal_intent_expiry_ms: _,
        optimistic_challenge_fee: _,
        optimistic_challenge_period_ms: _
    } = action;
}

public fun destroy_metadata_table_update(action: MetadataTableUpdateAction) {
    let MetadataTableUpdateAction {
        keys: _,
        values: _,
        keys_to_remove: _
    } = action;
}

public fun destroy_slash_distribution_update(action: SlashDistributionUpdateAction) {
    let SlashDistributionUpdateAction {
        slasher_reward_bps: _,
        dao_treasury_bps: _,
        protocol_bps: _,
        burn_bps: _
    } = action;
}

public fun destroy_queue_params_update(action: QueueParamsUpdateAction) {
    let QueueParamsUpdateAction {
        max_proposer_funded: _,
        max_concurrent_proposals: _,
        max_queue_size: _,
        fee_escalation_basis_points: _
    } = action;
}
EOF

echo "Config actions fixed."

# Fix liquidity_actions.move
echo "Fixing liquidity_actions.move..."
FILE="/Users/admin/monorepo/contracts/futarchy_actions/sources/liquidity/liquidity_actions.move"

# Add imports
sed -i '' '/use futarchy_core::{/a\
\    action_validation,\
\    action_types,
' "$FILE"

# Fix governance_actions.move
echo "Fixing governance_actions.move..."
FILE="/Users/admin/monorepo/contracts/futarchy_actions/sources/governance/governance_actions.move"

sed -i '' '/use futarchy_core::{/a\
\    action_validation,\
\    action_types,
' "$FILE"

# Fix platform_fee_actions.move
echo "Fixing platform_fee_actions.move..."
FILE="/Users/admin/monorepo/contracts/futarchy_actions/sources/governance/platform_fee_actions.move"

sed -i '' '/use futarchy_core::{/a\
\    action_validation,\
\    action_types,
' "$FILE"

# Replace is_current_action pattern
sed -i '' 's/assert!(executable::is_current_action<Outcome, CollectPlatformFeeAction>(executable), EWrongAction);/\/\/ Get the action spec\
    let specs = executable::intent(executable).action_specs();\
    let spec = specs.borrow(executable::action_idx(executable));\
    \
    \/\/ CRITICAL: Assert action type before deserialization\
    action_validation::assert_action_type<action_types::PlatformFeeWithdraw>(spec);/' "$FILE"

# Fix memo_actions.move
echo "Fixing memo_actions.move..."
FILE="/Users/admin/monorepo/contracts/futarchy_actions/sources/memo/memo_actions.move"

sed -i '' '/use futarchy_core::{/a\
\    action_validation,\
\    action_types,
' "$FILE"

# Replace is_current_action patterns
sed -i '' 's/assert!(executable::is_current_action<Outcome, EmitMemoAction>(executable), EWrongAction);/\/\/ Get the action spec\
    let specs = executable::intent(executable).action_specs();\
    let spec = specs.borrow(executable::action_idx(executable));\
    \
    \/\/ CRITICAL: Assert action type before deserialization\
    action_validation::assert_action_type<action_types::Memo>(spec);/' "$FILE"

# Fix dissolution_actions.move
echo "Fixing dissolution_actions.move..."
FILE="/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/dissolution/dissolution_actions.move"

if [ -f "$FILE" ]; then
    sed -i '' '/use futarchy_core::{/a\
\    action_validation,\
\    action_types,
' "$FILE"
fi

# Fix stream_actions.move
echo "Fixing stream_actions.move..."
FILE="/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/payments/stream_actions.move"

if [ -f "$FILE" ]; then
    sed -i '' '/use futarchy_core::{/a\
\    action_validation,\
\    action_types,
' "$FILE"
fi

# Fix oracle_actions.move
echo "Fixing oracle_actions.move..."
FILE="/Users/admin/monorepo/contracts/futarchy_lifecycle/sources/oracle/oracle_actions.move"

if [ -f "$FILE" ]; then
    sed -i '' '/use futarchy_core::{/a\
\    action_validation,\
\    action_types,
' "$FILE"
fi

# Fix operating_agreement_actions.move
echo "Fixing operating_agreement_actions.move..."
FILE="/Users/admin/monorepo/contracts/futarchy_specialized_actions/sources/legal/operating_agreement_actions.move"

if [ -f "$FILE" ]; then
    sed -i '' '/use futarchy_core::{/a\
\    action_validation,\
\    action_types,
' "$FILE"
fi

# Fix custody_actions.move
echo "Fixing custody_actions.move..."
FILE="/Users/admin/monorepo/contracts/futarchy_vault/sources/custody_actions.move"

if [ -f "$FILE" ]; then
    sed -i '' '/use futarchy_core::{/a\
\    action_validation,\
\    action_types,
' "$FILE"
fi

# Fix security_council_actions.move
echo "Fixing security_council_actions.move..."
FILE="/Users/admin/monorepo/contracts/futarchy_multisig/sources/security_council_actions.move"

if [ -f "$FILE" ]; then
    sed -i '' '/use futarchy_core::{/a\
\    action_validation,\
\    action_types,
' "$FILE"
fi

# Fix policy_actions.move
echo "Fixing policy_actions.move..."
FILE="/Users/admin/monorepo/contracts/futarchy_multisig/sources/policy/policy_actions.move"

if [ -f "$FILE" ]; then
    sed -i '' '/use futarchy_core::{/a\
\    action_validation,\
\    action_types,
' "$FILE"
fi

# Fix all decoder files to use non-deprecated APIs
echo "Fixing decoder files..."

# Find all decoder files
DECODER_FILES=$(find /Users/admin/monorepo/contracts -name "*_decoder.move" | grep -v "/build/")

for FILE in $DECODER_FILES; do
    echo "Fixing decoder: $FILE"

    # Replace deprecated type_name::get with type_name::with_defining_ids
    sed -i '' 's/type_name::get</type_name::with_defining_ids</g' "$FILE"

    # Replace deprecated type_name::get_address with type_name::address_string
    sed -i '' 's/type_name::get_address(/type_name::address_string(/g' "$FILE"

    # Replace deprecated type_name::get_module with type_name::module_string
    sed -i '' 's/type_name::get_module(/type_name::module_string(/g' "$FILE"
done

echo "======================================="
echo "All Futarchy actions have been updated!"
echo "======================================="
echo ""
echo "Next steps:"
echo "1. Review the changes manually"
echo "2. Add new_ functions following serialize-then-destroy pattern"
echo "3. Add delete_ functions for cleanup"
echo "4. Test compilation of all packages"
echo ""
echo "Use the developer guide at FUTARCHY_ACTION_DEVELOPER_GUIDE.md for reference."