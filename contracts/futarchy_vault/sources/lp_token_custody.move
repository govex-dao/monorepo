/// LP Token Custody Module
/// Manages LP tokens owned by DAOs from liquidity operations
/// 
/// This module provides secure custody of LP tokens using Account's managed assets feature.
/// Benefits of using managed assets over direct transfers:
/// 1. Enforces custody under Account's policy engine
/// 2. Prevents accidental outflows or unauthorized transfers
/// 3. Makes the relationship between Account and LP tokens explicit and enforceable
/// 4. Integrates with Account's permission system for access control
/// 5. Provides better tracking and audit capabilities
module futarchy_vault::lp_token_custody;

use std::{string::String, option};
use sui::{
    object::{Self, ID},
    table::{Self, Table},
    event,
    transfer,
};
use account_protocol::{
    account::{Self, Account, Auth},
};
use futarchy_core::version;
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_markets_core::unified_spot_pool::{Self, LPToken, UnifiedSpotPool};

// === Errors ===
const ELPTokenNotFound: u64 = 1;
const EInsufficientBalance: u64 = 2;
const EUnauthorized: u64 = 3;

// === Structs ===

/// Dynamic field key for LP token custody
public struct LPCustodyKey has copy, drop, store {}

/// Managed-asset key for storing LP tokens by ID (safer schema)
public struct LPKey has copy, drop, store {
    token_id: ID,
}

/// Enhanced LP token registry with better tracking capabilities
public struct LPTokenCustody has store {
    // Pool ID -> vector of LP token IDs
    tokens_by_pool: Table<ID, vector<ID>>,
    // Token ID -> amount for quick lookup
    token_amounts: Table<ID, u64>,
    // Token ID -> pool ID mapping for reverse lookup
    token_to_pool: Table<ID, ID>,
    // Pool ID -> total LP amount for that pool
    pool_totals: Table<ID, u64>,
    // Total value locked (sum of all LP tokens)
    total_value_locked: u64,
    // Registry of all pool IDs we have tokens for
    active_pools: vector<ID>,
}

// === Events ===

public struct LPTokenDeposited has copy, drop {
    account_id: ID,
    pool_id: ID,
    token_id: ID,
    amount: u64,
    new_pool_total: u64,
    new_total_value_locked: u64,
}

public struct LPTokenWithdrawn has copy, drop {
    account_id: ID,
    pool_id: ID,
    token_id: ID,
    amount: u64,
    recipient: address,
    new_pool_total: u64,
    new_total_value_locked: u64,
}

// === Public Functions ===

/// Initialize LP token custody for an account
public fun init_custody(
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext,
) {
    if (!has_custody(account)) {
        account::add_managed_data(
            account,
            LPCustodyKey {},
            LPTokenCustody {
                tokens_by_pool: table::new(ctx),
                token_amounts: table::new(ctx),
                token_to_pool: table::new(ctx),
                pool_totals: table::new(ctx),
                total_value_locked: 0,
                active_pools: vector::empty(),
            },
            version::current()
        );
    }
}

/// Check if account has LP custody initialized
public fun has_custody(account: &Account<FutarchyConfig>): bool {
    account::has_managed_data(account, LPCustodyKey {})
}

/// Deposit an LP token into custody
public fun deposit_lp_token<AssetType, StableType>(
    auth: Auth,
    account: &mut Account<FutarchyConfig>,
    pool_id: ID,
    token: LPToken<AssetType, StableType>,
    ctx: &mut TxContext,
) {
    account::verify(account, auth);
    
    // Get account ID before mutable borrowing
    let account_id = object::id(account);
    let account_address = object::id_address(account);
    
    // Initialize custody if needed
    if (!has_custody(account)) {
        init_custody(account, ctx);
    };
    
    let custody: &mut LPTokenCustody = account::borrow_managed_data_mut(
        account,
        LPCustodyKey {},
        version::current()
    );
    
    let token_id = object::id(&token);
    let amount = unified_spot_pool::lp_token_amount(&token);
    
    // Update tokens by pool
    if (!custody.tokens_by_pool.contains(pool_id)) {
        custody.tokens_by_pool.add(pool_id, vector::empty());
        custody.pool_totals.add(pool_id, 0);
        // Add to active pools if not already present
        let (found, _) = custody.active_pools.index_of(&pool_id);
        if (!found) {
            custody.active_pools.push_back(pool_id);
        };
    };
    let pool_tokens = custody.tokens_by_pool.borrow_mut(pool_id);
    pool_tokens.push_back(token_id);
    
    // Update token tracking tables
    custody.token_amounts.add(token_id, amount);
    custody.token_to_pool.add(token_id, pool_id);
    
    // Update pool total
    let pool_total = custody.pool_totals.borrow_mut(pool_id);
    *pool_total = *pool_total + amount;
    
    // Update global total
    custody.total_value_locked = custody.total_value_locked + amount;
    
    // Get values for event before transfer
    let new_pool_total = *custody.pool_totals.borrow(pool_id);
    let new_total_value_locked = custody.total_value_locked;
    
    // Store LP token as a managed asset in the Account
    // This ensures proper custody under Account's policy engine and prevents accidental outflows
    // The LPKey with token_id is used as the key for retrieval
    account::add_managed_asset(
        account,
        LPKey { token_id },
        token,
        version::current()
    );
    
    event::emit(LPTokenDeposited {
        account_id,
        pool_id,
        token_id,
        amount,
        new_pool_total,
        new_total_value_locked,
    });
}

/// Withdraw LP tokens from custody
/// The token_id identifies which LP token to withdraw from managed assets
/// The LP token is transferred to the account as a child object for safety
/// Users can then transfer it from the account in a separate transaction
public fun withdraw_lp_token<AssetType, StableType>(
    auth: Auth,
    account: &mut Account<FutarchyConfig>,
    pool_id: ID,
    token_id: ID,  // Changed from passing the token to just the ID
    _ctx: &mut TxContext,
) {
    account::verify(account, auth);
    
    // Get account ID before mutable borrowing
    let account_id = object::id(account);
    
    // Retrieve the LP token from managed assets
    let token: LPToken<AssetType, StableType> = account::remove_managed_asset(
        account,
        LPKey { token_id },
        version::current()
    );

    let amount = unified_spot_pool::lp_token_amount(&token);
    
    let custody: &mut LPTokenCustody = account::borrow_managed_data_mut(
        account,
        LPCustodyKey {},
        version::current()
    );
    
    // Verify token is in custody
    assert!(custody.token_amounts.contains(token_id), ELPTokenNotFound);
    assert!(custody.token_amounts[token_id] == amount, EInsufficientBalance);
    
    // Remove from tracking tables
    custody.token_amounts.remove(token_id);
    custody.token_to_pool.remove(token_id);
    
    // Update pool total
    let pool_total = custody.pool_totals.borrow_mut(pool_id);
    *pool_total = *pool_total - amount;
    
    // Update global total
    custody.total_value_locked = custody.total_value_locked - amount;
    
    // Remove from pool tokens list
    if (custody.tokens_by_pool.contains(pool_id)) {
        let pool_tokens = custody.tokens_by_pool.borrow_mut(pool_id);
        let (found, index) = pool_tokens.index_of(&token_id);
        if (found) {
            pool_tokens.remove(index);
            
            // If no more tokens for this pool, remove from active pools
            if (pool_tokens.is_empty()) {
                let (pool_found, pool_index) = custody.active_pools.index_of(&pool_id);
                if (pool_found) {
                    custody.active_pools.remove(pool_index);
                };
            };
        };
    };
    
    // Get values for event before transfer
    let new_pool_total = *custody.pool_totals.borrow(pool_id);
    let new_total_value_locked = custody.total_value_locked;
    
    // Transfer token to the account itself for safety
    // Users can transfer it from the account in a separate transaction
    let account_address = object::id_address(account);
    transfer::public_transfer(token, account_address);
    
    event::emit(LPTokenWithdrawn {
        account_id,
        pool_id,
        token_id,
        amount,
        recipient: account_address,
        new_pool_total,
        new_total_value_locked,
    });
}

/// Get total value locked in LP tokens
public fun get_total_value_locked(account: &Account<FutarchyConfig>): u64 {
    if (!has_custody(account)) {
        return 0
    };
    
    let custody: &LPTokenCustody = account::borrow_managed_data(
        account,
        LPCustodyKey {},
        version::current()
    );
    
    custody.total_value_locked
}

/// Get LP token IDs for a specific pool
public fun get_pool_tokens(
    account: &Account<FutarchyConfig>,
    pool_id: ID,
): vector<ID> {
    if (!has_custody(account)) {
        return vector::empty()
    };
    
    let custody: &LPTokenCustody = account::borrow_managed_data(
        account,
        LPCustodyKey {},
        version::current()
    );
    
    if (custody.tokens_by_pool.contains(pool_id)) {
        *custody.tokens_by_pool.borrow(pool_id)
    } else {
        vector::empty()
    }
}

/// Get amount for a specific LP token
public fun get_token_amount(
    account: &Account<FutarchyConfig>,
    token_id: ID,
): u64 {
    if (!has_custody(account)) {
        return 0
    };
    
    let custody: &LPTokenCustody = account::borrow_managed_data(
        account,
        LPCustodyKey {},
        version::current()
    );
    
    if (custody.token_amounts.contains(token_id)) {
        custody.token_amounts[token_id]
    } else {
        0
    }
}

/// Get the pool ID that contains a specific LP token
public fun get_token_pool(
    account: &Account<FutarchyConfig>,
    token_id: ID,
): Option<ID> {
    if (!has_custody(account)) {
        return option::none()
    };
    
    let custody: &LPTokenCustody = account::borrow_managed_data(
        account,
        LPCustodyKey {},
        version::current()
    );
    
    if (custody.token_to_pool.contains(token_id)) {
        option::some(custody.token_to_pool[token_id])
    } else {
        option::none()
    }
}

/// Get total LP token amount for a specific pool
public fun get_pool_total(
    account: &Account<FutarchyConfig>,
    pool_id: ID,
): u64 {
    if (!has_custody(account)) {
        return 0
    };
    
    let custody: &LPTokenCustody = account::borrow_managed_data(
        account,
        LPCustodyKey {},
        version::current()
    );
    
    if (custody.pool_totals.contains(pool_id)) {
        custody.pool_totals[pool_id]
    } else {
        0
    }
}

/// Get all active pool IDs (pools that have LP tokens)
public fun get_active_pools(
    account: &Account<FutarchyConfig>,
): vector<ID> {
    if (!has_custody(account)) {
        return vector::empty()
    };
    
    let custody: &LPTokenCustody = account::borrow_managed_data(
        account,
        LPCustodyKey {},
        version::current()
    );
    
    custody.active_pools
}

/// Check if account has any LP tokens for a specific pool
public fun has_tokens_for_pool(
    account: &Account<FutarchyConfig>,
    pool_id: ID,
): bool {
    if (!has_custody(account)) {
        return false
    };
    
    let custody: &LPTokenCustody = account::borrow_managed_data(
        account,
        LPCustodyKey {},
        version::current()
    );
    
    custody.tokens_by_pool.contains(pool_id) && !custody.tokens_by_pool[pool_id].is_empty()
}

/// Get summary statistics for all LP token holdings
public fun get_custody_summary(
    account: &Account<FutarchyConfig>,
): (u64, u64, vector<ID>) {
    if (!has_custody(account)) {
        return (0, 0, vector::empty())
    };
    
    let custody: &LPTokenCustody = account::borrow_managed_data(
        account,
        LPCustodyKey {},
        version::current()
    );
    
    (
        custody.total_value_locked,
        custody.active_pools.length(),
        custody.active_pools
    )
}