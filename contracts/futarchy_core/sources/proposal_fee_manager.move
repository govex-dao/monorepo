// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_core::proposal_fee_manager;

use futarchy_core::futarchy_config;
use futarchy_core::proposal_quota_registry;
use futarchy_one_shot_utils::constants;
use futarchy_one_shot_utils::math;
use sui::bag::{Self, Bag};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::transfer;

// === Errors ===
const EInvalidFeeAmount: u64 = 0;
const EProposalFeeNotFound: u64 = 1;

// === Constants ===
const FIXED_ACTIVATOR_REWARD: u64 = 1_000_000; // 0.001 tokens fixed reward for activators

// === Structs ===

/// Manages proposal submission fees and activator rewards
/// Generic over StableType to support different stable coins per DAO
public struct ProposalFeeManager<phantom StableType> has key, store {
    id: UID,
    /// Stores fees paid for proposals waiting in the queue
    /// Key is the proposal ID, value is the StableType Balance
    pending_proposal_fees: Bag,
    /// Total fees collected by the protocol from evicted/slashed proposals
    protocol_revenue: Balance<StableType>,
    /// Queue fees collected for proposals
    queue_fees: Balance<StableType>,
}

// === Events ===

public struct QueueFeeDeposited has copy, drop {
    amount: u64,
    depositor: address,
    timestamp: u64,
}

public struct ProposalFeeUpdated has copy, drop {
    proposal_id: ID,
    additional_amount: u64,
    new_total_amount: u64,
    timestamp: u64,
}

// === Public Functions ===

/// Creates a new ProposalFeeManager
public fun new<StableType>(ctx: &mut TxContext): ProposalFeeManager<StableType> {
    ProposalFeeManager {
        id: object::new(ctx),
        pending_proposal_fees: bag::new(ctx),
        protocol_revenue: balance::zero(),
        queue_fees: balance::zero(),
    }
}

/// Called by the DAO when a proposal is submitted to the queue
public fun deposit_proposal_fee<StableType>(
    manager: &mut ProposalFeeManager<StableType>,
    proposal_id: ID,
    fee_coin: Coin<StableType>,
) {
    assert!(fee_coin.value() > 0, EInvalidFeeAmount);
    let fee_balance = fee_coin.into_balance();
    manager.pending_proposal_fees.add(proposal_id, fee_balance);
}

/// Called when a proposal is submitted to the queue to pay the queue fee
/// Splits fee 80/20 between queue maintenance and protocol revenue
public fun deposit_queue_fee<StableType>(
    manager: &mut ProposalFeeManager<StableType>,
    fee_coin: Coin<StableType>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let amount = fee_coin.value();
    if (amount > 0) {
        // Split fee: 80% to queue, 20% to protocol (same as conditional AMM fees)
        // Use mul_div pattern for precision and overflow safety
        let protocol_share = math::mul_div_to_64(
            amount,
            constants::conditional_protocol_fee_share_bps(),
            constants::total_fee_bps(),
        );
        let queue_share = amount - protocol_share;

        let mut fee_balance = fee_coin.into_balance();

        // Add protocol's share to protocol revenue
        if (protocol_share > 0) {
            manager.protocol_revenue.join(fee_balance.split(protocol_share));
        };

        // Add queue's share to queue fees
        manager.queue_fees.join(fee_balance);

        event::emit(QueueFeeDeposited {
            amount,
            depositor: ctx.sender(),
            timestamp: clock.timestamp_ms(),
        });
    } else {
        fee_coin.destroy_zero();
    }
}

/// Called when a user increases the fee for an existing queued proposal
public fun add_to_proposal_fee<StableType>(
    manager: &mut ProposalFeeManager<StableType>,
    proposal_id: ID,
    additional_fee: Coin<StableType>,
    clock: &Clock,
) {
    assert!(manager.pending_proposal_fees.contains(proposal_id), EProposalFeeNotFound);
    assert!(additional_fee.value() > 0, EInvalidFeeAmount);

    let additional_amount = additional_fee.value();
    // Get the existing balance, join the new one, and put it back
    let mut existing_balance: Balance<StableType> = manager.pending_proposal_fees.remove(proposal_id);
    existing_balance.join(additional_fee.into_balance());
    let new_total = existing_balance.value();

    event::emit(ProposalFeeUpdated {
        proposal_id,
        additional_amount,
        new_total_amount: new_total,
        timestamp: clock.timestamp_ms(),
    });

    manager.pending_proposal_fees.add(proposal_id, existing_balance);
}

/// Called by the DAO when activating a proposal
/// Returns a fixed reward to the activator and keeps the rest as protocol revenue
public fun take_activator_reward<StableType>(
    manager: &mut ProposalFeeManager<StableType>,
    proposal_id: ID,
    ctx: &mut TxContext,
): Coin<StableType> {
    assert!(manager.pending_proposal_fees.contains(proposal_id), EProposalFeeNotFound);

    let mut fee_balance: Balance<StableType> = manager.pending_proposal_fees.remove(proposal_id);
    let total_fee = fee_balance.value();

    if (total_fee == 0) {
        return coin::from_balance(fee_balance, ctx)
    };

    // Give fixed reward to activator, rest goes to protocol
    if (total_fee >= FIXED_ACTIVATOR_REWARD) {
        // Split off the protocol's share (everything except the fixed reward)
        let protocol_share = fee_balance.split(total_fee - FIXED_ACTIVATOR_REWARD);
        manager.protocol_revenue.join(protocol_share);
        // Return the fixed reward to the activator
        coin::from_balance(fee_balance, ctx)
    } else {
        // If fee is less than fixed reward, give entire fee to activator
        coin::from_balance(fee_balance, ctx)
    }
}

/// Gets the current protocol revenue
public fun protocol_revenue<StableType>(manager: &ProposalFeeManager<StableType>): u64 {
    manager.protocol_revenue.value()
}

/// Withdraws accumulated protocol revenue to the main fee manager
public fun withdraw_protocol_revenue<StableType>(
    manager: &mut ProposalFeeManager<StableType>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<StableType> {
    coin::from_balance(manager.protocol_revenue.split(amount), ctx)
}

/// Called by the priority queue when a proposal is cancelled.
/// Removes the pending fee from the manager and returns it as a Coin.
/// This should be a friend function, callable only by the priority_queue module.
public fun refund_proposal_fee<StableType>(
    manager: &mut ProposalFeeManager<StableType>,
    proposal_id: ID,
    ctx: &mut TxContext,
): Coin<StableType> {
    assert!(manager.pending_proposal_fees.contains(proposal_id), EProposalFeeNotFound);
    let fee_balance: Balance<StableType> = manager.pending_proposal_fees.remove(proposal_id);
    coin::from_balance(fee_balance, ctx)
}

/// Check if a proposal fee exists
public fun has_proposal_fee<StableType>(manager: &ProposalFeeManager<StableType>, proposal_id: ID): bool {
    manager.pending_proposal_fees.contains(proposal_id)
}

/// Get the fee amount for a proposal
public fun get_proposal_fee<StableType>(manager: &ProposalFeeManager<StableType>, proposal_id: ID): u64 {
    if (manager.pending_proposal_fees.contains(proposal_id)) {
        let balance: &Balance<StableType> = &manager.pending_proposal_fees[proposal_id];
        balance.value()
    } else {
        0
    }
}

/// Pay reward to proposal creator when proposal passes
/// Takes from protocol revenue
public fun pay_proposal_creator_reward<StableType>(
    manager: &mut ProposalFeeManager<StableType>,
    reward_amount: u64,
    ctx: &mut TxContext,
): Coin<StableType> {
    if (manager.protocol_revenue.value() >= reward_amount) {
        coin::from_balance(manager.protocol_revenue.split(reward_amount), ctx)
    } else {
        // If not enough in protocol revenue, pay what's available
        let available = manager.protocol_revenue.value();
        if (available > 0) {
            coin::from_balance(manager.protocol_revenue.split(available), ctx)
        } else {
            coin::zero(ctx)
        }
    }
}

/// Pay reward to outcome creator when their outcome wins
/// Takes from protocol revenue
public fun pay_outcome_creator_reward<StableType>(
    manager: &mut ProposalFeeManager<StableType>,
    reward_amount: u64,
    ctx: &mut TxContext,
): Coin<StableType> {
    if (manager.protocol_revenue.value() >= reward_amount) {
        coin::from_balance(manager.protocol_revenue.split(reward_amount), ctx)
    } else {
        // If not enough in protocol revenue, pay what's available
        let available = manager.protocol_revenue.value();
        if (available > 0) {
            coin::from_balance(manager.protocol_revenue.split(available), ctx)
        } else {
            coin::zero(ctx)
        }
    }
}

/// Collect fee for advancing proposal state
/// Called when advancing from review to trading or when finalizing
public fun collect_advancement_fee<StableType>(manager: &mut ProposalFeeManager<StableType>, fee_coin: Coin<StableType>) {
    manager.protocol_revenue.join(fee_coin.into_balance());
}

// === Quota Integration Functions ===

/// Calculate the actual fee a proposer should pay, considering quotas
/// Returns (actual_fee_amount, used_quota)
public fun calculate_fee_with_quota<StableType>(
    quota_registry: &proposal_quota_registry::ProposalQuotaRegistry,
    dao_id: ID,
    proposer: address,
    base_fee: u64,
    clock: &Clock,
): (u64, bool) {
    // Check if proposer has an available quota
    let (has_quota, reduced_fee) = proposal_quota_registry::check_quota_available(
        quota_registry,
        dao_id,
        proposer,
        clock,
    );

    if (has_quota) {
        // Proposer has quota - use reduced fee
        (reduced_fee, true)
    } else {
        // No quota - pay full fee
        (base_fee, false)
    }
}

/// Commit quota usage after successful proposal creation
/// Should only be called if used_quota = true from calculate_fee_with_quota
public fun use_quota_for_proposal<StableType>(
    quota_registry: &mut proposal_quota_registry::ProposalQuotaRegistry,
    dao_id: ID,
    proposer: address,
    clock: &Clock,
) {
    proposal_quota_registry::use_quota(quota_registry, dao_id, proposer, clock);
}

/// Deposit revenue into protocol revenue (e.g., from proposal fee escrow)
/// Used when proposal fees are not fully refunded and should go to protocol
public fun deposit_revenue<StableType>(manager: &mut ProposalFeeManager<StableType>, revenue_coin: Coin<StableType>) {
    manager.protocol_revenue.join(revenue_coin.into_balance());
}

/// Refund fees to outcome creators whose outcome won
/// This is called after a proposal is finalized and the winning outcome is determined
/// Refunds are paid from protocol revenue
public fun refund_outcome_creator_fees<StableType>(
    manager: &mut ProposalFeeManager<StableType>,
    outcome_creator: address,
    refund_amount: u64,
    ctx: &mut TxContext,
): Coin<StableType> {
    if (manager.protocol_revenue.value() >= refund_amount) {
        coin::from_balance(manager.protocol_revenue.split(refund_amount), ctx)
    } else {
        // If not enough in protocol revenue, refund what's available
        let available = manager.protocol_revenue.value();
        if (available > 0) {
            coin::from_balance(manager.protocol_revenue.split(available), ctx)
        } else {
            coin::zero(ctx)
        }
    }
}

// === Test Only Functions ===

#[test_only]
/// Destroy a ProposalFeeManager for testing
public fun destroy_for_testing<StableType>(manager: ProposalFeeManager<StableType>) {
    use sui::test_utils::destroy;

    let ProposalFeeManager {
        id,
        pending_proposal_fees,
        protocol_revenue,
        queue_fees,
    } = manager;

    object::delete(id);
    destroy(pending_proposal_fees);
    destroy(protocol_revenue);
    destroy(queue_fees);
}
