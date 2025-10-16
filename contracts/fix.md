  TODO Comments by Package (30 Total)

  futarchy_actions (7 TODOs)

  Intent Lifecycle:
  - intent_janitor.move:278 - Implement proper outcome type checking
  - intent_janitor.move:282 - This requires the correct outcome type

  Governance:
  - platform_fee_actions.move:105 - Implement new arb-loop-based fee collection
  - governance_actions.move:842 - Integrate quota system to track if admin budget was used
  - governance_actions.move:877 - Integrate quota system to track if admin budget was used
  - governance_actions.move:914 - Integrate quota system to track if admin budget was used

  Liquidity:
  - liquidity_actions_migrated.move:252 - Replace with correct withdraw function when
  available

  ---
  futarchy_core (1 TODO)

  Proposal Fee Manager:
  - proposal_fee_manager.move:236 - Consider adding a separate burn_vault: Balance field to
   track burned amounts

  ---
  futarchy_dao (8 TODOs)

  Proposal Lifecycle:
  - proposal_lifecycle.move:438 - Intent cancellation logic needs to be updated for new
  InitActionSpecs design
  - proposal_lifecycle.move:890 - Populate conditional_types vector with actual TypeNames
  from market_state
  - proposal_lifecycle.move:892 - Extract from market_state when needed
  - proposal_lifecycle.move:1137 - Update this check for new InitActionSpecs design
  - proposal_lifecycle.move:1188 - Add execution tracking to proposal module
  - proposal_lifecycle.move:1196 - Add execution tracking to proposal module
  - proposal_lifecycle.move:1203 - Add intent key tracking to proposal module

  Garbage Collection:
  - janitor.move:354 - Implement proper indexing for expired intents

  ---
  futarchy_legal_actions (1 TODO)

  File Actions:
  - dao_file_actions.move:271 - Implement deletion logic in dao_doc_registry

  ---
  futarchy_markets_core (7 TODOs)

  Proposal:
  - proposal.move:2191 - Add proper error code (subsidy_escrow.is_none assertion)
  - proposal.move:2199 - Add proper error code (subsidy_escrow.is_some assertion)
  - proposal.move:2207 - Add proper error code (subsidy_escrow.is_some assertion)

  Unified Spot Pool (TWAP):
  - unified_spot_pool.move:975 - Implement advanced backfill logic when simple_twap
  supports it
  - unified_spot_pool.move:1015 - Implement once simple_twap::is_ready() exists
  - unified_spot_pool.move:1024 - Call simple_twap::is_ready() once it exists
  - unified_spot_pool.move:1031 - Use simple_twap::get_lending_twap() once it exists
  - unified_spot_pool.move:1038 - Use get_lending_twap() once it exists

  ---
  futarchy_markets_primitives (1 TODO)

  Geometric TWAP (Deprecated):
  - simple_twap_geometric.move:326 - Binary search for large cardinality (currently linear
  search)

  ---
  futarchy_multisig (3 TODOs)

  Security Council:
  - security_council_intents.move:232 - Check the policy mode to see if council is allowed

  Co-execution:
  - coexec_common.move:46 - Implement has_policy and get_policy functions
  - coexec_common.move:61 - Implement has_policy, get_policy and policy_account_id
  functions

  ---
  futarchy_vault (1 TODO)

  Vault:
  - futarchy_vault.move:168 - Fix deposit_new_coin_type - vault::deposit signature changed

  ---
