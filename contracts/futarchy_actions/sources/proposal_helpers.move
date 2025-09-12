/// Helper functions for standardizing proposal creation
module futarchy_actions::proposal_helpers;

use std::{string::String, type_name, vector};
use sui::bcs;
use account_protocol::intent_spec::{Self, ActionSpec};
use futarchy_markets::proposal::{Self, ProposalIntentSpec};
use futarchy_utils::action_types;

// === Constants ===

const OUTCOME_YES: u64 = 0;
const OUTCOME_NO: u64 = 1;

// === Public Functions ===

/// Create a standard reject outcome IntentSpec that only emits a memo
/// This ensures all rejected proposals have consistent behavior
public fun create_reject_intent_spec(): ProposalIntentSpec {
    // Create a memo action that just says "Proposal rejected"
    let memo_data = b"Proposal rejected";
    let action_spec = intent_spec::new_action_spec(
        type_name::get<action_types::EmitMemo>(),
        bcs::to_bytes(&memo_data)
    );
    
    proposal::new_proposal_intent_spec(
        b"Reject proposal".to_string(),
        vector[action_spec],
        false  // No voting required for memo
    )
}

/// Create standard outcome messages for binary proposals
public fun standard_outcome_messages(): vector<String> {
    vector[
        b"Approve".to_string(),
        b"Reject".to_string()
    ]
}

/// Create Yes/No outcome messages
public fun yes_no_outcome_messages(): vector<String> {
    vector[
        b"Yes".to_string(),
        b"No".to_string()
    ]
}

/// Validate that a proposal has the correct structure for binary outcomes
/// - Outcome 0 should have the actual actions
/// - Outcome 1 should only have a reject memo
public fun validate_binary_proposal_structure(
    approve_spec: &ProposalIntentSpec,
    reject_spec: &ProposalIntentSpec,
): bool {
    // Check that reject spec only has one action (the memo)
    let reject_actions = proposal::proposal_spec_actions(reject_spec);
    if (vector::length(reject_actions) != 1) {
        return false
    };
    
    // Check that the single action is a memo
    let reject_action = vector::borrow(reject_actions, 0);
    let action_type = intent_spec::action_type(reject_action);
    
    action_type == type_name::get<action_types::EmitMemo>()
}