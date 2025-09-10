/// Commitment Proposal Module
/// Allows founders/whales to propose burning or locking their tokens to reduce centralization risk.
/// Markets decide if this decentralization would increase the DAO's value.
module futarchy_actions::commitment_proposal;

use std::string::{Self, String};
use std::vector;
use std::option::{Self, Option};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::clock::{Self, Clock};
use sui::transfer;
use sui::tx_context::{Self, TxContext};
use sui::object::{Self, ID, UID};
use sui::event;
use account_protocol::{
    intents::{Expired},
    executable::{Self, Executable},
    account::{Self, Account},
    version_witness::VersionWitness,
};
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_markets::{
    proposal::{Self, Proposal},
    spot_amm::{Self, SpotAMM},
    spot_conditional_quoter,
    conditional_amm,
};

// === Errors ===
const EInvalidTiers: u64 = 0;
const ETiersNotSorted: u64 = 1;
const ETierAmountsExceedDeposit: u64 = 2;
const EProposalNotPassed: u64 = 3;
const EProposalNotExecuted: u64 = 4;
const ENotProposer: u64 = 5;
const ENotRecipient: u64 = 6;
const EStillLocked: u64 = 7;
const ENotLocked: u64 = 8;
const EAlreadyExecuted: u64 = 9;
const EInsufficientDeposit: u64 = 10;
const ETwapNotReady: u64 = 11;
const ENoTiersProvided: u64 = 12;
const EInvalidProposalId: u64 = 13;
const EInvalidLockDuration: u64 = 14;
const EAlreadyWithdrawn: u64 = 15;

// === Constants ===
const MAX_TIERS: u64 = 10;
const MIN_LOCK_DURATION_MS: u64 = 86_400_000; // 1 day
const MAX_LOCK_DURATION_MS: u64 = 63_072_000_000; // 2 years
const TWAP_MEASUREMENT_PERIOD_MS: u64 = 604_800_000; // 7 days
const MIN_COMMITMENT_AMOUNT: u64 = 1_000_000_000; // 1 token (assuming 9 decimals)

// === Events ===

/// Emitted when a commitment proposal is created
public struct CommitmentProposalCreated has copy, drop {
    proposal_id: ID,
    proposer: address,
    committed_amount: u64,
    tier_count: u64,
}

/// Emitted when commitment is executed
public struct CommitmentExecuted has copy, drop {
    proposal_id: ID,
    tier_reached: u64,
    twap_price: u128,
    locked_amount: u64,
    unlock_time: u64,
}

/// Emitted when locked tokens are withdrawn
public struct CommitmentWithdrawn has copy, drop {
    proposal_id: ID,
    recipient: address,
    amount: u64,
}

/// Emitted when withdrawal recipient is updated
public struct RecipientUpdated has copy, drop {
    proposal_id: ID,
    old_recipient: address,
    new_recipient: address,
}

/// Emitted when tokens are returned (proposal rejected)
public struct CommitmentReturned has copy, drop {
    proposal_id: ID,
    proposer: address,
    amount: u64,
}

// === Structs ===

/// A price tier defining lock conditions
public struct PriceTier has store, copy, drop {
    /// TWAP price threshold to trigger this tier (scaled by 1e12)
    twap_threshold: u128,
    /// Amount to lock at this price
    lock_amount: u64,
    /// How long to lock tokens (milliseconds)
    lock_duration_ms: u64,
}

/// Commitment proposal for token locking/burning
public struct CommitmentProposal<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    
    // Proposer info
    proposer: address,
    withdrawal_recipient: address,
    
    // Commitment details
    committed_amount: u64,
    committed_coins: Balance<AssetType>,
    
    // Price-based lock tiers (ordered by price)
    tiers: vector<PriceTier>,
    
    // Execution results
    locked_amount: u64,
    unlock_time: Option<u64>,
    tier_reached: Option<u64>,
    
    // Proposal state
    proposal_id: ID, // ID of the associated Proposal object
    executed: bool,
    withdrawn: bool,
    
    // Timestamps
    created_at: u64,
    trading_start: u64,
    trading_end: u64,
    
    // Metadata
    description: String,
}

// === Constructor Functions ===

/// Create a new commitment proposal
public fun create_commitment_proposal<AssetType, StableType>(
    proposer: address,
    committed_coins: Coin<AssetType>,
    tiers: vector<PriceTier>,
    proposal_id: ID,
    trading_start: u64,
    trading_end: u64,
    description: String,
    clock: &Clock,
    ctx: &mut TxContext,
): CommitmentProposal<AssetType, StableType> {
    let committed_amount = coin::value(&committed_coins);
    assert!(committed_amount >= MIN_COMMITMENT_AMOUNT, EInsufficientDeposit);
    assert!(vector::length(&tiers) > 0, ENoTiersProvided);
    assert!(vector::length(&tiers) <= MAX_TIERS, EInvalidTiers);
    
    // Validate tiers are sorted by price and amounts don't exceed deposit
    validate_tiers(&tiers, committed_amount);
    
    let id = object::new(ctx);
    let created_at = clock.timestamp_ms();
    
    event::emit(CommitmentProposalCreated {
        proposal_id: object::uid_to_inner(&id),
        proposer,
        committed_amount,
        tier_count: vector::length(&tiers),
    });
    
    CommitmentProposal {
        id,
        proposer,
        withdrawal_recipient: proposer,
        committed_amount,
        committed_coins: coin::into_balance(committed_coins),
        tiers,
        locked_amount: 0,
        unlock_time: option::none(),
        tier_reached: option::none(),
        proposal_id,
        executed: false,
        withdrawn: false,
        created_at,
        trading_start,
        trading_end,
        description,
    }
}

// === Validation Functions ===

fun validate_tiers(tiers: &vector<PriceTier>, max_amount: u64) {
    let len = vector::length(tiers);
    let mut i = 0;
    let mut prev_threshold = 0u128;
    
    while (i < len) {
        let tier = vector::borrow(tiers, i);
        
        // Check tiers are sorted by price
        assert!(tier.twap_threshold > prev_threshold, ETiersNotSorted);
        prev_threshold = tier.twap_threshold;
        
        // Check lock amount doesn't exceed deposit
        assert!(tier.lock_amount <= max_amount, ETierAmountsExceedDeposit);
        
        // Check lock duration is valid
        assert!(tier.lock_duration_ms >= MIN_LOCK_DURATION_MS, EInvalidLockDuration);
        assert!(tier.lock_duration_ms <= MAX_LOCK_DURATION_MS, EInvalidLockDuration);
        
        i = i + 1;
    }
}

// === Execution Functions ===

/// Execute commitment after proposal passes
public fun execute_commitment<AssetType, StableType>(
    commitment: &mut CommitmentProposal<AssetType, StableType>,
    proposal: &Proposal<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate commitment state
    assert!(!commitment.executed, EAlreadyExecuted);
    assert!(clock.timestamp_ms() >= commitment.trading_end, EProposalNotExecuted);
    
    // Validate proposal state - must be finalized with a winning outcome
    assert!(proposal::is_finalized(proposal), EProposalNotExecuted);
    assert!(proposal::is_winning_outcome_set(proposal), EProposalNotExecuted);
    
    // Validate proposal matches commitment
    assert!(object::id(proposal) == commitment.proposal_id, EInvalidProposalId);
    
    // Get TWAP from the winning outcome
    let outcome_idx = proposal::get_winning_outcome(proposal);
    
    // Get stored TWAP prices (indexed by outcome)
    let twap_prices = proposal::get_twap_prices(proposal);
    assert!(vector::length(twap_prices) > outcome_idx, ETwapNotReady);
    
    // Get the TWAP for the winning outcome
    let current_twap = *vector::borrow(twap_prices, outcome_idx);
    
    // Find highest tier where TWAP >= threshold
    let tier_index = find_highest_tier(&commitment.tiers, current_twap);
    
    if (option::is_some(&tier_index)) {
        // Lock tokens based on tier
        let index = *option::borrow(&tier_index);
        let tier = vector::borrow(&commitment.tiers, index);
        
        commitment.locked_amount = tier.lock_amount;
        commitment.unlock_time = option::some(
            clock.timestamp_ms() + tier.lock_duration_ms
        );
        commitment.tier_reached = option::some(index);
        
        // Return excess tokens if any
        let excess_amount = commitment.committed_amount - tier.lock_amount;
        if (excess_amount > 0) {
            let excess_coins = coin::from_balance(
                balance::split(&mut commitment.committed_coins, excess_amount),
                ctx
            );
            transfer::public_transfer(excess_coins, commitment.proposer);
        };
        
        event::emit(CommitmentExecuted {
            proposal_id: object::uid_to_inner(&commitment.id),
            tier_reached: index,
            twap_price: current_twap,
            locked_amount: tier.lock_amount,
            unlock_time: *option::borrow(&commitment.unlock_time),
        });
    } else {
        // No tier reached, return all tokens
        let all_coins = coin::from_balance(
            balance::withdraw_all(&mut commitment.committed_coins),
            ctx
        );
        transfer::public_transfer(all_coins, commitment.proposer);
        
        event::emit(CommitmentReturned {
            proposal_id: object::uid_to_inner(&commitment.id),
            proposer: commitment.proposer,
            amount: commitment.committed_amount,
        });
    };
    
    commitment.executed = true;
}

/// Find the highest tier where TWAP meets threshold
fun find_highest_tier(tiers: &vector<PriceTier>, twap: u128): Option<u64> {
    let len = vector::length(tiers);
    let mut highest_index = option::none<u64>();
    let mut i = 0;
    
    while (i < len) {
        let tier = vector::borrow(tiers, i);
        if (twap >= tier.twap_threshold) {
            highest_index = option::some(i);
        };
        i = i + 1;
    };
    
    highest_index
}

// === Withdrawal Functions ===

/// Withdraw unlocked tokens
public entry fun withdraw_unlocked_tokens<AssetType, StableType>(
    commitment: &mut CommitmentProposal<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(commitment.executed, EProposalNotExecuted);
    assert!(!commitment.withdrawn, EAlreadyWithdrawn);
    assert!(option::is_some(&commitment.unlock_time), ENotLocked);
    
    let unlock_time = *option::borrow(&commitment.unlock_time);
    assert!(clock.timestamp_ms() >= unlock_time, EStillLocked);
    
    let sender = tx_context::sender(ctx);
    assert!(sender == commitment.withdrawal_recipient, ENotRecipient);
    
    let withdrawal_coins = coin::from_balance(
        balance::withdraw_all(&mut commitment.committed_coins),
        ctx
    );
    
    transfer::public_transfer(withdrawal_coins, commitment.withdrawal_recipient);
    
    commitment.withdrawn = true;
    
    event::emit(CommitmentWithdrawn {
        proposal_id: object::uid_to_inner(&commitment.id),
        recipient: commitment.withdrawal_recipient,
        amount: commitment.locked_amount,
    });
}

/// Update withdrawal recipient
public entry fun update_withdrawal_recipient<AssetType, StableType>(
    commitment: &mut CommitmentProposal<AssetType, StableType>,
    new_recipient: address,
    ctx: &mut TxContext,
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == commitment.proposer, ENotProposer);
    
    // Only allow recipient updates before tokens are withdrawn
    assert!(!commitment.withdrawn, EAlreadyWithdrawn);
    
    let old_recipient = commitment.withdrawal_recipient;
    commitment.withdrawal_recipient = new_recipient;
    
    event::emit(RecipientUpdated {
        proposal_id: object::uid_to_inner(&commitment.id),
        old_recipient,
        new_recipient,
    });
}

// === Getter Functions ===

public fun get_proposer<AssetType, StableType>(
    commitment: &CommitmentProposal<AssetType, StableType>
): address {
    commitment.proposer
}

public fun get_withdrawal_recipient<AssetType, StableType>(
    commitment: &CommitmentProposal<AssetType, StableType>
): address {
    commitment.withdrawal_recipient
}

public fun get_committed_amount<AssetType, StableType>(
    commitment: &CommitmentProposal<AssetType, StableType>
): u64 {
    commitment.committed_amount
}

public fun get_locked_amount<AssetType, StableType>(
    commitment: &CommitmentProposal<AssetType, StableType>
): u64 {
    commitment.locked_amount
}

public fun get_unlock_time<AssetType, StableType>(
    commitment: &CommitmentProposal<AssetType, StableType>
): Option<u64> {
    commitment.unlock_time
}

public fun is_executed<AssetType, StableType>(
    commitment: &CommitmentProposal<AssetType, StableType>
): bool {
    commitment.executed
}

public fun is_withdrawn<AssetType, StableType>(
    commitment: &CommitmentProposal<AssetType, StableType>
): bool {
    commitment.withdrawn
}

public fun get_tier_count<AssetType, StableType>(
    commitment: &CommitmentProposal<AssetType, StableType>
): u64 {
    vector::length(&commitment.tiers)
}

public fun get_tier_at<AssetType, StableType>(
    commitment: &CommitmentProposal<AssetType, StableType>,
    index: u64
): &PriceTier {
    vector::borrow(&commitment.tiers, index)
}