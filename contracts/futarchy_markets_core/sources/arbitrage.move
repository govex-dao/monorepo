/// Unified arbitrage module that works for ANY outcome count
///
/// This module eliminates type explosion by using balance-based operations.
/// ONE arbitrage function works for 2, 3, 4, 5, or 200 outcomes.
///
/// Key innovation: Loops over outcomes using balance indices instead of
/// requiring N type parameters.

module futarchy_markets_core::arbitrage;

use futarchy_markets_primitives::conditional_balance::{Self, ConditionalMarketBalance};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_primitives::market_state;
use futarchy_markets_core::swap_core::{Self, SwapSession};
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_core::swap_position_registry::{Self, SwapPositionRegistry};
use sui::coin::{Self, Coin};
use sui::clock::Clock;
use sui::object::{Self, ID};
use sui::event;
use std::option;

// === Errors ===
const EZeroAmount: u64 = 0;
const EInsufficientProfit: u64 = 1;
const EInvalidDirection: u64 = 2;

// === Events ===

/// Emitted when spot arbitrage completes
public struct SpotArbitrageExecuted has copy, drop {
    proposal_id: ID,
    outcome_count: u64,
    input_asset: u64,
    input_stable: u64,
    output_asset: u64,
    output_stable: u64,
    profit_asset: u64,
    profit_stable: u64,
}

/// Emitted when conditional arbitrage completes
public struct ConditionalArbitrageExecuted has copy, drop {
    proposal_id: ID,
    outcome_idx: u8,
    amount_in: u64,
    amount_out: u64,
}

// === Main Arbitrage Functions ===

/// Execute spot arbitrage - works for ANY outcome count!
///
/// Takes spot coins, performs quantum mint + swaps across all outcomes,
/// finds complete set minimum, stores dust, burns complete set, returns profit.
///
/// # Arbitrage Flow
/// 1. Deposit spot coins to escrow (quantum liquidity)
/// 2. Add amounts to balance for ALL outcomes simultaneously
/// 3. Swap asset→stable (or stable→asset) in EACH outcome market
/// 4. Find minimum balance across outcomes (complete set limit)
/// 5. Store excess as dust (in registry OR return as balance)
/// 6. Burn complete set and withdraw spot coins as profit
///
/// # Arguments
/// * `stable_for_arb` - Spot stable coins to use (can be zero)
/// * `asset_for_arb` - Spot asset coins to use (can be zero)
/// * `min_profit` - Minimum profit required (0 = no minimum)
/// * `return_dust_balance` - If true, return dust as ConditionalMarketBalance object
///
/// # Returns
/// * Tuple: (stable_profit, asset_profit, optional_dust_balance)
/// * If return_dust_balance==false: third element is None (dust goes to registry)
/// * If return_dust_balance==true: third element contains ConditionalMarketBalance with dust
///
/// # Example
/// ```move
/// // Works for 2, 3, 4, 5 outcomes with same function!
/// let (stable_profit, asset_profit, dust_opt) = execute_optimal_spot_arbitrage(
///     spot_pool, proposal, escrow, registry, &session,
///     stable_coin, asset_coin, 0, recipient, true, clock, ctx
/// );
/// if (option::is_some(&dust_opt)) {
///     let dust = option::extract(&mut dust_opt);
///     transfer::public_transfer(dust, recipient);
/// }
/// ```
public fun execute_optimal_spot_arbitrage<AssetType, StableType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    session: &SwapSession,
    stable_for_arb: Coin<StableType>,
    asset_for_arb: Coin<AssetType>,
    min_profit: u64,
    recipient: address,
    return_dust_balance: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<StableType>, Coin<AssetType>, option::Option<ConditionalMarketBalance<AssetType, StableType>>) {
    // Validate market is live
    let market_state = coin_escrow::get_market_state(escrow);
    market_state::assert_trading_active(market_state);

    let stable_amt = stable_for_arb.value();
    let asset_amt = asset_for_arb.value();

    // Determine arbitrage direction and execute
    if (stable_amt > 0 && asset_amt == 0) {
        // Stable→Asset→Conditionals→Stable arbitrage
        // Destroy zero asset coin
        coin::destroy_zero(asset_for_arb);
        execute_spot_arb_stable_to_asset_direction(
            spot_pool, escrow, session,
            stable_for_arb, min_profit, recipient, return_dust_balance, clock, ctx
        )
    } else if (asset_amt > 0 && stable_amt == 0) {
        // Asset→Stable→Conditionals→Asset arbitrage
        // Destroy zero stable coin
        coin::destroy_zero(stable_for_arb);
        execute_spot_arb_asset_to_stable_direction(
            spot_pool, escrow, session,
            asset_for_arb, min_profit, recipient, return_dust_balance, clock, ctx
        )
    } else {
        // No coins or both coins provided - just destroy them and return zeros
        // This shouldn't happen in normal usage, but we handle it for completeness
        if (stable_amt > 0) {
            // TODO: Could return the coins instead of destroying them
            transfer::public_transfer(stable_for_arb, recipient);
        } else {
            coin::destroy_zero(stable_for_arb);
        };
        if (asset_amt > 0) {
            transfer::public_transfer(asset_for_arb, recipient);
        } else {
            coin::destroy_zero(asset_for_arb);
        };
        (coin::zero<StableType>(ctx), coin::zero<AssetType>(ctx), option::none())
    }
}

// === Direction-Specific Arbitrage ===

/// Execute: Stable → Spot Asset → Conditional Assets → Conditional Stables → Spot Stable (profit)
fun execute_spot_arb_stable_to_asset_direction<AssetType, StableType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    session: &SwapSession,
    stable_for_arb: Coin<StableType>,
    min_profit: u64,
    recipient: address,
    return_dust_balance: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<StableType>, Coin<AssetType>, option::Option<ConditionalMarketBalance<AssetType, StableType>>) {
    let stable_amt = stable_for_arb.value();
    assert!(stable_amt > 0, EZeroAmount);

    // Get market info from escrow
    let market_state = coin_escrow::get_market_state(escrow);
    let outcome_count = futarchy_markets_core::market_state::outcome_count(market_state);
    let market_id = futarchy_markets_core::market_state::market_id(market_state);

    // 1. Swap spot stable → spot asset
    let asset_from_spot = unified_spot_pool::swap_stable_for_asset(
        spot_pool, stable_for_arb, 0, clock, ctx
    );
    let asset_amt = asset_from_spot.value();

    // 2. Create temporary balance object for arbitrage
    let mut arb_balance = conditional_balance::new<AssetType, StableType>(
        market_id,
        (outcome_count as u8),
        ctx,
    );

    // 3. Deposit asset to escrow for quantum mint
    let (deposited_asset, _) = coin_escrow::deposit_spot_coins(
        escrow, asset_from_spot, coin::zero<StableType>(ctx)
    );

    // 4. Add to balance (quantum: same amount in ALL outcomes)
    let mut i = 0u8;
    while ((i as u64) < outcome_count) {
        conditional_balance::add_to_balance(&mut arb_balance, i, true, deposited_asset);
        i = i + 1;
    };

    // 5. Swap asset → stable in EACH conditional market (LOOP!)
    i = 0u8;
    while ((i as u64) < outcome_count) {
        swap_core::swap_balance_asset_to_stable<AssetType, StableType>(
            session, escrow, &mut arb_balance,
            i, asset_amt, 0, clock, ctx
        );
        i = i + 1;
    };

    // 6. Find minimum stable amount (complete set limit)
    let min_stable = conditional_balance::find_min_balance(&arb_balance, false);

    // 7. Burn complete set → withdraw spot stable
    let profit_stable = burn_complete_set_and_withdraw_stable(
        &mut arb_balance, escrow, min_stable, ctx
    );

    // Validate profit meets minimum
    assert!(profit_stable.value() >= min_profit, EInsufficientProfit);

    // Calculate net profit (handle losses where output < input)
    let net_profit_stable = if (profit_stable.value() >= stable_amt) {
        profit_stable.value() - stable_amt
    } else {
        0  // Loss case - report as 0 profit
    };

    // Emit event
    event::emit(SpotArbitrageExecuted {
        proposal_id: market_id,
        outcome_count,
        input_asset: 0,
        input_stable: stable_amt,
        output_asset: 0,
        output_stable: profit_stable.value(),
        profit_asset: 0,
        profit_stable: net_profit_stable,
    });

    // 8. Handle dust: return balance object OR destroy it
    if (return_dust_balance) {
        // Return balance object with dust to recipient
        (profit_stable, coin::zero<AssetType>(ctx), option::some(arb_balance))
    } else {
        // Dust goes to registry (TODO: implement registry deposit)
        // For now, clear all balances before destroying
        let mut i = 0u8;
        while ((i as u64) < outcome_count) {
            conditional_balance::set_balance(&mut arb_balance, i, true, 0);
            conditional_balance::set_balance(&mut arb_balance, i, false, 0);
            i = i + 1;
        };
        conditional_balance::destroy_empty(arb_balance);
        (profit_stable, coin::zero<AssetType>(ctx), option::none())
    }
}

/// Execute: Asset → Spot Stable → Conditional Stables → Conditional Assets → Spot Asset (profit)
fun execute_spot_arb_asset_to_stable_direction<AssetType, StableType>(
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    session: &SwapSession,
    asset_for_arb: Coin<AssetType>,
    min_profit: u64,
    recipient: address,
    return_dust_balance: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<StableType>, Coin<AssetType>, option::Option<ConditionalMarketBalance<AssetType, StableType>>) {
    let asset_amt = asset_for_arb.value();
    assert!(asset_amt > 0, EZeroAmount);

    // Get market info from escrow
    let market_state = coin_escrow::get_market_state(escrow);
    let outcome_count = futarchy_markets_core::market_state::outcome_count(market_state);
    let market_id = futarchy_markets_core::market_state::market_id(market_state);

    // 1. Swap spot asset → spot stable
    let stable_from_spot = unified_spot_pool::swap_asset_for_stable(
        spot_pool, asset_for_arb, 0, clock, ctx
    );
    let stable_amt = stable_from_spot.value();

    // 2. Create temporary balance object
    let mut arb_balance = conditional_balance::new<AssetType, StableType>(
        market_id,
        (outcome_count as u8),
        ctx,
    );

    // 3. Deposit stable to escrow for quantum mint
    let (_, deposited_stable) = coin_escrow::deposit_spot_coins(
        escrow, coin::zero<AssetType>(ctx), stable_from_spot
    );

    // 4. Add to balance (quantum: same amount in ALL outcomes)
    let mut i = 0u8;
    while ((i as u64) < outcome_count) {
        conditional_balance::add_to_balance(&mut arb_balance, i, false, deposited_stable);
        i = i + 1;
    };

    // 5. Swap stable → asset in EACH conditional market (LOOP!)
    i = 0u8;
    while ((i as u64) < outcome_count) {
        swap_core::swap_balance_stable_to_asset<AssetType, StableType>(
            session, escrow, &mut arb_balance,
            i, stable_amt, 0, clock, ctx
        );
        i = i + 1;
    };

    // 6. Find minimum asset amount (complete set limit)
    let min_asset = conditional_balance::find_min_balance(&arb_balance, true);

    // 7. Burn complete set → withdraw spot asset
    let profit_asset = burn_complete_set_and_withdraw_asset(
        &mut arb_balance, escrow, min_asset, ctx
    );

    // Validate profit meets minimum
    assert!(profit_asset.value() >= min_profit, EInsufficientProfit);

    // Calculate net profit (handle losses where output < input)
    let net_profit_asset = if (profit_asset.value() >= asset_amt) {
        profit_asset.value() - asset_amt
    } else {
        0  // Loss case - report as 0 profit
    };

    // Emit event
    event::emit(SpotArbitrageExecuted {
        proposal_id: market_id,
        outcome_count,
        input_asset: asset_amt,
        input_stable: 0,
        output_asset: profit_asset.value(),
        output_stable: 0,
        profit_asset: net_profit_asset,
        profit_stable: 0,
    });

    // 8. Handle dust: return balance object OR destroy it
    if (return_dust_balance) {
        // Return balance object with dust to recipient
        (coin::zero<StableType>(ctx), profit_asset, option::some(arb_balance))
    } else {
        // Dust goes to registry (TODO: implement registry deposit)
        // For now, clear all balances before destroying
        let mut i = 0u8;
        while ((i as u64) < outcome_count) {
            conditional_balance::set_balance(&mut arb_balance, i, true, 0);
            conditional_balance::set_balance(&mut arb_balance, i, false, 0);
            i = i + 1;
        };
        conditional_balance::destroy_empty(arb_balance);
        (coin::zero<StableType>(ctx), profit_asset, option::none())
    }
}

// === Helper Functions ===

/// Burn complete set of conditional stables and withdraw spot stable
///
/// Subtracts amount from ALL outcome stable balances, then withdraws from escrow.
/// This maintains the quantum liquidity invariant.
///
/// PUBLIC for use in swap_entry::finalize_conditional_swaps
public fun burn_complete_set_and_withdraw_stable<AssetType, StableType>(
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<StableType> {
    let outcome_count = conditional_balance::outcome_count(balance);

    // Subtract from all outcome stable balances
    let mut i = 0u8;
    while ((i as u64) < (outcome_count as u64)) {
        conditional_balance::sub_from_balance(balance, i, false, amount);
        i = i + 1;
    };

    // Withdraw from escrow
    let (asset, stable) = coin_escrow::withdraw_from_escrow(escrow, 0, amount, ctx);
    coin::destroy_zero(asset);  // Destroy zero asset coin
    stable
}

/// Burn complete set of conditional assets and withdraw spot asset
///
/// Subtracts amount from ALL outcome asset balances, then withdraws from escrow.
///
/// PUBLIC for use in swap_entry::finalize_conditional_swaps
public fun burn_complete_set_and_withdraw_asset<AssetType, StableType>(
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<AssetType> {
    let outcome_count = conditional_balance::outcome_count(balance);

    // Subtract from all outcome asset balances
    let mut i = 0u8;
    while ((i as u64) < (outcome_count as u64)) {
        conditional_balance::sub_from_balance(balance, i, true, amount);
        i = i + 1;
    };

    // Withdraw from escrow
    let (asset, stable) = coin_escrow::withdraw_from_escrow(escrow, amount, 0, ctx);
    coin::destroy_zero(stable);  // Destroy zero stable coin
    asset
}

/// Store excess balance as dust in registry
///
/// TODO: Implement when registry integration is needed
/// For now, this is a placeholder for future dust collection
#[allow(unused_variable)]
fun store_dust_in_registry<AssetType, StableType>(
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    registry: &mut SwapPositionRegistry<AssetType, StableType>,
    outcome_idx: u8,
    is_asset: bool,
    amount: u64,
    recipient: address,
) {
    // Subtract from balance
    conditional_balance::sub_from_balance(balance, outcome_idx, is_asset, amount);
    
    // TODO: Store in registry
    // This requires minting conditional coins and depositing to registry
    // Will be implemented when dust collection is prioritized
}
