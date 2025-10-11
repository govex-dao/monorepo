module futarchy_markets::liquidity_interact;

use futarchy_markets::conditional_amm;
use futarchy_markets::coin_escrow::{Self, TokenEscrow};
use futarchy_markets::fee::FeeManager;
use futarchy_markets::proposal::Proposal;
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;

// === Introduction ===
// Methods to interact with AMM liquidity and escrow balances using TreasuryCap-based conditional coins

// === Errors ===
const EInvalidOutcome: u64 = 0;
const EInvalidLiquidityTransfer: u64 = 1;
const EWrongOutcome: u64 = 2;
const EInvalidState: u64 = 3;
const EMarketIdMismatch: u64 = 4;
const EAssetReservesMismatch: u64 = 5;
const EStableReservesMismatch: u64 = 6;
const EInsufficientAmount: u64 = 7;
const EMinAmountNotMet: u64 = 8;

// === Events ===
public struct ProtocolFeesCollected has copy, drop {
    proposal_id: ID,
    winning_outcome: u64,
    fee_amount: u64,
    timestamp_ms: u64,
}

// === Liquidity Removal (After Finalization) ===

/// Empties the winning AMM pool and transfers the underlying liquidity to the original provider.
/// Called internally by `advance_stage` when a user-funded proposal finalizes.
///
/// IMPORTANT: With TreasuryCap-based conditional coins, this function:
/// 1. Removes liquidity from winning AMM pool (gets conditional coin amounts)
/// 2. Burns those conditional coins using TreasuryCaps
/// 3. Withdraws equivalent spot tokens from escrow
/// 4. Transfers spot tokens to liquidity provider
public fun empty_amm_and_return_to_provider<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    ctx: &mut TxContext,
) {
    assert!(proposal.is_finalized(), EInvalidState);
    assert!(!proposal.uses_dao_liquidity(), EInvalidState);

    let market_state = escrow.get_market_state();
    let winning_outcome = proposal.get_winning_outcome();
    market_state.assert_market_finalized();

    // Get winning pool from market_state and empty its liquidity (returns conditional coin amounts)
    let market_state = escrow.get_market_state_mut();
    let pool = futarchy_markets::market_state::get_pool_mut_by_outcome(market_state, (winning_outcome as u8));
    let (conditional_asset_amt, conditional_stable_amt) = pool.empty_all_amm_liquidity(ctx);

    // Burn the conditional coins (1:1 with spot due to quantum liquidity)
    let asset_coin = escrow.burn_conditional_asset_and_withdraw<AssetType, StableType, AssetConditionalCoin>(
        winning_outcome,
        conditional_asset_amt,
        ctx,
    );

    let stable_coin = escrow.burn_conditional_stable_and_withdraw<AssetType, StableType, StableConditionalCoin>(
        winning_outcome,
        conditional_stable_amt,
        ctx,
    );

    // Transfer spot tokens to provider
    let provider = *proposal.get_liquidity_provider().borrow();
    transfer::public_transfer(asset_coin, provider);
    transfer::public_transfer(stable_coin, provider);
}

/// Empties the winning AMM pool and returns the liquidity.
/// Called internally by `advance_stage` when a DAO-funded proposal finalizes.
/// Returns the asset and stable coins for the DAO to handle (e.g., deposit to vault).
public fun empty_amm_and_return_to_dao<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    ctx: &mut TxContext,
): (Coin<AssetType>, Coin<StableType>) {
    assert!(proposal.is_finalized(), EInvalidState);
    assert!(proposal.uses_dao_liquidity(), EInvalidState);

    let market_state = escrow.get_market_state();
    market_state.assert_market_finalized();

    let winning_outcome = proposal.get_winning_outcome();
    // Get winning pool from market_state
    let market_state = escrow.get_market_state_mut();
    let pool = futarchy_markets::market_state::get_pool_mut_by_outcome(market_state, (winning_outcome as u8));
    let (conditional_asset_amt, conditional_stable_amt) = pool.empty_all_amm_liquidity(ctx);

    // Burn conditional coins and withdraw spot tokens
    let asset_coin = escrow.burn_conditional_asset_and_withdraw<AssetType, StableType, AssetConditionalCoin>(
        winning_outcome,
        conditional_asset_amt,
        ctx,
    );

    let stable_coin = escrow.burn_conditional_stable_and_withdraw<AssetType, StableType, StableConditionalCoin>(
        winning_outcome,
        conditional_stable_amt,
        ctx,
    );

    (asset_coin, stable_coin)
}

// === Complete Set Minting/Redemption ===
// With TreasuryCap-based conditional coins, "complete set" operations work per-outcome

/// Mint a complete set of conditional coins for a specific outcome by depositing spot tokens
/// Deposits spot asset and mints conditional asset coin for the specified outcome
/// Returns the conditional asset coin
public fun mint_conditional_asset_for_outcome<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    spot_asset: Coin<AssetType>,
    ctx: &mut TxContext,
): Coin<ConditionalCoinType> {
    coin_escrow::deposit_asset_and_mint_conditional<AssetType, StableType, ConditionalCoinType>(
        escrow,
        outcome_index,
        spot_asset,
        ctx,
    )
}

/// Mint conditional stable coin for a specific outcome by depositing spot stable
public fun mint_conditional_stable_for_outcome<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    spot_stable: Coin<StableType>,
    ctx: &mut TxContext,
): Coin<ConditionalCoinType> {
    coin_escrow::deposit_stable_and_mint_conditional<AssetType, StableType, ConditionalCoinType>(
        escrow,
        outcome_index,
        spot_stable,
        ctx,
    )
}

/// Redeem conditional asset coin back to spot asset
/// Burns the conditional coin and returns spot asset
public fun redeem_conditional_asset<AssetType, StableType, ConditionalCoinType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    conditional_coin: Coin<ConditionalCoinType>,
    outcome_index: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    assert!(proposal.is_finalized(), EInvalidState);
    let winning_outcome = proposal.get_winning_outcome();
    assert!(outcome_index == winning_outcome, EWrongOutcome);

    let amount = conditional_coin.value();

    // Burn the conditional coin
    coin_escrow::burn_conditional_asset<AssetType, StableType, ConditionalCoinType>(
        escrow,
        outcome_index,
        conditional_coin,
    );

    // Withdraw spot asset (1:1)
    coin_escrow::withdraw_asset_balance(escrow, amount, ctx)
}

/// Redeem conditional stable coin back to spot stable
public fun redeem_conditional_stable<AssetType, StableType, ConditionalCoinType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    conditional_coin: Coin<ConditionalCoinType>,
    outcome_index: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableType> {
    assert!(proposal.is_finalized(), EInvalidState);
    let winning_outcome = proposal.get_winning_outcome();
    assert!(outcome_index == winning_outcome, EWrongOutcome);

    let amount = conditional_coin.value();

    // Burn the conditional coin
    coin_escrow::burn_conditional_stable<AssetType, StableType, ConditionalCoinType>(
        escrow,
        outcome_index,
        conditional_coin,
    );

    // Withdraw spot stable (1:1)
    coin_escrow::withdraw_stable_balance(escrow, amount, ctx)
}

// === AMM Liquidity Management ===

/// Add liquidity to an AMM pool for a specific outcome
/// Takes asset and stable conditional coins and mints LP tokens
/// Uses TreasuryCap-based conditional coins
public entry fun add_liquidity_entry<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin, LPConditionalCoin>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    asset_in: Coin<AssetConditionalCoin>,
    stable_in: Coin<StableConditionalCoin>,
    min_lp_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(!proposal.is_finalized(), EInvalidState);

    let asset_amount = asset_in.value();
    let stable_amount = stable_in.value();

    // Burn the conditional coins using TreasuryCaps
    coin_escrow::burn_conditional_asset<AssetType, StableType, AssetConditionalCoin>(
        escrow,
        outcome_idx,
        asset_in,
    );

    coin_escrow::burn_conditional_stable<AssetType, StableType, StableConditionalCoin>(
        escrow,
        outcome_idx,
        stable_in,
    );

    // Get the pool for this outcome from market_state
    let market_state = escrow.get_market_state_mut();
    let pool = futarchy_markets::market_state::get_pool_mut_by_outcome(market_state, (outcome_idx as u8));

    // Add liquidity through the AMM (updates virtual reserves)
    let lp_amount = conditional_amm::add_liquidity_proportional(
        pool,
        asset_amount,
        stable_amount,
        min_lp_out,
        clock,
        ctx
    );

    // Mint LP tokens using TreasuryCap
    let lp_token = coin_escrow::mint_conditional_asset<AssetType, StableType, LPConditionalCoin>(
        escrow,
        outcome_idx,
        lp_amount,
        ctx
    );

    // Transfer LP token to the sender
    transfer::public_transfer(lp_token, ctx.sender());
}

/// Remove liquidity from an AMM pool proportionally
/// Burns LP tokens and returns asset and stable conditional coins
public entry fun remove_liquidity_entry<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin, LPConditionalCoin>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    lp_token: Coin<LPConditionalCoin>,
    min_asset_out: u64,
    min_stable_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(!proposal.is_finalized(), EInvalidState);

    let lp_amount = lp_token.value();

    // Burn the LP token using TreasuryCap
    coin_escrow::burn_conditional_asset<AssetType, StableType, LPConditionalCoin>(
        escrow,
        outcome_idx,
        lp_token,
    );

    // Get the pool for this outcome from market_state
    let market_state = escrow.get_market_state_mut();
    let pool = futarchy_markets::market_state::get_pool_mut_by_outcome(market_state, (outcome_idx as u8));

    // Remove liquidity through the AMM (updates virtual reserves)
    let (asset_amount, stable_amount) = conditional_amm::remove_liquidity_proportional(
        pool,
        lp_amount,
        clock,
        ctx
    );

    // Verify slippage protection
    assert!(asset_amount >= min_asset_out, EMinAmountNotMet);
    assert!(stable_amount >= min_stable_out, EMinAmountNotMet);

    // Mint the asset and stable conditional tokens using TreasuryCaps
    let asset_token = coin_escrow::mint_conditional_asset<AssetType, StableType, AssetConditionalCoin>(
        escrow,
        outcome_idx,
        asset_amount,
        ctx
    );

    let stable_token = coin_escrow::mint_conditional_stable<AssetType, StableType, StableConditionalCoin>(
        escrow,
        outcome_idx,
        stable_amount,
        ctx
    );

    // Transfer tokens to the sender
    transfer::public_transfer(asset_token, ctx.sender());
    transfer::public_transfer(stable_token, ctx.sender());
}

// === Protocol Fee Collection ===

/// Collect protocol fees from the winning pool after finalization
/// Withdraws fees from escrow and deposits them to the fee manager
public fun collect_protocol_fees<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(proposal.is_finalized(), EInvalidState);
    assert!(proposal.is_winning_outcome_set(), EInvalidState);

    let winning_outcome = proposal.get_winning_outcome();
    // Get winning pool from market_state
    let market_state = escrow.get_market_state_mut();
    let winning_pool = futarchy_markets::market_state::get_pool_mut_by_outcome(market_state, (winning_outcome as u8));
    let protocol_fee_amount = winning_pool.get_protocol_fees();

    if (protocol_fee_amount > 0) {
        // Reset fees in the pool
        winning_pool.reset_protocol_fees();

        // Extract the fees from escrow (fees are in stable coins)
        let (spot_asset, spot_stable) = coin_escrow::get_spot_balances(escrow);
        assert!(spot_stable >= protocol_fee_amount, EInsufficientAmount);

        let fee_balance_coin = coin_escrow::withdraw_stable_balance(escrow, protocol_fee_amount, ctx);
        let fee_balance = coin::into_balance(fee_balance_coin);

        // Deposit to fee manager
        fee_manager.deposit_stable_fees<StableType>(
            fee_balance,
            proposal.get_id(),
            clock,
        );

        // Emit event
        event::emit(ProtocolFeesCollected {
            proposal_id: proposal.get_id(),
            winning_outcome,
            fee_amount: protocol_fee_amount,
            timestamp_ms: clock.timestamp_ms(),
        });
    }
}

// === Test Helpers ===

#[test_only]
public fun get_liquidity_for_proposal<AssetType, StableType>(
    escrow: &futarchy_markets::coin_escrow::TokenEscrow<AssetType, StableType>,
): vector<u64> {
    let market_state = escrow.get_market_state();
    let pools = futarchy_markets::market_state::borrow_amm_pools(market_state);
    let mut liquidity = vector[];
    let mut i = 0;
    while (i < pools.length()) {
        let pool = &pools[i];
        let (asset, stable) = pool.get_reserves();
        liquidity.push_back(asset);
        liquidity.push_back(stable);
        i = i + 1;
    };
    liquidity
}
