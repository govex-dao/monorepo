module futarchy::dao_liquidity_pool;

use sui::{
    balance::{Self, Balance},
    coin::{Self, Coin}
};

/// A DAO-owned pool used to provide liquidity for proposals.
public struct DAOLiquidityPool<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    dao_id: ID,
    asset_balance: Balance<AssetType>,
    stable_balance: Balance<StableType>,
}

// === Public Functions ===

/// Creates a new DAO liquidity pool
public fun new<AssetType, StableType>(
    dao_id: ID,
    ctx: &mut TxContext
): DAOLiquidityPool<AssetType, StableType> {
    DAOLiquidityPool {
        id: object::new(ctx),
        dao_id,
        asset_balance: balance::zero(),
        stable_balance: balance::zero(),
    }
}

/// Deposits asset coins into the pool
public(package) fun deposit_asset<AssetType, StableType>(
    pool: &mut DAOLiquidityPool<AssetType, StableType>,
    asset_coin: Coin<AssetType>
) {
    pool.asset_balance.join(asset_coin.into_balance());
}

/// Deposits stable coins into the pool
public(package) fun deposit_stable<AssetType, StableType>(
    pool: &mut DAOLiquidityPool<AssetType, StableType>,
    stable_coin: Coin<StableType>
) {
    pool.stable_balance.join(stable_coin.into_balance());
}

/// Withdraws all asset balance from the pool
public(package) fun withdraw_all_asset_balance<AssetType, StableType>(
    pool: &mut DAOLiquidityPool<AssetType, StableType>
): Balance<AssetType> {
    let amount = pool.asset_balance.value();
    pool.asset_balance.split(amount)
}

/// Withdraws all stable balance from the pool
public(package) fun withdraw_all_stable_balance<AssetType, StableType>(
    pool: &mut DAOLiquidityPool<AssetType, StableType>
): Balance<StableType> {
    let amount = pool.stable_balance.value();
    pool.stable_balance.split(amount)
}

/// Get asset balance
public fun asset_balance<AssetType, StableType>(
    pool: &DAOLiquidityPool<AssetType, StableType>
): u64 {
    pool.asset_balance.value()
}

/// Get stable balance
public fun stable_balance<AssetType, StableType>(
    pool: &DAOLiquidityPool<AssetType, StableType>
): u64 {
    pool.stable_balance.value()
}

/// Get available liquidity (asset and stable balances)
public fun get_available_liquidity<AssetType, StableType>(
    pool: &DAOLiquidityPool<AssetType, StableType>
): (u64, u64) {
    (pool.asset_balance.value(), pool.stable_balance.value())
}

/// Get DAO ID
public fun dao_id<AssetType, StableType>(
    pool: &DAOLiquidityPool<AssetType, StableType>
): ID {
    pool.dao_id
}

/// Join asset balance to the pool
public(package) fun join_asset_balance<AssetType, StableType>(
    pool: &mut DAOLiquidityPool<AssetType, StableType>,
    balance: Balance<AssetType>
) {
    pool.asset_balance.join(balance);
}

/// Join stable balance to the pool
public(package) fun join_stable_balance<AssetType, StableType>(
    pool: &mut DAOLiquidityPool<AssetType, StableType>,
    balance: Balance<StableType>
) {
    pool.stable_balance.join(balance);
}

/// Withdraw specific amount of asset from the pool
public(package) fun withdraw_asset<AssetType, StableType>(
    pool: &mut DAOLiquidityPool<AssetType, StableType>,
    amount: u64,
    ctx: &mut TxContext
): Coin<AssetType> {
    coin::from_balance(pool.asset_balance.split(amount), ctx)
}

/// Withdraw specific amount of stable from the pool
public(package) fun withdraw_stable<AssetType, StableType>(
    pool: &mut DAOLiquidityPool<AssetType, StableType>,
    amount: u64,
    ctx: &mut TxContext
): Coin<StableType> {
    coin::from_balance(pool.stable_balance.split(amount), ctx)
}