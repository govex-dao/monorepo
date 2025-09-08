module futarchy_markets::spot_conditional_router;

use futarchy_markets::swap;
use futarchy_markets::coin_escrow::{Self, TokenEscrow};
use futarchy_markets::conditional_token::ConditionalToken;
use futarchy_markets::proposal::Proposal;
use sui::coin::{Self, Coin};
use sui::clock::Clock;
use sui::transfer;
use sui::tx_context::TxContext;
use std::vector;

// Errors
const EMinOutNotMet: u64 = 1;
const EInvalidState: u64 = 2;
const EZeroAmount: u64 = 3;
const ESlippageTooHigh: u64 = 4;

/// Asset → Stable (spot exact-in)
/// Route: deposit ASSET → mint complete set of ASSET tokens →
///        swap each to STABLE in its outcome AMM → redeem STABLE complete set → STABLE coin.
#[allow(lint(self_transfer))]
public entry fun swap_spot_asset_to_spot_stable_exact_in<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_in: Coin<AssetType>,
    min_stable_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Disallow if market is finalized
    let market_state = escrow.get_market_state();
    assert!(!market_state.is_finalized(), EInvalidState);

    // 1) Mint complete set of ASSET conditional tokens
    let mut tokens = coin_escrow::mint_complete_set_asset(escrow, asset_in, clock, ctx);

    // Calculate per-leg minimum to prevent MEV attacks
    // Allow max 5% slippage per leg (95% of expected fair share)
    let num_outcomes = tokens.length();
    assert!(num_outcomes > 0, EZeroAmount);
    let per_leg_min = if (min_stable_out > 0 && num_outcomes > 0) {
        // Distribute minimum proportionally with 5% tolerance
        (min_stable_out * 95 / 100) / num_outcomes
    } else {
        0
    };

    // 2) Convert each token ASSET→STABLE via its outcome AMM
    let mut stable_tokens = vector::empty<ConditionalToken>();
    while (!tokens.is_empty()) {
        let t = tokens.pop_back();                     // take ownership
        let outcome_idx = (t.outcome() as u64);        // safe to rely on token metadata
        let s = swap::swap_asset_to_stable(
            proposal,
            escrow,
            outcome_idx,
            t,                                         // moved here
            per_leg_min,                               // MEV protection per swap
            clock,
            ctx
        );
        stable_tokens.push_back(s);
    };
    tokens.destroy_empty();

    // 3) Redeem STABLE complete set back to spot coin
    let balance_out = coin_escrow::redeem_complete_set_stable(escrow, stable_tokens, clock, ctx);
    let stable_out = coin::from_balance(balance_out, ctx);
    let out_amt = coin::value(&stable_out);
    assert!(out_amt >= min_stable_out, EMinOutNotMet);

    transfer::public_transfer(stable_out, ctx.sender());
}

/// Stable → Asset (spot exact-in)
/// Route: deposit STABLE → mint complete set of STABLE tokens →
///        swap each to ASSET in its outcome AMM → redeem ASSET complete set → ASSET coin.
#[allow(lint(self_transfer))]
public entry fun swap_spot_stable_to_spot_asset_exact_in<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    stable_in: Coin<StableType>,
    min_asset_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Disallow if market is finalized
    let market_state = escrow.get_market_state();
    assert!(!market_state.is_finalized(), EInvalidState);

    // 1) Mint complete set of STABLE conditional tokens
    let mut tokens = coin_escrow::mint_complete_set_stable(escrow, stable_in, clock, ctx);

    // Calculate per-leg minimum to prevent MEV attacks
    let num_outcomes = tokens.length();
    assert!(num_outcomes > 0, EZeroAmount);
    let per_leg_min = if (min_asset_out > 0 && num_outcomes > 0) {
        // Distribute minimum proportionally with 5% tolerance
        (min_asset_out * 95 / 100) / num_outcomes
    } else {
        0
    };

    // 2) Convert each token STABLE→ASSET via its outcome AMM
    let mut asset_tokens = vector::empty<ConditionalToken>();
    while (!tokens.is_empty()) {
        let t = tokens.pop_back();
        let outcome_idx = (t.outcome() as u64);
        let a = swap::swap_stable_to_asset(
            proposal,
            escrow,
            outcome_idx,
            t,
            per_leg_min,                               // MEV protection per swap
            clock,
            ctx
        );
        asset_tokens.push_back(a);
    };
    tokens.destroy_empty();

    // 3) Redeem ASSET complete set back to spot coin
    let balance_out = coin_escrow::redeem_complete_set_asset(escrow, asset_tokens, clock, ctx);
    let asset_out = coin::from_balance(balance_out, ctx);
    let out_amt = coin::value(&asset_out);
    assert!(out_amt >= min_asset_out, EMinOutNotMet);

    transfer::public_transfer(asset_out, ctx.sender());
}