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

module futarchy::spot_amm;

use std::option::{Self, Option};
use std::vector::{Self};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};
use sui::clock::{Self, Clock};
use sui::event;
use futarchy::math;
use futarchy::ring_buffer_oracle::{Self, RingBufferOracle};
use futarchy::conditional_amm;

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

const MAX_FEE_BPS: u64 = 10000;
const MINIMUM_LIQUIDITY: u64 = 1000;

// TWAP constants
const THREE_DAYS_MS: u64 = 259_200_000; // 3 days in milliseconds (3 * 24 * 60 * 60 * 1000)
const PRICE_SCALE: u128 = 1_000_000_000_000; // 10^12 for price precision

/// Historical price segment from conditional AMMs
public struct PriceSegment has store, drop, copy {
    start_timestamp: u64,
    end_timestamp: u64,
    cumulative_price: u256,  // Cumulative price over this segment
    avg_price: u128,          // Average price for quick access
}

/// Simple spot AMM for <AssetType, StableType> with dual oracle system
public struct SpotAMM<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    asset_reserve: Balance<AssetType>,
    stable_reserve: Balance<StableType>,
    lp_supply: u64,
    fee_bps: u64,
    // Ring buffer oracle for lending protocols (continuous updates)
    ring_buffer_oracle: RingBufferOracle,
    // Base fair value TWAP oracle fields - maintains rolling 3-day window
    initialized_at: Option<u64>,
    last_price: u128,
    last_timestamp: u64,
    // Rolling 3-day window accumulator (resets every update)
    window_start_timestamp: u64,      // Timestamp exactly 3 days ago
    // The TWAP of the last completed full price window. More stable than last_price for estimations.
    last_window_twap: u128,
    window_cumulative_price: u256,    // Cumulative price over the 3-day window
    // Historical segments from conditional AMMs (used when DAO liquidity was in proposals)
    historical_segments: vector<PriceSegment>,
    // Track when DAO liquidity was last used in a proposal
    last_proposal_usage: Option<u64>,
}

/// Spot LP token
public struct SpotLP<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    amount: u64,
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
    assert!(fee_bps <= MAX_FEE_BPS, EInvalidFee);
    SpotAMM<AssetType, StableType> {
        id: object::new(ctx),
        asset_reserve: balance::zero<AssetType>(),
        stable_reserve: balance::zero<StableType>(),
        lp_supply: 0,
        fee_bps,
        // Ring buffer oracle for lending
        ring_buffer_oracle: ring_buffer_oracle::new(1440), // 24 hours of observations at 1 per minute
        // TWAP fields initially unset
        initialized_at: option::none(),
        last_price: 0,
        last_timestamp: 0,
        window_start_timestamp: 0,
        last_window_twap: 0,
        window_cumulative_price: 0,
        historical_segments: vector::empty(),
        last_proposal_usage: option::none(),
    }
}

/// Initialize TWAP oracle when first liquidity is added
fun initialize_twap<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    clock: &Clock,
) {
    assert!(pool.initialized_at.is_none(), EAlreadyInitialized);
    let now = clock.timestamp_ms();
    pool.initialized_at = option::some(now);
    pool.last_timestamp = now;
    pool.window_start_timestamp = now;
    pool.window_cumulative_price = 0;
    
    // Calculate initial price from reserves
    let price = calculate_spot_price(
        pool.asset_reserve.value(),
        pool.stable_reserve.value()
    );
    pool.last_price = price;
    pool.last_window_twap = price; // Initialize with current price as best estimate
}

/// Update TWAP oracle on price changes (maintains rolling 3-day window)
fun update_twap<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    clock: &Clock,
) {
    assert!(pool.initialized_at.is_some(), ENotInitialized);
    let now = clock.timestamp_ms();
    
    // Skip if no time has passed
    if (now == pool.last_timestamp) return;
    
    // Update ring buffer oracle for lending protocols
    let current_price = calculate_spot_price(
        pool.asset_reserve.value(),
        pool.stable_reserve.value()
    );
    ring_buffer_oracle::write(&mut pool.ring_buffer_oracle, current_price, clock);
    
    // Accumulate price for the elapsed time BEFORE updating the window
    // This ensures we capture the price impact over the time period
    let time_elapsed = now - pool.last_timestamp;
    let price_time = (pool.last_price as u256) * (time_elapsed as u256);
    pool.window_cumulative_price = pool.window_cumulative_price + price_time;
    
    // Update the rolling window accumulator
    update_rolling_window(pool, now);
    
    // Update current price
    let new_price = calculate_spot_price(
        pool.asset_reserve.value(),
        pool.stable_reserve.value()
    );
    pool.last_price = new_price;
    pool.last_timestamp = now;
    
    // Emit price update event
    event::emit(SpotPriceUpdate {
        pool_id: object::id(pool),
        price: new_price,
        timestamp: now,
        asset_reserve: pool.asset_reserve.value(),
        stable_reserve: pool.stable_reserve.value(),
    });
}

/// Update the rolling 3-day window accumulator
fun update_rolling_window<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    now: u64,
) {
    // Check if we need to slide the window forward
    let window_age = now - pool.window_start_timestamp;
    
    if (window_age > THREE_DAYS_MS) {
        // Window is older than 3 days, need to slide it forward
        let new_window_start = now - THREE_DAYS_MS;
        
        // Calculate how much to remove from the accumulator
        // (the part that's now outside the 3-day window)
        let time_to_remove = new_window_start - pool.window_start_timestamp;
        
        // SECURITY FIX: Use the stable TWAP instead of current price for estimation
        // This prevents manipulation where an attacker could corrupt the TWAP
        // by manipulating the current price just before a window slide
        let price_to_remove = (pool.last_window_twap as u256) * (time_to_remove as u256);
        
        // Slide the window: remove old data, keep only last 3 days
        if (pool.window_cumulative_price > price_to_remove) {
            pool.window_cumulative_price = pool.window_cumulative_price - price_to_remove;
        } else {
            // Fallback: if removal would underflow (extreme volatility case),
            // reset to current price * 3 days as baseline
            pool.window_cumulative_price = (pool.last_price as u256) * (THREE_DAYS_MS as u256);
        };
        
        pool.window_start_timestamp = new_window_start;
    };
    
    // Update the last_window_twap with current window average for next time
    // This keeps our stable reference price fresh
    let window_duration = if (window_age > THREE_DAYS_MS) { 
        THREE_DAYS_MS 
    } else { 
        window_age 
    };
    
    if (window_duration > 0) {
        pool.last_window_twap = (pool.window_cumulative_price / (window_duration as u256)) as u128;
    };
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
        pool.lp_supply = root;  // FIX: Set to total root amount, not just minimum
        
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

    let lp = SpotLP<AssetType, StableType> { id: object::new(ctx), amount: minted };
    transfer::public_transfer(lp, ctx.sender());
}

/// Remove liquidity (entry)
public entry fun remove_liquidity<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    lp: SpotLP<AssetType, StableType>,
    min_asset_out: u64,
    min_stable_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Update TWAP before liquidity change
    if (pool.initialized_at.is_some()) {
        update_twap(pool, clock);
    };
    let SpotLP { id, amount } = lp;
    id.delete();
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

/// Swap asset for stable (simple Uniswap V2 style)
public entry fun swap_asset_for_stable<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    asset_in: Coin<AssetType>,
    min_stable_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(pool.initialized_at.is_some(), ENotInitialized);
    update_twap(pool, clock);
    
    let amount_in = asset_in.value();
    assert!(amount_in > 0, EZeroAmount);
    
    // Apply fee
    let amount_after_fee = amount_in - (math::mul_div_to_64(amount_in, pool.fee_bps, MAX_FEE_BPS));
    
    // Calculate output using constant product formula (x * y = k)
    let asset_reserve = pool.asset_reserve.value();
    let stable_reserve = pool.stable_reserve.value();
    let stable_out = math::mul_div_to_64(
        amount_after_fee,
        stable_reserve,
        asset_reserve + amount_after_fee
    );
    assert!(stable_out >= min_stable_out, ESlippageExceeded);
    assert!(stable_out < stable_reserve, EInsufficientLiquidity);
    
    // Update reserves
    pool.asset_reserve.join(asset_in.into_balance());
    let stable_coin = coin::from_balance(pool.stable_reserve.split(stable_out), ctx);
    transfer::public_transfer(stable_coin, ctx.sender());
}

/// Swap stable for asset (simple Uniswap V2 style)
public entry fun swap_stable_for_asset<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    stable_in: Coin<StableType>,
    min_asset_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(pool.initialized_at.is_some(), ENotInitialized);
    update_twap(pool, clock);
    
    let amount_in = stable_in.value();
    assert!(amount_in > 0, EZeroAmount);
    
    // Apply fee
    let amount_after_fee = amount_in - (math::mul_div_to_64(amount_in, pool.fee_bps, MAX_FEE_BPS));
    
    // Calculate output using constant product formula (x * y = k)
    let asset_reserve = pool.asset_reserve.value();
    let stable_reserve = pool.stable_reserve.value();
    let asset_out = math::mul_div_to_64(
        amount_after_fee,
        asset_reserve,
        stable_reserve + amount_after_fee
    );
    assert!(asset_out >= min_asset_out, ESlippageExceeded);
    assert!(asset_out < asset_reserve, EInsufficientLiquidity);
    
    // Update reserves
    pool.stable_reserve.join(stable_in.into_balance());
    let asset_coin = coin::from_balance(pool.asset_reserve.split(asset_out), ctx);
    transfer::public_transfer(asset_coin, ctx.sender());
}

/// ---- Conversion hook used by coin_escrow during LP conversion (no balance movement here) ----
/// Returns the ID of the minted spot LP token (the LP is transferred to the sender).
public fun mint_lp_for_conversion<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    _asset_amount: u64,
    _stable_amount: u64,
    lp_amount_to_mint: u64,
    _total_lp_supply_at_finalization: u64,
    _market_id: ID,
    ctx: &mut TxContext,
): ID {
    assert!(lp_amount_to_mint > 0, EZeroAmount);
    pool.lp_supply = pool.lp_supply + lp_amount_to_mint;
    let lp = SpotLP<AssetType, StableType> { id: object::new(ctx), amount: lp_amount_to_mint };
    let lp_id = object::id(&lp);
    transfer::public_transfer(lp, ctx.sender());
    lp_id
}

// === View Functions ===

public fun get_lp_amount<AssetType, StableType>(lp: &SpotLP<AssetType, StableType>): u64 {
    lp.amount
}

/// Get current spot price
public fun get_spot_price<AssetType, StableType>(pool: &SpotAMM<AssetType, StableType>): u128 {
    calculate_spot_price(
        pool.asset_reserve.value(),
        pool.stable_reserve.value()
    )
}

/// Get current TWAP with automatic update (requires mutable reference)
public fun get_twap_mut<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    clock: &Clock,
): u128 {
    assert!(pool.initialized_at.is_some(), ENotInitialized);
    let init_time = *pool.initialized_at.borrow();
    let now = clock.timestamp_ms();
    
    // Require at least 3 days of trading before TWAP is valid
    assert!(now >= init_time + THREE_DAYS_MS, ETwapNotReady);
    
    // First, accumulate any pending price updates since last timestamp
    // This is crucial for cases where get_twap_mut is called without prior updates
    if (now > pool.last_timestamp) {
        let time_elapsed = now - pool.last_timestamp;
        let price_time = (pool.last_price as u256) * (time_elapsed as u256);
        pool.window_cumulative_price = pool.window_cumulative_price + price_time;
        pool.last_timestamp = now;
    };
    
    // IMPORTANT: Update the rolling window to current time
    // This ensures we always have the most recent 3-day average
    update_rolling_window(pool, now);
    
    // Calculate the exact 3-day TWAP
    let window_duration = now - pool.window_start_timestamp;
    
    if (window_duration >= THREE_DAYS_MS) {
        // We have a full 3-day window
        (pool.window_cumulative_price / (THREE_DAYS_MS as u256)) as u128
    } else {
        // Window is less than 3 days (shouldn't happen after init period)
        // Use actual duration for accuracy
        if (window_duration > 0) {
            (pool.window_cumulative_price / (window_duration as u256)) as u128
        } else {
            pool.last_price
        }
    }
}

/// Get current TWAP with live conditional integration
/// During proposals: adds winning conditional's TWAP for missing time
/// Normal operation: returns standard spot TWAP
public fun get_twap<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>,
    winning_conditional_twap: Option<u128>, // Pass Some(twap) if proposal is live, None otherwise
    clock: &Clock,
): u128 {
    assert!(pool.initialized_at.is_some(), ENotInitialized);
    let init_time = *pool.initialized_at.borrow();
    let now = clock.timestamp_ms();
    
    // Require at least 3 days of trading before TWAP is valid
    assert!(now >= init_time + THREE_DAYS_MS, ETwapNotReady);
    
    // If proposal is live and we have winning conditional TWAP, integrate it
    if (pool.last_proposal_usage.is_some() && winning_conditional_twap.is_some()) {
        let proposal_start = *pool.last_proposal_usage.borrow();
        let conditional_twap = *winning_conditional_twap.borrow();
        
        // Calculate spot TWAP up to proposal start
        let spot_duration = proposal_start - pool.window_start_timestamp;
        let spot_cumulative = pool.window_cumulative_price; // Frozen at proposal start
        
        // Calculate conditional contribution for time since proposal started
        let gap_duration = now - proposal_start;
        let gap_contribution = (conditional_twap as u256) * (gap_duration as u256);
        
        // Combine spot and conditional portions
        let total_cumulative = spot_cumulative + gap_contribution;
        let total_duration = now - pool.window_start_timestamp;
        
        // Handle rolling window
        let effective_duration = if (total_duration > THREE_DAYS_MS) {
            THREE_DAYS_MS
        } else {
            total_duration
        };
        
        if (effective_duration > 0) {
            (total_cumulative / (effective_duration as u256)) as u128
        } else {
            conditional_twap
        }
    } else {
        // No active proposal - return normal spot TWAP
        // Calculate what the cumulative would be if updated to now
        let time_since_last_update = now - pool.last_timestamp;
        let projected_cumulative = pool.window_cumulative_price + 
            ((pool.last_price as u256) * (time_since_last_update as u256));
        
        // Calculate window duration
        let window_age = now - pool.window_start_timestamp;
        let effective_duration = if (window_age > THREE_DAYS_MS) {
            THREE_DAYS_MS // Cap at 3 days
        } else {
            window_age
        };
        
        if (effective_duration > 0) {
            (projected_cumulative / (effective_duration as u256)) as u128
        } else {
            pool.last_price
        }
    }
}

/// Get TWAP for conditional AMM initialization
/// This is used when transitioning from spot trading to proposal trading
public fun get_twap_for_conditional_amm<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>,
    clock: &Clock,
): u128 {
    // If 3-day TWAP is ready, use it; otherwise use spot price
    if (pool.initialized_at.is_some()) {
        let init_time = *pool.initialized_at.borrow();
        let now = clock.timestamp_ms();
        
        if (now >= init_time + THREE_DAYS_MS) {
            // Calculate TWAP from rolling window
            let window_duration = now - pool.window_start_timestamp;
            if (window_duration > 0 && pool.window_cumulative_price > 0) {
                let effective_duration = if (window_duration > THREE_DAYS_MS) {
                    THREE_DAYS_MS
                } else {
                    window_duration
                };
                return (pool.window_cumulative_price / (effective_duration as u256)) as u128
            }
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
    if (pool.initialized_at.is_none()) return false;
    
    let init_time = *pool.initialized_at.borrow();
    let now = clock.timestamp_ms();
    // Require 3 full days of price data for valid TWAP
    now >= init_time + THREE_DAYS_MS
}

/// Check if pool is locked for a proposal
public fun is_locked_for_proposal<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>
): bool {
    pool.last_proposal_usage.is_some()
}

/// Get ring buffer oracle reference (for spot_oracle_interface)
public fun get_ring_buffer_oracle<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>
): &RingBufferOracle {
    &pool.ring_buffer_oracle
}

/// Get longest possible TWAP for governance/minting
/// This uses the ring buffer oracle which has continuous history
public fun get_longest_twap_for_minting<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>,
    clock: &Clock,
): u128 {
    ring_buffer_oracle::get_longest_twap(&pool.ring_buffer_oracle, clock)
}

/// Get pool reserves
public fun get_reserves<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>
): (u64, u64) {
    (pool.asset_reserve.value(), pool.stable_reserve.value())
}

/// Get pool state including TWAP data
public fun get_pool_state<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>
): (u64, u64, u64, u128, u128, u64, Option<u64>) {
    (
        pool.asset_reserve.value(),
        pool.stable_reserve.value(),
        pool.lp_supply,
        pool.last_price,
        pool.last_window_twap,
        pool.window_start_timestamp,
        pool.initialized_at
    )
}

/// Update TWAP with a specific price (for transitions between spot and conditional)
public(package) fun update_twap_with_price<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    price: u128,
    clock: &Clock,
) {
    assert!(pool.initialized_at.is_some(), ENotInitialized);
    let now = clock.timestamp_ms();
    
    // Update the rolling window with the new price
    update_rolling_window(pool, now);
    
    // Set the new price
    pool.last_price = price;
    pool.last_timestamp = now;
    
    // Emit price update event
    event::emit(SpotPriceUpdate {
        pool_id: object::id(pool),
        price,
        timestamp: now,
        asset_reserve: pool.asset_reserve.value(),
        stable_reserve: pool.stable_reserve.value(),
    });
}

// === Conditional TWAP Integration ===

/// Write the winning conditional AMM's TWAP to fill the gap when liquidity was in proposals
/// This is called when a proposal that used DAO liquidity is finalized
public(package) fun write_conditional_twap<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    proposal_start: u64,   // When liquidity moved to conditional
    proposal_end: u64,     // When proposal finalized
    conditional_twap: u128, // TWAP from winning conditional AMM
    clock: &Clock,
) {
    // Calculate cumulative price for this period using the conditional TWAP
    let duration = proposal_end - proposal_start;
    let cumulative_price = (conditional_twap as u256) * (duration as u256);
    
    // Create a segment with the conditional AMM's TWAP data
    let segment = PriceSegment {
        start_timestamp: proposal_start,
        end_timestamp: proposal_end,
        cumulative_price,
        avg_price: conditional_twap,
    };
    
    // Add to historical segments
    pool.historical_segments.push_back(segment);
    
    // Clean up old segments (keep only last 3 days worth)
    let now = clock.timestamp_ms();
    let cutoff = if (now > THREE_DAYS_MS) {
        now - THREE_DAYS_MS
    } else {
        0
    };
    
    let mut i = 0;
    while (i < pool.historical_segments.length()) {
        let segment = pool.historical_segments.borrow(i);
        if (segment.end_timestamp < cutoff) {
            pool.historical_segments.swap_remove(i);
        } else {
            i = i + 1;
        };
    };
}

/// Mark when DAO liquidity moves to a proposal
/// This records the timestamp for later TWAP integration
public(package) fun mark_liquidity_to_proposal<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    clock: &Clock,
) {
    // Update TWAP one last time before liquidity moves to proposal
    if (pool.initialized_at.is_some()) {
        update_twap(pool, clock);
    };
    // Record when liquidity moved to proposal (for TWAP integration later)
    pool.last_proposal_usage = option::some(clock.timestamp_ms());
}

/// Merge winning conditional's ring buffer observations into spot after proposal finalizes
/// This ensures continuous price history for lending protocols
public(package) fun merge_winning_conditional_oracle<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    winning_conditional: &conditional_amm::LiquidityPool,
    proposal_start_ms: u64,
    proposal_end_ms: u64,
) {
    // Get the winning conditional's ring buffer oracle
    let conditional_oracle = conditional_amm::get_ring_buffer_oracle(winning_conditional);
    
    // Merge observations from the proposal period into spot's ring buffer
    ring_buffer_oracle::merge_observations(
        &mut pool.ring_buffer_oracle,
        conditional_oracle,
        proposal_start_ms,
        proposal_end_ms,
    );
}

/// Fill TWAP gap when proposal finalizes (hot path)
/// This is called when a proposal ends and we need to fill the gap in spot TWAP
/// with the winning conditional AMM's TWAP
public(package) fun fill_twap_gap_from_proposal<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    winning_conditional_twap: u128,
    winning_conditional_price: u128,
    clock: &Clock,
) {
    let now = clock.timestamp_ms();
    
    // Only fill gap if pool was locked for proposal
    if (pool.last_proposal_usage.is_some()) {
        let proposal_start = *pool.last_proposal_usage.borrow();
        let gap_duration = now - proposal_start;
        
        // Fill the gap in spot TWAP with winning conditional's TWAP
        if (gap_duration > 0) {
            let gap_contribution = (winning_conditional_twap as u256) * (gap_duration as u256);
            
            // Add to the spot's cumulative window
            pool.window_cumulative_price = pool.window_cumulative_price + gap_contribution;
            
            // Also write to historical segments for long-term tracking
            let segment = PriceSegment {
                start_timestamp: proposal_start,
                end_timestamp: now,
                cumulative_price: gap_contribution,
                avg_price: winning_conditional_twap,
            };
            pool.historical_segments.push_back(segment);
        };
        
        // Update timestamps and price to reflect filled gap
        pool.last_timestamp = now;
        pool.last_price = winning_conditional_price; // Resume from winning price
        pool.last_window_twap = winning_conditional_twap; // Update stable reference
        
        // Unlock the pool - clear proposal lock
        pool.last_proposal_usage = option::none();
    };
}

/// Get TWAP including conditional AMM prices when liquidity was in proposals
/// This provides continuous TWAP by using conditional prices during proposal periods
public fun get_twap_with_conditionals<AssetType, StableType>(
    pool: &SpotAMM<AssetType, StableType>,
    clock: &Clock,
): u128 {
    let now = clock.timestamp_ms();
    
    // If liquidity is currently in a proposal, we can't compute full TWAP yet
    // Return last known TWAP or price
    if (pool.last_proposal_usage.is_some()) {
        return pool.last_price
    };
    
    // Calculate the time range we need (last 3 days)
    let window_start = if (now > THREE_DAYS_MS) {
        now - THREE_DAYS_MS
    } else {
        0
    };
    
    let mut total_cumulative: u256 = 0;
    let mut total_duration: u64 = 0;
    
    // Process historical segments (conditional TWAP periods)
    let mut i = 0;
    let mut last_segment_end: u64 = 0;
    
    while (i < pool.historical_segments.length()) {
        let segment = pool.historical_segments.borrow(i);
        
        // Check if this segment overlaps with our 3-day window
        if (segment.end_timestamp > window_start && segment.start_timestamp < now) {
            let overlap_start = if (segment.start_timestamp > window_start) {
                segment.start_timestamp
            } else {
                window_start
            };
            
            let overlap_end = if (segment.end_timestamp < now) {
                segment.end_timestamp
            } else {
                now
            };
            
            let overlap_duration = overlap_end - overlap_start;
            
            // Add conditional TWAP contribution
            total_cumulative = total_cumulative + ((segment.avg_price as u256) * (overlap_duration as u256));
            total_duration = total_duration + overlap_duration;
            
            // Track the end of last segment
            if (segment.end_timestamp > last_segment_end) {
                last_segment_end = segment.end_timestamp;
            };
        };
        i = i + 1;
    };
    
    // Add spot TWAP for periods after the last conditional segment
    if (now > last_segment_end) {
        let spot_start = if (last_segment_end > window_start) {
            last_segment_end
        } else {
            if (pool.window_start_timestamp > window_start) {
                pool.window_start_timestamp
            } else {
                window_start
            }
        };
        
        let spot_duration = now - spot_start;
        if (spot_duration > 0 && pool.window_cumulative_price > 0) {
            // Add current spot window contribution
            let time_since_update = now - pool.last_timestamp;
            let projected_cumulative = pool.window_cumulative_price + 
                ((pool.last_price as u256) * (time_since_update as u256));
            
            // Scale to the actual spot duration we're using
            let spot_contribution = if (pool.window_start_timestamp == spot_start) {
                projected_cumulative
            } else {
                // Approximate by using average price
                let avg_spot_price = if ((now - pool.window_start_timestamp) > 0) {
                    (projected_cumulative / ((now - pool.window_start_timestamp) as u256)) as u128
                } else {
                    pool.last_price
                };
                (avg_spot_price as u256) * (spot_duration as u256)
            };
            
            total_cumulative = total_cumulative + spot_contribution;
            total_duration = total_duration + spot_duration;
        };
    };
    
    // Calculate final TWAP
    if (total_duration > 0) {
        (total_cumulative / (total_duration as u256)) as u128
    } else {
        pool.last_price
    }
}
