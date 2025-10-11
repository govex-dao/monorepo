module futarchy_markets::swap;

use futarchy_markets::coin_escrow::{Self, TokenEscrow};
use futarchy_markets::market_state::MarketState;
use futarchy_markets::proposal::{Self, Proposal};
use futarchy_markets::early_resolve;
use futarchy_markets::swap_position_registry::{Self, SwapPositionRegistry};
use futarchy_one_shot_utils::math;
use std::option::{Self, Option};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::object::{Self, ID};

// === Introduction ===
// Swap functions for TreasuryCap-based conditional coins
// Swaps work by: burn input → update AMM reserves → mint output
//
// Hot potato pattern ensures early resolve metrics are updated once per PTB:
// 1. begin_swap_session() - creates SwapSession hot potato
// 2. swap_*() - validates session, performs swaps
// 3. finalize_swap_session() - consumes hot potato, updates metrics ONCE

// === Errors ===
const EInvalidOutcome: u64 = 0;
const EWrongTokenType: u64 = 1;
const EWrongOutcome: u64 = 2;
const EInvalidState: u64 = 3;
const EMarketIdMismatch: u64 = 4;
const EInsufficientOutput: u64 = 5;
const ESessionMismatch: u64 = 6;

// === Constants ===
const STATE_TRADING: u8 = 2; // Must match proposal.move STATE_TRADING

// === Structs ===

/// Hot potato that enforces early resolve metrics update at end of swap session
/// No abilities = must be consumed by finalize_swap_session()
public struct SwapSession {
    proposal_id: ID,  // Track which proposal this session is for
}

// === Session Management ===

/// Begin a swap session (creates hot potato)
/// Must be called before any swaps in a PTB
///
/// Creates a hot potato that must be consumed by finalize_swap_session().
/// This ensures metrics are updated exactly once after all swaps complete.
public fun begin_swap_session<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): SwapSession {
    SwapSession {
        proposal_id: object::id(proposal),
    }
}

/// Finalize swap session (consumes hot potato and updates metrics)
/// Must be called at end of PTB to consume the SwapSession
/// This is where early resolve metrics are updated ONCE for efficiency
///
/// **Idempotency Guarantee:** update_early_resolve_metrics is idempotent when called
/// multiple times at the same timestamp with unchanged state. If winner hasn't flipped,
/// the second call is a no-op (just gas cost, no state changes). This ensures correctness
/// even if accidentally called multiple times in same PTB.
///
/// **Flip Recalculation:** This function recalculates the winning outcome from current
/// AMM prices AFTER all swaps complete, ensuring flip detection happens exactly once
/// per transaction with up-to-date market state.
public fun finalize_swap_session<AssetType, StableType>(
    session: SwapSession,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    clock: &Clock,
) {
    let SwapSession { proposal_id } = session;
    assert!(proposal_id == object::id(proposal), ESessionMismatch);

    // Update early resolve metrics once per session (efficient!)
    // Recalculates winner from current prices after all swaps complete
    // Get market_state from escrow to pass to early_resolve
    let market_state = coin_escrow::get_market_state_mut(escrow);
    early_resolve::update_metrics(proposal, market_state, clock);
}

// === Core Swap Functions ===

/// Swap conditional asset coins to conditional stable coins
/// Uses TreasuryCap system: burn input → AMM calculation → mint output
/// Requires valid SwapSession to ensure metrics are updated at end of PTB
public fun swap_asset_to_stable<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    session: &SwapSession,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    asset_in: Coin<AssetConditionalCoin>,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableConditionalCoin> {
    // Validate session matches proposal
    assert!(session.proposal_id == object::id(proposal), ESessionMismatch);

    assert!(proposal::state(proposal) == STATE_TRADING, EInvalidState);
    assert!(outcome_idx < proposal::outcome_count(proposal), EInvalidOutcome);

    let amount_in = asset_in.value();

    // Burn input conditional asset coins
    coin_escrow::burn_conditional_asset<AssetType, StableType, AssetConditionalCoin>(
        escrow,
        outcome_idx,
        asset_in,
    );

    // Calculate swap through AMM (access pools from market_state)
    let market_state = coin_escrow::get_market_state_mut(escrow);
    let market_id = futarchy_markets::market_state::market_id(market_state);
    let pool = futarchy_markets::market_state::get_pool_mut_by_outcome(market_state, (outcome_idx as u8));
    let amount_out = pool.swap_asset_to_stable(
        market_id,
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
/// Creates session, swaps, finalizes session (all in one call)
public entry fun swap_asset_to_stable_entry<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    asset_in: Coin<AssetConditionalCoin>,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Begin session (create hot potato)
    let session = begin_swap_session(proposal);

    // Perform swap
    let stable_out = swap_asset_to_stable<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
        &session,
        proposal,
        escrow,
        outcome_idx,
        asset_in,
        min_amount_out,
        clock,
        ctx,
    );

    // Finalize session (consume hot potato, update metrics)
    finalize_swap_session(session, proposal, escrow, clock);

    // Transfer output to sender
    transfer::public_transfer(stable_out, ctx.sender());
}

/// Swap conditional stable coins to conditional asset coins
/// Requires valid SwapSession to ensure metrics are updated at end of PTB
public fun swap_stable_to_asset<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    session: &SwapSession,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    stable_in: Coin<StableConditionalCoin>,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetConditionalCoin> {
    // Validate session matches proposal
    assert!(session.proposal_id == object::id(proposal), ESessionMismatch);

    assert!(proposal::state(proposal) == STATE_TRADING, EInvalidState);
    assert!(outcome_idx < proposal::outcome_count(proposal), EInvalidOutcome);

    let amount_in = stable_in.value();

    // Burn input conditional stable coins
    coin_escrow::burn_conditional_stable<AssetType, StableType, StableConditionalCoin>(
        escrow,
        outcome_idx,
        stable_in,
    );

    // Calculate swap through AMM (access pools from market_state)
    let market_state = coin_escrow::get_market_state_mut(escrow);
    let market_id = futarchy_markets::market_state::market_id(market_state);
    let pool = futarchy_markets::market_state::get_pool_mut_by_outcome(market_state, (outcome_idx as u8));
    let amount_out = pool.swap_stable_to_asset(
        market_id,
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
/// Creates session, swaps, finalizes session (all in one call)
public entry fun swap_stable_to_asset_entry<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    stable_in: Coin<StableConditionalCoin>,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Begin session (create hot potato)
    let session = begin_swap_session(proposal);

    // Perform swap
    let asset_out = swap_stable_to_asset<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
        &session,
        proposal,
        escrow,
        outcome_idx,
        stable_in,
        min_amount_out,
        clock,
        ctx,
    );

    // Finalize session (consume hot potato, update metrics)
    finalize_swap_session(session, proposal, escrow, clock);

    // Transfer output to sender
    transfer::public_transfer(asset_out, ctx.sender());
}

// === Batched Swap Entry Functions ===

/// Batch swap asset to stable across multiple outcomes in a single transaction
/// Efficient for M-of-N trading: metrics updated once after all swaps complete
///
/// **Gas Efficiency:** For M swaps, this is ~3× more efficient than M separate transactions
/// because metrics are calculated once instead of M times.
public entry fun swap_multiple_asset_to_stable_entry<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_indices: vector<u64>,
    mut assets_in: vector<Coin<AssetConditionalCoin>>,
    min_amounts_out: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(outcome_indices.length() == assets_in.length(), EInsufficientOutput);
    assert!(outcome_indices.length() == min_amounts_out.length(), EInsufficientOutput);

    // Begin session once for all swaps
    let session = begin_swap_session(proposal);

    // Transfer outputs as we go (Coins don't have drop ability)
    let sender = ctx.sender();
    let mut i = 0;
    while (i < outcome_indices.length()) {
        let stable_out = swap_asset_to_stable<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
            &session,
            proposal,
            escrow,
            *outcome_indices.borrow(i),
            vector::pop_back(&mut assets_in),
            *min_amounts_out.borrow(i),
            clock,
            ctx,
        );
        transfer::public_transfer(stable_out, sender);
        i = i + 1;
    };

    // Finalize session - metrics updated once after all swaps
    finalize_swap_session(session, proposal, escrow, clock);

    // Clean up empty vector
    vector::destroy_empty(assets_in);
}

/// Batch swap stable to asset across multiple outcomes in a single transaction
/// Efficient for M-of-N trading: metrics updated once after all swaps complete
public entry fun swap_multiple_stable_to_asset_entry<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_indices: vector<u64>,
    mut stables_in: vector<Coin<StableConditionalCoin>>,
    min_amounts_out: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(outcome_indices.length() == stables_in.length(), EInsufficientOutput);
    assert!(outcome_indices.length() == min_amounts_out.length(), EInsufficientOutput);

    // Begin session once for all swaps
    let session = begin_swap_session(proposal);

    // Transfer outputs as we go (Coins don't have drop ability)
    let sender = ctx.sender();
    let mut i = 0;
    while (i < outcome_indices.length()) {
        let asset_out = swap_stable_to_asset<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
            &session,
            proposal,
            escrow,
            *outcome_indices.borrow(i),
            vector::pop_back(&mut stables_in),
            *min_amounts_out.borrow(i),
            clock,
            ctx,
        );
        transfer::public_transfer(asset_out, sender);
        i = i + 1;
    };

    // Finalize session - metrics updated once after all swaps
    finalize_swap_session(session, proposal, escrow, clock);

    // Clean up empty vector
    vector::destroy_empty(stables_in);
}

// REMOVED: Multi-coin merge functions
// Users should merge coins in PTB using coin::join() before calling swap functions
// This keeps contract logic simple and gas-efficient

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

// === DEX Aggregator Compatibility Functions ===
//
// For DEX aggregators (like Aftermath), swaps during active proposals are problematic:
// - Input: 1 coin type (USDC)
// - Output: Multiple conditional coin types (Cond0_SUI + Cond1_SUI)
// - Aggregators expect single output type
//
// SOLUTION:
// 1. Smart recombination: Immediately recombine matching amounts to spot
// 2. Registry storage: Store remainder conditional coins in SwapPositionRegistry
// 3. Permissionless cranking: Anyone can settle positions after proposal resolves

/// Entry function wrapper: Swaps and uses registry by default
/// For DEX aggregators - always stores conditionals in registry
public entry fun swap_stable_to_asset_with_registry_2<AssetType, StableType, Cond0Asset, Cond1Asset, Cond0Stable, Cond1Stable>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    registry: &mut SwapPositionRegistry<AssetType, StableType>,
    stable_in: Coin<StableType>,
    min_asset_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let session = begin_swap_session(proposal);

    // Determine routing strategy
    let outcome_0_amount = stable_in.value() / 2;
    let _outcome_1_amount = stable_in.value() - outcome_0_amount;

    // Split input for each outcome
    let stable_for_0 = if (outcome_0_amount > 0) {
        stable_in.split(outcome_0_amount, ctx)
    } else {
        coin::zero<StableType>(ctx)
    };
    let stable_for_1 = stable_in;

    // Swap in each conditional pool
    let cond_asset_0 = if (stable_for_0.value() > 0) {
        let cond_stable = coin_escrow::deposit_stable_and_mint_conditional<AssetType, StableType, Cond0Stable>(
            escrow, 0, stable_for_0, ctx
        );
        let amount_in = cond_stable.value();
        coin_escrow::burn_conditional_stable(escrow, 0, cond_stable);
        let market_state = coin_escrow::get_market_state_mut(escrow);
        let pool = futarchy_markets::market_state::get_pool_mut_by_outcome(market_state, 0);
        let market_id = futarchy_markets::market_state::market_id(market_state);
        let amount_out = pool.swap_stable_to_asset(market_id, amount_in, 0, clock, ctx);
        coin_escrow::mint_conditional_asset<AssetType, StableType, Cond0Asset>(escrow, 0, amount_out, ctx)
    } else {
        coin::destroy_zero(stable_for_0);
        coin::zero<Cond0Asset>(ctx)
    };

    let cond_asset_1 = if (stable_for_1.value() > 0) {
        let cond_stable = coin_escrow::deposit_stable_and_mint_conditional<AssetType, StableType, Cond1Stable>(
            escrow, 1, stable_for_1, ctx
        );
        let amount_in = cond_stable.value();
        coin_escrow::burn_conditional_stable(escrow, 1, cond_stable);
        let market_state = coin_escrow::get_market_state_mut(escrow);
        let pool = futarchy_markets::market_state::get_pool_mut_by_outcome(market_state, 1);
        let market_id = futarchy_markets::market_state::market_id(market_state);
        let amount_out = pool.swap_stable_to_asset(market_id, amount_in, 0, clock, ctx);
        coin_escrow::mint_conditional_asset<AssetType, StableType, Cond1Asset>(escrow, 1, amount_out, ctx)
    } else {
        coin::destroy_zero(stable_for_1);
        coin::zero<Cond1Asset>(ctx)
    };

    // Smart recombination
    let amount_0 = cond_asset_0.value();
    let amount_1 = cond_asset_1.value();
    let min_amount = math::min(amount_0, amount_1);

    let spot_asset = if (min_amount > 0) {
        let to_burn_0 = cond_asset_0.split(min_amount, ctx);
        let to_burn_1 = cond_asset_1.split(min_amount, ctx);
        coin_escrow::burn_conditional_asset(escrow, 0, to_burn_0);
        coin_escrow::burn_conditional_asset(escrow, 1, to_burn_1);
        coin_escrow::withdraw_asset_balance(escrow, min_amount, ctx)
    } else {
        coin::zero<AssetType>(ctx)
    };

    // Store remainders in registry
    let proposal_id = object::id(proposal);
    let owner = ctx.sender();

    if (cond_asset_0.value() > 0) {
        swap_position_registry::store_conditional_asset(
            registry, owner, proposal_id, 0, cond_asset_0, clock, ctx
        );
    } else {
        coin::destroy_zero(cond_asset_0);
    };

    if (cond_asset_1.value() > 0) {
        swap_position_registry::store_conditional_asset(
            registry, owner, proposal_id, 1, cond_asset_1, clock, ctx
        );
    } else {
        coin::destroy_zero(cond_asset_1);
    };

    finalize_swap_session(session, proposal, escrow, clock);

    // Verify min output
    assert!(spot_asset.value() >= min_asset_out, EInsufficientOutput);

    // Transfer spot asset to user
    if (spot_asset.value() > 0) {
        transfer::public_transfer(spot_asset, ctx.sender());
    } else {
        coin::destroy_zero(spot_asset);
    };
}
