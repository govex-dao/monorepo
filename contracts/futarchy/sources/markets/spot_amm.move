module futarchy::spot_amm;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};
use futarchy::math;

// Basic errors
const EZeroAmount: u64 = 1;
const EInsufficientLiquidity: u64 = 2;
const ESlippageExceeded: u64 = 3;
const EInvalidFee: u64 = 4;
const EOverflow: u64 = 5;
const EImbalancedLiquidity: u64 = 6;

const MAX_FEE_BPS: u64 = 10000;
const MINIMUM_LIQUIDITY: u64 = 1000;

/// Simple spot AMM for <AssetType, StableType>
public struct SpotAMM<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    asset_reserve: Balance<AssetType>,
    stable_reserve: Balance<StableType>,
    lp_supply: u64,
    fee_bps: u64,
}

/// Spot LP token
public struct SpotLP<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    amount: u64,
}

/// Create a new pool
public fun new<AssetType, StableType>(fee_bps: u64, ctx: &mut TxContext): SpotAMM<AssetType, StableType> {
    assert!(fee_bps <= MAX_FEE_BPS, EInvalidFee);
    SpotAMM<AssetType, StableType> {
        id: object::new(ctx),
        asset_reserve: balance::zero<AssetType>(),
        stable_reserve: balance::zero<StableType>(),
        lp_supply: 0,
        fee_bps,
    }
}

/// Add liquidity (entry)
public entry fun add_liquidity<AssetType, StableType>(
    pool: &mut SpotAMM<AssetType, StableType>,
    asset_in: Coin<AssetType>,
    stable_in: Coin<StableType>,
    min_lp_out: u64,
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
        root - MINIMUM_LIQUIDITY  // Return minted amount minus locked liquidity
    } else {
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
        
        // Use minimum to be conservative
        math::min(from_a, from_s)
    };
    assert!(minted >= min_lp_out, ESlippageExceeded);

    pool.asset_reserve.join(asset_in.into_balance());
    pool.stable_reserve.join(stable_in.into_balance());
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
    ctx: &mut TxContext,
) {
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

/// ---- Conversion hook used by coin_escrow during LP conversion (no balance movement here) ----
/// Returns the ID of the minted spot LP token (the LP is transferred to the sender).
public fun mint_lp_for_conversion<AssetType, StableType, Dummy>(
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