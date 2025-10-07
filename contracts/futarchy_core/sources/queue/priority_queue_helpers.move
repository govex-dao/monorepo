module futarchy_core::priority_queue_helpers;

use futarchy_core::priority_queue::{Self, ProposalData, QueuedProposal, ProposalQueue, QueueMutationAuth};
use std::string::String;
use sui::coin::Coin;

// === Errors ===
const EQueueEmpty: u64 = 0;

/// Creates proposal data for a queued proposal
public fun new_proposal_data(
    title: String,
    metadata: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
    initial_asset_amounts: vector<u64>,
    initial_stable_amounts: vector<u64>,
): ProposalData {
    priority_queue::new_proposal_data(
        title,
        metadata,
        outcome_messages,
        outcome_details,
        initial_asset_amounts,
        initial_stable_amounts,
    )
}

/// Extracts the maximum priority proposal from the queue without activating it
/// Requires QueueMutationAuth witness - only package modules can create this
public fun extract_max<StableCoin>(
    auth: QueueMutationAuth,
    queue: &mut ProposalQueue<StableCoin>,
): QueuedProposal<StableCoin> {
    let result = priority_queue::try_activate_next(auth, queue);
    assert!(option::is_some(&result), EQueueEmpty);
    option::destroy_some(result)
}

// === Getter functions for QueuedProposal ===

public fun get_proposal_id<StableCoin>(proposal: &QueuedProposal<StableCoin>): ID {
    priority_queue::get_proposal_id(proposal)
}

public fun get_proposer<StableCoin>(proposal: &QueuedProposal<StableCoin>): address {
    priority_queue::get_proposer(proposal)
}

public fun get_fee<StableCoin>(proposal: &QueuedProposal<StableCoin>): u64 {
    priority_queue::get_fee(proposal)
}

public fun uses_dao_liquidity<StableCoin>(proposal: &QueuedProposal<StableCoin>): bool {
    priority_queue::uses_dao_liquidity(proposal)
}

public fun get_data<StableCoin>(proposal: &QueuedProposal<StableCoin>): &ProposalData {
    priority_queue::get_proposal_data(proposal)
}

public fun get_bond<StableCoin>(
    auth: QueueMutationAuth,
    proposal: &mut QueuedProposal<StableCoin>,
): Option<Coin<StableCoin>> {
    priority_queue::extract_bond(auth, proposal)
}

public fun get_timestamp<StableCoin>(proposal: &QueuedProposal<StableCoin>): u64 {
    priority_queue::get_timestamp(proposal)
}

// === Getter functions for ProposalData ===

public fun get_title(data: &ProposalData): &String {
    priority_queue::get_title(data)
}

public fun get_metadata(data: &ProposalData): &String {
    priority_queue::get_metadata(data)
}

public fun get_outcome_messages(data: &ProposalData): &vector<String> {
    priority_queue::get_outcome_messages(data)
}

public fun get_outcome_details(data: &ProposalData): &vector<String> {
    priority_queue::get_outcome_details(data)
}

public fun get_initial_asset_amounts(data: &ProposalData): vector<u64> {
    priority_queue::get_initial_asset_amounts(data)
}

public fun get_initial_stable_amounts(data: &ProposalData): vector<u64> {
    priority_queue::get_initial_stable_amounts(data)
}