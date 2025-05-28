module futarchy::liquidity_initialize;

use futarchy::amm::{Self, LiquidityPool};
use futarchy::coin_escrow::{Self, TokenEscrow};
use futarchy::conditional_token as token;
use futarchy::market_state;
use sui::balance::Balance;
use sui::clock::Clock;

// === Introduction ===
// Method to initialize AMM liquidity

// === Errors ===
const E_INIT_ASSET_RESERVES_MISMATCH: u64 = 100;
const E_INIT_STABLE_RESERVES_MISMATCH: u64 = 101;
const E_INIT_POOL_COUNT_MISMATCH: u64 = 102;
const E_INIT_POOL_OUTCOME_MISMATCH: u64 = 103;

// === Public Functions ===
public(package) fun create_outcome_markets<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_count: u64,
    asset_amounts: vector<u64>,
    stable_amounts: vector<u64>,
    twap_start_delay: u64,
    twap_initial_observation: u128,
    twap_step_max: u64,
    initial_asset: Balance<AssetType>,
    initial_stable: Balance<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (vector<ID>, vector<LiquidityPool>) {
    let mut supply_ids = vector::empty<ID>();
    let mut amm_pools = vector::empty<LiquidityPool>();

    // 1. Create supplies and register them for each outcome
    let mut i = 0;
    while (i < outcome_count) {
        // Use same pattern as original to avoid borrow issues
        {
            let ms = coin_escrow::get_market_state(escrow); // Immutable borrow
            let asset_supply = token::new_supply(ms, 0, (i as u8), ctx);
            let stable_supply = token::new_supply(ms, 1, (i as u8), ctx);

            // Record their IDs
            let asset_supply_id = object::id(&asset_supply);
            let stable_supply_id = object::id(&stable_supply);
            vector::push_back(&mut supply_ids, asset_supply_id);
            vector::push_back(&mut supply_ids, stable_supply_id);

            // Register
            coin_escrow::register_supplies(escrow, i, asset_supply, stable_supply);
        };

        i = i + 1;
    };

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

    // 3. Create AMM pools for each outcome - same as original
    i = 0;
    while (i < outcome_count) {
        let asset_amt = *vector::borrow(&asset_amounts, i);
        let stable_amt = *vector::borrow(&stable_amounts, i);

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
                ctx,
            );
            vector::push_back(&mut amm_pools, pool);
        };

        i = i + 1;
    };

    assert_initial_reserves_consistency<AssetType, StableType>(escrow, &amm_pools);

    (supply_ids, amm_pools)
}

fun assert_initial_reserves_consistency<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    amm_pools: &vector<LiquidityPool>,
) {
    let outcome_count = market_state::outcome_count(coin_escrow::get_market_state(escrow));

    assert!(vector::length(amm_pools) == outcome_count, E_INIT_POOL_COUNT_MISMATCH);

    let (escrow_asset, escrow_stable) = coin_escrow::get_balances(escrow);

    let mut i = 0;
    while (i < outcome_count) {
        let pool = vector::borrow(amm_pools, i);

        assert!(amm::get_outcome_idx(pool) == (i as u8), E_INIT_POOL_OUTCOME_MISMATCH);

        let (amm_asset, amm_stable) = amm::get_reserves(pool);
        let protocol_fees = amm::get_protocol_fees(pool);
        assert!(protocol_fees == 0, E_INIT_STABLE_RESERVES_MISMATCH); // Fees must be 0 initially

        let (
            _fetched_escrow_asset,
            _fetched_escrow_stable,
            asset_total_supply,
            stable_total_supply,
        ) = coin_escrow::get_escrow_balances_and_supply(escrow, i);

        // --- Perform the Core Assertions ---

        // Verify asset equation: AMM asset reserves + asset token supply = total escrow asset
        assert!(amm_asset + asset_total_supply == escrow_asset, E_INIT_ASSET_RESERVES_MISMATCH);

        // Verify stable equation: AMM stable reserves + protocol fees (0) + stable token supply = total escrow stable
        assert!(
            amm_stable + protocol_fees + stable_total_supply == escrow_stable, // protocol_fees is 0 here
            E_INIT_STABLE_RESERVES_MISMATCH,
        );

        i = i + 1;
    };
}
