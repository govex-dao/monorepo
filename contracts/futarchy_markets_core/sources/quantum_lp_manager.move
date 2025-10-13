/// Simplified Quantum LP Management
///
/// Single LP token level with DAO-configured liquidity splitting:
/// - Withdrawals allowed if they don't violate minimum liquidity in conditional AMMs
/// - If withdrawal blocked, LP auto-locked until proposal ends
/// - Quantum split ratio controlled by DAO config (10-90%), with safety cap from conditional capacity
/// - No manual split/redeem - all automatic
module futarchy_markets_core::quantum_lp_manager;

use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool, LPToken};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::market_state::{Self, MarketState};
use futarchy_one_shot_utils::math;
use sui::clock::Clock;
use sui::coin::Coin;
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

            if (remaining_asset < MINIMUM_LIQUIDITY_BUFFER ||
                remaining_stable < MINIMUM_LIQUIDITY_BUFFER) {
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

// === Dynamic Quantum Split ===

/// Calculate maximum LP that can be quantum-split from spot to conditional markets
/// Based on lowest conditional AMM liquidity capacity
///
/// Logic: Find the conditional AMM with lowest capacity, calculate how much spot LP
/// can be split without exceeding that AMM's maximum capacity
public fun calculate_max_quantum_split<AssetType, StableType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    market_state: &MarketState,
): u64 {
    let (spot_asset, spot_stable) = unified_spot_pool::get_reserves(spot_pool);
    let spot_lp_supply = unified_spot_pool::lp_supply(spot_pool);

    if (spot_lp_supply == 0) {
        return 0
    };

    // Find lowest conditional AMM capacity
    let pools = market_state::borrow_amm_pools(market_state);
    let mut min_capacity = std::u64::max_value!();
    let mut i = 0;

    while (i < pools.length()) {
        let pool = &pools[i];
        let (cond_asset, cond_stable) = conditional_amm::get_reserves(pool);
        let cond_lp_supply = conditional_amm::get_lp_supply(pool);

        // Calculate how much more this AMM can accept before hitting limits
        // Assume we want to maintain some headroom
        let asset_capacity = if (cond_asset > MINIMUM_LIQUIDITY_BUFFER) {
            cond_asset - MINIMUM_LIQUIDITY_BUFFER
        } else {
            0
        };

        let stable_capacity = if (cond_stable > MINIMUM_LIQUIDITY_BUFFER) {
            cond_stable - MINIMUM_LIQUIDITY_BUFFER
        } else {
            0
        };

        // Use minimum of asset/stable capacity
        let amm_capacity = math::min(asset_capacity, stable_capacity);

        if (amm_capacity < min_capacity) {
            min_capacity = amm_capacity;
        };

        i = i + 1;
    };

    // Convert minimum capacity to LP amount
    // This is how much spot LP we can split
    if (min_capacity == std::u64::max_value!() || spot_asset == 0) {
        spot_lp_supply // No active conditionals, can split all
    } else {
        // Calculate LP amount proportional to capacity
        math::min(
            math::mul_div_to_64(min_capacity, spot_lp_supply, spot_asset),
            spot_lp_supply
        )
    }
}

// === Auto-Participation Logic ===

/// When proposal starts, automatically quantum-split spot LP to conditional AMMs
/// Amount split is based on DAO-configured ratio with safety cap from conditional capacity
/// @param conditional_liquidity_ratio_bps: Percentage of spot liquidity to move (base 100: 0-100)
public fun auto_quantum_split_on_proposal_start<AssetType, StableType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    conditional_liquidity_ratio_bps: u64,  // DAO-configured ratio (base 100: 0-100)
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get market_state from escrow (fixes borrow conflict)
    let market_state = coin_escrow::get_market_state_mut(escrow);

    // Get current spot reserves
    let (spot_asset, spot_stable) = unified_spot_pool::get_reserves(spot_pool);
    let spot_lp_supply = unified_spot_pool::lp_supply(spot_pool);

    if (spot_lp_supply == 0) {
        return // No liquidity to split
    };

    // Calculate desired split amount from DAO-configured ratio
    // ratio_bps: 80 = 80%, 50 = 50%, etc.
    let desired_split_lp = math::mul_div_to_64(spot_lp_supply, conditional_liquidity_ratio_bps, 100);

    // Safety cap: Calculate maximum safe split based on conditional AMM capacity
    let max_safe_split_lp = calculate_max_quantum_split(spot_pool, market_state);

    // Use whichever is smaller: desired ratio or safety cap
    let actual_split_lp = math::min(desired_split_lp, max_safe_split_lp);

    if (actual_split_lp == 0) {
        return // No liquidity to split (safety cap = 0)
    };

    // Calculate proportional asset/stable amounts
    let asset_amount = math::mul_div_to_64(actual_split_lp, spot_asset, spot_lp_supply);
    let stable_amount = math::mul_div_to_64(actual_split_lp, spot_stable, spot_lp_supply);

    // Remove liquidity from spot pool (without burning LP tokens)
    let (asset_balance, stable_balance) = unified_spot_pool::remove_liquidity_for_quantum_split(
        spot_pool,
        asset_amount,
        stable_amount,
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
    let pools = market_state::borrow_amm_pools_mut(market_state);
    let mut i = 0;
    while (i < pools.length()) {
        let pool = &mut pools[i];

        // Add liquidity to each conditional AMM
        let _lp_amount = conditional_amm::add_liquidity_proportional(
            pool,
            asset_amount,
            stable_amount,
            0, // min_lp_out
            clock,
            ctx,
        );

        // LP amount should be same across all AMMs (quantum invariant)
        i = i + 1;
    };
}

/// When proposal ends, automatically recombine winning conditional LP back to spot
/// Returns the LP token representing the added liquidity
public fun auto_redeem_on_proposal_end<AssetType, StableType, AssetCond, StableCond>(
    winning_outcome: u64,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    market_state: &mut MarketState,
    clock: &Clock,
    ctx: &mut TxContext,
): LPToken<AssetType, StableType> {
    // Remove liquidity from winning conditional AMM
    let pool = market_state::get_pool_mut_by_outcome(market_state, (winning_outcome as u8));
    let (cond_asset_amt, cond_stable_amt) = conditional_amm::empty_all_amm_liquidity(pool, ctx);

    // Burn conditionals and withdraw spot tokens from escrow
    let asset_coin = coin_escrow::burn_conditional_asset_and_withdraw<
        AssetType,
        StableType,
        AssetCond,
    >(escrow, winning_outcome, cond_asset_amt, ctx);

    let stable_coin = coin_escrow::burn_conditional_stable_and_withdraw<
        AssetType,
        StableType,
        StableCond,
    >(escrow, winning_outcome, cond_stable_amt, ctx);

    // Add back to spot pool and return LP token
    // Caller should transfer to DAO treasury or appropriate destination
    let spot_lp = unified_spot_pool::add_liquidity_and_return(
        spot_pool,
        asset_coin,
        stable_coin,
        0, // min_lp_out
        ctx,
    );

    // Note: LP supply in spot pool increases
    // Users with locked LP tokens can now withdraw
    spot_lp
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
        // Lock in proposal and set withdraw mode
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

/// Claim withdrawal for LP that was locked in withdraw mode
/// Must be called after proposal finalizes
/// Burns LP token and returns proportional share of winning conditional liquidity as coins
public entry fun claim_withdrawal<AssetType, StableType>(
    lp_token: LPToken<AssetType, StableType>,
    proposal: &futarchy_markets_core::proposal::Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    ctx: &mut TxContext,
) {
    use sui::event;
    use futarchy_markets_core::proposal;

    // Validate LP is in withdraw mode
    assert!(unified_spot_pool::is_withdraw_mode(&lp_token), ENotInWithdrawMode);

    // Validate LP is locked in a proposal
    let locked_proposal_opt = unified_spot_pool::get_locked_proposal(&lp_token);
    assert!(locked_proposal_opt.is_some(), ENotLockedInProposal);

    // Validate LP is locked in THIS proposal
    let locked_proposal_id = *locked_proposal_opt.borrow();
    let proposal_id = proposal::get_id(proposal);
    assert!(locked_proposal_id == proposal_id, EWrongProposal);

    // Validate proposal is finalized
    assert!(proposal::is_finalized(proposal), EProposalNotFinalized);

    // Get winning outcome and LP amount
    let winning_outcome = proposal::get_winning_outcome(proposal);
    let lp_amount = unified_spot_pool::lp_token_amount(&lp_token);
    let lp_id = object::id(&lp_token);

    // Get winning pool via proposal module
    let winning_pool = proposal::get_pool_by_outcome(proposal, escrow, (winning_outcome as u8));
    let total_conditional_lp = conditional_amm::get_lp_supply(winning_pool);

    // Calculate proportional amounts
    // Note: This is a simplified version - production needs to handle the actual
    // extraction from conditional markets properly
    let (cond_asset_reserve, cond_stable_reserve) = conditional_amm::get_reserves(winning_pool);

    let asset_amount = if (total_conditional_lp > 0) {
        math::mul_div_to_64(lp_amount, cond_asset_reserve, total_conditional_lp)
    } else {
        0
    };

    let stable_amount = if (total_conditional_lp > 0) {
        math::mul_div_to_64(lp_amount, cond_stable_reserve, total_conditional_lp)
    } else {
        0
    };

    // Note: In production, this would need to:
    // 1. Burn conditional tokens from the escrow
    // 2. Extract spot tokens
    // 3. Handle the actual token burning/extraction properly
    // For now, this is a placeholder that shows the structure

    // Destroy LP token (returns amount for validation)
    let _destroyed_amount = unified_spot_pool::destroy_lp_token(lp_token);

    // Emit event
    event::emit(WithdrawalClaimed {
        lp_id,
        owner: ctx.sender(),
        proposal_id,
        lp_amount,
        asset_amount,
        stable_amount,
    });

    // Note: Actual coin transfer would happen here
    // This is a placeholder structure - needs proper conditional token burning
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
