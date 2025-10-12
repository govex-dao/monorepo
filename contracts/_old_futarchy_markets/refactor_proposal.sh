#!/bin/bash

# Script to refactor proposal field accesses

# Timing fields
sed -i '' 's/proposal\.created_at/proposal.timing.created_at/g' sources/proposal.move
sed -i '' 's/proposal\.market_initialized_at/proposal.timing.market_initialized_at/g' sources/proposal.move
sed -i '' 's/proposal\.review_period_ms/proposal.timing.review_period_ms/g' sources/proposal.move
sed -i '' 's/proposal\.trading_period_ms/proposal.timing.trading_period_ms/g' sources/proposal.move
sed -i '' 's/proposal\.last_twap_update/proposal.timing.last_twap_update/g' sources/proposal.move
sed -i '' 's/proposal\.twap_start_delay/proposal.timing.twap_start_delay/g' sources/proposal.move

# Liquidity config fields
sed -i '' 's/proposal\.min_asset_liquidity/proposal.liquidity_config.min_asset_liquidity/g' sources/proposal.move
sed -i '' 's/proposal\.min_stable_liquidity/proposal.liquidity_config.min_stable_liquidity/g' sources/proposal.move
sed -i '' 's/proposal\.asset_amounts/proposal.liquidity_config.asset_amounts/g' sources/proposal.move
sed -i '' 's/proposal\.stable_amounts/proposal.liquidity_config.stable_amounts/g' sources/proposal.move
sed -i '' 's/proposal\.uses_dao_liquidity/proposal.liquidity_config.uses_dao_liquidity/g' sources/proposal.move

# TWAP config fields
sed -i '' 's/proposal\.twap_prices/proposal.twap_config.twap_prices/g' sources/proposal.move
sed -i '' 's/proposal\.twap_initial_observation/proposal.twap_config.twap_initial_observation/g' sources/proposal.move
sed -i '' 's/proposal\.twap_step_max/proposal.twap_config.twap_step_max/g' sources/proposal.move
sed -i '' 's/proposal\.twap_threshold/proposal.twap_config.twap_threshold/g' sources/proposal.move

# Outcome data fields
sed -i '' 's/proposal\.outcome_count/proposal.outcome_data.outcome_count/g' sources/proposal.move
sed -i '' 's/proposal\.outcome_messages/proposal.outcome_data.outcome_messages/g' sources/proposal.move
sed -i '' 's/proposal\.outcome_creators/proposal.outcome_data.outcome_creators/g' sources/proposal.move
sed -i '' 's/proposal\.intent_keys/proposal.outcome_data.intent_keys/g' sources/proposal.move
sed -i '' 's/proposal\.actions_per_outcome/proposal.outcome_data.actions_per_outcome/g' sources/proposal.move
sed -i '' 's/proposal\.winning_outcome/proposal.outcome_data.winning_outcome/g' sources/proposal.move

echo "Refactoring complete!"