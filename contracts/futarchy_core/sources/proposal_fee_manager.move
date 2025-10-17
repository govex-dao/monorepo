// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_core::proposal_fee_manager;

use futarchy_core::futarchy_config::{Self, SlashDistribution};
use futarchy_core::proposal_quota_registry;
use futarchy_one_shot_utils::constants;
use futarchy_one_shot_utils::math;
use sui::bag::{Self, Bag};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use sui::transfer;

// === Errors ===
const EInvalidFeeAmount: u64 = 0;
const EProposalFeeNotFound: u64 = 1;

// === Constants ===
const FIXED_ACTIVATOR_REWARD: u64 = 1_000_000; // 0.001 SUI fixed reward for activators

// === Structs ===

/// Manages proposal submission fees and activator rewards
public struct ProposalFeeManager has key, store {
    id: UID,
    /// Stores fees paid for proposals waiting in the queue
    /// Key is the proposal ID, value is the SUI Balance
    pending_proposal_fees: Bag,
    /// Total fees collected by the protocol from evicted/slashed proposals
    protocol_revenue: Balance<SUI>,
    /// Queue fees collected for proposals
    queue_fees: Balance<SUI>,
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
public fun new(ctx: &mut TxContext): ProposalFeeManager {
    ProposalFeeManager {
        id: object::new(ctx),
        pending_proposal_fees: bag::new(ctx),
        protocol_revenue: balance::zero(),
        queue_fees: balance::zero(),
    }
}

/// Called by the DAO when a proposal is submitted to the queue
public fun deposit_proposal_fee(
    manager: &mut ProposalFeeManager,
    proposal_id: ID,
    fee_coin: Coin<SUI>,
) {
    assert!(fee_coin.value() > 0, EInvalidFeeAmount);
    let fee_balance = fee_coin.into_balance();
    manager.pending_proposal_fees.add(proposal_id, fee_balance);
}

/// Called when a proposal is submitted to the queue to pay the queue fee
/// Splits fee 80/20 between queue maintenance and protocol revenue
public fun deposit_queue_fee(
    manager: &mut ProposalFeeManager,
    fee_coin: Coin<SUI>,
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
public fun add_to_proposal_fee(
    manager: &mut ProposalFeeManager,
    proposal_id: ID,
    additional_fee: Coin<SUI>,
    clock: &Clock,
) {
    assert!(manager.pending_proposal_fees.contains(proposal_id), EProposalFeeNotFound);
    assert!(additional_fee.value() > 0, EInvalidFeeAmount);

    let additional_amount = additional_fee.value();
    // Get the existing balance, join the new one, and put it back
    let mut existing_balance: Balance<SUI> = manager.pending_proposal_fees.remove(proposal_id);
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
public fun take_activator_reward(
    manager: &mut ProposalFeeManager,
    proposal_id: ID,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert!(manager.pending_proposal_fees.contains(proposal_id), EProposalFeeNotFound);

    let mut fee_balance: Balance<SUI> = manager.pending_proposal_fees.remove(proposal_id);
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

/// Called by the DAO when a proposal is evicted from the queue
/// Splits the fee according to SlashDistribution config:
/// - slasher_reward_bps% to slasher
/// - remainder to proposal creator as refund
/// Returns (slasher_reward, creator_refund)
public fun slash_proposal_fee_with_distribution(
    manager: &mut ProposalFeeManager,
    proposal_id: ID,
    slash_config: &SlashDistribution,
    ctx: &mut TxContext,
): (Coin<SUI>, Coin<SUI>) {
    // Returns (slasher_reward, proposal_creator_refund)
    assert!(manager.pending_proposal_fees.contains(proposal_id), EProposalFeeNotFound);

    let mut fee_balance: Balance<SUI> = manager.pending_proposal_fees.remove(proposal_id);
    let total_amount = fee_balance.value();

    if (total_amount == 0) {
        fee_balance.destroy_zero();
        return (coin::zero(ctx), coin::zero(ctx))
    };

    // Get slasher reward percentage from DAO config
    let slasher_bps = futarchy_config::slasher_reward_bps(slash_config) as u64;
    let slasher_amount = (total_amount * slasher_bps) / 10000;

    // Create slasher reward coin
    let slasher_reward = if (slasher_amount > 0) {
        coin::from_balance(fee_balance.split(slasher_amount), ctx)
    } else {
        coin::zero(ctx)
    };

    // Remaining goes to proposal creator as refund
    let creator_refund = coin::from_balance(fee_balance, ctx);

    (slasher_reward, creator_refund)
}

/// Gets the current protocol revenue
public fun protocol_revenue(manager: &ProposalFeeManager): u64 {
    manager.protocol_revenue.value()
}

/// Withdraws accumulated protocol revenue to the main fee manager
public fun withdraw_protocol_revenue(
    manager: &mut ProposalFeeManager,
    amount: u64,
    ctx: &mut TxContext,
): Coin<SUI> {
    coin::from_balance(manager.protocol_revenue.split(amount), ctx)
}

// Debt tracking system removed - replaced with per-execution fees

/// Called by the priority queue when a proposal is cancelled.
/// Removes the pending fee from the manager and returns it as a Coin.
/// This should be a friend function, callable only by the priority_queue module.
public fun refund_proposal_fee(
    manager: &mut ProposalFeeManager,
    proposal_id: ID,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert!(manager.pending_proposal_fees.contains(proposal_id), EProposalFeeNotFound);
    let fee_balance: Balance<SUI> = manager.pending_proposal_fees.remove(proposal_id);
    coin::from_balance(fee_balance, ctx)
}

/// Check if a proposal fee exists
public fun has_proposal_fee(manager: &ProposalFeeManager, proposal_id: ID): bool {
    manager.pending_proposal_fees.contains(proposal_id)
}

/// Get the fee amount for a proposal
public fun get_proposal_fee(manager: &ProposalFeeManager, proposal_id: ID): u64 {
    if (manager.pending_proposal_fees.contains(proposal_id)) {
        let balance: &Balance<SUI> = &manager.pending_proposal_fees[proposal_id];
        balance.value()
    } else {
        0
    }
}

/// Pay reward to proposal creator when proposal passes
/// Takes from protocol revenue
public fun pay_proposal_creator_reward(
    manager: &mut ProposalFeeManager,
    reward_amount: u64,
    ctx: &mut TxContext,
): Coin<SUI> {
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
public fun pay_outcome_creator_reward(
    manager: &mut ProposalFeeManager,
    reward_amount: u64,
    ctx: &mut TxContext,
): Coin<SUI> {
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
public fun collect_advancement_fee(manager: &mut ProposalFeeManager, fee_coin: Coin<SUI>) {
    manager.protocol_revenue.join(fee_coin.into_balance());
}

// === Quota Integration Functions ===

/// Calculate the actual fee a proposer should pay, considering quotas
/// Returns (actual_fee_amount, used_quota)
public fun calculate_fee_with_quota(
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
public fun use_quota_for_proposal(
    quota_registry: &mut proposal_quota_registry::ProposalQuotaRegistry,
    dao_id: ID,
    proposer: address,
    clock: &Clock,
) {
    proposal_quota_registry::use_quota(quota_registry, dao_id, proposer, clock);
}

/// Deposit revenue into protocol revenue (e.g., from proposal fee escrow)
/// Used when proposal fees are not fully refunded and should go to protocol
public fun deposit_revenue(manager: &mut ProposalFeeManager, revenue_coin: Coin<SUI>) {
    manager.protocol_revenue.join(revenue_coin.into_balance());
}

/// Refund fees to outcome creators whose outcome won
/// This is called after a proposal is finalized and the winning outcome is determined
/// Refunds are paid from protocol revenue
/// DEPRECATED: Use proposal fee escrow instead for per-proposal tracking
public fun refund_outcome_creator_fees(
    manager: &mut ProposalFeeManager,
    outcome_creator: address,
    refund_amount: u64,
    ctx: &mut TxContext,
): Coin<SUI> {
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
