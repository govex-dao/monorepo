module futarchy_markets::swap;

use futarchy_markets::coin_escrow::{Self, TokenEscrow};
use futarchy_markets::market_state::MarketState;
use futarchy_markets::proposal::{Self, Proposal};
use sui::clock::Clock;
use sui::coin::{Self, Coin};

// === Introduction ===
// Swap functions for TreasuryCap-based conditional coins
// Swaps work by: burn input → update AMM reserves → mint output

// === Errors ===
const EInvalidOutcome: u64 = 0;
const EWrongTokenType: u64 = 1;
const EWrongOutcome: u64 = 2;
const EInvalidState: u64 = 3;
const EMarketIdMismatch: u64 = 4;
const EInsufficientOutput: u64 = 5;

// === Constants ===
const STATE_TRADING: u8 = 2; // Must match proposal.move STATE_TRADING

// === Core Swap Functions ===

/// Swap conditional asset coins to conditional stable coins
/// Uses TreasuryCap system: burn input → AMM calculation → mint output
public fun swap_asset_to_stable<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    asset_in: Coin<AssetConditionalCoin>,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableConditionalCoin> {
    assert!(proposal::state(proposal) == STATE_TRADING, EInvalidState);
    assert!(outcome_idx < proposal::outcome_count(proposal), EInvalidOutcome);

    let amount_in = asset_in.value();

    // Burn input conditional asset coins
    coin_escrow::burn_conditional_asset<AssetType, StableType, AssetConditionalCoin>(
        escrow,
        outcome_idx,
        asset_in,
    );

    // Calculate swap through AMM
    let pool = proposal::get_pool_mut_by_outcome(proposal, (outcome_idx as u8));
    let amount_out = pool.swap_asset_to_stable(
        escrow.get_market_state(),
        amount_in,
        min_amount_out,
        clock,
        ctx
    );

    assert!(amount_out >= min_amount_out, EInsufficientOutput);

    // Mint output conditional stable coins
    coin_escrow::mint_conditional_stable<AssetType, StableType, StableConditionalCoin>(
        escrow,
        outcome_idx,
        amount_out,
        ctx,
    )
}

/// Entry function wrapper for asset to stable swap
public entry fun swap_asset_to_stable_entry<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    asset_in: Coin<AssetConditionalCoin>,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let stable_out = swap_asset_to_stable<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
        proposal,
        escrow,
        outcome_idx,
        asset_in,
        min_amount_out,
        clock,
        ctx,
    );
    transfer::public_transfer(stable_out, ctx.sender());
}

/// Swap conditional stable coins to conditional asset coins
public fun swap_stable_to_asset<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    stable_in: Coin<StableConditionalCoin>,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetConditionalCoin> {
    assert!(proposal::state(proposal) == STATE_TRADING, EInvalidState);
    assert!(outcome_idx < proposal::outcome_count(proposal), EInvalidOutcome);

    let amount_in = stable_in.value();

    // Burn input conditional stable coins
    coin_escrow::burn_conditional_stable<AssetType, StableType, StableConditionalCoin>(
        escrow,
        outcome_idx,
        stable_in,
    );

    // Calculate swap through AMM
    let pool = proposal::get_pool_mut_by_outcome(proposal, (outcome_idx as u8));
    let amount_out = pool.swap_stable_to_asset(
        escrow.get_market_state(),
        amount_in,
        min_amount_out,
        clock,
        ctx
    );

    assert!(amount_out >= min_amount_out, EInsufficientOutput);

    // Mint output conditional asset coins
    coin_escrow::mint_conditional_asset<AssetType, StableType, AssetConditionalCoin>(
        escrow,
        outcome_idx,
        amount_out,
        ctx,
    )
}

/// Entry function wrapper for stable to asset swap
public entry fun swap_stable_to_asset_entry<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    stable_in: Coin<StableConditionalCoin>,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let asset_out = swap_stable_to_asset<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
        proposal,
        escrow,
        outcome_idx,
        stable_in,
        min_amount_out,
        clock,
        ctx,
    );
    transfer::public_transfer(asset_out, ctx.sender());
}

// REMOVED: create_and_swap_* functions
// These functions relied on ConditionalToken's merge_many() and split_and_return() operations
// which don't exist for native Sui Coin<T> types.
//
// With TreasuryCap-based conditional coins, users should:
// 1. Deposit spot tokens to mint conditional coins for a specific outcome
// 2. Use coin::split() and coin::join() for merging/splitting
// 3. Call swap functions directly with the conditional coins
//
// The frontend/SDK can compose these operations in PTBs as needed.
