/// ============================================================================
/// SPOT AMM WITH BASE FAIR VALUE TWAP - CRITICAL ARCHITECTURE NOTES
/// ============================================================================
/// 
/// This is a specialized spot AMM designed for Hanson-style futarchy with quantum
/// liquidity splitting. The TWAP here serves as the "base fair value" price for
/// internal protocol functions like founder token minting based on price targets.
/// 
/// KEY ARCHITECTURAL DECISIONS:
/// 
/// 1. QUANTUM LIQUIDITY MODEL (Hanson Futarchy)
///    - When a proposal uses DAO liquidity, 1 spot dollar becomes 1 conditional 
///      dollar in EACH outcome (not split, but quantum - exists in all states)
///    - Spot pool becomes COMPLETELY EMPTY during these proposals
///    - Only the highest-priced conditional market determines the winner
/// 
/// 2. TWAP CONTINUITY ACROSS TRANSITIONS
///    The spot TWAP must maintain continuity even when liquidity moves to conditional AMMs:
///    
///    Timeline example:
///    [Spot Active: N seconds] → [Proposal Live: M seconds] → [Spot Active Again]
///    
///    - N could be >> M (spot active much longer than proposal)
///    - M could be >> N (long proposal, short spot history)
///    - We don't know relative durations in advance
/// 
/// 3. LOCKING MECHANISM
///    When proposal starts:
///    - Spot pool is LOCKED (last_proposal_usage timestamp set)
///    - No TWAP updates allowed while locked
///    - All liquidity moves to conditional AMMs
///    
///    During proposal (spot locked):
///    - get_twap() reads from WINNING conditional AMM (highest price)
///    - Adds conditional TWAP for the missing time period
///    - Maintains continuous price history
///    
///    When proposal ends:
///    - Winning conditional's TWAP fills the gap in spot history
///    - Pool unlocks and resumes normal operation
///    - Liquidity returns from winning conditional
/// 
/// 4. TWAP CALCULATION LOGIC
///    
///    Normal operation (no active proposal):
///    - Standard rolling 3-day window
///    - Accumulates price × time
///    - Updates on swaps and liquidity events
///    
///    During live proposal:
///    - Spot accumulator frozen at proposal start time
///    - get_twap() adds: winning_conditional_twap × time_since_proposal_start
///    - Returns combined TWAP over full window
///    
///    After proposal (hot path):
///    - fill_twap_gap_from_proposal() writes: winning_twap × proposal_duration
///    - Adds to window_cumulative_price permanently
///    - Resumes from winning conditional's final price
/// 
/// 5. NOT FOR EXTERNAL PROTOCOLS
///    This TWAP is NOT suitable for:
///    - Lending protocols (need continuous updates)
///    - External price oracles (too specialized)
///    - High-frequency trading (updates only on major events)
///    
///    It IS designed for:
///    - Founder token minting based on price milestones
///    - Long-term protocol health metrics
///    - Base fair value for protocol decisions
/// 
/// 6. SECURITY CONSIDERATIONS
///    - Manipulation requires attacking the WINNING conditional market
///    - Historical segments cannot be modified after writing
///    - Lock prevents TWAP updates during proposals (no double-counting)
///    - Window sliding uses last_window_twap (stable reference) not current price
/// 
/// ============================================================================

module futarchy_markets::spot_amm;

use std::option::{Self, Option};
use std::vector::{Self};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};
use sui::clock::{Self, Clock};
use sui::event;
use futarchy_one_shot_utils::math;
use futarchy_markets::conditional_amm;
use futarchy_markets::simple_twap::{Self, SimpleTWAP};
use futarchy_one_shot_utils::constants;
use futarchy_markets::position_nft;
use futarchy_markets::swap_position_registry::{Self, SwapPositionRegistry};

/// Data structure for passing conditional oracle information
/// (Move doesn't allow Option<&T>, so we pass values instead of references)
public struct ConditionalOracleData has copy, drop {
    window_cumulative: u256,
    window_start: u64,
    last_price: u128,
    last_timestamp: u64,
}

/// Helper to extract oracle data from SimpleTWAP
public fun extract_oracle_data(oracle: &SimpleTWAP): ConditionalOracleData {
    ConditionalOracleData {
        window_cumulative: simple_twap::window_cumulative_price(oracle),
        window_start: simple_twap::window_start_timestamp(oracle),
        last_price: simple_twap::last_price(oracle),
        last_timestamp: simple_twap::last_timestamp(oracle),
    }
}

// Basic errors
const EZeroAmount: u64 = 1;
const EInsufficientLiquidity: u64 = 2;
const ESlippageExceeded: u64 = 3;
const EInvalidFee: u64 = 4;
const EOverflow: u64 = 5;
const EImbalancedLiquidity: u64 = 6;
const ENotInitialized: u64 = 7;
const EAlreadyInitialized: u64 = 8;
const ETwapNotReady: u64 = 9;
const EPoolLockedForProposal: u64 = 10;
const EOracleTooStale: u64 = 11;
const EKInvariantViolation: u64 = 12;

// Aggregator interface errors
const ENoActiveProposal: u64 = 13;
const EProposalMismatch: u64 = 14;
const EEscrowMismatch: u64 = 15;
const ENoRegistry: u64 = 16;

// MAX_FEE_BPS moved to constants module
const MINIMUM_LIQUIDITY: u64 = 1000;

// TWAP constants
const THREE_DAYS_MS: u64 = 259_200_000; // 3 days in milliseconds (3 * 24 * 60 * 60 * 1000)
const PRICE_SCALE: u128 = 1_000_000_000_000; // 10^12 for price precision

// Oracle staleness limit (1 hour)
const MAX_ORACLE_STALENESS_MS: u64 = 3_600_000;

/// Simple spot AMM for <AssetType, StableType> with SimpleTWAP oracle
public struct SpotAMM<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    asset_reserve: Balance<AssetType>,
    stable_reserve: Balance<StableType>,
    lp_supply: u64,
    fee_bps: u64,
    // SimpleTWAP oracle for external consumers (lending protocols, etc.)
    simple_twap: Option<SimpleTWAP>,  // None until first liquidity added
    // Track when DAO liquidity was last used in a proposal
    last_proposal_usage: Option<u64>,
    // Proposal lock parameters (set when proposal locks pool for liquidity-weighted oracle)
    conditional_liquidity_ratio_bps: u64,     // % of liquidity moved to conditionals (0 if no active proposal)
    oracle_conditional_threshold_bps: u64,    // Threshold to trust conditional oracle (0 if no active proposal)
    // Protocol fees accumulated (in stable token)
    protocol_fees_stable: Balance<StableType>,
    // Active proposal ID for clean aggregator interface
    active_proposal_id: Option<ID>,
    // Registry for swap dust positions (owned by AMM)
    registry: Option<SwapPositionRegistry<AssetType, StableType>>,
}

/// Event emitted when spot price updates
public struct SpotPriceUpdate has copy, drop {
    pool_id: ID,
    price: u128,
    timestamp: u64,
    asset_reserve: u64,
    stable_reserve: u64,
}

/// Event emitted when TWAP is updated
public struct SpotTwapUpdate has copy, drop {
    pool_id: ID,
    twap: u128,
    window_start: u64,
    window_end: u64,
}

/// Create a new pool (simple Uniswap V2 style)
public fun new<AssetType, StableType>(fee_bps: u64, ctx: &mut TxContext): SpotAMM<AssetType, StableType> {
    assert!(fee_bps <= constants::max_amm_fee_bps(), EInvalidFee);

    // Create registry for swap dust positions
    let registry = swap_position_registry::new<AssetType, StableType>(ctx);

    SpotAMM<AssetType, StableType> {
        id: object::new(ctx),
        asset_reserve: balance::zero<AssetType>(),
        stable_reserve: balance::zero<StableType>(),
        lp_supply: 0,
        fee_bps,
        simple_twap: option::none(),  // Initialize when first liquidity added
        last_proposal_usage: option::none(),
        conditional_liquidity_ratio_bps: 0,  // No active proposal initially
        oracle_conditional_threshold_bps: 0,  // No active proposal initially
        protocol_fees_stable: balance::zero<StableType>(),
        active_proposal_id: option::none(),  // No active proposal initially
        registry: option::some(registry),  // Registry created with AMM
    }
}

/// Initialize SimpleTWAP oracle when first liquidity is added
fun initialize_twap<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    clock: &Clock,
) {
    assert!(pool.simple_twap.is_none(), EAlreadyInitialized);

    // Calculate initial price from reserves
    let price = calculate_spot_price(
        pool.asset_reserve.value(),
        pool.stable_reserve.value()
    );

    // Create SimpleTWAP - Uniswap V2 style (no capping)
    let twap = simple_twap::new(price, clock);
    option::fill(&mut pool.simple_twap, twap);
}

/// Update SimpleTWAP oracle on price changes
fun update_twap<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    clock: &Clock,
) {
    assert!(pool.simple_twap.is_some(), ENotInitialized);

    // Calculate current raw price from reserves
    let raw_price = calculate_spot_price(
        pool.asset_reserve.value(),
        pool.stable_reserve.value()
    );

    // Update SimpleTWAP (handles capping and accumulation internally)
    simple_twap::update(pool.simple_twap.borrow_mut(), raw_price, clock);

    // Emit price update event
    event::emit(SpotPriceUpdate {
        pool_id: object::id(pool),
        price: simple_twap::last_price(pool.simple_twap.borrow()),
        timestamp: clock.timestamp_ms(),
        asset_reserve: pool.asset_reserve.value(),
        stable_reserve: pool.stable_reserve.value(),
    });
}

/// Calculate spot price (stable per asset) with scaling
fun calculate_spot_price(asset_reserve: u64, stable_reserve: u64): u128 {
    if (asset_reserve == 0) return 0;
    
    // Price = stable_reserve / asset_reserve * PRICE_SCALE
    ((stable_reserve as u128) * PRICE_SCALE) / (asset_reserve as u128)
}

/// Add liquidity (entry)
public entry fun add_liquidity<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    asset_in: Coin<AssetType>,
    stable_in: Coin<StableType>,
    min_lp_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let a = asset_in.value();
    let s = stable_in.value();
    assert!(a > 0 && s > 0, EZeroAmount);

    let minted = if (pool.lp_supply == 0) {
        let prod = (a as u128) * (s as u128);
        let root_u128 = math::sqrt_u128(prod);
        assert!(root_u128 <= (std::u64::max_value!() as u128), EOverflow);
        let root = root_u128 as u64;
        assert!(root > MINIMUM_LIQUIDITY, EInsufficientLiquidity);
        // Lock MINIMUM_LIQUIDITY permanently to prevent rounding attacks
        pool.lp_supply = MINIMUM_LIQUIDITY;  // Set to minimum, will add minted below
        
        // Initialize TWAP oracle on first liquidity
        pool.asset_reserve.join(asset_in.into_balance());
        pool.stable_reserve.join(stable_in.into_balance());
        initialize_twap(pool, clock);
        
        root - MINIMUM_LIQUIDITY  // Return minted amount minus locked liquidity
    } else {
        // Update TWAP before liquidity change
        update_twap(pool, clock);
        
        // For subsequent deposits, calculate LP tokens based on proportional contribution
        let from_a = math::mul_div_to_64(a, pool.lp_supply, pool.asset_reserve.value());
        let from_s = math::mul_div_to_64(s, pool.lp_supply, pool.stable_reserve.value());
        
        // Enforce balanced deposits with 1% tolerance to prevent value extraction
        let max_delta = if (from_a > from_s) {
            from_a - from_s
        } else {
            from_s - from_a
        };
        let avg = (from_a + from_s) / 2;
        assert!(max_delta <= avg / 100, EImbalancedLiquidity); // Max 1% imbalance
        
        // Add liquidity to reserves
        pool.asset_reserve.join(asset_in.into_balance());
        pool.stable_reserve.join(stable_in.into_balance());
        
        // Use minimum to be conservative
        math::min(from_a, from_s)
    };
    assert!(minted >= min_lp_out, ESlippageExceeded);

    pool.lp_supply = pool.lp_supply + minted;

    // Mint NFT position receipt
    let position = position_nft::mint_spot_position<AssetType, StableType>(
        object::id(pool),
        minted,
        pool.fee_bps,
        clock,
        ctx
    );
    transfer::public_transfer(position, ctx.sender());
}

/// Remove liquidity (entry)
public entry fun remove_liquidity<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    position: position_nft::SpotLPPosition<AssetType, StableType>,
    min_asset_out: u64,
    min_stable_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Update TWAP before liquidity change
    if (pool.simple_twap.is_some()) {
        update_twap(pool, clock);
    };

    // Get LP amount from NFT position and burn it
    let amount = position_nft::get_spot_lp_amount(&position);
    position_nft::burn_spot_position(position, clock, ctx);

    assert!(amount > 0, EZeroAmount);
    assert!(pool.lp_supply > MINIMUM_LIQUIDITY, EInsufficientLiquidity);

    let a = math::mul_div_to_64(amount, pool.asset_reserve.value(), pool.lp_supply);
    let s = math::mul_div_to_64(amount, pool.stable_reserve.value(), pool.lp_supply);
    assert!(a >= min_asset_out, ESlippageExceeded);
    assert!(s >= min_stable_out, ESlippageExceeded);

    pool.lp_supply = pool.lp_supply - amount;
    let a_out = coin::from_balance(pool.asset_reserve.split(a), ctx);
    let s_out = coin::from_balance(pool.stable_reserve.split(s), ctx);
    transfer::public_transfer(a_out, ctx.sender());
    transfer::public_transfer(s_out, ctx.sender());
}

/// Swap asset for stable (simple spot swap, no inline arbitrage)
/// Arbitrage happens externally via PTBs - see ARBITRAGE_ANALYSIS.md
///
/// Fee split model (matches conditional AMM):
/// - Calculate gross stable output based on constant product
/// - Take fee from this output
/// - Split fee: spot_lp_fee_share_bps to LPs (stays in pool), remainder to protocol
/// - User receives net stable output
public fun swap_asset_for_stable<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    asset_in: Coin<AssetType>,
    min_stable_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableType> {
    assert!(pool.simple_twap.is_some(), ENotInitialized);
    update_twap(pool, clock);

    let amount_in = asset_in.value();
    assert!(amount_in > 0, EZeroAmount);

    // K-GUARD: Capture reserves before swap to validate constant-product invariant
    // WHY: LP fees stay in pool so k must GROW, protocol fees don't. This catches rounding bugs.
    let asset_before = pool.asset_reserve.value();
    let stable_before = pool.stable_reserve.value();
    let k_before = (asset_before as u128) * (stable_before as u128);

    // Calculate gross output using constant product formula (x * y = k)
    let stable_out_before_fee = math::mul_div_to_64(
        amount_in,
        stable_before,
        asset_before + amount_in
    );

    // Calculate fee from stable output
    let total_fee = math::mul_div_to_64(stable_out_before_fee, pool.fee_bps, constants::max_fee_bps());
    let lp_share = math::mul_div_to_64(total_fee, constants::spot_lp_fee_share_bps(), constants::total_fee_bps());
    let protocol_share = total_fee - lp_share;

    // Net amount for user
    let stable_out = stable_out_before_fee - total_fee;
    assert!(stable_out >= min_stable_out, ESlippageExceeded);
    assert!(stable_out_before_fee < stable_before, EInsufficientLiquidity);

    // Update reserves
    pool.asset_reserve.join(asset_in.into_balance());

    // Protocol share goes to protocol_fees_stable, LP share stays in pool
    pool.protocol_fees_stable.join(pool.stable_reserve.split(protocol_share));
    let stable_coin = coin::from_balance(pool.stable_reserve.split(stable_out), ctx);

    // K-GUARD: Validate k increased (LP fees stay in pool, so k must grow)
    // Formula: (asset + amount_in) * (stable - stable_out - protocol_share) >= asset * stable
    let asset_after = pool.asset_reserve.value();
    let stable_after = pool.stable_reserve.value();
    let k_after = (asset_after as u128) * (stable_after as u128);
    assert!(k_after >= k_before, EKInvariantViolation);

    stable_coin
}

/// Entry wrapper - swaps and transfers output
public entry fun swap_asset_for_stable_entry<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    asset_in: Coin<AssetType>,
    min_stable_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let stable_out = swap_asset_for_stable(
        pool,
        asset_in,
        min_stable_out,
        clock,
        ctx,
    );
    transfer::public_transfer(stable_out, ctx.sender());
}


/// Swap stable for asset (simple spot swap, no inline arbitrage)
/// Arbitrage happens externally via PTBs - see ARBITRAGE_ANALYSIS.md
///
/// Fee split model (matches conditional AMM):
/// - Take fee from stable input
/// - Split fee: spot_lp_fee_share_bps to LPs (stays in pool), remainder to protocol
/// - Calculate asset output based on amount after LP fee
public fun swap_stable_for_asset<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    stable_in: Coin<StableType>,
    min_asset_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    assert!(pool.simple_twap.is_some(), ENotInitialized);
    update_twap(pool, clock);

    let amount_in = stable_in.value();
    assert!(amount_in > 0, EZeroAmount);

    // K-GUARD: Capture reserves before swap to validate constant-product invariant
    // WHY: LP fees stay in pool so k must GROW, protocol fees don't. This catches rounding bugs.
    let asset_before = pool.asset_reserve.value();
    let stable_before = pool.stable_reserve.value();
    let k_before = (asset_before as u128) * (stable_before as u128);

    // Calculate fee from stable input
    let total_fee = math::mul_div_to_64(amount_in, pool.fee_bps, constants::max_fee_bps());
    let lp_share = math::mul_div_to_64(total_fee, constants::spot_lp_fee_share_bps(), constants::total_fee_bps());
    let protocol_share = total_fee - lp_share;

    // Amount used for swap calculation (after removing total fee)
    let amount_in_after_fee = amount_in - total_fee;

    // Calculate output using constant product formula (x * y = k)
    let asset_out = math::mul_div_to_64(
        amount_in_after_fee,
        asset_before,
        stable_before + amount_in_after_fee
    );
    assert!(asset_out >= min_asset_out, ESlippageExceeded);
    assert!(asset_out < asset_before, EInsufficientLiquidity);

    // Update reserves
    // Protocol share goes to protocol_fees_stable, LP share + amount_in_after_fee stay in pool
    let mut stable_balance = stable_in.into_balance();
    pool.protocol_fees_stable.join(stable_balance.split(protocol_share));
    pool.stable_reserve.join(stable_balance); // This adds amount_in_after_fee + lp_share

    let asset_coin = coin::from_balance(pool.asset_reserve.split(asset_out), ctx);

    // K-GUARD: Validate k increased (LP fees stay in pool, so k must grow)
    // Formula: (asset - asset_out) * (stable + amount_in_after_fee + lp_share) >= asset * stable
    let asset_after = pool.asset_reserve.value();
    let stable_after = pool.stable_reserve.value();
    let k_after = (asset_after as u128) * (stable_after as u128);
    assert!(k_after >= k_before, EKInvariantViolation);

    asset_coin
}

/// Entry wrapper - swaps and transfers output
public entry fun swap_stable_for_asset_entry<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    stable_in: Coin<StableType>,
    min_asset_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let asset_out = swap_stable_for_asset(
        pool,
        stable_in,
        min_asset_out,
        clock,
        ctx,
    );
    transfer::public_transfer(asset_out, ctx.sender());
}


/// ---- Conversion hook used by coin_escrow during LP conversion (no balance movement here) ----
/// Returns the ID of the minted spot LP position NFT (the NFT is transferred to the sender).
public fun mint_lp_for_conversion<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    _asset_amount: u64,
    _stable_amount: u64,
    lp_amount_to_mint: u64,
    _total_lp_supply_at_finalization: u64,
    _market_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert!(lp_amount_to_mint > 0, EZeroAmount);
    pool.lp_supply = pool.lp_supply + lp_amount_to_mint;

    // Mint NFT position receipt
    let position = position_nft::mint_spot_position<AssetType, StableType>(
        object::id(pool),
        lp_amount_to_mint,
        pool.fee_bps,
        clock,
        ctx
    );
    let position_id = object::id(&position);
    transfer::public_transfer(position, ctx.sender());
    position_id
}

// === Arbitrage Helper Functions ===

/// Feeless swap asset→stable (for internal arbitrage only)
/// No fees charged to maximize arbitrage efficiency
/// Profits distributed separately by arbitrage module
///
/// IMPORTANT: Caller must have already added amount_in to asset_reserve
/// This function updates reserves and returns output amount
public(package) fun feeless_swap_asset_to_stable<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    amount_in: u64,
): u64 {
    assert!(amount_in > 0, EZeroAmount);

    // K-GUARD: Feeless swaps should preserve k EXACTLY (no fees = no k growth)
    // WHY: Validates b-parameterization math is correct
    let asset_reserve = pool.asset_reserve.value();
    let stable_reserve = pool.stable_reserve.value();
    let k_before = (asset_reserve as u128) * (stable_reserve as u128);

    // No fee for arbitrage swaps (fee-free constant product)
    let stable_out = math::mul_div_to_64(
        amount_in,
        stable_reserve,
        asset_reserve + amount_in
    );
    assert!(stable_out < stable_reserve, EInsufficientLiquidity);

    // K-GUARD: Validate k unchanged (feeless swap preserves k within rounding)
    // Formula: (asset + amount_in) * (stable - stable_out) ≈ asset * stable
    // Allow tiny rounding tolerance (1 part in 10^6)
    let k_after = (asset_reserve + amount_in as u128) * ((stable_reserve - stable_out) as u128);
    let k_delta = if (k_after > k_before) { k_after - k_before } else { k_before - k_after };
    let tolerance = k_before / 1000000; // 0.0001% tolerance
    assert!(k_delta <= tolerance, EKInvariantViolation);

    stable_out
}

/// Feeless swap stable→asset (for internal arbitrage only)
public(package) fun feeless_swap_stable_to_asset<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    amount_in: u64,
): u64 {
    assert!(amount_in > 0, EZeroAmount);

    // K-GUARD: Feeless swaps should preserve k EXACTLY (no fees = no k growth)
    // WHY: Validates b-parameterization math is correct
    let asset_reserve = pool.asset_reserve.value();
    let stable_reserve = pool.stable_reserve.value();
    let k_before = (asset_reserve as u128) * (stable_reserve as u128);

    // No fee for arbitrage swaps
    let asset_out = math::mul_div_to_64(
        amount_in,
        asset_reserve,
        stable_reserve + amount_in
    );
    assert!(asset_out < asset_reserve, EInsufficientLiquidity);

    // K-GUARD: Validate k unchanged (feeless swap preserves k within rounding)
    // Formula: (asset - asset_out) * (stable + amount_in) ≈ asset * stable
    // Allow tiny rounding tolerance (1 part in 10^6)
    let k_after = ((asset_reserve - asset_out) as u128) * ((stable_reserve + amount_in) as u128);
    let k_delta = if (k_after > k_before) { k_after - k_before } else { k_before - k_after };
    let tolerance = k_before / 1000000; // 0.0001% tolerance
    assert!(k_delta <= tolerance, EKInvariantViolation);

    asset_out
}

/// Simulate asset→stable swap without executing
/// Pure function for arbitrage optimization
public fun simulate_swap_asset_to_stable<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>,
    amount_in: u64,
): u64 {
    if (amount_in == 0) return 0;

    let asset_reserve = pool.asset_reserve.value();
    let stable_reserve = pool.stable_reserve.value();

    if (asset_reserve == 0 || stable_reserve == 0) return 0;

    // Simulate with fee (user-facing simulation)
    let amount_after_fee = amount_in - math::mul_div_to_64(
        amount_in,
        pool.fee_bps,
        constants::max_fee_bps()
    );

    let stable_out = math::mul_div_to_64(
        amount_after_fee,
        stable_reserve,
        asset_reserve + amount_after_fee
    );

    if (stable_out >= stable_reserve) return 0;

    stable_out
}

/// Simulate stable→asset swap without executing
public fun simulate_swap_stable_to_asset<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>,
    amount_in: u64,
): u64 {
    if (amount_in == 0) return 0;

    let asset_reserve = pool.asset_reserve.value();
    let stable_reserve = pool.stable_reserve.value();

    if (asset_reserve == 0 || stable_reserve == 0) return 0;

    // Simulate with fee
    let amount_after_fee = amount_in - math::mul_div_to_64(
        amount_in,
        pool.fee_bps,
        constants::max_fee_bps()
    );

    let asset_out = math::mul_div_to_64(
        amount_after_fee,
        asset_reserve,
        stable_reserve + amount_after_fee
    );

    if (asset_out >= asset_reserve) return 0;

    asset_out
}

// === View Functions ===

/// Get current spot price
public fun get_spot_price<AssetType, StableType>(pool: &SpotAMM<AssetType, StableType>): u128 {
    calculate_spot_price(
        pool.asset_reserve.value(),
        pool.stable_reserve.value()
    )
}

/// Get current TWAP (3-day rolling window)
public fun get_twap_mut<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    clock: &Clock,
): u128 {
    assert!(pool.simple_twap.is_some(), ENotInitialized);

    // Update oracle to current time before reading
    let raw_price = calculate_spot_price(pool.asset_reserve.value(), pool.stable_reserve.value());
    simple_twap::update(pool.simple_twap.borrow_mut(), raw_price, clock);

    // Get TWAP from SimpleTWAP
    simple_twap::get_twap(pool.simple_twap.borrow(), clock)
}

/// Get current TWAP with live conditional integration
/// During proposals: combines spot's frozen cumulative + conditional's live cumulative
/// Normal operation: returns SimpleTWAP
///
/// # Arguments
/// * `conditional_data` - Oracle data from winning conditional (if proposal active)
///
/// # Sophisticated Time-Weighted Combination
/// This properly combines spot frozen period + conditional live period by:
/// 1. Taking spot's cumulative up to proposal start (frozen)
/// 2. Adding conditional's cumulative for proposal period (live)
/// 3. Dividing by total window duration
///
/// This maintains proper time weighting (unlike naive averaging)
public fun get_twap<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>,
    conditional_data: Option<ConditionalOracleData>,
    clock: &Clock,
): u128 {
    assert!(pool.simple_twap.is_some(), ENotInitialized);
    let spot_oracle = pool.simple_twap.borrow();
    let now = clock.timestamp_ms();

    // Require at least 3 days of history
    assert!(simple_twap::is_ready(spot_oracle, clock), ETwapNotReady);

    // If no conditional active, just return spot TWAP
    if (conditional_data.is_none()) {
        return simple_twap::get_twap(spot_oracle, clock)
    };

    // Sophisticated cumulative combination for proposal period
    let cond = *option::borrow(&conditional_data);

    // SAFETY: Validate conditional oracle is not stale (within 1 hour)
    let time_since_update = now - cond.last_timestamp;
    assert!(time_since_update <= MAX_ORACLE_STALENESS_MS, EOracleTooStale);

    // Must have proposal_start timestamp
    assert!(pool.last_proposal_usage.is_some(), ENotInitialized);
    let proposal_start = *pool.last_proposal_usage.borrow();

    // Get spot's cumulative up to proposal start (frozen)
    let spot_cumulative = simple_twap::projected_cumulative_to(spot_oracle, proposal_start);
    let spot_window_start = simple_twap::window_start_timestamp(spot_oracle);

    // Calculate conditional's contribution for the proposal period
    // Note: Conditional oracle started at proposal_start, so its window might be different
    let conditional_duration = now - cond.window_start;
    let proposal_duration = now - proposal_start;

    // Conditional's cumulative scaled to just the proposal period
    let conditional_contribution = if (conditional_duration > 0) {
        // SAFETY: Use overflow-protected multiplication
        // Scale: (conditional_cumulative × proposal_duration) / conditional_duration
        simple_twap::safe_mul_u256(cond.window_cumulative, (proposal_duration as u256)) / (conditional_duration as u256)
    } else {
        0
    };

    // Combine: spot's frozen cumulative + conditional's live cumulative
    let total_cumulative = spot_cumulative + conditional_contribution;

    // Total duration is from spot's window start to now
    let total_duration = now - spot_window_start;

    // Apply 3-day rolling window (cap at THREE_DAYS_MS)
    let effective_duration = if (total_duration > THREE_DAYS_MS) {
        THREE_DAYS_MS
    } else {
        total_duration
    };

    // Calculate properly time-weighted average
    if (effective_duration > 0) {
        ((total_cumulative / (effective_duration as u256)) as u128)
    } else {
        cond.last_price
    }
}

/// Get TWAP for conditional AMM initialization
/// This is used when transitioning from spot trading to proposal trading
public fun get_twap_for_conditional_amm<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>,
    clock: &Clock,
): u128 {
    if (pool.simple_twap.is_some()) {
        let oracle = pool.simple_twap.borrow();
        if (simple_twap::is_ready(oracle, clock)) {
            return simple_twap::get_twap(oracle, clock)
        }
    };

    // Fall back to spot price if TWAP not ready
    // This allows proposals before 3-day TWAP is available
    get_spot_price(pool)
}

/// Check if TWAP oracle is ready (has been running for at least 3 days)
public fun is_twap_ready<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>,
    clock: &Clock,
): bool {
    if (pool.simple_twap.is_none()) return false;
    simple_twap::is_ready(pool.simple_twap.borrow(), clock)
}

/// Check if pool is locked for a proposal
public fun is_locked_for_proposal<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>
): bool {
    pool.last_proposal_usage.is_some()
}

/// Get conditional liquidity ratio (% of liquidity moved to conditionals)
/// Returns 0 if no active proposal
public fun get_conditional_liquidity_ratio_bps<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>
): u64 {
    pool.conditional_liquidity_ratio_bps
}

/// Get oracle conditional threshold (threshold to trust conditional oracle)
/// Returns 0 if no active proposal
public fun get_oracle_conditional_threshold_bps<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>
): u64 {
    pool.oracle_conditional_threshold_bps
}


/// Get pool reserves
public fun get_reserves<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>
): (u64, u64) {
    (pool.asset_reserve.value(), pool.stable_reserve.value())
}

/// Get pool fee in basis points
public fun get_fee_bps<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>
): u64 {
    pool.fee_bps
}

/// Get SimpleTWAP oracle reference (for spot_oracle_interface)
public fun get_simple_twap<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>
): &SimpleTWAP {
    assert!(pool.simple_twap.is_some(), ENotInitialized);
    pool.simple_twap.borrow()
}

// === Aggregator Integration Helpers ===

/// Register a proposal as active in the spot pool
/// Called when proposal enters TRADING state
/// This allows aggregators to discover proposal/escrow IDs from spot_pool alone
public(package) fun register_active_proposal<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    proposal_id: ID,
) {
    pool.active_proposal_id = option::some(proposal_id);
}

/// Clear active proposal from spot pool
/// Called when proposal ends trading
public(package) fun clear_active_proposal<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
) {
    pool.active_proposal_id = option::none();
}

/// Get active proposal ID (for aggregator discovery)
/// Returns None if no proposal is currently trading
public fun get_active_proposal_id<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>
): Option<ID> {
    pool.active_proposal_id
}

/// Validate arbitrage objects and borrow registry
///
/// AGGREGATOR INTERFACE: Simplifies integration by validating all objects match.
///
/// Aggregators only need to:
/// 1. Track spot_pool ID in their database
/// 2. Query get_active_proposal_id(spot_pool) to discover proposal
/// 3. Query proposal::escrow_id(proposal) to discover escrow
/// 4. Pass all three objects to swap functions
/// 5. This function validates they match and returns registry
///
/// This allows aggregators to start from spot_pool ID alone.
public fun validate_arb_objects_and_borrow_registry<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
): &mut SwapPositionRegistry<AssetType, StableType> {
    use futarchy_markets::proposal;
    use futarchy_markets::coin_escrow;

    // Validate active proposal exists
    assert!(pool.active_proposal_id.is_some(), ENoActiveProposal);

    // Validate proposal ID matches
    let expected_proposal_id = *pool.active_proposal_id.borrow();
    let actual_proposal_id = proposal::get_id(proposal);
    assert!(expected_proposal_id == actual_proposal_id, EProposalMismatch);

    // Validate escrow ID matches
    let expected_escrow_id = proposal::escrow_id(proposal);
    let actual_escrow_id = object::id(escrow);
    assert!(expected_escrow_id == actual_escrow_id, EEscrowMismatch);

    // Borrow registry
    assert!(pool.registry.is_some(), ENoRegistry);
    pool.registry.borrow_mut()
}

/// Get pool state (basic info)
public fun get_pool_state<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>
): (u64, u64, u64) {
    (
        pool.asset_reserve.value(),
        pool.stable_reserve.value(),
        pool.lp_supply,
    )
}

/// Get accumulated protocol fees (in stable tokens)
public fun get_protocol_fees<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>
): u64 {
    pool.protocol_fees_stable.value()
}

/// Reset protocol fees to zero and return the balance
/// Should only be called by fee collection mechanisms
public(package) fun reset_protocol_fees<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    ctx: &mut TxContext,
): Coin<StableType> {
    let fee_amount = pool.protocol_fees_stable.value();
    if (fee_amount > 0) {
        coin::from_balance(pool.protocol_fees_stable.split(fee_amount), ctx)
    } else {
        coin::zero<StableType>(ctx)
    }
}

// === Conditional TWAP Integration ===


/// Mark when DAO liquidity moves to a proposal
/// This records the timestamp and lock parameters for liquidity-weighted oracle logic
public fun mark_liquidity_to_proposal<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    conditional_liquidity_ratio_bps: u64,
    oracle_conditional_threshold_bps: u64,
    clock: &Clock,
) {
    // Update SimpleTWAP one last time before liquidity moves to proposal
    if (pool.simple_twap.is_some()) {
        update_twap(pool, clock);
    };
    // Record when liquidity moved to proposal (spot oracle freezes here)
    pool.last_proposal_usage = option::some(clock.timestamp_ms());
    // Store lock parameters for liquidity-weighted oracle logic
    pool.conditional_liquidity_ratio_bps = conditional_liquidity_ratio_bps;
    pool.oracle_conditional_threshold_bps = oracle_conditional_threshold_bps;
}

/// Backfill spot's SimpleTWAP with winning conditional's data after proposal ends
///
/// # Arguments
/// * `winning_conditional_oracle` - SimpleTWAP from winning conditional AMM
public fun backfill_from_winning_conditional<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    winning_conditional_oracle: &SimpleTWAP,
    clock: &Clock,
) {
    assert!(pool.simple_twap.is_some(), ENotInitialized);
    assert!(pool.last_proposal_usage.is_some(), ENotInitialized); // Must be locked

    let proposal_start = *pool.last_proposal_usage.borrow();
    let proposal_end = clock.timestamp_ms();

    // Calculate conditional's cumulative for the proposal period
    let conditional_window_start = simple_twap::window_start_timestamp(winning_conditional_oracle);
    let conditional_cumulative = simple_twap::projected_cumulative_to(winning_conditional_oracle, proposal_end);
    let conditional_duration = proposal_end - conditional_window_start;
    let proposal_duration = proposal_end - proposal_start;

    // SAFETY: Scale to just the proposal period with overflow protection
    let period_cumulative = if (conditional_duration > 0) {
        simple_twap::safe_mul_u256(conditional_cumulative, (proposal_duration as u256)) / (conditional_duration as u256)
    } else {
        0
    };

    let period_final_price = simple_twap::last_price(winning_conditional_oracle);

    // Backfill spot's SimpleTWAP with conditional's data
    simple_twap::backfill_from_conditional(
        pool.simple_twap.borrow_mut(),
        proposal_start,
        proposal_end,
        period_cumulative,
        period_final_price,
    );

    // Unlock the pool and reset lock parameters
    pool.last_proposal_usage = option::none();
    pool.conditional_liquidity_ratio_bps = 0;
    pool.oracle_conditional_threshold_bps = 0;
}

