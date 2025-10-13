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
/// - futarchy_markets basic types (swap_position_registry, simple_twap, coin_escrow)
/// - Does NOT import: proposal or lifecycle modules
///
/// This ensures: proposal.move → unified_spot_pool (one-way dependency)
///
/// ============================================================================

module futarchy_markets_core::unified_spot_pool;

use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::object::{Self, UID, ID};
use sui::transfer;
use std::option::{Self, Option};
use std::type_name::TypeName;
use std::vector;
use futarchy_markets_core::swap_position_registry::{Self, SwapPositionRegistry};
use futarchy_markets_primitives::simple_twap::{Self, SimpleTWAP};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};

// === Errors ===
const EInsufficientLiquidity: u64 = 1;
const EInsufficientOutputAmount: u64 = 2;
const EInsufficientLPSupply: u64 = 3;
const EZeroAmount: u64 = 4;
const ESlippageExceeded: u64 = 5;
const EMinimumLiquidityNotMet: u64 = 6;
const ENoActiveProposal: u64 = 7;
const EProposalMismatch: u64 = 8;
const EEscrowMismatch: u64 = 9;
const ENoRegistry: u64 = 10;
const EAggregatorNotEnabled: u64 = 11;

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
    fee_bps: u64,
    minimum_liquidity: u64,

    // Optional aggregator configuration
    aggregator_config: Option<AggregatorConfig<AssetType, StableType>>,
}

/// Aggregator-specific configuration (only present when enabled)
public struct AggregatorConfig<phantom AssetType, phantom StableType> has store {
    // Active escrow for proposal trading (owned by pool during trading)
    // Moved IN when proposal starts, moved OUT when proposal ends
    active_escrow: Option<TokenEscrow<AssetType, StableType>>,

    // Conditional coin types for active proposal (for external integrators like Aftermath SDK)
    // Order: [Cond0Asset, Cond0Stable, Cond1Asset, Cond1Stable, ...]
    // Empty when no proposal is active
    conditional_type_names: vector<TypeName>,

    // Swap position registry for dust tracking
    registry: SwapPositionRegistry<AssetType, StableType>,

    // TWAP oracle for price feeds
    simple_twap: SimpleTWAP,

    // Liquidity tracking for oracle switching
    last_proposal_usage: Option<u64>,
    conditional_liquidity_ratio_bps: u64,  // 0-10000 (0-100%)
    oracle_conditional_threshold_bps: u64, // When to use conditional vs spot oracle

    // Protocol fees (separate from LP fees)
    protocol_fees_stable: Balance<StableType>,
}

/// LP Token - represents ownership of pool liquidity
public struct LPToken<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    /// Amount of LP tokens
    amount: u64,
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
public fun lp_token_amount<AssetType, StableType>(
    lp_token: &LPToken<AssetType, StableType>
): u64 {
    lp_token.amount
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
    lp_token: &LPToken<AssetType, StableType>
): Option<ID> {
    lp_token.locked_in_proposal
}

/// Check if LP is in withdraw mode
public fun is_withdraw_mode<AssetType, StableType>(
    lp_token: &LPToken<AssetType, StableType>
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
    let LPToken { id, amount, locked_in_proposal: _, withdraw_mode: _ } = lp_token;
    object::delete(id);
    amount
}

// === Creation Functions ===

/// Create a basic pool without aggregator support
/// This is lightweight - no TWAP, no registry, minimal overhead
public fun new<AssetType, StableType>(
    fee_bps: u64,
    ctx: &mut TxContext,
): UnifiedSpotPool<AssetType, StableType> {
    UnifiedSpotPool {
        id: object::new(ctx),
        asset_reserve: balance::zero(),
        stable_reserve: balance::zero(),
        lp_supply: 0,
        fee_bps,
        minimum_liquidity: MINIMUM_LIQUIDITY,
        aggregator_config: option::none(),
    }
}

/// Create a pool WITH aggregator support
/// This includes TWAP oracle, registry, and all aggregator features
public fun new_with_aggregator<AssetType, StableType>(
    fee_bps: u64,
    oracle_conditional_threshold_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): UnifiedSpotPool<AssetType, StableType> {
    let registry = swap_position_registry::new<AssetType, StableType>(ctx);
    let simple_twap = simple_twap::new(0, clock); // Initialize with 0 price (will be updated on first swap)

    let aggregator_config = AggregatorConfig {
        active_escrow: option::none(),
        conditional_type_names: vector::empty(),
        registry,
        simple_twap,
        last_proposal_usage: option::none(),
        conditional_liquidity_ratio_bps: 0,
        oracle_conditional_threshold_bps,
        protocol_fees_stable: balance::zero(),
    };

    UnifiedSpotPool {
        id: object::new(ctx),
        asset_reserve: balance::zero(),
        stable_reserve: balance::zero(),
        lp_supply: 0,
        fee_bps,
        minimum_liquidity: MINIMUM_LIQUIDITY,
        aggregator_config: option::some(aggregator_config),
    }
}

/// Upgrade existing pool to add aggregator support
/// Can be called via governance to enable aggregator features
public fun enable_aggregator<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    oracle_conditional_threshold_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Only enable if not already enabled
    if (pool.aggregator_config.is_none()) {
        let registry = swap_position_registry::new<AssetType, StableType>(ctx);
        let simple_twap = simple_twap::new(get_spot_price(pool), clock); // Initialize with current price

        let config = AggregatorConfig {
            active_escrow: option::none(),
            conditional_type_names: vector::empty(),
            registry,
            simple_twap,
            last_proposal_usage: option::none(),
            conditional_liquidity_ratio_bps: 0,
            oracle_conditional_threshold_bps,
            protocol_fees_stable: balance::zero(),
        };

        option::fill(&mut pool.aggregator_config, config);
    }
}

// === Escrow Management Functions (Aggregator Only) ===

/// Move escrow into pool when proposal starts trading
/// Stores conditional types for external integrators (Aftermath SDK)
public(package) fun store_active_escrow<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    escrow: TokenEscrow<AssetType, StableType>,
    conditional_types: vector<TypeName>,  // Order: [Cond0Asset, Cond0Stable, Cond1Asset, Cond1Stable, ...]
) {
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow_mut();
    assert!(config.active_escrow.is_none(), ENoActiveProposal); // Must not already have escrow
    option::fill(&mut config.active_escrow, escrow);
    config.conditional_type_names = conditional_types;
}

/// Extract escrow from pool when proposal ends
/// Returns the escrow object to caller (usually for finalization)
public(package) fun extract_active_escrow<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
): TokenEscrow<AssetType, StableType> {
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow_mut();
    assert!(config.active_escrow.is_some(), ENoActiveProposal); // Must have escrow
    config.conditional_type_names = vector::empty();  // Clear conditional types
    option::extract(&mut config.active_escrow)
}

/// Borrow escrow mutably for swaps (internal use)
/// Fails if no active escrow
public(package) fun borrow_active_escrow_mut<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
): &mut TokenEscrow<AssetType, StableType> {
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow_mut();
    assert!(config.active_escrow.is_some(), ENoActiveProposal);
    config.active_escrow.borrow_mut()
}

/// Get registry reference (for dust management)
public(package) fun borrow_registry_mut<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
): &mut SwapPositionRegistry<AssetType, StableType> {
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow_mut();
    &mut config.registry
}

// === Core AMM Functions ===

/// Add liquidity to the pool and return LP token
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
        // Proportional liquidity
        let asset_reserve = balance::value(&pool.asset_reserve);
        let stable_reserve = balance::value(&pool.stable_reserve);

        let lp_from_asset = (asset_amount as u128) * (pool.lp_supply as u128) / (asset_reserve as u128);
        let lp_from_stable = (stable_amount as u128) * (pool.lp_supply as u128) / (stable_reserve as u128);

        ((lp_from_asset.min(lp_from_stable)) as u64)
    };

    assert!(lp_amount >= min_lp_out, ESlippageExceeded);

    // Add to reserves
    balance::join(&mut pool.asset_reserve, coin::into_balance(asset_coin));
    balance::join(&mut pool.stable_reserve, coin::into_balance(stable_coin));

    pool.lp_supply = pool.lp_supply + lp_amount;

    // Create and return LP token (unlocked, normal mode by default)
    LPToken<AssetType, StableType> {
        id: object::new(ctx),
        amount: lp_amount,
        locked_in_proposal: option::none(),
        withdraw_mode: false,
    }
}

/// Remove liquidity from the pool
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

    // Calculate proportional amounts
    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    let asset_out = (asset_reserve as u128) * (lp_amount as u128) / (pool.lp_supply as u128);
    let stable_out = (stable_reserve as u128) * (lp_amount as u128) / (pool.lp_supply as u128);

    assert!((asset_out as u64) >= min_asset_out, ESlippageExceeded);
    assert!((stable_out as u64) >= min_stable_out, ESlippageExceeded);

    // Burn LP token
    let LPToken { id, amount: _, locked_in_proposal: _, withdraw_mode: _ } = lp_token;
    object::delete(id);

    pool.lp_supply = pool.lp_supply - lp_amount;

    // Return assets
    let asset_coin = coin::from_balance(
        balance::split(&mut pool.asset_reserve, (asset_out as u64)),
        ctx
    );
    let stable_coin = coin::from_balance(
        balance::split(&mut pool.stable_reserve, (stable_out as u64)),
        ctx
    );

    (asset_coin, stable_coin)
}

/// INTERNAL: Swap stable for asset (used by arbitrage only)
/// Public swaps must go through swap_entry to trigger auto-arbitrage
public fun swap_stable_for_asset<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    stable_in: Coin<StableType>,
    min_asset_out: u64,
    _clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    let stable_amount = coin::value(&stable_in);
    assert!(stable_amount > 0, EZeroAmount);

    // Calculate output with fee
    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    let stable_after_fee = stable_amount - (stable_amount * pool.fee_bps / 10000);
    let asset_out = (asset_reserve as u128) * (stable_after_fee as u128) /
                    ((stable_reserve as u128) + (stable_after_fee as u128));

    assert!((asset_out as u64) >= min_asset_out, ESlippageExceeded);
    assert!((asset_out as u64) < asset_reserve, EInsufficientLiquidity);

    // Update reserves
    balance::join(&mut pool.stable_reserve, coin::into_balance(stable_in));
    let asset_coin = coin::from_balance(
        balance::split(&mut pool.asset_reserve, (asset_out as u64)),
        ctx
    );

    asset_coin
}

/// INTERNAL: Swap asset for stable (used by arbitrage only)
/// Public swaps must go through swap_entry to trigger auto-arbitrage
public fun swap_asset_for_stable<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    asset_in: Coin<AssetType>,
    min_stable_out: u64,
    _clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableType> {
    let asset_amount = coin::value(&asset_in);
    assert!(asset_amount > 0, EZeroAmount);

    // Calculate output with fee
    let asset_reserve = balance::value(&pool.asset_reserve);
    let stable_reserve = balance::value(&pool.stable_reserve);

    let asset_after_fee = asset_amount - (asset_amount * pool.fee_bps / 10000);
    let stable_out = (stable_reserve as u128) * (asset_after_fee as u128) /
                     ((asset_reserve as u128) + (asset_after_fee as u128));

    assert!((stable_out as u64) >= min_stable_out, ESlippageExceeded);
    assert!((stable_out as u64) < stable_reserve, EInsufficientLiquidity);

    // Update reserves
    balance::join(&mut pool.asset_reserve, coin::into_balance(asset_in));
    let stable_coin = coin::from_balance(
        balance::split(&mut pool.stable_reserve, (stable_out as u64)),
        ctx
    );

    stable_coin
}

// === View Functions ===

/// Get current reserves
public fun get_reserves<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>
): (u64, u64) {
    (
        balance::value(&pool.asset_reserve),
        balance::value(&pool.stable_reserve)
    )
}

/// Get LP supply
public fun lp_supply<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>
): u64 {
    pool.lp_supply
}

/// Get spot price (asset per stable)
public fun get_spot_price<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>
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
    pool: &UnifiedSpotPool<AssetType, StableType>
): bool {
    pool.aggregator_config.is_some()
}

/// Check if pool has active escrow (trading proposal active)
public fun has_active_escrow<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>
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
    pool: &UnifiedSpotPool<AssetType, StableType>
): bool {
    if (pool.aggregator_config.is_none()) {
        return false
    };

    let config = pool.aggregator_config.borrow();
    config.last_proposal_usage.is_some()
}

/// Get conditional liquidity ratio (aggregator only)
public fun get_conditional_liquidity_ratio_bps<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>
): u64 {
    if (pool.aggregator_config.is_none()) {
        return 0
    };

    let config = pool.aggregator_config.borrow();
    config.conditional_liquidity_ratio_bps
}

/// Get oracle threshold (aggregator only)
public fun get_oracle_conditional_threshold_bps<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>
): u64 {
    if (pool.aggregator_config.is_none()) {
        return 10000 // Default: always use spot
    };

    let config = pool.aggregator_config.borrow();
    config.oracle_conditional_threshold_bps
}

/// Get conditional types for active proposal (aggregator only)
/// Returns empty vector if no proposal is active or aggregator not enabled
/// This is the primary integration point for external SDKs like Aftermath
///
/// Returns types in order: [Cond0Asset, Cond0Stable, Cond1Asset, Cond1Stable, ...]
public fun get_conditional_types<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>
): vector<TypeName> {
    if (pool.aggregator_config.is_none()) {
        return vector::empty()
    };

    let config = pool.aggregator_config.borrow();
    config.conditional_type_names
}

// === Quantum Liquidity Functions ===

/// Remove liquidity for quantum split (doesn't burn LP tokens)
/// Used when proposal starts - liquidity moves to conditional markets
public(package) fun remove_liquidity_for_quantum_split<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    asset_amount: u64,
    stable_amount: u64,
): (Balance<AssetType>, Balance<StableType>) {
    assert!(asset_amount > 0 && stable_amount > 0, EZeroAmount);
    assert!(asset_amount <= balance::value(&pool.asset_reserve), EInsufficientLiquidity);
    assert!(stable_amount <= balance::value(&pool.stable_reserve), EInsufficientLiquidity);

    // Remove from reserves but DON'T burn LP tokens
    // LP tokens still represent value - the liquidity exists quantum-mechanically in conditional markets
    let asset_balance = balance::split(&mut pool.asset_reserve, asset_amount);
    let stable_balance = balance::split(&mut pool.stable_reserve, stable_amount);

    (asset_balance, stable_balance)
}

/// Add liquidity back from quantum redeem (when proposal ends)
/// Returns liquidity from conditional markets back to spot pool
public(package) fun add_liquidity_from_quantum_redeem<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    asset: Balance<AssetType>,
    stable: Balance<StableType>,
) {
    balance::join(&mut pool.asset_reserve, asset);
    balance::join(&mut pool.stable_reserve, stable);
    // LP supply unchanged - LP tokens existed throughout the quantum split
}

// === Aggregator-Specific Functions ===

/// Mark liquidity as moving to proposal (for aggregator support)
/// Updates tracking for liquidity-weighted oracle logic
public fun mark_liquidity_to_proposal<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    conditional_liquidity_ratio_bps: u64,
    clock: &Clock,
) {
    if (pool.aggregator_config.is_none()) {
        return
    };

    // Calculate spot price first (before borrowing config mutably)
    let current_price = get_spot_price(pool);

    let config = pool.aggregator_config.borrow_mut();

    // Update SimpleTWAP one last time before liquidity moves to proposal
    simple_twap::update(&mut config.simple_twap, current_price, clock);

    // Record when liquidity moved to proposal (spot oracle freezes here)
    config.last_proposal_usage = option::some(clock.timestamp_ms());

    // Store conditional liquidity ratio for liquidity-weighted oracle logic
    config.conditional_liquidity_ratio_bps = conditional_liquidity_ratio_bps;
}

/// Backfill spot's SimpleTWAP with winning conditional's data after proposal ends
/// This fills the gap [proposal_start, proposal_end] with conditional's price history
public fun backfill_from_winning_conditional<AssetType, StableType>(
    pool: &mut UnifiedSpotPool<AssetType, StableType>,
    winning_conditional_oracle: &SimpleTWAP,
    clock: &Clock,
) {
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);

    let config = pool.aggregator_config.borrow_mut();
    assert!(config.last_proposal_usage.is_some(), ENoActiveProposal); // Must be locked

    let proposal_start = *config.last_proposal_usage.borrow();
    let proposal_end = clock.timestamp_ms();

    // Calculate conditional's cumulative for the proposal period
    let conditional_window_start = simple_twap::window_start_timestamp(winning_conditional_oracle);
    let conditional_cumulative = simple_twap::projected_cumulative_to(winning_conditional_oracle, proposal_end);
    let conditional_duration = proposal_end - conditional_window_start;
    let proposal_duration = proposal_end - proposal_start;

    // SAFETY: Scale to just the proposal period with overflow protection
    let period_cumulative: u256 = if (conditional_duration > 0) {
        // Use safe multiplication to avoid overflow
        (conditional_cumulative as u256) * (proposal_duration as u256) / (conditional_duration as u256)
    } else {
        0
    };

    let period_final_price = simple_twap::last_price(winning_conditional_oracle);

    // Backfill spot's SimpleTWAP with conditional's data
    simple_twap::backfill_from_conditional(
        &mut config.simple_twap,
        proposal_start,
        proposal_end,
        period_cumulative,
        period_final_price,
    );

    // Unlock the pool and reset lock parameters
    config.last_proposal_usage = option::none();
    config.conditional_liquidity_ratio_bps = 0;
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
    simple_twap::is_ready(&config.simple_twap, clock)
}

/// Get current TWAP (without conditional integration)
/// Returns spot SimpleTWAP - normal operation
public fun get_twap<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
    clock: &Clock,
): u128 {
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow();
    simple_twap::get_twap(&config.simple_twap, clock)
}

/// Get current TWAP with conditional integration (sophisticated combination)
/// During proposals: combines spot's frozen cumulative + conditional's live cumulative
///
/// # Conditional Oracle Data
/// Pass oracle data from winning conditional for proper time-weighted combination
public fun get_twap_with_conditional<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>,
    winning_conditional_oracle: &SimpleTWAP,
    clock: &Clock,
): u128 {
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow();
    let spot_oracle = &config.simple_twap;
    let now = clock.timestamp_ms();

    let cond_oracle = winning_conditional_oracle;

    // Must have proposal_start timestamp
    if (config.last_proposal_usage.is_none()) {
        return simple_twap::get_twap(spot_oracle, clock)
    };

    let proposal_start = *config.last_proposal_usage.borrow();

    // Get spot's cumulative up to proposal start (frozen)
    let spot_cumulative = simple_twap::projected_cumulative_to(spot_oracle, proposal_start);
    let spot_window_start = simple_twap::window_start_timestamp(spot_oracle);

    // Calculate conditional's contribution for the proposal period
    let cond_window_start = simple_twap::window_start_timestamp(cond_oracle);
    let cond_cumulative = simple_twap::projected_cumulative_to(cond_oracle, now);
    let conditional_duration = now - cond_window_start;
    let proposal_duration = now - proposal_start;

    // Conditional's cumulative scaled to just the proposal period
    let conditional_contribution = if (conditional_duration > 0) {
        (cond_cumulative as u256) * (proposal_duration as u256) / (conditional_duration as u256)
    } else {
        0
    };

    // Combine: spot's frozen cumulative + conditional's live cumulative
    let total_cumulative = spot_cumulative + conditional_contribution;

    // Total duration is from spot's window start to now
    let total_duration = now - spot_window_start;

    // Calculate properly time-weighted average
    if (total_duration > 0) {
        ((total_cumulative / (total_duration as u256)) as u128)
    } else {
        simple_twap::last_price(cond_oracle)
    }
}

/// Get SimpleTWAP oracle reference for advanced integration
public fun get_simple_twap<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>
): &SimpleTWAP {
    assert!(pool.aggregator_config.is_some(), EAggregatorNotEnabled);
    let config = pool.aggregator_config.borrow();
    &config.simple_twap
}

/// Get fee in basis points
public fun get_fee_bps<AssetType, StableType>(
    pool: &UnifiedSpotPool<AssetType, StableType>
): u64 {
    pool.fee_bps
}

/// Simulate swap asset to stable (view function)
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

    let asset_after_fee = asset_in - (asset_in * pool.fee_bps / 10000);
    let stable_out = (stable_reserve as u128) * (asset_after_fee as u128) /
                     ((asset_reserve as u128) + (asset_after_fee as u128));

    if ((stable_out as u64) >= stable_reserve) {
        return 0
    };

    (stable_out as u64)
}

/// Simulate swap stable to asset (view function)
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

    let stable_after_fee = stable_in - (stable_in * pool.fee_bps / 10000);
    let asset_out = (asset_reserve as u128) * (stable_after_fee as u128) /
                    ((stable_reserve as u128) + (stable_after_fee as u128));

    if ((asset_out as u64) >= asset_reserve) {
        return 0
    };

    (asset_out as u64)
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

    if (enable_aggregator) {
        let clock = clock::create_for_testing(ctx);
        let pool = new_with_aggregator<AssetType, StableType>(fee_bps, 8000, &clock, ctx);
        clock::destroy_for_testing(clock);
        pool
    } else {
        new<AssetType, StableType>(fee_bps, ctx)
    }
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
        lp_supply: 1000,  // Default LP supply for testing
        fee_bps,
        minimum_liquidity: 1000,  // Standard minimum
        aggregator_config: option::none(),  // No aggregator for simple testing
    }
}

#[test_only]
/// Destroy pool for testing
public fun destroy_for_testing<AssetType, StableType>(pool: UnifiedSpotPool<AssetType, StableType>) {
    use sui::balance;
    use sui::test_utils;

    let UnifiedSpotPool {
        id,
        asset_reserve,
        stable_reserve,
        lp_supply: _,
        fee_bps: _,
        minimum_liquidity: _,
        aggregator_config,
    } = pool;

    object::delete(id);
    balance::destroy_for_testing(asset_reserve);
    balance::destroy_for_testing(stable_reserve);

    if (aggregator_config.is_some()) {
        let config = option::destroy_some(aggregator_config);
        let AggregatorConfig {
            active_escrow,
            conditional_type_names: _,
            registry,
            simple_twap,
            last_proposal_usage: _,
            conditional_liquidity_ratio_bps: _,
            oracle_conditional_threshold_bps: _,
            protocol_fees_stable,
        } = config;

        // Destroy active escrow if present
        if (active_escrow.is_some()) {
            let escrow = option::destroy_some(active_escrow);
            coin_escrow::destroy_for_testing(escrow);
        } else {
            option::destroy_none(active_escrow);
        };

        swap_position_registry::destroy_for_testing(registry);
        simple_twap::destroy_for_testing(simple_twap);
        balance::destroy_for_testing(protocol_fees_stable);
    } else {
        option::destroy_none(aggregator_config);
    };
}

#[test_only]
/// Destroy LP token for testing
public fun destroy_lp_token_for_testing<AssetType, StableType>(lp_token: LPToken<AssetType, StableType>) {
    let LPToken { id, amount: _, locked_in_proposal: _, withdraw_mode: _ } = lp_token;
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
