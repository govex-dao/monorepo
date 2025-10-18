// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Simplified Quantum LP Management
///
/// Single LP token level with DAO-configured liquidity splitting:
/// - Withdrawals allowed if they don't violate minimum liquidity in conditional AMMs
/// - If withdrawal blocked, LP auto-locked until proposal ends
/// - Quantum split ratio controlled by DAO config (10-90%), with safety cap from conditional capacity
/// - No manual split/redeem - all automatic
module futarchy_markets_core::quantum_lp_manager;

use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool, LPToken};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use futarchy_markets_primitives::market_state::{Self, MarketState};
use futarchy_one_shot_utils::math;
use std::option;
use sui::clock::Clock;
use sui::coin::{Self as coin, Coin};
use sui::object::{Self, ID};
use sui::transfer;

// === Errors ===
const ELPLocked: u64 = 0;
const EInsufficientLiquidity: u64 = 1;
const EZeroAmount: u64 = 2;
const ENotInWithdrawMode: u64 = 3;
const ENotLockedInProposal: u64 = 4;
const EWrongProposal: u64 = 5;
const EProposalNotFinalized: u64 = 6;
const ENoActiveProposal: u64 = 7;

// === Constants ===
const MINIMUM_LIQUIDITY_BUFFER: u64 = 1000; // Minimum liquidity to maintain in each AMM

// === Withdrawal Check ===

/// Check if LP withdrawal would violate minimum liquidity in ANY conditional AMM
/// Returns (can_withdraw, min_violating_amm_index)
public fun would_violate_minimum_liquidity<AssetType, StableType>(
    lp_token: &LPToken<AssetType, StableType>,
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    market_state: &MarketState,
): (bool, Option<u8>) {
    let lp_amount = unified_spot_pool::lp_token_amount(lp_token);
    let total_lp_supply = unified_spot_pool::lp_supply(spot_pool);

    if (lp_amount == 0 || total_lp_supply == 0) {
        return (true, option::none())
    };

    // Check each conditional AMM
    let pools = market_state::borrow_amm_pools(market_state);
    let mut i = 0;
    while (i < pools.length()) {
        let pool = &pools[i];
        let (asset_reserve, stable_reserve) = conditional_amm::get_reserves(pool);
        let cond_lp_supply = conditional_amm::get_lp_supply(pool);

        if (cond_lp_supply > 0) {
            // Calculate proportional withdrawal from this conditional AMM
            let asset_out = math::mul_div_to_64(lp_amount, asset_reserve, cond_lp_supply);
            let stable_out = math::mul_div_to_64(lp_amount, stable_reserve, cond_lp_supply);

            // Check if remaining would be below minimum
            let remaining_asset = asset_reserve - asset_out;
            let remaining_stable = stable_reserve - stable_out;

            if (
                remaining_asset < MINIMUM_LIQUIDITY_BUFFER ||
                remaining_stable < MINIMUM_LIQUIDITY_BUFFER
            ) {
                return (false, option::some((i as u8)))
            };
        };

        i = i + 1;
    };

    (true, option::none())
}

/// Attempt to withdraw LP with minimum liquidity check
/// If withdrawal would violate minimum, LP is locked in proposal and set to withdraw mode
/// Returns: (can_withdraw_now, proposal_id_if_locked)
public fun check_and_lock_if_needed<AssetType, StableType>(
    lp_token: &mut LPToken<AssetType, StableType>,
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    market_state: &MarketState,
    proposal_id: ID,
): (bool, Option<ID>) {
    // Check if already locked
    if (unified_spot_pool::is_locked_in_proposal(lp_token)) {
        let locked_proposal = unified_spot_pool::get_locked_proposal(lp_token);
        return (false, locked_proposal)
    };

    // Check if withdrawal would violate minimum liquidity
    let (can_withdraw, _violating_amm) = would_violate_minimum_liquidity(
        lp_token,
        spot_pool,
        market_state,
    );

    if (can_withdraw) {
        // Withdrawal allowed
        (true, option::none())
    } else {
        // Lock in proposal and set withdraw mode
        unified_spot_pool::lock_in_proposal(lp_token, proposal_id);
        unified_spot_pool::set_withdraw_mode(lp_token, true);
        (false, option::some(proposal_id))
    }
}

// === Auto-Participation Logic ===

/// When proposal starts, automatically quantum-split spot LP to conditional AMMs
/// Amount split is based on DAO-configured ratio with safety cap from conditional capacity
///
/// Quantum-splits BOTH LIVE and TRANSITIONING buckets to conditionals.
/// - LIVE bucket: Will recombine back to spot.LIVE when proposal ends
/// - TRANSITIONING bucket: Will recombine to spot.WITHDRAW_ONLY (frozen for claiming)
/// - WITHDRAW_ONLY bucket: Stays in spot, not quantum-split
///
/// @param conditional_liquidity_ratio_percent: Percentage of LIVE liquidity to move (base 100: 1-99)
public fun auto_quantum_split_on_proposal_start<AssetType, StableType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    conditional_liquidity_ratio_percent: u64, // DAO-configured ratio (base 100: 1-99)
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get market_state from escrow (fixes borrow conflict)
    let market_state = coin_escrow::get_market_state_mut(escrow);

    // Get BOTH LIVE and TRANSITIONING bucket reserves
    // WITHDRAW_ONLY bucket stays in spot (frozen, ready for claiming)

    let (spot_asset_live, spot_stable_live) = unified_spot_pool::get_active_quantum_lp_reserves(spot_pool);
    let spot_lp_live = unified_spot_pool::get_active_quantum_lp_supply(spot_pool);

    // Get TRANSITIONING bucket reserves
    let (
        spot_asset_trans,
        spot_stable_trans,
        spot_lp_trans,
    ) = unified_spot_pool::get_leaving_on_proposal_end_reserves(spot_pool);

    // Total LP supply across both buckets
    let total_lp = spot_lp_live + spot_lp_trans;

    if (total_lp == 0) {
        return // No liquidity to split
    };

    // Calculate amounts to split for LIVE bucket
    // Apply ratio only to LIVE bucket (TRANSITIONING always gets 100% quantum-split)
    let live_split_ratio = conditional_liquidity_ratio_percent;
    let asset_live_split = math::mul_div_to_64(spot_asset_live, live_split_ratio, 100);
    let stable_live_split = math::mul_div_to_64(spot_stable_live, live_split_ratio, 100);
    let lp_live_split = math::mul_div_to_64(spot_lp_live, live_split_ratio, 100);

    // TRANSITIONING bucket: quantum-split 100% (users marked for withdrawal, still trading)
    let asset_trans_split = spot_asset_trans;
    let stable_trans_split = spot_stable_trans;
    let lp_trans_split = spot_lp_trans;

    // Total amounts to quantum-split
    let total_asset_split = asset_live_split + asset_trans_split;
    let total_stable_split = stable_live_split + stable_trans_split;

    if (total_asset_split == 0 || total_stable_split == 0) {
        return // No liquidity to split
    };

    // Remove liquidity from spot pool (without burning LP tokens)
    let (
        asset_balance,
        stable_balance,
    ) = unified_spot_pool::remove_liquidity_for_quantum_split_with_buckets(
        spot_pool,
        asset_live_split,
        asset_trans_split,
        stable_live_split,
        stable_trans_split,
    );

    // Deposit to escrow as quantum backing
    coin_escrow::deposit_spot_liquidity(
        escrow,
        asset_balance,
        stable_balance,
    );

    // Get market_state again for pool mutations
    let market_state = coin_escrow::get_market_state_mut(escrow);

    // Add to ALL conditional AMMs (quantum split - same amount to each)
    // IMPORTANT: This only happens at proposal START when all pools have identical ratios
    // New LP added DURING proposals stays in spot and participates in the NEXT proposal
    let pools = market_state::borrow_amm_pools_mut(market_state);
    let mut i = 0;
    while (i < pools.length()) {
        let pool = &mut pools[i];

        // Add liquidity to conditional AMM - populates reserves and LP supply
        let _lp_amount = conditional_amm::add_liquidity_proportional(
            pool,
            total_asset_split,
            total_stable_split,
            0, // min_lp_out
            clock,
            ctx,
        );

        i = i + 1;
    };

    // Update price leaderboard after liquidity changes (if initialized)
    // Prices change when liquidity is added, so we need to update the cache
    if (market_state::has_price_leaderboard(market_state)) {
        let mut i = 0;
        let n = market_state::outcome_count(market_state);
        while (i < n) {
            let pool = market_state::get_pool_mut_by_outcome(market_state, (i as u8));
            let new_price = conditional_amm::get_current_price(pool);
            market_state::update_price_in_leaderboard(market_state, i, new_price);
            i = i + 1;
        };
    };
}

/// When proposal ends, automatically recombine winning conditional LP back to spot
/// Uses bucket-aware recombination:
/// - conditional.LIVE → spot.LIVE (will quantum-split for next proposal)
/// - conditional.TRANSITIONING → spot.WITHDRAW_ONLY (frozen for claiming)
///
/// NOTE: Does NOT mint LP tokens. User LP tokens existed throughout quantum split,
/// they're now just backed by spot liquidity again after recombination.
///
/// CRITICAL FIX: Derives bucket amounts from current reserves and original LP token ratios
/// instead of using stale bucket counters (which aren't updated during swaps).
public fun auto_redeem_on_proposal_end<AssetType, StableType>(
    winning_outcome: u64,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    market_state: &mut MarketState,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Determine LIVE vs TRANSITIONING allocation using LP share ratios
    // Swaps change reserves but leave LP supply constant, so proportions stay accurate
    let pool = market_state::get_pool_by_outcome(market_state, (winning_outcome as u8));
    let (total_asset, total_stable) = conditional_amm::get_reserves(pool);
    let (
        _asset_live_bucket,
        _asset_transition_bucket,
        _stable_live_bucket,
        _stable_transition_bucket,
        lp_live_bucket,
        lp_transition_bucket,
    ) = conditional_amm::get_bucket_amounts(pool);

    let total_lp_bucket = lp_live_bucket + lp_transition_bucket;
    let (asset_live, asset_transitioning, stable_live, stable_transitioning) = if (
        total_lp_bucket == 0
    ) {
        (total_asset, 0, total_stable, 0)
    } else {
        let asset_live_calc = math::mul_div_to_64(total_asset, lp_live_bucket, total_lp_bucket);
        let stable_live_calc = math::mul_div_to_64(total_stable, lp_live_bucket, total_lp_bucket);
        (
            asset_live_calc,
            total_asset - asset_live_calc,
            stable_live_calc,
            total_stable - stable_live_calc,
        )
    };

    // Now remove liquidity from winning conditional AMM
    let pool_mut = market_state::get_pool_mut_by_outcome(market_state, (winning_outcome as u8));
    let (cond_asset_amt, cond_stable_amt) = conditional_amm::empty_all_amm_liquidity(pool_mut, ctx);

    // Withdraw matching spot balances from escrow (1:1 due to quantum liquidity invariant)
    let asset_coin = coin_escrow::withdraw_asset_balance(escrow, cond_asset_amt, ctx);
    let stable_coin = coin_escrow::withdraw_stable_balance(escrow, cond_stable_amt, ctx);

    // Add back to spot pool with DERIVED bucket amounts
    // LIVE → spot.LIVE, TRANSITIONING → spot.WITHDRAW_ONLY
    unified_spot_pool::add_liquidity_from_quantum_redeem_with_buckets(
        spot_pool,
        coin::into_balance(asset_coin),
        coin::into_balance(stable_coin),
        asset_live, // ← DERIVED from ratios, not stale counters!
        asset_transitioning,
        stable_live,
        stable_transitioning,
    );

    // Merge PENDING bucket into LIVE now that proposal has ended
    // New LP added during the proposal can now participate in future proposals
    unified_spot_pool::merge_joining_to_active_quantum_lp(spot_pool);

    // Done! User LP tokens are now backed by spot liquidity again.
    // No need to mint new LP tokens - they existed throughout the quantum split.
}

// === Entry Functions ===

/// Withdraw LP with automatic lock check
/// If withdrawal would violate minimum liquidity, LP is locked in proposal with withdraw mode
public entry fun withdraw_with_lock_check<AssetType, StableType>(
    mut lp_token: LPToken<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    market_state: &MarketState,
    proposal_id: ID,
    min_asset_out: u64,
    min_stable_out: u64,
    ctx: &mut TxContext,
) {
    use sui::event;

    // Check if already locked
    assert!(!unified_spot_pool::is_locked_in_proposal(&lp_token), ELPLocked);

    // Check if withdrawal would violate minimum liquidity
    let (can_withdraw, _) = would_violate_minimum_liquidity(
        &lp_token,
        spot_pool,
        market_state,
    );

    if (can_withdraw) {
        // Process withdrawal using existing function
        let (asset_coin, stable_coin) = unified_spot_pool::remove_liquidity(
            spot_pool,
            lp_token,
            min_asset_out,
            min_stable_out,
            ctx,
        );

        // Transfer coins to user
        transfer::public_transfer(asset_coin, ctx.sender());
        transfer::public_transfer(stable_coin, ctx.sender());
    } else {
        // Move LP share into withdraw flow and lock until proposal settles
        unified_spot_pool::mark_lp_for_withdrawal(spot_pool, &mut lp_token);

        let lp_amount = unified_spot_pool::lp_token_amount(&lp_token);
        unified_spot_pool::lock_in_proposal(&mut lp_token, proposal_id);
        unified_spot_pool::set_withdraw_mode(&mut lp_token, true);

        // Emit event for frontend tracking
        event::emit(LPLockedForWithdrawal {
            lp_id: object::id(&lp_token),
            owner: ctx.sender(),
            proposal_id,
            amount: lp_amount,
        });

        // Return locked LP token to user
        transfer::public_transfer(lp_token, ctx.sender());
    }
}

/// Unlock an LP token after the associated proposal has finalized
/// Allows users whose withdrawal was delayed to proceed with claiming
public entry fun unlock_after_proposal_finalized<AssetType, StableType>(
    lp_token: &mut LPToken<AssetType, StableType>,
    market_state: &MarketState,
) {
    assert!(unified_spot_pool::is_locked_in_proposal(lp_token), ENotLockedInProposal);

    let mut locked_proposal_opt = unified_spot_pool::get_locked_proposal(lp_token);
    assert!(locked_proposal_opt.is_some(), ENotLockedInProposal);
    let locked_proposal_id = option::extract(&mut locked_proposal_opt);
    option::destroy_none(locked_proposal_opt);

    assert!(market_state::is_finalized(market_state), EProposalNotFinalized);
    let market_id = market_state::market_id(market_state);
    assert!(market_id == locked_proposal_id, EWrongProposal);

    unified_spot_pool::unlock_from_proposal(lp_token);
}

/// Withdraw LP tokens after they've been marked for withdrawal and moved to WITHDRAW_ONLY bucket
/// This is the simple spot-only version - no conditional token complexity
///
/// Flow:
/// 1. User marks LP for withdrawal → moves LIVE → TRANSITIONING (if proposal active) or LIVE → WITHDRAW_ONLY (if no proposal)
/// 2. If proposal was active: quantum split happens, then recombination moves TRANSITIONING → WITHDRAW_ONLY
/// 3. User calls this function → withdraws from WITHDRAW_ONLY bucket as coins
///
/// NOTE: LP must be in withdraw mode and NOT locked in a proposal
public entry fun claim_withdrawal<AssetType, StableType>(
    lp_token: LPToken<AssetType, StableType>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    ctx: &mut TxContext,
) {
    use sui::event;

    // Validate LP is in withdraw mode
    assert!(unified_spot_pool::is_withdraw_mode(&lp_token), ENotInWithdrawMode);

    // Validate LP is NOT locked (if locked, must wait for proposal to end and crank to run)
    let locked_proposal_opt = unified_spot_pool::get_locked_proposal(&lp_token);
    assert!(locked_proposal_opt.is_none(), ENoActiveProposal);

    let lp_amount = unified_spot_pool::lp_token_amount(&lp_token);
    let lp_id = object::id(&lp_token);

    // Withdraw from WITHDRAW_ONLY bucket (handles all the bucket accounting)
    let (asset_coin, stable_coin) = unified_spot_pool::withdraw_lp(
        spot_pool,
        lp_token, // This burns the LP token
        ctx,
    );

    let asset_amount = coin::value(&asset_coin);
    let stable_amount = coin::value(&stable_coin);

    // Emit event for tracking
    event::emit(WithdrawalClaimed {
        lp_id,
        owner: ctx.sender(),
        proposal_id: object::id_from_address(@0x0), // No proposal (already finalized and recombined)
        lp_amount,
        asset_amount,
        stable_amount,
    });

    // Transfer coins to user
    transfer::public_transfer(asset_coin, ctx.sender());
    transfer::public_transfer(stable_coin, ctx.sender());
}

// === Events ===

public struct LPLockedForWithdrawal has copy, drop {
    lp_id: ID,
    owner: address,
    proposal_id: ID,
    amount: u64,
}

public struct WithdrawalClaimed has copy, drop {
    lp_id: ID,
    owner: address,
    proposal_id: ID,
    lp_amount: u64,
    asset_amount: u64,
    stable_amount: u64,
}
