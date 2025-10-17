#!/bin/bash

# Fix the malformed imports that have "use futarchy_core::futarchy_config;" prepended

cd /Users/admin/monorepo/contracts/futarchy

# Fix files that have the double import issue
find sources -name "*.move" -exec sed -i '' 's/use futarchy_core::futarchy_config;[[:space:]]*futarchy_config/futarchy_core::futarchy_config/g' {} \;

# Also need to fix other imports from futarchy_core
find sources -name "*.move" -exec sed -i '' 's/use futarchy_core::futarchy_config;[[:space:]]*config_/futarchy_core::config_/g' {} \;

# Fix imports that should be from futarchy_markets
find sources -name "*.move" -exec sed -i '' 's/use futarchy::/use futarchy_markets::/g' {} \;

# Fix imports for modules that stayed in futarchy
find sources -name "*.move" -exec sed -i '' 's/use futarchy_markets::action_dispatcher/use futarchy::action_dispatcher/g' {} \;
find sources -name "*.move" -exec sed -i '' 's/use futarchy_markets::execute/use futarchy::execute/g' {} \;
find sources -name "*.move" -exec sed -i '' 's/use futarchy_markets::resource_requests/use futarchy::resource_requests/g' {} \;

# Fix imports for all the dao modules that stayed in futarchy
for module in config_actions config_dispatcher config_intents dissolution_actions dissolution_dispatcher dissolution_intents \
              governance_actions governance_dispatcher governance_intents governance_intents intent_janitor intent_spec \
              intent_spec_builder intent_witnesses optimistic_dispatcher optimistic_intents optimistic_proposal \
              oracle_actions proposal_lifecycle protocol_admin_actions protocol_admin_intents liquidity_actions liquidity_dispatcher liquidity_intents \
              memo_actions memo_dispatcher memo_intents operating_agreement operating_agreement_actions \
              operating_agreement_dispatcher operating_agreement_intents policy_actions policy_dispatcher \
              policy_registry resources security_council security_council_actions security_council_intents \
              upgrade_cap_intents weighted_multisig stream_actions stream_dispatcher stream_intents \
              custody_actions futarchy_vault futarchy_vault_init lp_token_custody vault_governance_dispatcher \
              vault_governance_intents launchpad launchpad_rewards factory janitor registry cross_dao_bundle \
              coexec_common coexec_custody policy_registry_coexec upgrade_cap_coexec; do
    find sources -name "*.move" -exec sed -i '' "s/use futarchy_markets::${module}/use futarchy::${module}/g" {} \;
done

echo "Import fixes complete"