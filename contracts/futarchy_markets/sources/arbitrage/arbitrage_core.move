/// ARBITRAGE CORE - Complex logic extracted from arbitrage_executor.move
///
/// All the hard stuff lives here. Per-N wrappers just call these with explicit types.
///
/// AUDITOR: This is where the real arbitrage algorithms are.

module futarchy_markets::arbitrage_core;

use futarchy_markets::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets::coin_escrow::{Self, TokenEscrow};
use futarchy_markets::proposal::Proposal;
use futarchy_markets::arbitrage_math;
use futarchy_markets::market_state;
use futarchy_markets::swap_position_registry::SwapPositionRegistry;
use sui::coin::{Self, Coin};
use sui::balance::{Self, Balance};
use sui::clock::Clock;

// === Errors ===
const EInsufficientProfit: u64 = 1;

// === Core Algorithms (Copied from arbitrage_executor.move) ===

/// Validate arbitrage is profitable before execution
/// (Copied from arbitrage_executor.move lines 84-98)
public fun validate_profitable<AssetType, StableType>(
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
    arb_amount: u64,
    min_profit_out: u64,
    is_spot_swap_stable_to_asset: bool,
): u128 {
    let market_state = coin_escrow::get_market_state(escrow);
    let conditional_pools = market_state::borrow_amm_pools(market_state);

    let expected_profit = arbitrage_math::calculate_spot_arbitrage_profit(
        spot_pool,
        conditional_pools,
        arb_amount,
        is_spot_swap_stable_to_asset,
    );

    assert!(expected_profit >= (min_profit_out as u128), EInsufficientProfit);
    expected_profit
}

/// Swap stable → asset in spot pool
/// (Copied from arbitrage_executor.move lines 108-114)
public fun spot_swap_stable_to_asset<AssetType, StableType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    stable_for_arb: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    unified_spot_pool::swap_stable_for_asset(
        spot_pool,
        stable_for_arb,
        0,  // No intermediate minimum (atomic execution)
        clock,
        ctx,
    )
}

/// Swap asset → stable in spot pool
/// (Copied from arbitrage_executor.move lines 386-392)
public fun spot_swap_asset_to_stable<AssetType, StableType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    asset_for_arb: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableType> {
    unified_spot_pool::swap_asset_for_stable(
        spot_pool,
        asset_for_arb,
        0,
        clock,
        ctx,
    )
}

/// Deposit asset ONCE for quantum minting N conditional assets
/// (Copied from arbitrage_executor.move lines 121-122)
public fun deposit_asset_for_quantum_mint<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset: Coin<AssetType>,
) {
    let asset_balance = coin::into_balance(asset);
    coin_escrow::deposit_spot_liquidity(escrow, asset_balance, balance::zero<StableType>());
}

/// Deposit stable ONCE for quantum minting N conditional stables
/// (Copied from arbitrage_executor.move lines 398-399)
public fun deposit_stable_for_quantum_mint<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    stable: Coin<StableType>,
) {
    let stable_balance = coin::into_balance(stable);
    coin_escrow::deposit_spot_liquidity(escrow, balance::zero<AssetType>(), stable_balance);
}

/// Find minimum value across coins
/// (Copied from arbitrage_executor.move lines 178-187)
public fun find_min_value<T>(coins: &vector<Coin<T>>): u64 {
    let mut min_amount = std::u64::max_value!();
    let mut i = 0;
    while (i < vector::length(coins)) {
        let amount = vector::borrow(coins, i).value();
        if (amount < min_amount) {
            min_amount = amount;
        };
        i = i + 1;
    };
    min_amount
}

/// Withdraw spot stable after burning complete sets
public fun withdraw_stable<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<StableType> {
    coin_escrow::withdraw_stable_balance(escrow, amount, ctx)
}

/// Withdraw spot asset after burning complete sets
public fun withdraw_asset<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<AssetType> {
    coin_escrow::withdraw_asset_balance(escrow, amount, ctx)
}

/// Burn conditional asset and withdraw spot asset
/// Used in conditional arbitrage to convert conditional → spot
public fun burn_and_withdraw_conditional_asset<AssetType, StableType, CondAsset>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    conditional: Coin<CondAsset>,
    ctx: &mut TxContext,
): Coin<AssetType> {
    let amount = conditional.value();
    coin_escrow::burn_conditional_asset<AssetType, StableType, CondAsset>(
        escrow, outcome_idx, conditional
    );
    coin_escrow::withdraw_asset_balance(escrow, amount, ctx)
}

/// Burn conditional stable and withdraw spot stable
/// Used in conditional arbitrage to convert conditional → spot
public fun burn_and_withdraw_conditional_stable<AssetType, StableType, CondStable>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    conditional: Coin<CondStable>,
    ctx: &mut TxContext,
): Coin<StableType> {
    let amount = conditional.value();
    coin_escrow::burn_conditional_stable<AssetType, StableType, CondStable>(
        escrow, outcome_idx, conditional
    );
    coin_escrow::withdraw_stable_balance(escrow, amount, ctx)
}
