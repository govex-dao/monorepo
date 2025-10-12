module futarchy_markets::spot_conditional_quoter;

use std::option::{Self, Option};
use futarchy_markets::conditional_amm::{Self, LiquidityPool};
use futarchy_markets::proposal::{Self, Proposal};
use futarchy_markets::coin_escrow::TokenEscrow;
use futarchy_markets::market_state::MarketState;
use futarchy_markets::unified_spot_pool::{Self, UnifiedSpotPool};
use sui::clock::Clock;

// === Introduction ===
// This module provides quote functionality for spot token swaps through conditional AMMs.
// It simulates the routing process to provide accurate quotes without executing trades.
//
// Key features:
// - Provides accurate quotes for spot-to-spot swaps through conditional AMMs
// - Accounts for complete set minting/redemption costs
// - Simulates the full routing path without state changes
// - Returns both output amounts and price impact information

// === Errors ===
const EInvalidOutcome: u64 = 0;
const EZeroAmount: u64 = 1;
const EMarketNotActive: u64 = 2;
const EInsufficientLiquidity: u64 = 3;

// === Structs ===

/// Quote result for a spot swap
public struct SpotQuote has copy, drop {
    /// The expected output amount
    amount_out: u64,
    /// The effective price (amount_out / amount_in scaled by 1e9)
    effective_price: u64,
    /// The price impact percentage (scaled by 1e4, so 100 = 1%)
    price_impact_bps: u64,
    /// The outcome being traded through
    outcome: u64,
    /// Whether this is asset->stable (true) or stable->asset (false)
    is_asset_to_stable: bool,
}

/// Detailed quote with breakdown
public struct DetailedSpotQuote has copy, drop {
    /// Basic quote information
    quote: SpotQuote,
    /// Amount of conditional tokens created
    conditional_tokens_created: u64,
    /// Amount of conditional tokens that would be returned as excess
    excess_conditional_tokens: u64,
    /// The spot price before the trade
    spot_price_before: u64,
    /// The spot price after the trade
    spot_price_after: u64,
}

// === Public View Functions ===

/// Get a quote for swapping spot asset to spot stable through a specific outcome
public fun quote_spot_asset_to_stable<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    amount_in: u64,
    clock: &Clock,
): SpotQuote {
    // Validate inputs
    assert!(amount_in > 0, EZeroAmount);
    assert!(outcome_idx < proposal.outcome_count(), EInvalidOutcome);
    
    // Verify market is active
    let market_state = escrow.get_market_state();
    assert!(market_state.is_trading_active(), EMarketNotActive);
    
    // Step 1: Complete set minting creates amount_in of each conditional token
    let conditional_asset_amount = amount_in;

    // Step 2: Get the AMM for this outcome
    let amm = proposal.get_pool_by_outcome(escrow, (outcome_idx as u8));
    
    // Step 3: Calculate swap output for asset -> stable
    let stable_out = conditional_amm::quote_swap_asset_to_stable(
        amm,
        conditional_asset_amount
    );
    
    // Step 4: Complete set redemption would give us stable_out spot tokens
    // (other outcomes would have excess conditional tokens returned)
    
    // Calculate effective price (scaled by 1e9 for precision)
    let effective_price = if (amount_in > 0) {
        (stable_out as u128) * 1_000_000_000 / (amount_in as u128)
    } else {
        0
    };
    
    // Calculate price impact
    let (asset_reserve, stable_reserve) = conditional_amm::get_reserves(amm);
    let spot_price_before = if (asset_reserve > 0) {
        (stable_reserve as u128) * 1_000_000_000 / (asset_reserve as u128)
    } else {
        0
    };
    
    let price_impact_bps = calculate_price_impact(
        spot_price_before as u64,
        effective_price as u64
    );
    
    SpotQuote {
        amount_out: stable_out,
        effective_price: effective_price as u64,
        price_impact_bps,
        outcome: outcome_idx,
        is_asset_to_stable: true,
    }
}

/// Get a quote for swapping spot stable to spot asset through a specific outcome
public fun quote_spot_stable_to_asset<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    amount_in: u64,
    clock: &Clock,
): SpotQuote {
    // Validate inputs
    assert!(amount_in > 0, EZeroAmount);
    assert!(outcome_idx < proposal.outcome_count(), EInvalidOutcome);
    
    // Verify market is active
    let market_state = escrow.get_market_state();
    assert!(market_state.is_trading_active(), EMarketNotActive);
    
    // Step 1: Complete set minting creates amount_in of each conditional token
    let conditional_stable_amount = amount_in;

    // Step 2: Get the AMM for this outcome
    let amm = proposal.get_pool_by_outcome(escrow, (outcome_idx as u8));
    
    // Step 3: Calculate swap output for stable -> asset
    let asset_out = conditional_amm::quote_swap_stable_to_asset(
        amm,
        conditional_stable_amount
    );
    
    // Step 4: Complete set redemption would give us asset_out spot tokens
    
    // Calculate effective price (scaled by 1e9 for precision)
    let effective_price = if (amount_in > 0) {
        (asset_out as u128) * 1_000_000_000 / (amount_in as u128)
    } else {
        0
    };
    
    // Calculate price impact
    let (asset_reserve, stable_reserve) = conditional_amm::get_reserves(amm);
    let spot_price_before = if (stable_reserve > 0) {
        (asset_reserve as u128) * 1_000_000_000 / (stable_reserve as u128)
    } else {
        0
    };
    
    let price_impact_bps = calculate_price_impact(
        spot_price_before as u64,
        effective_price as u64
    );
    
    SpotQuote {
        amount_out: asset_out,
        effective_price: effective_price as u64,
        price_impact_bps,
        outcome: outcome_idx,
        is_asset_to_stable: false,
    }
}

/// Get a detailed quote with additional information
public fun quote_spot_asset_to_stable_detailed<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    amount_in: u64,
    clock: &Clock,
): DetailedSpotQuote {
    // Get basic quote
    let quote = quote_spot_asset_to_stable(
        proposal,
        escrow,
        outcome_idx,
        amount_in,
        clock
    );
    
    // Get AMM for detailed calculations
    let amm = proposal.get_pool_by_outcome(escrow, (outcome_idx as u8));
    let (asset_reserve_before, stable_reserve_before) = conditional_amm::get_reserves(amm);

    // Calculate reserves after trade
    let asset_reserve_after = asset_reserve_before + amount_in;
    let stable_reserve_after = stable_reserve_before - quote.amount_out;
    
    // Calculate spot prices
    let spot_price_before = if (asset_reserve_before > 0) {
        (stable_reserve_before as u128) * 1_000_000_000 / (asset_reserve_before as u128)
    } else {
        0
    };
    
    let spot_price_after = if (asset_reserve_after > 0) {
        (stable_reserve_after as u128) * 1_000_000_000 / (asset_reserve_after as u128)
    } else {
        0
    };
    
    // Calculate excess tokens (all non-traded outcomes)
    let outcome_count = proposal.outcome_count();
    let excess_conditional_tokens = (outcome_count - 1) * amount_in;
    
    DetailedSpotQuote {
        quote,
        conditional_tokens_created: outcome_count * amount_in,
        excess_conditional_tokens,
        spot_price_before: spot_price_before as u64,
        spot_price_after: spot_price_after as u64,
    }
}

/// Get a detailed quote for stable to asset swap
public fun quote_spot_stable_to_asset_detailed<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    amount_in: u64,
    clock: &Clock,
): DetailedSpotQuote {
    // Get basic quote
    let quote = quote_spot_stable_to_asset(
        proposal,
        escrow,
        outcome_idx,
        amount_in,
        clock
    );

    // Get AMM for detailed calculations
    let amm = proposal.get_pool_by_outcome(escrow, (outcome_idx as u8));
    let (asset_reserve_before, stable_reserve_before) = conditional_amm::get_reserves(amm);

    // Calculate reserves after trade
    let stable_reserve_after = stable_reserve_before + amount_in;
    let asset_reserve_after = asset_reserve_before - quote.amount_out;
    
    // Calculate spot prices
    let spot_price_before = if (stable_reserve_before > 0) {
        (asset_reserve_before as u128) * 1_000_000_000 / (stable_reserve_before as u128)
    } else {
        0
    };
    
    let spot_price_after = if (stable_reserve_after > 0) {
        (asset_reserve_after as u128) * 1_000_000_000 / (stable_reserve_after as u128)
    } else {
        0
    };
    
    // Calculate excess tokens
    let outcome_count = proposal.outcome_count();
    let excess_conditional_tokens = (outcome_count - 1) * amount_in;
    
    DetailedSpotQuote {
        quote,
        conditional_tokens_created: outcome_count * amount_in,
        excess_conditional_tokens,
        spot_price_before: spot_price_before as u64,
        spot_price_after: spot_price_after as u64,
    }
}

/// Find the best outcome to route a spot asset to stable swap through
public fun find_best_asset_to_stable_route<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
    amount_in: u64,
    clock: &Clock,
): (u64, SpotQuote) {
    assert!(amount_in > 0, EZeroAmount);
    
    let outcome_count = proposal.outcome_count();
    assert!(outcome_count > 0, EInvalidOutcome);
    
    let mut best_outcome = 0;
    let mut best_quote = quote_spot_asset_to_stable(
        proposal,
        escrow,
        0,
        amount_in,
        clock
    );
    
    let mut i = 1;
    while (i < outcome_count) {
        let quote = quote_spot_asset_to_stable(
            proposal,
            escrow,
            i,
            amount_in,
            clock
        );
        
        if (quote.amount_out > best_quote.amount_out) {
            best_outcome = i;
            best_quote = quote;
        };
        
        i = i + 1;
    };
    
    (best_outcome, best_quote)
}

/// Find the best outcome to route a spot stable to asset swap through
public fun find_best_stable_to_asset_route<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
    amount_in: u64,
    clock: &Clock,
): (u64, SpotQuote) {
    assert!(amount_in > 0, EZeroAmount);
    
    let outcome_count = proposal.outcome_count();
    assert!(outcome_count > 0, EInvalidOutcome);
    
    let mut best_outcome = 0;
    let mut best_quote = quote_spot_stable_to_asset(
        proposal,
        escrow,
        0,
        amount_in,
        clock
    );
    
    let mut i = 1;
    while (i < outcome_count) {
        let quote = quote_spot_stable_to_asset(
            proposal,
            escrow,
            i,
            amount_in,
            clock
        );
        
        if (quote.amount_out > best_quote.amount_out) {
            best_outcome = i;
            best_quote = quote;
        };
        
        i = i + 1;
    };
    
    (best_outcome, best_quote)
}

// === Helper Functions ===

/// Calculate price impact in basis points
fun calculate_price_impact(price_before: u64, effective_price: u64): u64 {
    if (price_before == 0) {
        return 0
    };
    
    let diff = if (effective_price > price_before) {
        effective_price - price_before
    } else {
        price_before - effective_price
    };
    
    // Calculate impact as basis points (1 bp = 0.01%)
    let impact = (diff as u128) * 10000 / (price_before as u128);
    impact as u64
}

// === Accessor Functions ===

public fun get_amount_out(quote: &SpotQuote): u64 {
    quote.amount_out
}

public fun get_effective_price(quote: &SpotQuote): u64 {
    quote.effective_price
}

public fun get_price_impact_bps(quote: &SpotQuote): u64 {
    quote.price_impact_bps
}

public fun get_outcome(quote: &SpotQuote): u64 {
    quote.outcome
}

public fun is_asset_to_stable(quote: &SpotQuote): bool {
    quote.is_asset_to_stable
}

public fun get_conditional_tokens_created(detailed: &DetailedSpotQuote): u64 {
    detailed.conditional_tokens_created
}

public fun get_excess_conditional_tokens(detailed: &DetailedSpotQuote): u64 {
    detailed.excess_conditional_tokens
}

public fun get_spot_price_before(detailed: &DetailedSpotQuote): u64 {
    detailed.spot_price_before
}

public fun get_spot_price_after(detailed: &DetailedSpotQuote): u64 {
    detailed.spot_price_after
}

// === Oracle Price Functions ===

/// Get combined oracle price from spot AMM
/// Returns the spot AMM TWAP (no conditional data in simple quoter)
public fun get_combined_oracle_price<AssetType, StableType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    clock: &Clock,
): u128 {
    // Return the spot AMM TWAP (no conditional data in simple quoter)
    unified_spot_pool::get_twap(spot_pool, clock)
}

/// Check if a price meets a threshold condition
public fun check_price_threshold(
    price: u128,
    threshold: u128,
    is_above_threshold: bool,
): bool {
    if (is_above_threshold) {
        price >= threshold
    } else {
        price <= threshold
    }
}

/// Check if proposals can be created based on TWAP readiness
public fun can_create_proposal<AssetType, StableType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    clock: &Clock,
): bool {
    unified_spot_pool::is_twap_ready(spot_pool, clock)
}

/// Get time until proposals are allowed (returns 0 if ready)
public fun time_until_proposals_allowed<AssetType, StableType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    clock: &Clock,
): u64 {
    // Check if TWAP is ready
    if (unified_spot_pool::is_twap_ready(spot_pool, clock)) {
        return 0
    };

    // Calculate remaining time (simplified - assumes 3 days needed)
    259_200_000 // Return 3 days in ms as placeholder
}

/// Get initialization price for conditional AMMs
public fun get_initialization_price<AssetType, StableType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    clock: &Clock,
): u128 {
    unified_spot_pool::get_twap(spot_pool, clock)
}