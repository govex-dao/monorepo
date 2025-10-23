// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Handles the complete lifecycle of proposals from queue activation to intent execution
module futarchy_governance::proposal_lifecycle;

use account_actions::vault;
use account_protocol::account::{Self, Account};
use account_protocol::executable::{Self, Executable};
use account_protocol::intents::{Self, Intent};
use futarchy_core::futarchy_config::{Self, FutarchyConfig, FutarchyOutcome};
use futarchy_core::proposal_fee_manager::{Self, ProposalFeeManager};
use futarchy_core::version;
use futarchy_governance_actions::governance_intents;
use futarchy_markets_primitives::coin_escrow;
use futarchy_markets_primitives::conditional_amm;
use futarchy_markets_core::early_resolve;
use futarchy_markets_primitives::market_state::{Self, MarketState};
use futarchy_markets_core::proposal::{Self, Proposal};
use futarchy_markets_core::quantum_lp_manager;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_one_shot_utils::strategy;
use futarchy_types::init_action_specs::InitActionSpecs;
use futarchy_types::signed::{Self as signed};
use std::option;
use std::string::String;
use std::vector;
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object;

// === Errors ===
const EProposalNotActive: u64 = 1;
const EMarketNotFinalized: u64 = 2;
const EProposalNotApproved: u64 = 3;
const ENoIntentKey: u64 = 4;
const EInvalidWinningOutcome: u64 = 5;
const EIntentExpiryTooLong: u64 = 6;
const ENotEligibleForEarlyResolve: u64 = 7;
const EInsufficientSpread: u64 = 8;
const EProposalCreationBlocked: u64 = 9; // Pool launch fee decay in progress

// === Constants ===
const OUTCOME_ACCEPTED: u64 = 0;
const OUTCOME_REJECTED: u64 = 1;

// === Events ===

/// Emitted when a proposal is activated from the queue
public struct ProposalActivated has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    has_intent_spec: bool,
    timestamp: u64,
}

/// Emitted when a proposal's market is finalized
public struct ProposalMarketFinalized has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    winning_outcome: u64,
    approved: bool,
    timestamp: u64,
}

/// Emitted when a proposal's intent is executed
public struct ProposalIntentExecuted has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    intent_key: String,
    timestamp: u64,
}

/// Create a ProposalIntentExecuted event
public(package) fun new_proposal_intent_executed(
    proposal_id: ID,
    dao_id: ID,
    intent_key: String,
    timestamp: u64,
): ProposalIntentExecuted {
    ProposalIntentExecuted {
        proposal_id,
        dao_id,
        intent_key,
        timestamp,
    }
}

/// Emitted when a proposal is resolved early
public struct ProposalEarlyResolvedEvent has copy, drop {
    proposal_id: ID,
    winning_outcome: u64,
    proposal_age_ms: u64,
    keeper: address,
    keeper_reward: u64,
    timestamp: u64,
}

/// Emitted when the next proposal is reserved (locked) into PREMARKET
public struct ProposalReserved has copy, drop {
    queued_proposal_id: ID,
    premarket_proposal_id: ID,
    dao_id: ID,
    timestamp: u64,
}

// === Public Functions ===

/// Finalizes a proposal's market and determines the winning outcome
/// This should be called after trading has ended and TWAP prices are calculated
public fun finalize_proposal_market<AssetType, StableType>(
    account: &mut Account,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut futarchy_markets_primitives::coin_escrow::TokenEscrow<AssetType, StableType>,
    market_state: &mut MarketState,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    fee_manager: &mut ProposalFeeManager<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    finalize_proposal_market_internal(
        account,
        proposal,
        escrow,
        market_state,
        spot_pool,
        fee_manager,
        false,
        clock,
        ctx,
    );
}

/// Internal implementation shared by both finalization functions
fun finalize_proposal_market_internal<AssetType, StableType>(
    account: &mut Account,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut futarchy_markets_primitives::coin_escrow::TokenEscrow<AssetType, StableType>,
    market_state: &mut MarketState,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    fee_manager: &mut ProposalFeeManager<StableType>,
    _is_early_resolution: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Calculate winning outcome and get TWAPs in single computation
    let (winning_outcome, twap_prices) = calculate_winning_outcome_with_twaps(
        proposal,
        escrow,
        clock,
    );

    // Store the final TWAPs for third-party access
    proposal::set_twap_prices(proposal, twap_prices);

    // Set the winning outcome on the proposal
    proposal::set_winning_outcome(proposal, winning_outcome);

    // Finalize the market state
    market_state::finalize(market_state, winning_outcome, clock);

    // If this proposal used DAO liquidity, recombine winning liquidity and integrate its oracle data
    if (proposal::uses_dao_liquidity(proposal)) {
        // Return quantum-split liquidity back to the spot pool
        quantum_lp_manager::auto_redeem_on_proposal_end(
            winning_outcome,
            spot_pool,
            escrow,
            market_state,
            clock,
            ctx,
        );

        // CRITICAL FIX (Issue 3): Extract and clear escrow ID from spot pool
        // This clears the active escrow flag so has_active_escrow() returns false
        let _escrow_id = unified_spot_pool::extract_active_escrow(spot_pool);

        // Reborrow winning pool to read oracle after recombination
        let winning_pool_view = proposal::get_pool_by_outcome(
            proposal,
            escrow,
            winning_outcome as u8,
        );
        let winning_conditional_oracle = conditional_amm::get_simple_twap(winning_pool_view);

        // Backfill spot's SimpleTWAP with winning conditional's oracle data
        unified_spot_pool::backfill_from_winning_conditional(
            spot_pool,
            winning_conditional_oracle,
            clock,
        );

        // Crank: Transition TRANSITIONING bucket to WITHDRAW_ONLY
        // This allows LPs who marked for withdrawal to claim their coins
        futarchy_markets_operations::liquidity_interact::crank_recombine_and_transition<
            AssetType,
            StableType,
        >(spot_pool);
    };

    // NEW: Cancel losing outcome intents in the hot path using a scoped witness.
    // This ensures per-proposal isolation and prevents cross-proposal cancellation
    let num_outcomes = proposal::get_num_outcomes(proposal);
    let mut i = 0u64;
    while (i < num_outcomes) {
        if (i != winning_outcome) {
            // Mint a scoped cancel witness for this specific proposal/outcome
            let mut cw_opt = proposal::make_cancel_witness(proposal, i);
            if (option::is_some(&cw_opt)) {
                let _cw = option::extract(&mut cw_opt);
                // No additional work required: make_cancel_witness removes the spec
                // and resets the action count for this outcome in the new InitActionSpecs model.
            };
            // Properly destroy the empty option
            option::destroy_none(cw_opt);
        };
        i = i + 1;
    };

    // --- BEGIN OUTCOME CREATOR FEE REFUNDS & REWARDS ---
    // Economic model per user requirement:
    // - Outcome 0 wins: DAO keeps all fees (reject/no action taken)
    // - Outcomes 1-N win:
    //   1. Refund ALL creators of outcomes 1-N (collaborative model)
    //   2. Pay bonus reward to winning outcome creator (configurable)
    //
    // Game Theory Rationale:
    // - Eliminates fee-stealing attacks (both proposer and mutator get refunded)
    // - No incentive to hedge by creating trivial mutations
    // - Makes mutations collaborative rather than adversarial
    // - Original proposer always protected if any action is taken
    // - Encourages healthy debate without perverse incentives
    // - Winning creator gets bonus to incentivize quality
    if (winning_outcome > 0) {
        let config = account::config(account);
        let num_outcomes = proposal::get_num_outcomes(proposal);

        // 1. Refund fees to ALL creators of outcomes 1-N from proposal's fee escrow
        // SECURITY: Use per-proposal escrow instead of global protocol revenue
        // This ensures each proposal's fees are properly tracked and refunded
        let fee_escrow_balance = proposal::take_fee_escrow(proposal);
        let mut fee_escrow_coin = coin::from_balance(fee_escrow_balance, ctx);

        let mut i = 1u64;
        while (i < num_outcomes) {
            let creator_fee = proposal::get_outcome_creator_fee(proposal, i);
            if (creator_fee > 0 && fee_escrow_coin.value() >= creator_fee) {
                let creator = proposal::get_outcome_creator(proposal, i);
                let refund_coin = coin::split(&mut fee_escrow_coin, creator_fee, ctx);
                // Transfer refund to outcome creator
                transfer::public_transfer(refund_coin, creator);
            };
            i = i + 1;
        };

        // Any remaining escrow gets destroyed (no refund for outcome 0 creator/proposer)
        // Note: In StableType, not SUI, so cannot deposit to SUI-denominated protocol revenue
        if (fee_escrow_coin.value() > 0) {
            transfer::public_transfer(fee_escrow_coin, @0x0); // Burn by sending to null address
        } else {
            fee_escrow_coin.destroy_zero();
        };

        // 2. Pay bonus reward to WINNING outcome creator (if configured)
        // Note: Reward is paid in SUI from protocol revenue
        // DAOs can set this to 0 to disable, or any amount to incentivize quality outcomes
        // IMPORTANT: Skip reward if proposal used admin budget/quota
        let win_reward = futarchy_config::outcome_win_reward(config);
        let used_quota = proposal::get_used_quota(proposal);
        if (win_reward > 0 && !used_quota) {
            let winner = proposal::get_outcome_creator(proposal, winning_outcome);
            let reward_coin = proposal_fee_manager::pay_outcome_creator_reward(
                fee_manager,
                win_reward,
                ctx,
            );
            if (reward_coin.value() > 0) {
                transfer::public_transfer(reward_coin, winner);
            } else {
                reward_coin.destroy_zero();
            };
        };
    };
    // If outcome 0 wins, DAO keeps all fees - no refunds or rewards
    // --- END OUTCOME CREATOR FEE REFUNDS & REWARDS ---

    // Emit finalization event
    event::emit(ProposalMarketFinalized {
        proposal_id: proposal::get_id(proposal),
        dao_id: proposal::get_dao_id(proposal),
        winning_outcome,
        approved: winning_outcome == OUTCOME_ACCEPTED,
        timestamp: clock.timestamp_ms(),
    });
}

/// Try to resolve a proposal early if it meets eligibility criteria
/// This function can be called by anyone (typically keepers) to trigger early resolution
public entry fun try_early_resolve<AssetType, StableType>(
    account: &mut Account,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut futarchy_markets_primitives::coin_escrow::TokenEscrow<AssetType, StableType>,
    market_state: &mut MarketState,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    fee_manager: &mut ProposalFeeManager<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Extract values we need from config before using mutable account
    let config = account::config(account);
    let early_resolve_config = futarchy_config::early_resolve_config(config);
    let min_spread = futarchy_config::early_resolve_min_spread(early_resolve_config);
    let keeper_reward_bps = futarchy_config::early_resolve_keeper_reward_bps(early_resolve_config);

    // Check basic eligibility (time-based checks, stability, etc.)
    let (is_eligible, _reason) = early_resolve::check_eligibility(
        proposal,
        market_state,
        early_resolve_config,
        clock,
    );

    // Abort if not eligible
    assert!(is_eligible, ENotEligibleForEarlyResolve);

    // Calculate current winner and check spread requirement
    let (winner_idx, _winner_twap, spread) = proposal::calculate_current_winner(
        proposal,
        escrow,
        clock,
    );
    assert!(spread >= min_spread, EInsufficientSpread);

    // NEW: Additional flip count check with TWAP scaling
    let max_flips = futarchy_config::early_resolve_max_flips_in_window(early_resolve_config);
    let flip_window = futarchy_config::early_resolve_flip_window_duration(early_resolve_config);
    let twap_scaling_enabled = futarchy_config::early_resolve_twap_scaling_enabled(
        early_resolve_config,
    );

    let current_time = clock.timestamp_ms();
    let cutoff_time = if (current_time > flip_window) {
        current_time - flip_window
    } else {
        0
    };
    let flips_in_window = market_state::count_flips_in_window(market_state, cutoff_time);

    // Calculate effective max flips with TWAP scaling if enabled
    let effective_max_flips = if (twap_scaling_enabled && min_spread > 0) {
        // Scale flip tolerance based on current spread
        // Formula: base + (base * scale_factor) = base * (1 + scale_factor)
        // Example at 4% spread (min_spread = 4%):
        //   scale_factor = 1, effective = 1 + 1 = 2 flips
        // Example at 8% spread:
        //   scale_factor = 2, effective = 1 + 2 = 3 flips
        let scale_factor = (spread / min_spread) as u64;
        max_flips + (max_flips * scale_factor)
    } else {
        max_flips
    };

    // Check if flips exceed effective maximum
    assert!(flips_in_window <= effective_max_flips, ENotEligibleForEarlyResolve);

    // Get proposal age for event
    let start_time = if (proposal::get_market_initialized_at(proposal) > 0) {
        proposal::get_market_initialized_at(proposal)
    } else {
        proposal::get_created_at(proposal)
    };
    let proposal_age_ms = clock.timestamp_ms() - start_time;

    // Call standard finalization
    finalize_proposal_market(
        account,
        proposal,
        escrow,
        market_state,
        spot_pool,
        fee_manager,
        clock,
        ctx,
    );

    // Keeper reward payment: Use outcome creator reward mechanism
    // The keeper gets rewarded from protocol fees
    let keeper_reward = if (keeper_reward_bps > 0) {
        // Use outcome creator reward function for keeper payment
        let reward_amount = 100_000_000u64; // 0.1 SUI fixed reward
        let reward_coin = proposal_fee_manager::pay_outcome_creator_reward(
            fee_manager,
            reward_amount,
            ctx,
        );
        let actual_reward = reward_coin.value();
        transfer::public_transfer(reward_coin, ctx.sender());
        actual_reward
    } else {
        0
    };

    // Emit early resolution event (create our own copy since early_resolve::ProposalEarlyResolved is package-only)
    event::emit(ProposalEarlyResolvedEvent {
        proposal_id: proposal::get_id(proposal),
        winning_outcome: winner_idx,
        proposal_age_ms,
        keeper: ctx.sender(),
        keeper_reward,
        timestamp: clock.timestamp_ms(),
    });
}

// === Proposal State Transitions with Quantum Split ===

/// Advances proposal state and handles quantum liquidity operations
/// Call this periodically to transition proposals through their lifecycle
///
/// CRITICAL: Respects withdraw_only_mode flag to prevent auto-reinvestment
/// If previous proposal has withdraw_only_mode=true, its liquidity will NOT be quantum-split
public entry fun advance_proposal_state<AssetType, StableType>(
    account: &mut Account,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut futarchy_markets_primitives::coin_escrow::TokenEscrow<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    // Try to advance the proposal state
    let state_changed = proposal::advance_state(proposal, escrow, clock, ctx);

    // If state just changed to TRADING and proposal uses DAO liquidity
    if (state_changed && proposal::is_live(proposal) && proposal::uses_dao_liquidity(proposal)) {
        // CRITICAL: Check withdraw_only_mode flag before quantum split
        // If liquidity provider wants to withdraw after this proposal ends,
        // we should NOT quantum-split their liquidity for trading
        if (!proposal::is_withdraw_only(proposal)) {
            // Get conditional liquidity ratio from DAO config
            let config = account::config(account);
            let conditional_liquidity_ratio_percent = futarchy_config::conditional_liquidity_ratio_percent(
                config,
            );

            // Perform quantum split: move liquidity from spot to conditional markets
            quantum_lp_manager::auto_quantum_split_on_proposal_start(
                spot_pool,
                escrow,
                conditional_liquidity_ratio_percent,
                clock,
                ctx,
            );

            // CRITICAL FIX (Issue 3): Store escrow ID in spot pool
            // This enables has_active_escrow() to return true, which routes LPs to TRANSITIONING bucket
            let escrow_id = object::id(escrow);
            unified_spot_pool::store_active_escrow(spot_pool, escrow_id);
        };
        // If withdraw_only_mode = true, skip quantum split
        // Liquidity will be returned to provider when proposal finalizes
    };

    state_changed
}

// === Helper Functions ===

/// Checks if a proposal can be executed
public fun can_execute_proposal<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    market: &MarketState,
): bool {
    // Market must be finalized
    if (!market_state::is_finalized(market)) {
        return false
    };

    // Proposal must have been approved (YES outcome)
    let winning_outcome = market_state::get_winning_outcome(market);
    if (winning_outcome != OUTCOME_ACCEPTED) {
        return false
    };

    // InitActionSpecs are now stored directly in proposals (no separate intent key system)
    // No additional check needed - if proposal is finalized with ACCEPTED outcome, it can execute
    true
}

/// Calculates the winning outcome and returns TWAP prices to avoid double computation
/// Returns (outcome, twap_prices) where outcome is OUTCOME_ACCEPTED or OUTCOME_REJECTED
/// IMPORTANT: Uses effective threshold which accounts for sponsorship reduction
public fun calculate_winning_outcome_with_twaps<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut futarchy_markets_primitives::coin_escrow::TokenEscrow<AssetType, StableType>,
    clock: &Clock,
): (u64, vector<u128>) {
    // Get TWAP prices from all pools (only computed once now)
    let twap_prices = proposal::get_twaps_for_proposal(proposal, escrow, clock);

    // For a simple YES/NO proposal, compare the YES TWAP to the threshold
    let winning_outcome = if (twap_prices.length() >= 2) {
        let yes_twap = *twap_prices.borrow(OUTCOME_ACCEPTED);

        // CRITICAL: Use effective threshold which accounts for sponsorship reduction
        // If proposal is sponsored, this returns (base_threshold - sponsor_reduction)
        // making it easier for the proposal to pass
        let threshold = proposal::get_effective_twap_threshold(proposal);
        let yes_signed = signed::from_u128(yes_twap);

        // If YES TWAP exceeds threshold, YES wins
        if (signed::compare(&yes_signed, &threshold) == signed::ordering_greater()) {
            OUTCOME_ACCEPTED
        } else {
            OUTCOME_REJECTED
        }
    } else {
        // Default to NO if we can't determine
        OUTCOME_REJECTED
    };

    (winning_outcome, twap_prices)
}

// === Helper Functions for PTB Execution ===

public fun is_passed<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): bool {
    use futarchy_markets_core::proposal as proposal_mod;
    proposal_mod::is_finalized(proposal) && proposal_mod::get_winning_outcome(proposal) == OUTCOME_ACCEPTED
}
