#!/bin/bash

# Update all action type instantiations to use constructor functions

# Map of action types to their constructor functions
declare -A CONSTRUCTORS=(
    ["AddCoinType"]="add_coin_type()"
    ["AddLiquidity"]="add_liquidity()"
    ["BatchDistribute"]="batch_distribute()"
    ["BatchOperatingAgreement"]="batch_operating_agreement()"
    ["ConditionalMint"]="conditional_mint()"
    ["CreateCommitmentProposal"]="create_commitment_proposal()"
    ["CreateOperatingAgreement"]="create_operating_agreement()"
    ["ExecuteCommitment"]="execute_commitment()"
    ["FinalizeDissolution"]="finalize_dissolution()"
    ["GovernanceUpdate"]="governance_update()"
    ["InitiateDissolution"]="initiate_dissolution()"
    ["InsertLineAfter"]="insert_line_after()"
    ["InsertLineAtBeginning"]="insert_line_at_beginning()"
    ["MetadataUpdate"]="metadata_update()"
    ["QueueParamsUpdate"]="queue_params_update()"
    ["ReadOraclePrice"]="read_oracle_price()"
    ["RemoveCoinType"]="remove_coin_type()"
    ["RemoveLine"]="remove_line()"
    ["RemoveLiquidity"]="remove_liquidity()"
    ["SetProposalsEnabled"]="set_proposals_enabled()"
    ["SlashDistributionUpdate"]="slash_distribution_update()"
    ["TieredMint"]="tiered_mint()"
    ["TradingParamsUpdate"]="trading_params_update()"
    ["TwapConfigUpdate"]="twap_config_update()"
    ["UpdateCommitmentRecipient"]="update_commitment_recipient()"
    ["UpdateLine"]="update_line()"
    ["UpdateName"]="update_name()"
    ["WithdrawUnlockedTokens"]="withdraw_unlocked_tokens()"
)

# Files to update
FILES=(
    "futarchy_actions/sources/config/config_intents.move"
    "futarchy_actions/sources/intent_lifecycle/commitment_intents.move"
    "futarchy_actions/sources/liquidity/liquidity_intents.move"
    "futarchy_actions/sources/vault_governance_intents.move"
    "futarchy_lifecycle/sources/dissolution/dissolution_intents.move"
    "futarchy_lifecycle/sources/oracle/oracle_intents.move"
    "futarchy_specialized_actions/sources/legal/operating_agreement_intents.move"
)

for file in "${FILES[@]}"; do
    echo "Updating $file"
    for type in "${!CONSTRUCTORS[@]}"; do
        constructor="${CONSTRUCTORS[$type]}"
        sed -i '' "s/action_types::${type} {}/action_types::${constructor}/g" "$file"
    done
done

echo "Done updating action type instantiations"