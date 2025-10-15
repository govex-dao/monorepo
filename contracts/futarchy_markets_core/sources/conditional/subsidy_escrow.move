/// Subsidy escrow execution module for conditional AMMs
/// Config types live in futarchy_core::subsidy_config
/// This module handles escrow creation, cranking, and finalization
module futarchy_markets_core::subsidy_escrow;

use std::option::{Self, Option};
use sui::object::{Self, UID, ID};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::clock::{Self, Clock};
use sui::tx_context::{Self, TxContext};
use sui::sui::SUI;
use sui::transfer;
use sui::event;
use futarchy_one_shot_utils::math;
use futarchy_core::subsidy_config::{Self, ProtocolSubsidyConfig};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};

// === Errors ===
const ESubsidyExhausted: u64 = 0;           // All cranks completed
const EProposalMismatch: u64 = 1;           // Escrow not for this proposal
const EAmmMismatch: u64 = 2;                // AMM ID not in escrow's tracked list
const EInsufficientBalance: u64 = 3;        // Not enough SUI in escrow
const ETooEarlyCrank: u64 = 4;              // Cranking too fast (min interval not met)
const EProposalFinalized: u64 = 5;          // Cannot crank after finalization
const EZeroSubsidy: u64 = 7;                // Subsidy amount is zero

// === Constants ===
const MIN_CRANK_INTERVAL_MS: u64 = 300_000;  // 5 minutes minimum between cranks

// === Structs ===

/// Escrow holding DAO treasury funds for gradual subsidy dripping
/// Created when proposal enters trading state
/// NOTE: This is an OWNED object (store only), not a shared object.
/// It lives inside the Proposal struct to ensure automatic cleanup.
public struct SubsidyEscrow has store {
    proposal_id: ID,                            // Which proposal this subsidizes
    dao_id: ID,                                 // Which DAO this belongs to (for refund)
    amm_ids: vector<ID>,                        // Allowed AMM IDs (security check)
    subsidy_balance: Balance<SUI>,              // DAO treasury funds to drip feed
    total_subsidy: u64,                         // Original treasury amount
    cranks_completed: u64,                      // How many cranks done
    total_cranks: u64,                          // Total cranks allowed
    keeper_fee_per_crank: u64,                  // Flat keeper fee
    last_crank_time: Option<u64>,              // Last crank timestamp (for rate limiting)
}

// === Events ===

/// Emitted when subsidy escrow is created
public struct SubsidyEscrowCreated has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    total_subsidy: u64,
    total_cranks: u64,
    outcome_count: u64,
    subsidy_per_outcome_per_crank: u64,
}

/// Emitted when keeper cranks subsidy into AMMs
public struct SubsidyCranked has copy, drop {
    proposal_id: ID,
    crank_number: u64,
    total_cranks: u64,
    subsidy_distributed: u64,       // Amount added to AMMs (after keeper fee)
    amount_per_amm: u64,
    outcome_count: u64,
    keeper_fee: u64,
    keeper: address,
    timestamp: u64,
}

/// Emitted when escrow is finalized (returns remainder to treasury)
public struct SubsidyFinalized has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    cranks_completed: u64,
    remaining_balance: u64,         // Returned to DAO treasury
    timestamp: u64,
}

// === Getters for SubsidyEscrow ===
public fun escrow_proposal_id(escrow: &SubsidyEscrow): ID { escrow.proposal_id }
public fun escrow_dao_id(escrow: &SubsidyEscrow): ID { escrow.dao_id }
public fun escrow_total_subsidy(escrow: &SubsidyEscrow): u64 { escrow.total_subsidy }
public fun escrow_cranks_completed(escrow: &SubsidyEscrow): u64 { escrow.cranks_completed }
public fun escrow_total_cranks(escrow: &SubsidyEscrow): u64 { escrow.total_cranks }
public fun escrow_remaining_balance(escrow: &SubsidyEscrow): u64 { escrow.subsidy_balance.value() }

// === Public Functions ===

/// Create subsidy escrow when proposal enters trading
/// Called by proposal lifecycle when transitioning to TRADING state
/// Withdraws from DAO treasury based on protocol config
///
/// ## Arguments
/// - `proposal_id`: ID of the proposal being subsidized
/// - `dao_id`: ID of the DAO (for refund tracking)
/// - `amm_ids`: Vector of conditional AMM IDs (for security validation)
/// - `treasury_coins`: Coins from DAO treasury (calculated amount)
/// - `config`: Protocol subsidy configuration
/// - `ctx`: Transaction context
public fun create_escrow(
    proposal_id: ID,
    dao_id: ID,
    amm_ids: vector<ID>,
    treasury_coins: Coin<SUI>,
    config: &ProtocolSubsidyConfig,
    ctx: &mut TxContext,
): SubsidyEscrow {
    let total_subsidy = treasury_coins.value();
    assert!(total_subsidy > 0, EZeroSubsidy);

    let outcome_count = amm_ids.length();

    // Validate subsidy amount matches expected
    let expected_subsidy = subsidy_config::calculate_total_subsidy(config, outcome_count);
    assert!(total_subsidy == expected_subsidy, EZeroSubsidy);

    // Emit creation event
    event::emit(SubsidyEscrowCreated {
        proposal_id,
        dao_id,
        total_subsidy,
        total_cranks: subsidy_config::crank_steps(config),
        outcome_count,
        subsidy_per_outcome_per_crank: subsidy_config::subsidy_per_outcome_per_crank(config),
    });

    SubsidyEscrow {
        proposal_id,
        dao_id,
        amm_ids,
        subsidy_balance: coin::into_balance(treasury_coins),
        total_subsidy,
        cranks_completed: 0,
        total_cranks: subsidy_config::crank_steps(config),
        keeper_fee_per_crank: subsidy_config::keeper_fee_per_crank(config),
        last_crank_time: option::none(),
    }
}

/// Crank subsidy into conditional AMMs (permissionless keeper function)
///
/// ## Flow (REWARD SYSTEM):
/// 1. Verify escrow matches proposal and AMMs
/// 2. Calculate crank amount (remaining_balance / remaining_cranks)
/// 3. Calculate keeper fee (flat 0.1 SUI per crank)
/// 4. Split remaining SUI equally across all conditional AMMs
/// 5. Accumulate as LP rewards (NO price manipulation!)
/// 6. Pay keeper fee
/// 7. Update escrow state
///
/// ## CRITICAL: Stable-Only Rewards
/// Subsidies are distributed as SUI rewards (stable-side) for LPs to claim
/// Does NOT touch AMM reserves or manipulate prices
///
/// ## Arguments
/// - `escrow`: Subsidy escrow to crank from
/// - `proposal_id`: Proposal ID (security check)
/// - `conditional_pools`: Vector of conditional AMM pools (must match escrow.amm_ids)
/// - `clock`: For timestamp and rate limiting
/// - `ctx`: Transaction context (to pay keeper)
///
/// ## Returns
/// - Keeper fee coin
public fun crank_subsidy(
    escrow: &mut SubsidyEscrow,
    proposal_id: ID,
    conditional_pools: &mut vector<LiquidityPool>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<SUI> {
    // Security checks
    assert!(escrow.proposal_id == proposal_id, EProposalMismatch);
    assert!(escrow.cranks_completed < escrow.total_cranks, ESubsidyExhausted);

    // Rate limiting: ensure minimum interval between cranks
    let now = clock.timestamp_ms();
    if (escrow.last_crank_time.is_some()) {
        let last_crank = *escrow.last_crank_time.borrow();
        assert!(now >= last_crank + MIN_CRANK_INTERVAL_MS, ETooEarlyCrank);
    };

    // Verify AMM IDs match escrow
    let outcome_count = conditional_pools.length();
    assert!(outcome_count == escrow.amm_ids.length(), EAmmMismatch);

    let mut i = 0;
    while (i < outcome_count) {
        let pool = vector::borrow(conditional_pools, i);
        let pool_id = conditional_amm::get_id(pool);
        let expected_id = *vector::borrow(&escrow.amm_ids, i);
        assert!(pool_id == expected_id, EAmmMismatch);
        i = i + 1;
    };

    // Calculate crank amount (evenly distribute remaining balance across remaining cranks)
    let remaining_cranks = escrow.total_cranks - escrow.cranks_completed;
    let current_balance = escrow.subsidy_balance.value();
    let crank_amount = current_balance / remaining_cranks;
    assert!(crank_amount > 0, EInsufficientBalance);

    // Calculate keeper fee: FLAT per crank (0.1 SUI default)
    // This is correct because keeper does ONE transaction for ALL AMMs
    let keeper_fee = math::min(escrow.keeper_fee_per_crank, crank_amount);

    // Amount to distribute to AMMs (after keeper fee)
    let subsidy_amount = crank_amount - keeper_fee;

    // Split subsidy equally across all conditional AMMs
    let amount_per_amm = subsidy_amount / outcome_count;

    // If amount rounds to zero, skip this crank (insufficient subsidy)
    // This can happen when subsidy_amount < outcome_count
    if (amount_per_amm == 0) {
        // Return keeper fee anyway (keeper still did work)
        let keeper_fee_balance = escrow.subsidy_balance.split(keeper_fee);

        // Update state
        escrow.cranks_completed = escrow.cranks_completed + 1;
        escrow.last_crank_time = option::some(now);

        return coin::from_balance(keeper_fee_balance, ctx)
    };

    // CRITICAL FIX: Extract subsidy from escrow (hard backing!)
    let mut subsidy_balance = escrow.subsidy_balance.split(subsidy_amount);

    // Add to each conditional AMM as LP rewards (NOT reserves!)
    let mut j = 0;
    while (j < outcome_count) {
        let pool = vector::borrow_mut(conditional_pools, j);

        // For the last pool, add all remaining balance (handles remainder from integer division)
        let pool_reward = if (j == outcome_count - 1) {
            subsidy_balance.withdraw_all()
        } else {
            subsidy_balance.split(amount_per_amm)
        };

        // Accumulate as LP rewards (does NOT touch reserves or price!)
        conditional_amm::accumulate_subsidy_rewards(pool, pool_reward);

        j = j + 1;
    };

    // subsidy_balance should now be empty (all distributed)
    subsidy_balance.destroy_zero();

    // Update escrow state
    escrow.cranks_completed = escrow.cranks_completed + 1;
    escrow.last_crank_time = option::some(now);

    // Extract keeper fee from escrow
    let keeper_fee_balance = escrow.subsidy_balance.split(keeper_fee);

    // Emit crank event
    event::emit(SubsidyCranked {
        proposal_id: escrow.proposal_id,
        crank_number: escrow.cranks_completed,
        total_cranks: escrow.total_cranks,
        subsidy_distributed: subsidy_amount,
        amount_per_amm,
        outcome_count,
        keeper_fee,
        keeper: tx_context::sender(ctx),
        timestamp: now,
    });

    // Return keeper fee
    coin::from_balance(keeper_fee_balance, ctx)
}

/// Finalize escrow and return remaining balance to DAO treasury
/// Called after proposal ends (win or lose)
/// NOTE: This now CONSUMES the escrow (automatic cleanup)
public fun finalize_escrow(
    escrow: SubsidyEscrow,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<SUI> {
    let SubsidyEscrow {
        proposal_id,
        dao_id,
        amm_ids: _,
        subsidy_balance,
        total_subsidy: _,
        cranks_completed,
        total_cranks: _,
        keeper_fee_per_crank: _,
        last_crank_time: _,
    } = escrow;

    let remaining = subsidy_balance.value();

    // Emit finalization event
    event::emit(SubsidyFinalized {
        proposal_id,
        dao_id,
        cranks_completed,
        remaining_balance: remaining,
        timestamp: clock.timestamp_ms(),
    });

    // Extract all remaining balance (return to DAO treasury)
    coin::from_balance(subsidy_balance, ctx)
}

// === Internal Helper Functions ===
// NOTE: inject_subsidy_proportional() has been REMOVED (phantom liquidity bug)
// Subsidies are now accumulated as LP rewards via accumulate_subsidy_rewards()
//
// NOTE: The following deprecated functions have been REMOVED:
// - create_and_share_escrow() - Use proposal_lifecycle::create_subsidy_escrow_for_proposal()
// - crank_subsidy_entry() - Use proposal_lifecycle::crank_subsidy_for_proposal()
// - finalize_escrow_entry() - Auto-cleanup via proposal_lifecycle::finalize_proposal_market()
// - destroy_escrow() - Auto-cleanup via finalize_escrow() which consumes the escrow

// === Test-Only Functions ===

#[test_only]
public fun create_test_escrow(
    proposal_id: ID,
    dao_id: ID,
    amm_ids: vector<ID>,
    total_subsidy: u64,
    total_cranks: u64,
    _ctx: &mut TxContext,
): SubsidyEscrow {
    SubsidyEscrow {
        proposal_id,
        dao_id,
        amm_ids,
        subsidy_balance: balance::create_for_testing(total_subsidy),
        total_subsidy,
        cranks_completed: 0,
        total_cranks,
        keeper_fee_per_crank: 100_000_000,  // 0.1 SUI default
        last_crank_time: option::none(),
    }
}

#[test_only]
public fun destroy_test_escrow(escrow: SubsidyEscrow) {
    let SubsidyEscrow {
        proposal_id: _,
        dao_id: _,
        amm_ids: _,
        subsidy_balance,
        total_subsidy: _,
        cranks_completed: _,
        total_cranks: _,
        keeper_fee_per_crank: _,
        last_crank_time: _,
    } = escrow;

    balance::destroy_for_testing(subsidy_balance);
}

// NOTE: mark_finalized_for_testing() removed - no longer needed with owned object model
