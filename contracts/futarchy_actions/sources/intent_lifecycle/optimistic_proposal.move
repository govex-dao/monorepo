// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Optimistic Proposal System
/// Proposals execute automatically after a delay unless challenged
/// Challenges trigger futarchy markets using standard proposal fees
module futarchy_actions::optimistic_proposal;

use account_protocol::account::{Self, Account};
use account_protocol::executable::{Self, Executable};
use account_protocol::intents::{Self, Intent, ActionSpec};
use futarchy_core::dao_config;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_markets_core::proposal::{Self, Proposal};
use std::option::{Self, Option};
use std::string::{Self, String};
use std::vector;
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, ID, UID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// === Errors ===
const ENotOptimistic: u64 = 0;
const EAlreadyChallenged: u64 = 1;
const EChallengePeriodEnded: u64 = 2;
const EChallengePeriodNotEnded: u64 = 3;
const EAlreadyExecuted: u64 = 4;
const ENotProposer: u64 = 5;
const EInvalidFeeAmount: u64 = 6;
const EChallengeAlreadyResolved: u64 = 7;
const EProposalNotFinalized: u64 = 8;

// === Constants ===
// Challenge period is now configured in DAO config
// const DEFAULT_CHALLENGE_PERIOD_MS: u64 = 259_200_000; // 3 days
// const MIN_CHALLENGE_PERIOD_MS: u64 = 86_400_000; // 1 day
// const MAX_CHALLENGE_PERIOD_MS: u64 = 604_800_000; // 7 days

// === Events ===

/// Emitted when an optimistic proposal is created
public struct OptimisticProposalCreated has copy, drop {
    proposal_id: ID,
    proposer: address,
    challenge_period_end: u64,
    description: String,
}

/// Emitted when a proposal is challenged
public struct ProposalChallenged has copy, drop {
    proposal_id: ID,
    challenger: address,
    futarchy_proposal_id: ID,
    timestamp: u64,
}

/// Emitted when an optimistic proposal executes (no challenge)
public struct OptimisticProposalExecuted has copy, drop {
    proposal_id: ID,
    timestamp: u64,
}

/// Emitted when a challenge is resolved
public struct ChallengeResolved has copy, drop {
    proposal_id: ID,
    challenge_succeeded: bool,
    challenger_refunded: bool,
}

// === Structs ===

/// An optimistic proposal that executes unless challenged
public struct OptimisticProposal has key, store {
    id: UID,
    // Core proposal data
    proposer: address,
    intent_specs: vector<ActionSpec>, // The action blueprints to execute
    description: String,
    // Challenge mechanics
    challenge_period_end: u64,
    is_challenged: bool,
    challenger: Option<address>,
    // If challenged, links to futarchy proposal
    futarchy_proposal_id: Option<ID>,
    challenge_succeeded: Option<bool>,
    // Execution state
    executed: bool,
    created_at: u64,
    // Metadata
    metadata: String,
}

/// Action to create an optimistic proposal
public struct CreateOptimisticProposalAction has store {
    intent: Intent<String>,
    description: String,
    challenge_period_ms: u64, // If 0, uses DAO config default
    metadata: String,
}

/// Action to challenge an optimistic proposal
public struct ChallengeOptimisticProposalAction has drop, store {
    optimistic_proposal_id: ID,
    challenge_description: String,
}

/// Action to execute an unchallenged optimistic proposal
public struct ExecuteOptimisticProposalAction has drop, store {
    optimistic_proposal_id: ID,
}

/// Action to resolve a challenge after futarchy markets decide
public struct ResolveChallengeAction has drop, store {
    optimistic_proposal_id: ID,
    futarchy_proposal_id: ID,
}

// === Constructor Functions ===

/// Create a new optimistic proposal
public fun create_optimistic_proposal(
    proposer: address,
    intent_specs: vector<ActionSpec>,
    description: String,
    challenge_period_ms: u64, // If 0, uses DAO config default
    metadata: String,
    account: &Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
): OptimisticProposal {
    // Get challenge period from config if not specified
    let actual_challenge_period = if (challenge_period_ms == 0) {
        let futarchy_config = account::config(account);
        futarchy_config::optimistic_challenge_period_ms(futarchy_config)
    } else {
        // If specified, just ensure it's non-zero
        assert!(challenge_period_ms > 0, EInvalidFeeAmount);
        challenge_period_ms
    };

    let id = object::new(ctx);
    let proposal_id = object::uid_to_inner(&id);
    let created_at = clock.timestamp_ms();
    let challenge_period_end = created_at + actual_challenge_period;

    event::emit(OptimisticProposalCreated {
        proposal_id,
        proposer,
        challenge_period_end,
        description: description,
    });

    OptimisticProposal {
        id,
        proposer,
        intent_specs,
        description,
        challenge_period_end,
        is_challenged: false,
        challenger: option::none(),
        futarchy_proposal_id: option::none(),
        challenge_succeeded: option::none(),
        executed: false,
        created_at,
        metadata,
    }
}

// === Challenge Functions ===

/// Challenge an optimistic proposal (requires fee in DAO's native token)
public fun challenge_optimistic_proposal<AssetType>(
    optimistic: &mut OptimisticProposal,
    challenger: address,
    account: &mut Account<FutarchyConfig>,
    fee_coin: Coin<AssetType>, // Fee must be in DAO's token type
    futarchy_proposal_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate challenge timing
    let now = clock.timestamp_ms();
    assert!(now < optimistic.challenge_period_end, EChallengePeriodEnded);
    assert!(!optimistic.is_challenged, EAlreadyChallenged);
    assert!(!optimistic.executed, EAlreadyExecuted);

    // Get the required fee amount from DAO config
    let futarchy_config = account::config(account);
    let fee_amount = futarchy_config::optimistic_challenge_fee(futarchy_config);
    assert!(coin::value(&fee_coin) >= fee_amount, EInvalidFeeAmount);

    // Transfer fee to DAO treasury (challenger loses this if challenge fails)
    transfer::public_transfer(fee_coin, account::addr(account));

    // Mark as challenged
    optimistic.is_challenged = true;
    optimistic.challenger = option::some(challenger);
    optimistic.futarchy_proposal_id = option::some(futarchy_proposal_id);

    event::emit(ProposalChallenged {
        proposal_id: object::id(optimistic),
        challenger,
        futarchy_proposal_id,
        timestamp: now,
    });
}

// === Execution Functions ===

/// Execute an unchallenged optimistic proposal after challenge period
public fun execute_optimistic_proposal(
    optimistic: &mut OptimisticProposal,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate execution conditions
    assert!(!optimistic.executed, EAlreadyExecuted);
    assert!(!optimistic.is_challenged, EAlreadyChallenged);
    assert!(clock.timestamp_ms() >= optimistic.challenge_period_end, EChallengePeriodNotEnded);

    optimistic.executed = true;

    event::emit(OptimisticProposalExecuted {
        proposal_id: object::id(optimistic),
        timestamp: clock.timestamp_ms(),
    });

    // Intent execution would be handled separately
    // The intent remains stored in the proposal for reference
}

/// Resolve a challenge after futarchy markets decide
public fun resolve_challenge<AssetType, StableType>(
    optimistic: &mut OptimisticProposal,
    futarchy_proposal: &Proposal<AssetType, StableType>,
    account: &mut Account<FutarchyConfig>,
    mut refund_coin: Option<Coin<AssetType>>, // Coin for refund if challenge succeeds
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate resolution conditions
    assert!(optimistic.is_challenged, ENotOptimistic);
    assert!(option::is_none(&optimistic.challenge_succeeded), EChallengeAlreadyResolved);
    assert!(proposal::is_finalized(futarchy_proposal), EProposalNotFinalized);

    // Check if the futarchy proposal passed (challenge failed) or failed (challenge succeeded)
    // If futarchy REJECTS the optimistic proposal, the challenge succeeded
    let challenge_succeeded =
        !proposal::is_winning_outcome_set(futarchy_proposal) || 
                             proposal::get_winning_outcome(futarchy_proposal) == 1; // REJECT outcome

    optimistic.challenge_succeeded = option::some(challenge_succeeded);

    // Handle fee based on challenge result
    let challenger_refunded = if (challenge_succeeded && option::is_some(&optimistic.challenger)) {
        // Challenge succeeded - refund challenger
        if (option::is_some(&refund_coin)) {
            let coin = option::extract(&mut refund_coin);
            let challenger = *option::borrow(&optimistic.challenger);
            transfer::public_transfer(coin, challenger);
        };
        true
    } else {
        // Challenge failed - DAO keeps the fee (already in treasury)
        // Destroy the refund coin if provided
        if (option::is_some(&refund_coin)) {
            let coin = option::extract(&mut refund_coin);
            transfer::public_transfer(coin, account::addr(account)); // Keep in DAO
        };
        false
    };

    // If challenge failed, the optimistic proposal can still execute
    if (!challenge_succeeded) {
        // Proposal was validated by markets, can execute
        optimistic.executed = false; // Still needs explicit execution
    } else {
        // Challenge succeeded, proposal is blocked
        optimistic.executed = true; // Mark as executed to prevent future execution
    };

    event::emit(ChallengeResolved {
        proposal_id: object::id(optimistic),
        challenge_succeeded,
        challenger_refunded,
    });

    // Destroy the Option if it still contains a coin (shouldn't happen in normal flow)
    if (option::is_some(&refund_coin)) {
        let leftover_coin = option::extract(&mut refund_coin);
        transfer::public_transfer(leftover_coin, account::addr(account)); // Send to DAO treasury
    };
    option::destroy_none(refund_coin);
}

// === Getter Functions ===

public fun is_challengeable(optimistic: &OptimisticProposal, clock: &Clock): bool {
    !optimistic.is_challenged && 
    !optimistic.executed && 
    clock.timestamp_ms() < optimistic.challenge_period_end
}

public fun is_executable(optimistic: &OptimisticProposal, clock: &Clock): bool {
    !optimistic.executed && 
    !optimistic.is_challenged && 
    clock.timestamp_ms() >= optimistic.challenge_period_end
}

public fun get_proposer(optimistic: &OptimisticProposal): address {
    optimistic.proposer
}

public fun get_challenger(optimistic: &OptimisticProposal): Option<address> {
    optimistic.challenger
}

public fun is_challenged(optimistic: &OptimisticProposal): bool {
    optimistic.is_challenged
}

public fun is_executed(optimistic: &OptimisticProposal): bool {
    optimistic.executed
}

public fun get_challenge_period_end(optimistic: &OptimisticProposal): u64 {
    optimistic.challenge_period_end
}

public fun get_futarchy_proposal_id(optimistic: &OptimisticProposal): Option<ID> {
    optimistic.futarchy_proposal_id
}

public fun get_challenge_result(optimistic: &OptimisticProposal): Option<bool> {
    optimistic.challenge_succeeded
}
