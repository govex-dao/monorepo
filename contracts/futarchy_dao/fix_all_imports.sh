#!/bin/bash

cd /Users/admin/monorepo/contracts/futarchy

# Step 1: Fix the double "use futarchy_core::futarchy_config;" lines
find sources -name "*.move" -exec sed -i '' '/^use futarchy_core::futarchy_config;$/d' {} \;

# Step 2: Fix imports that should be from futarchy_core
find sources -name "*.move" -exec sed -i '' 's/use futarchy_markets::$/use futarchy_core::/g' {} \;
find sources -name "*.move" -exec sed -i '' 's/    futarchy_config/use futarchy_core::futarchy_config/g' {} \;
find sources -name "*.move" -exec sed -i '' 's/    config_dispatcher/use futarchy::config_dispatcher/g' {} \;
find sources -name "*.move" -exec sed -i '' 's/    config_actions/use futarchy::config_actions/g' {} \;

# Step 3: Fix the imports with inline references
find sources -name "*.move" -exec sed -i '' 's/futarchy_core::futarchy_config::/use futarchy_core::futarchy_config::/g' {} \;
find sources -name "*.move" -exec sed -i '' 's/futarchy_core::config_/use futarchy::config_/g' {} \;

# Step 4: Fix imports that should be from futarchy (dao modules)
for module in action_dispatcher execute resource_requests \
              config_actions config_dispatcher config_intents \
              dissolution_actions dissolution_dispatcher dissolution_intents \
              governance_actions governance_dispatcher governance_intents \
              intent_janitor intent_spec intent_spec_builder intent_witnesses \
              optimistic_dispatcher optimistic_intents optimistic_proposal \
              oracle_actions proposal_lifecycle protocol_admin_actions protocol_admin_intents \
              commitment_actions commitment_dispatcher commitment_proposal \
              liquidity_actions liquidity_dispatcher liquidity_intents \
              memo_actions memo_dispatcher memo_intents \
              operating_agreement operating_agreement_actions operating_agreement_dispatcher operating_agreement_intents \
              policy_actions policy_dispatcher policy_registry resources \
              security_council security_council_actions security_council_intents \
              upgrade_cap_intents weighted_multisig \
              stream_actions stream_dispatcher stream_intents \
              custody_actions futarchy_vault futarchy_vault_init lp_token_custody \
              vault_governance_dispatcher vault_governance_intents \
              launchpad launchpad_rewards factory \
              janitor registry gc_janitor \
              cross_dao_bundle \
              coexec_common coexec_custody policy_registry_coexec upgrade_cap_coexec \
              events; do
    find sources -name "*.move" -exec sed -i '' "s/use futarchy_markets::${module}/use futarchy::${module}/g" {} \;
done

echo "Import fixes complete"