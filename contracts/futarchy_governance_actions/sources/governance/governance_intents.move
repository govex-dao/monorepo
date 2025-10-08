/// Governance module for creating and executing intents from approved proposals
/// This module provides a simplified interface for governance operations
module futarchy_governance_actions::governance_intents;

// === Imports ===
use std::string::{Self, String};
use std::option::{Self, Option};
use std::vector;
use sui::{
    clock::Clock,
    tx_context::TxContext,
    object,
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents::{Self, Intent, Params},
    intent_interface,
};
use futarchy_types::action_specs::{Self, InitActionSpecs};
use futarchy_core::version;
use futarchy_core::{
    futarchy_config::{Self, FutarchyConfig},
};
use futarchy_markets::{
    proposal::{Self, Proposal},
    market_state::MarketState,
};

// === Aliases ===
use fun intent_interface::build_intent as Account.build_intent;

// === Witness ===
/// Single witness for governance intents
public struct GovernanceWitness has copy, drop {}

/// Get the governance witness
public fun witness(): GovernanceWitness {
    GovernanceWitness {}
}

// === Intent Creation Functions ===

/// Create a simple treasury transfer intent
/// For actual transfers, use vault_intents::request_spend_and_transfer directly
public fun create_transfer_intent<Outcome: store + drop + copy>(
    account: &Account<FutarchyConfig>,
    recipient: address,
    amount: u64,
    outcome: Outcome,
    clock: &Clock,
    ctx: &mut TxContext
): Intent<Outcome> {
    // Generate intent key
    let mut intent_key = b"transfer_".to_string();
    intent_key.append(recipient.to_string());
    intent_key.append(b"_".to_string());
    intent_key.append(amount.to_string());
    
    // Create intent parameters
    let params = intents::new_params(
        intent_key,
        b"Treasury Transfer".to_string(),
        vector[clock.timestamp_ms() + 3_600_000], // 1 hour delay
        clock.timestamp_ms() + 86_400_000, // 24 hour expiry
        clock,
        ctx
    );
    
    // Create intent using account
    let intent = account.create_intent(
        params,
        outcome,
        b"TreasuryTransfer".to_string(),
        version::current(),
        witness(),
        ctx
    );
    
    // Note: Actions should be added by the caller using vault_intents
    intent
}

/// Create a config update intent
public fun create_config_intent<Outcome: store + drop + copy>(
    account: &Account<FutarchyConfig>,
    update_type: String,
    outcome: Outcome,
    clock: &Clock,
    ctx: &mut TxContext
): Intent<Outcome> {
    // Generate intent key
    let mut intent_key = b"config_".to_string();
    intent_key.append(update_type);
    intent_key.append(b"_".to_string());
    intent_key.append(clock.timestamp_ms().to_string());
    
    // Create intent parameters
    let params = intents::new_params(
        intent_key,
        b"Config Update".to_string(),
        vector[clock.timestamp_ms() + 3_600_000],
        clock.timestamp_ms() + 86_400_000,
        clock,
        ctx
    );
    
    // Create intent
    let intent = account.create_intent(
        params,
        outcome,
        b"ConfigUpdate".to_string(),
        version::current(),
        witness(),
        ctx
    );
    
    intent
}

/// Create a dissolution intent
public fun create_dissolution_intent<Outcome: store + drop + copy>(
    account: &Account<FutarchyConfig>,
    outcome: Outcome,
    clock: &Clock,
    ctx: &mut TxContext
): Intent<Outcome> {
    // Generate intent key
    let mut intent_key = b"dissolution_".to_string();
    intent_key.append(clock.timestamp_ms().to_string());
    
    // Create intent parameters
    let params = intents::new_params(
        intent_key,
        b"DAO Dissolution".to_string(),
        vector[clock.timestamp_ms() + 7_200_000], // 2 hour delay for dissolution
        clock.timestamp_ms() + 86_400_000,
        clock,
        ctx
    );
    
    // Create intent
    let intent = account.create_intent(
        params,
        outcome,
        b"Dissolution".to_string(),
        version::current(),
        witness(),
        ctx
    );
    
    intent
}

// === Execution Functions ===

/// Execute a governance intent from an approved proposal
/// This creates an Intent just-in-time from the stored IntentSpec blueprint
/// and immediately converts it to an executable for execution
public fun execute_proposal_intent<AssetType, StableType, Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    proposal: &mut Proposal<AssetType, StableType>,
    _market: &MarketState,
    outcome_index: u64,
    outcome: Outcome,
    clock: &Clock,
    ctx: &mut TxContext
): Executable<Outcome> {
    // === CRITICAL SECURITY: DEFENSIVE POLICY VALIDATION ===
    // Verify that policy enforcement was satisfied at proposal creation time
    // This is a defensive check - the real enforcement happens at proposal creation
    //
    // IMPORTANT: We validate against the STORED policy data in the Proposal,
    // NOT against the current policy registry. This ensures that if the DAO
    // changes its policies via another proposal, it won't brick execution of
    // in-flight proposals that were created under the old policy.
    //
    // Each proposal "locks in" the policy requirements that were active when
    // it was created, stored INLINE in the Proposal struct (not in shared objects).
    let policy_mode = proposal::get_policy_mode_for_outcome(proposal, outcome_index);
    let council_approval_proof = proposal::get_council_approval_proof_for_outcome(proposal, outcome_index);

    // Note: Policy validation happens at proposal creation time.
    // This defensive check verifies that if council approval was required (mode 3),
    // the approval proof exists.
    if (policy_mode == 3) { // MODE_DAO_AND_COUNCIL
        assert!(option::is_some(&council_approval_proof), 8); // EPolicyRequirementMissing
    };

    // Get the intent spec from the proposal for the specified outcome
    let mut intent_spec_opt = proposal::take_intent_spec_for_outcome(proposal, outcome_index);

    // Extract the intent spec - if no spec exists, this indicates no action was defined for this outcome
    assert!(option::is_some(&intent_spec_opt), 4); // EIntentNotFound
    let intent_spec = option::extract(&mut intent_spec_opt);
    option::destroy_none(intent_spec_opt);

    // Create and store Intent temporarily, then immediately create Executable
    let intent_key = create_and_store_intent_from_spec(
        account,
        intent_spec,
        outcome,
        clock,
        ctx
    );

    // Now create the executable from the stored intent
    let (_outcome, executable) = account::create_executable<FutarchyConfig, Outcome, GovernanceWitness>(
        account,
        intent_key,
        clock,
        version::current(),
        GovernanceWitness{},
        ctx,
    );

    executable
}

// === Helper Functions ===

/// Helper to create intent params with standard settings
public fun create_standard_params(
    key: String,
    description: String,
    delay_ms: u64,
    expiry_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext
): Params {
    intents::new_params(
        key,
        description,
        vector[clock.timestamp_ms() + delay_ms],
        clock.timestamp_ms() + expiry_ms,
        clock,
        ctx
    )
}

/// Create and store an Intent from an InitActionSpecs blueprint
/// Returns the intent key for immediate execution
public fun create_and_store_intent_from_spec<Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    spec: InitActionSpecs,
    outcome: Outcome,
    clock: &Clock,
    ctx: &mut TxContext
): String {
    // Generate a unique key for this just-in-time intent
    let mut intent_key = b"jit_intent_".to_string();
    intent_key.append(clock.timestamp_ms().to_string());
    intent_key.append(b"_".to_string());
    intent_key.append(object::id_address(account).to_string());

    // Create intent parameters with immediate execution
    let params = intents::new_params(
        intent_key,
        b"Just-in-time Proposal Execution".to_string(),
        vector[clock.timestamp_ms()], // Execute immediately
        clock.timestamp_ms() + 3_600_000, // 1 hour expiry
        clock,
        ctx
    );

    // Create the intent using the account module
    let mut intent = account::create_intent(
        account,
        params,
        outcome,
        b"ProposalExecution".to_string(),
        version::current(),
        witness(),
        ctx
    );

    // Add all actions from the spec to the intent
    let actions = action_specs::actions(&spec);
    let mut i = 0;
    let len = vector::length(actions);
    while (i < len) {
        let action = vector::borrow(actions, i);
        // Add the action to the intent using add_action_spec
        intents::add_action_spec(
            &mut intent,
            witness(),
            *action_specs::action_data(action),
            witness()
        );
        i = i + 1;
    };

    // Store the intent in the account
    let key_copy = intent_key;
    account::insert_intent(account, intent, version::current(), witness());

    key_copy
}

// === Notes ===
// For actual action execution, use the appropriate modules directly:
// - Transfers: account_actions::vault_intents
// - Config: futarchy::config_intents
// - Liquidity: futarchy::liquidity_intents
// - Dissolution: futarchy::dissolution_intents
// - Streaming: futarchy::stream_intents