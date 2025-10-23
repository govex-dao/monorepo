// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// ============================================================================
/// UNIFIED SPOT POOL - Single pool type with optional aggregator support
/// ============================================================================
///
/// DESIGN GOALS:
/// - Replace both SpotAMM and AccountSpotPool with single unified type
/// - Optional aggregator features (zero overhead when disabled)
/// - NO circular dependencies (uses IDs, not concrete types)
/// - Backward compatible initialization
///
/// DEPENDENCY SAFETY:
/// This module ONLY imports:
/// - sui framework (clock, balance, coin, etc.)
/// - futarchy_markets basic types (simple_twap, coin_escrow)
/// - Does NOT import: proposal or lifecycle modules
///
/// This ensures: proposal.move → unified_spot_pool (one-way dependency)
///
/// ============================================================================

module futarchy_markets_core::unified_spot_pool;

use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::PCW_TWAP_oracle::{Self, SimpleTWAP};
use futarchy_markets_primitives::fee_scheduler::{Self, FeeSchedule};
use std::option::{Self, Option};
use std::type_name::TypeName;
use std::vector;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::object::{Self, UID, ID};
use sui::transfer;

// === Errors ===
const EInsufficientLiquidity: u64 = 1;
const EInsufficientLPSupply: u64 = 3;
const EZeroAmount: u64 = 4;
const ESlippageExceeded: u64 = 5;
const EMinimumLiquidityNotMet: u64 = 6;
const ENoActiveProposal: u64 = 7;
const EAggregatorNotEnabled: u64 = 11;
const EPoolMismatch: u64 = 12;
const ELpStateMismatch: u64 = 13;
const EInvalidSplitAmount: u64 = 14;

// === Constants ===
const MINIMUM_LIQUIDITY: u64 = 1000;
const PRECISION: u128 = 1_000_000_000_000; // 1e12 for price calculations

// === Structs ===

/// Unified spot pool with optional aggregator support
public struct UnifiedSpotPool<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    // Core AMM fields
    asset_reserve: Balance<AssetType>,
    stable_reserve: Balance<StableType>,
    lp_supply: u64,
    fee_bps: u64, // Static fee (used if fee_schedule is None)
    minimum_liquidity: u64,
    // Dynamic fee scheduling (optional, for launchpad anti-snipe)
    fee_schedule: Option<FeeSchedule>,
    fee_schedule_activation_time: u64, // When fee decay starts (usually pool creation)
    // Bucket tracking for LP withdrawal system - HYPER EXPLICIT NAMES
    //
    // spot_active_quantum_lp:
    //   - Normal active LP that quantum-splits when proposals start
    //   - Can be removed anytime (if no proposal active)
    //
    // spot_leave_lp_when_proposal_ends:
    //   - User marked for exit during active proposal
    //   - Gets one final quantum-split to conditionals
    //   - Becomes spot_frozen_claimable_lp when proposal ends
    //
    // spot_frozen_claimable_lp:
    //   - Fully withdrawn, ready for user to claim
    //   - Does NOT quantum-split (stays in spot)
    //   - Final destination before burning LP token
    //
    // spot_join_quantum_lp_when_proposal_ends:
    //   - New LP added during active proposal
    //   - Does NOT quantum-split to current proposal (isolated from outcome)
    //   - Becomes spot_active_quantum_lp when proposal ends
    asset_spot_active_quantum_lp: u64,
    asset_spot_leave_lp_when_proposal_ends: u64,
    asset_spot_frozen_claimable_lp: u64,
    asset_spot_join_quantum_lp_when_proposal_ends: u64,
    stable_spot_active_quantum_lp: u64,
    stable_spot_leave_lp_when_proposal_ends: u64,
    stable_spot_frozen_claimable_lp: u64,
    stable_spot_join_quantum_lp_when_proposal_ends: u64,
    lp_spot_active_quantum_lp: u64,
    lp_spot_leave_lp_when_proposal_ends: u64,
    lp_spot_frozen_claimable_lp: u64,
    lp_spot_join_quantum_lp_when_proposal_ends: u64,
    // Optional aggregator configuration
    aggregator_config: Option<AggregatorConfig<AssetType, StableType>>,
}

/// Aggregator-specific configuration (only present when enabled)
public struct AggregatorConfig<phantom AssetType, phantom StableType> has store {
    // Active escrow ID for proposal trading
    // Stored when proposal starts, cleared when proposal ends
    // NOTE: We store ID (not TokenEscrow) because shared objects can't be stored in owned objects
    active_escrow: Option<ID>,
    // TWAP oracle for price feeds
    simple_twap: SimpleTWAP,
    // Liquidity tracking for oracle switching
    last_proposal_usage: Option<u64>,
    conditional_liquidity_ratio_percent: u64, // 1-99 (base 100, enforced by DAO config)
    oracle_conditional_threshold_bps: u64, // When to use conditional vs spot oracle
    spot_cumulative_at_lock: Option<u256>,
    // Protocol fees (separate from LP fees) - collected in both asset and stable tokens
    protocol_fees_asset: Balance<AssetType>,
    protocol_fees_stable: Balance<StableType>,
}

/// LP Token - represents ownership of pool liquidity
public struct LPToken<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    /// Amount of LP tokens
    amount: u64,
    /// Parent pool that minted this LP
    pool_id: ID,
    /// Proposal lock - if Some(id), LP is locked in proposal {id}
    /// Liquidity is quantum-split to conditional markets during proposal
    /// None = LP is in spot pool and can be withdrawn freely
    locked_in_proposal: Option<ID>,
    /// Withdraw mode - if true, extract as coins when proposal ends
    /// If false (default), auto-recombine to spot LP when proposal ends
    /// Set to true when user tries to withdraw but would violate minimum liquidity
    withdraw_mode: bool,
}

// === LP Token Functions ===

/// Get LP token amount
public fun lp_token_amount<AssetType, StableType>(lp_token: &LPToken<AssetType, StableType>): u64 {
    lp_token.amount
}

/// Get the pool ID this LP belongs to
public fun lp_token_pool_id<AssetType, StableType>(lp_token: &LPToken<AssetType, StableType>): ID {
    lp_token.pool_id
}

/// Check if LP is locked in a proposal
/// Returns true if locked and proposal is not finalized
public fun is_locked_in_proposal<AssetType, StableType>(
    lp_token: &LPToken<AssetType, StableType>,
): bool {
    lp_token.locked_in_proposal.is_some()
}

/// Get the proposal ID this LP is locked in
public fun get_locked_proposal<AssetType, StableType>(
    lp_token: &LPToken<AssetType, StableType>,
): Option<ID> {
    lp_token.locked_in_proposal
}

/// Check if LP is in withdraw mode
public fun is_withdraw_mode<AssetType, StableType>(
    lp_token: &LPToken<AssetType, StableType>,
): bool {
    lp_token.withdraw_mode
}

/// Lock LP in a proposal (package-visible for quantum_lp_manager)
public(package) fun lock_in_proposal<AssetType, StableType>(
    lp_token: &mut LPToken<AssetType, StableType>,
    proposal_id: ID,
) {
    lp_token.locked_in_proposal = option::some(proposal_id);
}

/// Unlock LP from proposal (package-visible for quantum_lp_manager)
public(package) fun unlock_from_proposal<AssetType, StableType>(
    lp_token: &mut LPToken<AssetType, StableType>,
) {
    lp_token.locked_in_proposal = option::none();
}

/// Set withdraw mode (package-visible for quantum_lp_manager)
public(package) fun set_withdraw_mode<AssetType, StableType>(
    lp_token: &mut LPToken<AssetType, StableType>,
    mode: bool,
) {
    lp_token.withdraw_mode = mode;
}

/// Destroy LP token (package-visible for quantum_lp_manager claim flow)
/// Returns the LP amount for calculation purposes
public(package) fun destroy_lp_token<AssetType, StableType>(
    lp_token: LPToken<AssetType, StableType>,
): u64 {
    let LPToken { id, amount, pool_id: _, locked_in_proposal: _, withdraw_mode: _ } = lp_token;
    object::delete(id);
    amount
}

// === Creation Functions ===

/// Create a basic pool without aggregator support
/// This is lightweight - no TWAP, no registry, minimal overhead
public fun new<AssetType, StableType>(
    fee_bps: u64,
    fee_schedule: Option<FeeSchedule>, // Optional dynamic fee schedule (for launchpad)
    clock: &Clock,                     // For recording activation time
    ctx: &mut TxContext,
): UnifiedSpotPool<AssetType, StableType> {
    UnifiedSpotPool {
        id: object::new(ctx),
        asset_reserve: balance::zero(),
        stable_reserve: balance::zero(),
        lp_supply: 0,
        fee_bps,
        minimum_liquidity: MINIMUM_LIQUIDITY,
        // Fee schedule (optional dynamic fees)
        fee_schedule,
        fee_schedule_activation_time: clock.timestamp_ms(),
        // Initialize all bucket system to zero
        asset_spot_active_quantum_lp: 0,
        asset_spot_leave_lp_when_proposal_ends: 0,
        asset_spot_frozen_claimable_lp: 0,
        asset_spot_join_quantum_lp_when_proposal_ends: 0,
        stable_spot_active_quantum_lp: 0,
        stable_spot_leave_lp_when_proposal_ends: 0,
        stable_spot_frozen_claimable_lp: 0,
        stable_spot_join_quantum_lp_when_proposal_ends: 0,
        lp_spot_active_quantum_lp: 0,
        lp_spot_leave_lp_when_proposal_ends: 0,
        lp_spot_frozen_claimable_lp: 0,
        lp_spot_join_quantum_lp_when_proposal_ends: 0,
        aggregator_config: option::none(),
    }
}

/// Create a pool WITH aggregator support
/// This includes TWAP oracle and all aggregator features
public fun new_with_aggregator<AssetType, StableType>(
    fee_bps: u64,
    fee_schedule: Option<FeeSchedule>, // Optional dynamic fee schedule (for launchpad)
    oracle_conditional_threshold_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): UnifiedSpotPool<AssetType, StableType> {
    let simple_twap = PCW_TWAP_oracle::new_default(0, clock); // Initialize with 0 price (will be updated on first swap)

    let aggregator_config = AggregatorConfig {
        active_escrow: option::none(),
        simple_twap,
        last_proposal_usage: option::none(),
        conditional_liquidity_ratio_percent: 0,
        oracle_conditional_threshold_bps,
        spot_cumulative_at_lock: option::none(),
        protocol_fees_asset: balance::zero(),
        protocol_fees_stable: balance::zero(),
    };

    UnifiedSpotPool {
        id: object::new(ctx),
        asset_reserve: balance::zero(),
        stable_reserve: balance::zero(),
        lp_supply: 0,
        fee_bps,
        minimum_liquidity: MINIMUM_LIQUIDITY,
        // Fee schedule (optional dynamic fees)
        fee_schedule,
        fee_schedule_activation_time: clock.timestamp_ms(),
        // Initialize all bucket system to zero
        asset_spot_active_quantum_lp: 0,
        asset_spot_leave_lp_when_proposal_ends: 0,
        asset_spot_frozen_claimable_lp: 0,
        asset_spot_join_quantum_lp_when_proposal_ends: 0,
        stable_spot_active_quantum_lp: 0,
        stable_spot_leave_lp_when_proposal_ends: 0,
        stable_spot_frozen_claimable_lp: 0,
        stable_spot_join_quantum_lp_when_proposal_ends: 0,
        lp_spot_active_quantum_lp: 0,
        lp_spot_leave_lp_when_proposal_ends: 0,
        lp_spot_frozen_claimable_lp: 0,
        lp_spot_join_quantum_lp_when_proposal_ends: 0,
        aggregator_config: option::some(aggregator_config),
    }
}

/// Upgrade existing pool to add aggregator support
/// Can be called via governance to enable aggregator features
public fun enable_aggregator<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    oracle_conditional_threshold_bps: u64,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Only enable if not already enabled
    if (pool.aggregator_config.is_none()) {
        let simple_twap = PCW_TWAP_oracle::new_default(get_spot_price(pool), clock); // Initialize with current price

        let config = AggregatorConfig {
            active_escrow: option::none(),
            simple_twap,
            last_proposal_usage: option::none(),
            conditional_liquidity_ratio_percent: 0,
            oracle_conditional_threshold_bps,
            spot_cumulative_at_lock: option::none(),
            protocol_fees_asset: balance::zero(),
            protocol_fees_stable: balance::zero(),
        };

        option::fill(&mut pool.aggregator_config, config);
    }
}

// === Escrow Management Functions (Aggregator Only) ===

/// Store active escrow ID when proposal starts trading
/// NOTE: Takes ID (not TokenEscrow object) because shared objects can't be stored
public fun store_active_escrow<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    escrow_id: ID,
) {
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow_mut();
    assert!(config.active_escrow.is_none(), ENoActiveProposal); // Must not already have escrow
    option::fill(&mut config.active_escrow, escrow_id);
}

/// Extract active escrow ID when proposal ends
/// Returns the escrow ID to caller (to look up the shared object)
public fun extract_active_escrow<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
): ID {
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow_mut();
    assert!(config.active_escrow.is_some(), ENoActiveProposal); // Must have escrow
    option::extract(&mut config.active_escrow)
}

/// Get active escrow ID (read-only)
/// Returns None if no active escrow
public fun get_active_escrow_id<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
): Option<ID> {
    if (pool.aggregator_config.is_none()) {
        return option::none()
    };
    let config = pool.aggregator_config.borrow();
    config.active_escrow
}

// === Core AMM Functions ===

/// Add liquidity to the pool and return LP token
///
/// IMPORTANT: LP can be added anytime, including during active proposals.
/// - If no proposal active: LP goes to LIVE bucket (participates immediately)
/// - If proposal active: LP goes to PENDING bucket (joins spot pool when proposal ends)
///
/// This prevents new LP from unfairly benefiting from conditional market outcomes.
public fun add_liquidity<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    min_lp_out: u64,
    ctx: &mut TxContext,
): LPToken<AssetType, StableType> {
    add_liquidity_and_return(pool, asset_coin, stable_coin, min_lp_out, ctx)
}

/// Add liquidity and return LP token (explicit name for clarity)
public fun add_liquidity_and_return<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    min_lp_out: u64,
    ctx: &mut TxContext,
): LPToken<AssetType, StableType> {
    let asset_amount = coin::value(&asset_coin);
    let stable_amount = coin::value(&stable_coin);

    assert!(asset_amount > 0 && stable_amount > 0, EZeroAmount);

    // Calculate LP tokens to mint
    let lp_amount = if (pool.lp_supply == 0) {
        // Initial liquidity
        let product = (asset_amount as u128) * (stable_amount as u128);
        let initial_lp = (product.sqrt() as u64);
        assert!(initial_lp >= pool.minimum_liquidity, EMinimumLiquidityNotMet);

        // Lock minimum liquidity permanently
        pool.lp_supply = pool.minimum_liquidity;
        initial_lp - pool.minimum_liquidity
    } else {
        // Proportional liquidity based on current reserves
        // NOTE: This function is now blocked during active proposals,
        // so we always use actual spot reserves (no quantum-split complexity)
        let asset_reserve = balance::value(&pool.asset_reserve);
        let stable_reserve = balance::value(&pool.stable_reserve);

        let lp_from_asset =
            (asset_amount as u128) * (pool.lp_supply as u128) / (asset_reserve as u128);
        let lp_from_stable =
            (stable_amount as u128) * (pool.lp_supply as u128) / (stable_reserve as u128);

        ((lp_from_asset.min(lp_from_stable)) as u64)
    };

    assert!(lp_amount >= min_lp_out, ESlippageExceeded);

    // Add to reserves
    balance::join(&mut pool.asset_reserve, coin::into_balance(asset_coin));
    balance::join(&mut pool.stable_reserve, coin::into_balance(stable_coin));

    pool.lp_supply = pool.lp_supply + lp_amount;

    // Route to appropriate bucket based on proposal status
    if (is_locked_for_proposal(pool)) {
        // Proposal is active - add to PENDING bucket
        // This LP will merge into LIVE when proposal ends
        pool.asset_spot_join_quantum_lp_when_proposal_ends = pool.asset_spot_join_quantum_lp_when_proposal_ends + asset_amount;
        pool.stable_spot_join_quantum_lp_when_proposal_ends = pool.stable_spot_join_quantum_lp_when_proposal_ends + stable_amount;
        pool.lp_spot_join_quantum_lp_when_proposal_ends = pool.lp_spot_join_quantum_lp_when_proposal_ends + lp_amount;
    } else {
        // No active proposal - add to LIVE bucket
        pool.asset_spot_active_quantum_lp = pool.asset_spot_active_quantum_lp + asset_amount;
        pool.stable_spot_active_quantum_lp = pool.stable_spot_active_quantum_lp + stable_amount;
        pool.lp_spot_active_quantum_lp = pool.lp_spot_active_quantum_lp + lp_amount;
    };

    // Create and return LP token (unlocked, normal mode by default)
    LPToken<AssetType, StableType> {
        id: object::new(ctx),
        amount: lp_amount,
        pool_id: object::uid_to_inner(&pool.id),
        locked_in_proposal: option::none(),
        withdraw_mode: false,
    }
}

/// Merge PENDING bucket into LIVE bucket
/// Called after proposal ends to activate LP that was added during the proposal
public(package) fun merge_joining_to_active_quantum_lp<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
) {
    pool.asset_spot_active_quantum_lp = pool.asset_spot_active_quantum_lp + pool.asset_spot_join_quantum_lp_when_proposal_ends;
    pool.stable_spot_active_quantum_lp = pool.stable_spot_active_quantum_lp + pool.stable_spot_join_quantum_lp_when_proposal_ends;
    pool.lp_spot_active_quantum_lp = pool.lp_spot_active_quantum_lp + pool.lp_spot_join_quantum_lp_when_proposal_ends;

    // Reset pending buckets to zero
    pool.asset_spot_join_quantum_lp_when_proposal_ends = 0;
    pool.stable_spot_join_quantum_lp_when_proposal_ends = 0;
    pool.lp_spot_join_quantum_lp_when_proposal_ends = 0;
}

/// Remove liquidity from the pool
/// NOTE: This function is for removing from LIVE bucket ONLY
/// For withdrawal after marking, use mark_lp_for_withdrawal() + withdraw_lp()
public fun remove_liquidity<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    lp_token: LPToken<AssetType, StableType>,
    min_asset_out: u64,
    min_stable_out: u64,
    ctx: &mut TxContext,
): (Coin<AssetType>, Coin<StableType>) {
    let lp_amount = lp_token.amount;
    assert!(lp_amount > 0, EZeroAmount);
    assert!(pool.lp_supply >= lp_amount, EInsufficientLPSupply);

    // CRITICAL: Check LP token state - can only remove from LIVE bucket
    assert!(!lp_token.withdraw_mode, EInsufficientLiquidity); // Use mark_lp_for_withdrawal() + withdraw_lp() instead
    assert!(lp_token.locked_in_proposal.is_none(), ENoActiveProposal); // Can't remove while locked

    // Calculate proportional amounts from total reserves
    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    let asset_out = (asset_reserve as u128) * (lp_amount as u128) / (pool.lp_supply as u128);
    let stable_out = (stable_reserve as u128) * (lp_amount as u128) / (pool.lp_supply as u128);

    assert!((asset_out as u64) >= min_asset_out, ESlippageExceeded);
    assert!((stable_out as u64) >= min_stable_out, ESlippageExceeded);

    // Burn LP token
    let LPToken { id, amount: _, pool_id: _, locked_in_proposal: _, withdraw_mode: _ } = lp_token;
    object::delete(id);

    // Update total supply
    pool.lp_supply = pool.lp_supply - lp_amount;

    // CRITICAL FIX: Update bucket tracking (remove from LIVE bucket)
    // Calculate proportional amounts from LIVE bucket
    let asset_from_live = (lp_amount as u128) * (pool.asset_spot_active_quantum_lp as u128) / (pool.lp_spot_active_quantum_lp as u128);
    let stable_from_live =
        (lp_amount as u128) * (pool.stable_spot_active_quantum_lp as u128) / (pool.lp_spot_active_quantum_lp as u128);

    pool.lp_spot_active_quantum_lp = pool.lp_spot_active_quantum_lp - lp_amount;
    pool.asset_spot_active_quantum_lp = pool.asset_spot_active_quantum_lp - (asset_from_live as u64);
    pool.stable_spot_active_quantum_lp = pool.stable_spot_active_quantum_lp - (stable_from_live as u64);

    // Return assets
    let asset_coin = coin::from_balance(
        balance::split(&mut pool.asset_reserve, (asset_out as u64)),
        ctx,
    );
    let stable_coin = coin::from_balance(
        balance::split(&mut pool.stable_reserve, (stable_out as u64)),
        ctx,
    );

    // CRITICAL: Ensure remaining pool maintains minimum liquidity requirement
    // Three-layer defense:
    // 1. Protocol min (100,000 via DAO config) - prevents misconfiguration
    // 2. Check k >= 1000 - Uniswap V2 invariant (basic protection)
    // 3. Check against active ratio - Future-proof for multi-proposal scenarios
    let remaining_asset = balance::value(&pool.asset_reserve);
    let remaining_stable = balance::value(&pool.stable_reserve);
    let remaining_k = (remaining_asset as u128) * (remaining_stable as u128);

    // Basic check: k >= 1000 (Uniswap V2 minimum)
    assert!(remaining_k >= (MINIMUM_LIQUIDITY as u128), EMinimumLiquidityNotMet);

    // Enhanced check: If proposal is active with stored ratio, validate against that ratio
    // This handles future multi-proposal scenarios where ratio might change during active proposals
    // Current model: one proposal at a time (ratio stored, used, then reset to 0)
    // Future model: multiple proposals could require stacked ratio validation
    if (pool.aggregator_config.is_some()) {
        let config = pool.aggregator_config.borrow();
        let active_ratio = config.conditional_liquidity_ratio_percent;

        // If ratio is active (non-zero), ensure remaining liquidity could support that ratio
        // with k >= 1000 after a quantum split
        if (active_ratio > 0) {
            let spot_ratio = 100 - active_ratio;
            let projected_spot_asset = (remaining_asset as u128) * (spot_ratio as u128) / 100u128;
            let projected_spot_stable = (remaining_stable as u128) * (spot_ratio as u128) / 100u128;
            let projected_k = projected_spot_asset * projected_spot_stable;
            assert!(projected_k >= (MINIMUM_LIQUIDITY as u128), EMinimumLiquidityNotMet);
        };
    };

    (asset_coin, stable_coin)
}

// === LP Withdrawal System ===

/// Mark LP for withdrawal - user triggers this to exit
/// If proposal is active: moves LIVE → TRANSITIONING (still trades)
/// If no proposal: moves LIVE → WITHDRAW_ONLY (immediate)
public entry fun mark_lp_for_withdrawal<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    lp_token: &mut LPToken<AssetType, StableType>,
) {
    // Can't mark for withdrawal if already locked in a proposal
    assert!(lp_token.locked_in_proposal.is_none(), ENoActiveProposal);

    // Can't mark twice
    assert!(!lp_token.withdraw_mode, EInsufficientLiquidity);

    let lp_amount = lp_token.amount;
    assert!(lp_amount > 0, EZeroAmount);

    // Check if there's an active proposal
    let proposal_active = is_locked_for_proposal(pool);

    if (proposal_active) {
        // Move from LIVE → TRANSITIONING
        // Calculate proportional share of LIVE bucket
        assert!(pool.lp_spot_active_quantum_lp >= lp_amount, EInsufficientLPSupply);

        let asset_to_move =
            (lp_amount as u128) * (pool.asset_spot_active_quantum_lp as u128) / (pool.lp_spot_active_quantum_lp as u128);
        let stable_to_move =
            (lp_amount as u128) * (pool.stable_spot_active_quantum_lp as u128) / (pool.lp_spot_active_quantum_lp as u128);

        // Update buckets
        pool.lp_spot_active_quantum_lp = pool.lp_spot_active_quantum_lp - lp_amount;
        pool.lp_spot_leave_lp_when_proposal_ends = pool.lp_spot_leave_lp_when_proposal_ends + lp_amount;

        pool.asset_spot_active_quantum_lp = pool.asset_spot_active_quantum_lp - (asset_to_move as u64);
        pool.asset_spot_leave_lp_when_proposal_ends = pool.asset_spot_leave_lp_when_proposal_ends + (asset_to_move as u64);

        pool.stable_spot_active_quantum_lp = pool.stable_spot_active_quantum_lp - (stable_to_move as u64);
        pool.stable_spot_leave_lp_when_proposal_ends = pool.stable_spot_leave_lp_when_proposal_ends + (stable_to_move as u64);
    } else {
        // Move from LIVE → WITHDRAW_ONLY (immediate)
        assert!(pool.lp_spot_active_quantum_lp >= lp_amount, EInsufficientLPSupply);

        let asset_to_move =
            (lp_amount as u128) * (pool.asset_spot_active_quantum_lp as u128) / (pool.lp_spot_active_quantum_lp as u128);
        let stable_to_move =
            (lp_amount as u128) * (pool.stable_spot_active_quantum_lp as u128) / (pool.lp_spot_active_quantum_lp as u128);

        // Update buckets
        pool.lp_spot_active_quantum_lp = pool.lp_spot_active_quantum_lp - lp_amount;
        pool.lp_spot_frozen_claimable_lp = pool.lp_spot_frozen_claimable_lp + lp_amount;

        pool.asset_spot_active_quantum_lp = pool.asset_spot_active_quantum_lp - (asset_to_move as u64);
        pool.asset_spot_frozen_claimable_lp = pool.asset_spot_frozen_claimable_lp + (asset_to_move as u64);

        pool.stable_spot_active_quantum_lp = pool.stable_spot_active_quantum_lp - (stable_to_move as u64);
        pool.stable_spot_frozen_claimable_lp = pool.stable_spot_frozen_claimable_lp + (stable_to_move as u64);
    };

    // Mark token as in withdraw mode
    lp_token.withdraw_mode = true;
}

/// Withdraw LP after it's been marked and crank has run
/// Burns the LP token and returns coins from WITHDRAW_ONLY bucket
public fun withdraw_lp<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    lp_token: LPToken<AssetType, StableType>,
    ctx: &mut TxContext,
): (Coin<AssetType>, Coin<StableType>) {
    // Must be marked for withdrawal
    assert!(lp_token.withdraw_mode, EInsufficientLiquidity);

    // Must not be locked in a proposal
    assert!(lp_token.locked_in_proposal.is_none(), ENoActiveProposal);

    let lp_amount = lp_token.amount;
    assert!(lp_amount > 0, EZeroAmount);
    assert!(pool.lp_spot_frozen_claimable_lp >= lp_amount, EInsufficientLPSupply);

    // Calculate proportional share of WITHDRAW_ONLY bucket
    let asset_out =
        (lp_amount as u128) * (pool.asset_spot_frozen_claimable_lp as u128) / (pool.lp_spot_frozen_claimable_lp as u128);
    let stable_out =
        (lp_amount as u128) * (pool.stable_spot_frozen_claimable_lp as u128) / (pool.lp_spot_frozen_claimable_lp as u128);

    // Update buckets
    pool.lp_spot_frozen_claimable_lp = pool.lp_spot_frozen_claimable_lp - lp_amount;
    pool.asset_spot_frozen_claimable_lp = pool.asset_spot_frozen_claimable_lp - (asset_out as u64);
    pool.stable_spot_frozen_claimable_lp = pool.stable_spot_frozen_claimable_lp - (stable_out as u64);

    // Update total supply
    pool.lp_supply = pool.lp_supply - lp_amount;

    // Burn LP token
    let LPToken { id, amount: _, pool_id: _, locked_in_proposal: _, withdraw_mode: _ } = lp_token;
    object::delete(id);

    // Extract coins from reserves
    let asset_coin = coin::from_balance(
        balance::split(&mut pool.asset_reserve, (asset_out as u64)),
        ctx,
    );
    let stable_coin = coin::from_balance(
        balance::split(&mut pool.stable_reserve, (stable_out as u64)),
        ctx,
    );

    (asset_coin, stable_coin)
}

/// Transition all TRANSITIONING bucket amounts to WITHDRAW_ONLY
/// Called by crank when proposal finalizes
/// This is an atomic batch operation that makes all marked LPs claimable
public(package) fun transition_leaving_to_claimable<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
) {
    // Move all TRANSITIONING amounts to WITHDRAW_ONLY
    pool.asset_spot_frozen_claimable_lp = pool.asset_spot_frozen_claimable_lp + pool.asset_spot_leave_lp_when_proposal_ends;
    pool.stable_spot_frozen_claimable_lp = pool.stable_spot_frozen_claimable_lp + pool.stable_spot_leave_lp_when_proposal_ends;
    pool.lp_spot_frozen_claimable_lp = pool.lp_spot_frozen_claimable_lp + pool.lp_spot_leave_lp_when_proposal_ends;

    // Reset TRANSITIONING buckets to zero
    pool.asset_spot_leave_lp_when_proposal_ends = 0;
    pool.stable_spot_leave_lp_when_proposal_ends = 0;
    pool.lp_spot_leave_lp_when_proposal_ends = 0;
}

/// Alias for transition_leaving_to_claimable (for backward compatibility)
/// Public visibility for cross-package calls
public fun transition_leaving_to_frozen_claimable<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
) {
    transition_leaving_to_claimable(pool)
}

// === Fee Calculation ===

/// Get current fee for this pool based on fee schedule or static fee
fun get_current_fee_bps<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
    clock: &Clock
): u64 {
    if (pool.fee_schedule.is_some()) {
        // Use dynamic fee schedule with pool's base fee as final target
        fee_scheduler::get_current_fee(
            pool.fee_schedule.borrow(),
            pool.fee_bps,  // Final fee = pool's base spot fee
            pool.fee_schedule_activation_time,
            clock.timestamp_ms()
        )
    } else {
        // Use static fee
        pool.fee_bps
    }
}

/// Update the pool's cached fee_bps from fee schedule (if active)
/// Call this BEFORE swaps/arbitrage to ensure fee_bps is current
/// After fee schedule ends, fee_bps will equal the final static fee
public(package) fun update_cached_fee_if_needed<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    clock: &Clock
) {
    if (pool.fee_schedule.is_some()) {
        let current_fee = get_current_fee_bps(pool, clock);
        pool.fee_bps = current_fee;  // Cache current fee for pure functions
    }
    // If no schedule, fee_bps already has the static fee
}

/// Check if proposals are allowed for this pool
/// Returns false if fee schedule is still active (decaying)
/// CRITICAL: Prevents proposals from starting while fees are high (would break arbitrage)
public fun can_create_proposals<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
    clock: &Clock
): bool {
    if (pool.fee_schedule.is_some()) {
        // If fee schedule exists, check if decay period has ended
        let schedule = pool.fee_schedule.borrow();
        let current_time = clock.timestamp_ms();
        let activation_time = pool.fee_schedule_activation_time;

        // Fee schedule is active if we're still within the decay period
        let is_active = if (current_time <= activation_time) {
            true // Not started yet
        } else {
            let elapsed = current_time - activation_time;
            elapsed < fee_scheduler::duration_ms(schedule)
        };

        // Proposals allowed when fee schedule is NOT active (has ended)
        !is_active
    } else {
        // No fee schedule, proposals always allowed
        true
    }
}

/// INTERNAL: Swap stable for asset (used by arbitrage only)
/// Public swaps must go through swap_entry to trigger auto-arbitrage
public fun swap_stable_for_asset<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    mut stable_in: Coin<StableType>,
    min_asset_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    let stable_amount = coin::value(&stable_in);
    assert!(stable_amount > 0, EZeroAmount);

    // Calculate output with fee
    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    // Get dynamic fee if fee scheduler is configured
    let current_fee_bps = get_current_fee_bps(pool, clock);
    let total_fee = stable_amount * current_fee_bps / 10000;

    // Split fee: 90% for LPs, 10% for protocol (if aggregator enabled)
    let (lp_share, protocol_share) = if (pool.aggregator_config.is_some()) {
        use futarchy_one_shot_utils::constants;
        use futarchy_one_shot_utils::math;
        let lp_fee = math::mul_div_to_64(total_fee, constants::spot_lp_fee_share_bps(), constants::total_fee_bps());
        let protocol_fee = total_fee - lp_fee;
        (lp_fee, protocol_fee)
    } else {
        (total_fee, 0) // No aggregator = all fees to LPs
    };

    let stable_after_fee = stable_amount - total_fee;
    let asset_out =
        (asset_reserve as u128) * (stable_after_fee as u128) /
                    ((stable_reserve as u128) + (stable_after_fee as u128));

    assert!((asset_out as u64) >= min_asset_out, ESlippageExceeded);
    assert!((asset_out as u64) < asset_reserve, EInsufficientLiquidity);

    // Update spot TWAP and collect protocol fees (if aggregator enabled)
    if (pool.aggregator_config.is_some()) {
        let price_before = get_spot_price(pool);
        let config = pool.aggregator_config.borrow_mut();
        PCW_TWAP_oracle::update(&mut config.simple_twap, price_before, clock);

        // Collect protocol fee in stable token
        if (protocol_share > 0) {
            let protocol_fee_balance = balance::split(coin::balance_mut(&mut stable_in), protocol_share);
            balance::join(&mut config.protocol_fees_stable, protocol_fee_balance);
        };
    };

    // Update reserves (LP share + swap amount goes to reserves)
    balance::join(&mut pool.stable_reserve, coin::into_balance(stable_in));
    let asset_coin = coin::from_balance(
        balance::split(&mut pool.asset_reserve, (asset_out as u64)),
        ctx,
    );

    asset_coin
}

/// INTERNAL: Swap asset for stable (used by arbitrage only)
/// Public swaps must go through swap_entry to trigger auto-arbitrage
public fun swap_asset_for_stable<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    mut asset_in: Coin<AssetType>,
    min_stable_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableType> {
    let asset_amount = coin::value(&asset_in);
    assert!(asset_amount > 0, EZeroAmount);

    // Calculate output with fee
    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    // Get dynamic fee if fee scheduler is configured
    let current_fee_bps = get_current_fee_bps(pool, clock);
    let total_fee = asset_amount * current_fee_bps / 10000;

    // Split fee: 90% for LPs, 10% for protocol (if aggregator enabled)
    let (lp_share, protocol_share) = if (pool.aggregator_config.is_some()) {
        use futarchy_one_shot_utils::constants;
        use futarchy_one_shot_utils::math;
        let lp_fee = math::mul_div_to_64(total_fee, constants::spot_lp_fee_share_bps(), constants::total_fee_bps());
        let protocol_fee = total_fee - lp_fee;
        (lp_fee, protocol_fee)
    } else {
        (total_fee, 0) // No aggregator = all fees to LPs
    };

    let asset_after_fee = asset_amount - total_fee;
    let stable_out =
        (stable_reserve as u128) * (asset_after_fee as u128) /
                     ((asset_reserve as u128) + (asset_after_fee as u128));

    assert!((stable_out as u64) >= min_stable_out, ESlippageExceeded);
    assert!((stable_out as u64) < stable_reserve, EInsufficientLiquidity);

    // Update spot TWAP and collect protocol fees (if aggregator enabled)
    if (pool.aggregator_config.is_some()) {
        let price_before = get_spot_price(pool);
        let config = pool.aggregator_config.borrow_mut();
        PCW_TWAP_oracle::update(&mut config.simple_twap, price_before, clock);

        // Collect protocol fee in asset token
        if (protocol_share > 0) {
            let protocol_fee_balance = balance::split(coin::balance_mut(&mut asset_in), protocol_share);
            balance::join(&mut config.protocol_fees_asset, protocol_fee_balance);
        };
    };

    // Update reserves (LP share + swap amount goes to reserves)
    balance::join(&mut pool.asset_reserve, coin::into_balance(asset_in));
    let stable_coin = coin::from_balance(
        balance::split(&mut pool.stable_reserve, (stable_out as u64)),
        ctx,
    );

    stable_coin
}

// === View Functions ===

/// Get current reserves
public fun get_reserves<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
): (u64, u64) {
    (balance::value(&pool.asset_reserve), balance::value(&pool.stable_reserve))
}

/// Get LP supply
public fun lp_supply<AssetType, StableType>(pool: &UnifiedSpotPool<AssetType, StableType>): u64 {
    pool.lp_supply
}

/// Get LIVE bucket reserves (will quantum-split for next proposal)
public fun get_active_quantum_lp_reserves<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
): (u64, u64) {
    (pool.asset_spot_active_quantum_lp, pool.stable_spot_active_quantum_lp)
}

/// Get LIVE bucket LP supply
public fun get_active_quantum_lp_supply<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
): u64 {
    pool.lp_spot_active_quantum_lp
}

/// Get TRANSITIONING bucket reserves (will move to WITHDRAW_ONLY when proposal ends)
public fun get_leaving_on_proposal_end_reserves<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
): (u64, u64, u64) {
    (pool.asset_spot_leave_lp_when_proposal_ends, pool.stable_spot_leave_lp_when_proposal_ends, pool.lp_spot_leave_lp_when_proposal_ends)
}

/// Get WITHDRAW_ONLY bucket reserves (frozen, ready for claiming)
public fun get_frozen_claimable_lp_reserves<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
): (u64, u64, u64) {
    (pool.asset_spot_frozen_claimable_lp, pool.stable_spot_frozen_claimable_lp, pool.lp_spot_frozen_claimable_lp)
}

/// Get spot price (asset per stable)
public fun get_spot_price<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
): u128 {
    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    if (asset_reserve == 0 || stable_reserve == 0) {
        return 0
    };

    (stable_reserve as u128) * PRECISION / (asset_reserve as u128)
}

/// Check if aggregator is enabled
public fun is_aggregator_enabled<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
): bool {
    pool.aggregator_config.is_some()
}

/// Check if pool has active escrow (trading proposal active)
public fun has_active_escrow<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
): bool {
    if (pool.aggregator_config.is_none()) {
        return false
    };

    let config = pool.aggregator_config.borrow();
    config.active_escrow.is_some()
}

/// Check if pool is locked for proposal (liquidity moved to conditionals)
/// This is used by oracle interface to determine whether to read from conditional vs spot
public fun is_locked_for_proposal<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
): bool {
    if (pool.aggregator_config.is_none()) {
        return false
    };

    let config = pool.aggregator_config.borrow();
    config.last_proposal_usage.is_some()
}

/// Get conditional liquidity ratio (aggregator only)
public fun get_conditional_liquidity_ratio_percent<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
): u64 {
    if (pool.aggregator_config.is_none()) {
        return 0
    };

    let config = pool.aggregator_config.borrow();
    config.conditional_liquidity_ratio_percent
}

/// Get oracle threshold (aggregator only)
public fun get_oracle_conditional_threshold_bps<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
): u64 {
    if (pool.aggregator_config.is_none()) {
        return 10000 // Default: always use spot
    };

    let config = pool.aggregator_config.borrow();
    config.oracle_conditional_threshold_bps
}


// === Quantum Liquidity Functions ===

/// Remove liquidity for quantum split with bucket tracking (doesn't burn LP tokens)
/// Used when proposal starts - liquidity moves to conditional markets
/// Removes from BOTH LIVE and TRANSITIONING buckets with explicit amounts for each
/// WITHDRAW_ONLY bucket stays in spot (frozen, ready for claiming)
public(package) fun remove_liquidity_for_quantum_split_with_buckets<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    asset_live_amount: u64,
    asset_trans_amount: u64,
    stable_live_amount: u64,
    stable_trans_amount: u64,
): (Balance<AssetType>, Balance<StableType>) {
    let total_asset = asset_live_amount + asset_trans_amount;
    let total_stable = stable_live_amount + stable_trans_amount;

    assert!(total_asset > 0 && total_stable > 0, EZeroAmount);
    assert!(total_asset <= balance::value(&pool.asset_reserve), EInsufficientLiquidity);
    assert!(total_stable <= balance::value(&pool.stable_reserve), EInsufficientLiquidity);

    // Ensure we have enough in each bucket
    assert!(asset_live_amount <= pool.asset_spot_active_quantum_lp, EInsufficientLiquidity);
    assert!(asset_trans_amount <= pool.asset_spot_leave_lp_when_proposal_ends, EInsufficientLiquidity);
    assert!(stable_live_amount <= pool.stable_spot_active_quantum_lp, EInsufficientLiquidity);
    assert!(stable_trans_amount <= pool.stable_spot_leave_lp_when_proposal_ends, EInsufficientLiquidity);

    // Remove from reserves but DON'T burn LP tokens
    // LP tokens still represent value - the liquidity exists quantum-mechanically in conditional markets
    let asset_balance = balance::split(&mut pool.asset_reserve, total_asset);
    let stable_balance = balance::split(&mut pool.stable_reserve, total_stable);

    // Update bucket tracking
    pool.asset_spot_active_quantum_lp = pool.asset_spot_active_quantum_lp - asset_live_amount;
    pool.asset_spot_leave_lp_when_proposal_ends = pool.asset_spot_leave_lp_when_proposal_ends - asset_trans_amount;
    pool.stable_spot_active_quantum_lp = pool.stable_spot_active_quantum_lp - stable_live_amount;
    pool.stable_spot_leave_lp_when_proposal_ends = pool.stable_spot_leave_lp_when_proposal_ends - stable_trans_amount;
    // Note: lp_live and lp_transitioning stay same - LP tokens still exist, just liquidity is in conditionals

    // CRITICAL: Ensure remaining spot pool meets minimum liquidity requirement (k >= 1000)
    let remaining_asset = balance::value(&pool.asset_reserve);
    let remaining_stable = balance::value(&pool.stable_reserve);
    let remaining_k = (remaining_asset as u128) * (remaining_stable as u128);
    assert!(remaining_k >= (MINIMUM_LIQUIDITY as u128), EMinimumLiquidityNotMet);

    (asset_balance, stable_balance)
}

public(package) fun remove_liquidity_for_quantum_split<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    asset_amount: u64,
    stable_amount: u64,
): (Balance<AssetType>, Balance<StableType>) {
    // Default behavior: remove from LIVE bucket only
    remove_liquidity_for_quantum_split_with_buckets(
        pool,
        asset_amount,
        0, // no TRANSITIONING
        stable_amount,
        0, // no TRANSITIONING
    )
}

/// Add liquidity back from quantum redeem with bucket awareness (when proposal ends)
/// Returns liquidity from conditional markets back to spot pool
/// LIVE bucket → spot.LIVE (will quantum-split for next proposal)
/// TRANSITIONING bucket → spot.WITHDRAW_ONLY (frozen for claiming)
public(package) fun add_liquidity_from_quantum_redeem_with_buckets<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    asset: Balance<AssetType>,
    stable: Balance<StableType>,
    asset_live: u64,
    asset_transitioning: u64,
    stable_live: u64,
    stable_transitioning: u64,
) {
    let asset_amount = balance::value(&asset);
    let stable_amount = balance::value(&stable);

    // Verify bucket amounts sum to total
    assert!(asset_live + asset_transitioning == asset_amount, EInsufficientLiquidity);
    assert!(stable_live + stable_transitioning == stable_amount, EInsufficientLiquidity);

    // Add to reserves
    balance::join(&mut pool.asset_reserve, asset);
    balance::join(&mut pool.stable_reserve, stable);

    // Add LIVE bucket → spot.LIVE (will quantum-split for next proposal)
    pool.asset_spot_active_quantum_lp = pool.asset_spot_active_quantum_lp + asset_live;
    pool.stable_spot_active_quantum_lp = pool.stable_spot_active_quantum_lp + stable_live;

    // Add TRANSITIONING bucket → spot.WITHDRAW_ONLY (frozen for claiming!)
    // This skips spot.TRANSITIONING and goes directly to WITHDRAW_ONLY
    pool.asset_spot_frozen_claimable_lp = pool.asset_spot_frozen_claimable_lp + asset_transitioning;
    pool.stable_spot_frozen_claimable_lp = pool.stable_spot_frozen_claimable_lp + stable_transitioning;

    // Note: LP buckets (lp_live, lp_withdraw_only) don't change here
    // LP tokens existed throughout the quantum split, only reserves moved
    // The crank's transition_to_withdraw_only() handles moving lp_transitioning → lp_withdraw_only
}

public(package) fun add_liquidity_from_quantum_redeem<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    asset: Balance<AssetType>,
    stable: Balance<StableType>,
) {
    let asset_amount = balance::value(&asset);
    let stable_amount = balance::value(&stable);

    // Default behavior: add everything to LIVE bucket (old behavior)
    add_liquidity_from_quantum_redeem_with_buckets(
        pool,
        asset,
        stable,
        asset_amount,
        0, // no transitioning
        stable_amount,
        0, // no transitioning
    )
}

// === Aggregator-Specific Functions ===

const LONG_WINDOW_MS: u64 = 7_776_000_000; // 90 days

/// Mark liquidity as moving to proposal (for aggregator support)
/// Updates tracking for liquidity-weighted oracle logic
public fun mark_liquidity_to_proposal<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    conditional_liquidity_ratio_percent: u64,
    clock: &Clock,
) {
    if (pool.aggregator_config.is_none()) {
        return
    };

    // Calculate spot price first (before borrowing config mutably)
    let current_price = get_spot_price(pool);

    let config = pool.aggregator_config.borrow_mut();

    // Update SimpleTWAP one last time before liquidity moves to proposal
    PCW_TWAP_oracle::update(&mut config.simple_twap, current_price, clock);

    // Record when liquidity moved to proposal (spot oracle freezes here)
    let proposal_start = clock.timestamp_ms();
    config.last_proposal_usage = option::some(proposal_start);

    // Snapshot cumulative at proposal lock for later blending/backfill
    let cumulative_at_lock = PCW_TWAP_oracle::cumulative_total(&config.simple_twap);
    config.spot_cumulative_at_lock = option::some(cumulative_at_lock);

    // Store conditional liquidity ratio for liquidity-weighted oracle logic
    config.conditional_liquidity_ratio_percent = conditional_liquidity_ratio_percent;
}

/// Backfill spot's SimpleTWAP with winning conditional's data after proposal ends
/// This fills the gap [proposal_start, proposal_end] with conditional's price history
/// Updates oracle windows using winning conditional's data
public fun backfill_from_winning_conditional<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    winning_conditional_oracle: &SimpleTWAP,
    clock: &Clock,
) {
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);

    let config = pool.aggregator_config.borrow_mut();
    assert!(config.last_proposal_usage.is_some(), ENoActiveProposal); // Must be locked
    assert!(config.spot_cumulative_at_lock.is_some(), ENoActiveProposal);

    let proposal_start = option::extract(&mut config.last_proposal_usage);
    let _ = option::extract(&mut config.spot_cumulative_at_lock);
    let proposal_end = clock.timestamp_ms();

    // Calculate conditional cumulative over the proposal window
    let period_cumulative = PCW_TWAP_oracle::projected_cumulative_arithmetic_to(
        winning_conditional_oracle,
        proposal_end,
    );
    let period_final_price = PCW_TWAP_oracle::last_price(winning_conditional_oracle);

    // Backfill spot oracle with conditional data
    PCW_TWAP_oracle::backfill_from_conditional(
        &mut config.simple_twap,
        proposal_start,
        proposal_end,
        period_cumulative,
        period_final_price,
    );

    // Reset liquidity tracking
    config.conditional_liquidity_ratio_percent = 0;

    // Commit a checkpoint after backfill to anchor the long window
    PCW_TWAP_oracle::force_commit_checkpoint(&mut config.simple_twap, clock);
}

/// Check if TWAP is ready (has enough history)
public fun is_twap_ready<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
    clock: &Clock,
): bool {
    if (pool.aggregator_config.is_none()) {
        return false
    };

    let config = pool.aggregator_config.borrow();
    PCW_TWAP_oracle::is_ready(&config.simple_twap, clock)
}

/// Get governance TWAP (90-day arithmetic window)
/// Uses SimpleTWAP's long-window checkpoints for 90-day averaging
public fun get_geometric_twap<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
    clock: &Clock,
): u128 {
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow();
    let base_twap = PCW_TWAP_oracle::get_twap(&config.simple_twap);
    let long_opt = PCW_TWAP_oracle::get_ninety_day_twap(&config.simple_twap, clock);
    unwrap_option_with_default(long_opt, base_twap)
}

/// Get current 90-day TWAP with conditional integration
/// During proposals: uses conditional TWAP when conditional liquidity dominates, otherwise spot
public fun get_twap_with_conditional<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
    winning_conditional_oracle: &SimpleTWAP,
    clock: &Clock,
): u128 {
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow();

    let spot_base_twap = PCW_TWAP_oracle::get_twap(&config.simple_twap);
    let spot_long_opt = PCW_TWAP_oracle::get_ninety_day_twap(
        &config.simple_twap,
        clock,
    );
    let spot_long_twap = unwrap_option_with_default(spot_long_opt, spot_base_twap);

    // If no proposal is active, return spot TWAP
    if (config.last_proposal_usage.is_none()) {
        return spot_long_twap
    };

    // Only pivot to conditional if configuration says conditional market owns majority liquidity
    let threshold_percent = config.oracle_conditional_threshold_bps / 100;
    if (config.conditional_liquidity_ratio_percent < threshold_percent) {
        return spot_long_twap
    };

    // Conditional market dominates: use its long-window TWAP
    let conditional_base = PCW_TWAP_oracle::get_twap(winning_conditional_oracle);
    let conditional_opt = PCW_TWAP_oracle::get_ninety_day_twap(
        winning_conditional_oracle,
        clock,
    );
    unwrap_option_with_default(conditional_opt, conditional_base)
}

fun unwrap_option_with_default(opt: option::Option<u128>, fallback: u128): u128 {
    if (option::is_some(&opt)) {
        option::destroy_some(opt)
    } else {
        option::destroy_none(opt);
        fallback
    }
}

/// Get SimpleTWAP oracle reference for advanced integration
public fun get_simple_twap<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
): &SimpleTWAP {
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow();
    &config.simple_twap
}

/// Get fee in basis points
public fun get_fee_bps<AssetType, StableType>(pool: &UnifiedSpotPool<AssetType, StableType>): u64 {
    pool.fee_bps
}

/// Simulate swap asset to stable (view function)
/// Uses cached fee_bps (call update_cached_fee_if_needed first for current fee)
public fun simulate_swap_asset_to_stable<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
    asset_in: u64,
): u64 {
    if (asset_in == 0) {
        return 0
    };

    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    if (asset_reserve == 0 || stable_reserve == 0) {
        return 0
    };

    // Use cached fee (updated by update_cached_fee_if_needed before arbitrage)
    let asset_after_fee = asset_in - (asset_in * pool.fee_bps / 10000);
    let stable_out =
        (stable_reserve as u128) * (asset_after_fee as u128) /
                     ((asset_reserve as u128) + (asset_after_fee as u128));

    if ((stable_out as u64) >= stable_reserve) {
        return 0
    };

    (stable_out as u64)
}

/// Simulate swap stable to asset (view function)
/// Uses cached fee_bps (call update_cached_fee_if_needed first for current fee)
public fun simulate_swap_stable_to_asset<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
    stable_in: u64,
): u64 {
    if (stable_in == 0) {
        return 0
    };

    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    if (asset_reserve == 0 || stable_reserve == 0) {
        return 0
    };

    // Use cached fee (updated by update_cached_fee_if_needed before arbitrage)
    let stable_after_fee = stable_in - (stable_in * pool.fee_bps / 10000);
    let asset_out =
        (asset_reserve as u128) * (stable_after_fee as u128) /
                    ((stable_reserve as u128) + (stable_after_fee as u128));

    if ((asset_out as u64) >= asset_reserve) {
        return 0
    };

    (asset_out as u64)
}

// === Dissolution Functions ===

/// Remove liquidity for dissolution using actual LP token object
/// bypass_minimum: If true, allows emptying below MINIMUM_LIQUIDITY
/// ✅ Public so dissolution actions can call from different package
///
/// ⚠️ CRITICAL: Use this for dissolution instead of remove_liquidity()
/// - Burns actual LP token object (not numeric amount)
/// - Can bypass MINIMUM_LIQUIDITY check for complete emptying
/// - Disables trading by setting fee to 100% when bypassing minimum
public fun remove_liquidity_for_dissolution<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    lp_token: LPToken<AssetType, StableType>,
    bypass_minimum: bool,
    ctx: &mut TxContext,
): (Coin<AssetType>, Coin<StableType>) {
    let lp_amount = lp_token.amount;
    assert!(lp_amount > 0, EZeroAmount);
    assert!(pool.lp_supply >= lp_amount, EInsufficientLPSupply);

    // CRITICAL: Check LP token state
    assert!(!lp_token.withdraw_mode, EInsufficientLiquidity);
    assert!(lp_token.locked_in_proposal.is_none(), ENoActiveProposal);

    // Calculate proportional amounts from total reserves
    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    let asset_out = (asset_reserve as u128) * (lp_amount as u128) / (pool.lp_supply as u128);
    let stable_out = (stable_reserve as u128) * (lp_amount as u128) / (pool.lp_supply as u128);

    // Burn LP token
    let LPToken { id, amount: _, pool_id: _, locked_in_proposal: _, withdraw_mode: _ } = lp_token;
    object::delete(id);

    // Update total supply
    pool.lp_supply = pool.lp_supply - lp_amount;

    // Update bucket tracking (remove from LIVE bucket)
    let asset_from_live = (lp_amount as u128) * (pool.asset_spot_active_quantum_lp as u128) / (pool.lp_spot_active_quantum_lp as u128);
    let stable_from_live =
        (lp_amount as u128) * (pool.stable_spot_active_quantum_lp as u128) / (pool.lp_spot_active_quantum_lp as u128);

    pool.lp_spot_active_quantum_lp = pool.lp_spot_active_quantum_lp - lp_amount;
    pool.asset_spot_active_quantum_lp = pool.asset_spot_active_quantum_lp - (asset_from_live as u64);
    pool.stable_spot_active_quantum_lp = pool.stable_spot_active_quantum_lp - (stable_from_live as u64);

    // Extract coins from reserves
    let asset_coin = coin::from_balance(
        balance::split(&mut pool.asset_reserve, (asset_out as u64)),
        ctx,
    );
    let stable_coin = coin::from_balance(
        balance::split(&mut pool.stable_reserve, (stable_out as u64)),
        ctx,
    );

    // Check minimum ONLY if bypass is false
    if (!bypass_minimum) {
        let remaining_asset = balance::value(&pool.asset_reserve);
        let remaining_stable = balance::value(&pool.stable_reserve);
        let remaining_k = (remaining_asset as u128) * (remaining_stable as u128);
        assert!(remaining_k >= (MINIMUM_LIQUIDITY as u128), EMinimumLiquidityNotMet);
    } else {
        // SHUTDOWN: Disable trading by setting fee to 100%
        pool.fee_bps = 10000;
    };

    (asset_coin, stable_coin)
}

/// Get DAO's proportional LP value without withdrawing
/// Used for calculating treasury value including AMM position
public fun get_dao_lp_value<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
    dao_owned_lp_amount: u64,
): (u64, u64) {
    let total_lp = pool.lp_supply;
    if (total_lp == 0) {
        return (0, 0)
    };

    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    let asset_value = (asset_reserve as u128) * (dao_owned_lp_amount as u128) / (total_lp as u128);
    let stable_value =
        (stable_reserve as u128) * (dao_owned_lp_amount as u128) / (total_lp as u128);

    ((asset_value as u64), (stable_value as u64))
}

// === Protocol Fee Management ===

/// Withdraw accumulated protocol fees in asset tokens
/// Returns the balance to be deposited into FeeManager
public(package) fun withdraw_protocol_fees_asset<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
): Balance<AssetType> {
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow_mut();
    let amount = config.protocol_fees_asset.value();
    config.protocol_fees_asset.split(amount)
}

/// Withdraw accumulated protocol fees in stable tokens
/// Returns the balance to be deposited into FeeManager
public(package) fun withdraw_protocol_fees_stable<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
): Balance<StableType> {
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow_mut();
    let amount = config.protocol_fees_stable.value();
    config.protocol_fees_stable.split(amount)
}

/// View function: get accumulated protocol fee amounts
public fun get_protocol_fee_amounts<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
): (u64, u64) {
    if (pool.aggregator_config.is_none()) {
        return (0, 0)
    };
    let config = pool.aggregator_config.borrow();
    (config.protocol_fees_asset.value(), config.protocol_fees_stable.value())
}

// === Sharing Function ===

/// Share the pool object (can only be called by module that defines the type)
public fun share<AssetType, StableType>(pool: UnifiedSpotPool<AssetType, StableType>) {
    transfer::public_share_object(pool);
}

// === Test Functions ===

#[test_only]
public fun new_for_testing<AssetType, StableType>(
    fee_bps: u64,
    enable_aggregator: bool,
    ctx: &mut TxContext,
): UnifiedSpotPool<AssetType, StableType> {
    use sui::clock;

    let clock = clock::create_for_testing(ctx);
    let pool = if (enable_aggregator) {
        new_with_aggregator<AssetType, StableType>(
            fee_bps,
            option::none(), // No fee schedule in tests by default
            8000,
            &clock,
            ctx
        )
    } else {
        new<AssetType, StableType>(
            fee_bps,
            option::none(), // No fee schedule in tests by default
            &clock,
            ctx
        )
    };
    clock::destroy_for_testing(clock);
    pool
}

#[test_only]
/// Create a pool with initial liquidity for testing arbitrage_math
public fun create_pool_for_testing<AssetType, StableType>(
    asset_amount: u64,
    stable_amount: u64,
    fee_bps: u64,
    ctx: &mut TxContext,
): UnifiedSpotPool<AssetType, StableType> {
    use sui::balance;
    use sui::test_utils;

    // Create balances from amounts
    let asset_balance = balance::create_for_testing<AssetType>(asset_amount);
    let stable_balance = balance::create_for_testing<StableType>(stable_amount);

    UnifiedSpotPool {
        id: object::new(ctx),
        asset_reserve: asset_balance,
        stable_reserve: stable_balance,
        lp_supply: 1000, // Default LP supply for testing
        fee_bps,
        minimum_liquidity: 1000, // Standard minimum
        fee_schedule: option::none(), // No fee schedule for testing
        fee_schedule_activation_time: 0,
        // Initialize all liquidity in active quantum LP bucket for testing
        asset_spot_active_quantum_lp: asset_amount,
        asset_spot_leave_lp_when_proposal_ends: 0,
        asset_spot_frozen_claimable_lp: 0,
        asset_spot_join_quantum_lp_when_proposal_ends: 0,
        stable_spot_active_quantum_lp: stable_amount,
        stable_spot_leave_lp_when_proposal_ends: 0,
        stable_spot_frozen_claimable_lp: 0,
        stable_spot_join_quantum_lp_when_proposal_ends: 0,
        lp_spot_active_quantum_lp: 1000,
        lp_spot_leave_lp_when_proposal_ends: 0,
        lp_spot_frozen_claimable_lp: 0,
        lp_spot_join_quantum_lp_when_proposal_ends: 0,
        aggregator_config: option::none(), // No aggregator for simple testing
    }
}

#[test_only]
/// Destroy pool for testing
public fun destroy_for_testing<AssetType, StableType>(
    pool: UnifiedSpotPool<AssetType, StableType>,
) {
    use sui::balance;
    use sui::test_utils;

    let UnifiedSpotPool {
        id,
        asset_reserve,
        stable_reserve,
        lp_supply: _,
        fee_bps: _,
        minimum_liquidity: _,
        fee_schedule: _,
        fee_schedule_activation_time: _,
        asset_spot_active_quantum_lp: _,
        asset_spot_leave_lp_when_proposal_ends: _,
        asset_spot_frozen_claimable_lp: _,
        asset_spot_join_quantum_lp_when_proposal_ends: _,
        stable_spot_active_quantum_lp: _,
        stable_spot_leave_lp_when_proposal_ends: _,
        stable_spot_frozen_claimable_lp: _,
        stable_spot_join_quantum_lp_when_proposal_ends: _,
        lp_spot_active_quantum_lp: _,
        lp_spot_leave_lp_when_proposal_ends: _,
        lp_spot_frozen_claimable_lp: _,
        lp_spot_join_quantum_lp_when_proposal_ends: _,
        aggregator_config,
    } = pool;

    object::delete(id);
    balance::destroy_for_testing(asset_reserve);
    balance::destroy_for_testing(stable_reserve);

    if (aggregator_config.is_some()) {
        let config = option::destroy_some(aggregator_config);
        let AggregatorConfig {
            active_escrow,
            simple_twap,
            last_proposal_usage: _,
            conditional_liquidity_ratio_percent: _,
            oracle_conditional_threshold_bps: _,
            spot_cumulative_at_lock: _,
            protocol_fees_asset,
            protocol_fees_stable,
        } = config;

        // Destroy active escrow ID if present (just an Option<ID>, no object to destroy)
        if (active_escrow.is_some()) {
            option::destroy_some(active_escrow);
        } else {
            option::destroy_none(active_escrow);
        };

        PCW_TWAP_oracle::destroy_for_testing(simple_twap);
        balance::destroy_for_testing(protocol_fees_asset);
        balance::destroy_for_testing(protocol_fees_stable);
    } else {
        option::destroy_none(aggregator_config);
    };
}

#[test_only]
/// Destroy LP token for testing
public fun destroy_lp_token_for_testing<AssetType, StableType>(
    lp_token: LPToken<AssetType, StableType>,
) {
    let LPToken { id, amount: _, pool_id: _, locked_in_proposal: _, withdraw_mode: _ } = lp_token;
    object::delete(id);
}

#[test_only]
/// Create LP token for testing
public fun create_lp_token_for_testing<AssetType, StableType>(
    amount: u64,
    locked_in_proposal: Option<ID>,
    withdraw_mode: bool,
    ctx: &mut TxContext,
): LPToken<AssetType, StableType> {
    LPToken {
        id: object::new(ctx),
        amount,
        pool_id: object::id_from_address(@0x0), // Dummy pool ID for testing
        locked_in_proposal,
        withdraw_mode,
    }
}

#[test_only]
/// Lock LP token in proposal for testing
public fun lock_in_proposal_for_testing<AssetType, StableType>(
    lp_token: &mut LPToken<AssetType, StableType>,
    proposal_id: ID,
) {
    lp_token.locked_in_proposal = option::some(proposal_id);
}

#[test_only]
/// Unlock LP token from proposal for testing
public fun unlock_from_proposal_for_testing<AssetType, StableType>(
    lp_token: &mut LPToken<AssetType, StableType>,
) {
    lp_token.locked_in_proposal = option::none();
}

#[test_only]
/// Test helper to directly mark amounts for withdrawal
/// Moves specified amounts from LIVE to TRANSITIONING bucket
public fun mark_for_withdrawal_for_testing<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    asset_amount: u64,
    stable_amount: u64,
    lp_amount: u64,
) {
    // Ensure we have enough in LIVE bucket
    assert!(pool.asset_spot_active_quantum_lp >= asset_amount, EInsufficientLiquidity);
    assert!(pool.stable_spot_active_quantum_lp >= stable_amount, EInsufficientLiquidity);
    assert!(pool.lp_spot_active_quantum_lp >= lp_amount, EInsufficientLPSupply);

    // Move from LIVE to TRANSITIONING
    pool.asset_spot_active_quantum_lp = pool.asset_spot_active_quantum_lp - asset_amount;
    pool.asset_spot_leave_lp_when_proposal_ends = pool.asset_spot_leave_lp_when_proposal_ends + asset_amount;

    pool.stable_spot_active_quantum_lp = pool.stable_spot_active_quantum_lp - stable_amount;
    pool.stable_spot_leave_lp_when_proposal_ends = pool.stable_spot_leave_lp_when_proposal_ends + stable_amount;

    pool.lp_spot_active_quantum_lp = pool.lp_spot_active_quantum_lp - lp_amount;
    pool.lp_spot_leave_lp_when_proposal_ends = pool.lp_spot_leave_lp_when_proposal_ends + lp_amount;
}
