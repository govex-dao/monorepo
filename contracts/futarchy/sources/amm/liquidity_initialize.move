module futarchy::liquidity_initialize;

use futarchy::amm::{Self, LiquidityPool};
use futarchy::coin_escrow::{Self, TokenEscrow};
use futarchy::conditional_token as token;
use sui::balance::Balance;
use sui::clock::Clock;

// === Introduction ===
// Method to initialize AMM liquidity

// === Public Functions ===
public fun create_outcome_markets<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_count: u64,
    asset_amounts: vector<u64>,
    stable_amounts: vector<u64>,
    twap_start_delay: u64,
    twap_initial_observation: u128,
    twap_step_max: u64,
    creation_time: u64,
    initial_asset: Balance<AssetType>,
    initial_stable: Balance<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (vector<ID>, vector<LiquidityPool>) {
    let mut supply_ids = vector[];
    let mut amm_pools = vector[];

    // 1. Create supplies and register them for each outcome
    outcome_count.do!(|i| {
        // Use same pattern as original to avoid borrow issues
        {
            let ms = coin_escrow::get_market_state(escrow); // Immutable borrow
            let asset_supply = token::new_supply(ms, 0, (i as u8), ctx);
            let stable_supply = token::new_supply(ms, 1, (i as u8), ctx);

            // Record their IDs
            let asset_supply_id = object::id(&asset_supply);
            let stable_supply_id = object::id(&stable_supply);
            supply_ids.push_back(asset_supply_id); // Method syntax
            supply_ids.push_back(stable_supply_id); // Method syntax

            // Register
            coin_escrow::register_supplies(escrow, i, asset_supply, stable_supply);
        };
    });

    // 2. Deposit liquidity and handle differential minting in one step
    coin_escrow::deposit_initial_liquidity(
        escrow,
        outcome_count,
        &asset_amounts,
        &stable_amounts,
        initial_asset,
        initial_stable,
        clock,
        ctx,
    );

    // 3. Create AMM pools for each outcome
    outcome_count.do!(|i| {
        let asset_amt = asset_amounts[i]; // Using index syntax instead of vector::borrow
        let stable_amt = stable_amounts[i];

        // Use same scoped borrow pattern as original
        {
            let ms = coin_escrow::get_market_state(escrow); // Immutable borrow
            let pool = amm::new_pool(
                ms,
                (i as u8),
                asset_amt,
                stable_amt,
                twap_initial_observation,
                twap_start_delay,
                twap_step_max,
                creation_time,
                ctx,
            );
            amm_pools.push_back(pool); // Method syntax
        };
    });

    (supply_ids, amm_pools)
}
