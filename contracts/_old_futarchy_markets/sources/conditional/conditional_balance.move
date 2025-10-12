/// Balance-based conditional market position tracking
///
/// This module provides a type-agnostic way to track conditional market positions
/// without requiring N type parameters. Instead of tracking Coin<Cond0Asset>, Coin<Cond1Asset>, etc.,
/// we track balances as u64 values in a dense vector.
///
/// **Key Innovation:** Eliminates type explosion by decoupling balance tracking from types.
/// Users only need typed coins when unwrapping to use in external DeFi.
///
/// **Storage Layout:**
/// balances = [out0_asset, out0_stable, out1_asset, out1_stable, ...]
/// Index formula: idx = (outcome_idx * 2) + (is_asset ? 0 : 1)

module futarchy_markets::conditional_balance;

use sui::object::{Self, UID, ID};
use sui::coin::Coin;
use sui::event;
use std::vector;
use futarchy_markets::coin_escrow;

// === Errors ===
const EInvalidOutcomeIndex: u64 = 0;
const EInvalidBalanceAccess: u64 = 1;
const ENotEmpty: u64 = 2;
const EInsufficientBalance: u64 = 3;
const EInvalidOutcomeCount: u64 = 4;
const EOutcomeCountExceedsMax: u64 = 5;
const EProposalMismatch: u64 = 6;
const EOutcomeNotRegistered: u64 = 7;

// === Constants ===
const VERSION: u8 = 1;
const MIN_OUTCOMES: u8 = 2;
const MAX_OUTCOMES: u8 = 200;

// === Events ===

/// Emitted when balance is unwrapped to a typed coin
public struct BalanceUnwrapped has copy, drop {
    balance_id: ID,
    outcome_idx: u8,
    is_asset: bool,
    amount: u64,
}

/// Emitted when a typed coin is wrapped back to balance
public struct BalanceWrapped has copy, drop {
    balance_id: ID,
    outcome_idx: u8,
    is_asset: bool,
    amount: u64,
}

// === Structs ===

/// Balance object tracking all conditional market positions
///
/// This object stores balances for ALL outcomes in a single dense vector.
/// No type parameters for conditional coins - only phantom types for base coins.
///
/// Example for 3 outcomes:
/// balances[0] = Outcome 0 asset balance
/// balances[1] = Outcome 0 stable balance
/// balances[2] = Outcome 1 asset balance
/// balances[3] = Outcome 1 stable balance
/// balances[4] = Outcome 2 asset balance
/// balances[5] = Outcome 2 stable balance
public struct ConditionalMarketBalance<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    market_id: ID,  // ID of the market this balance belongs to
    outcome_count: u8,
    version: u8,  // For future migrations

    /// Dense vector: [out0_asset, out0_stable, out1_asset, out1_stable, ...]
    /// Index formula: idx = (outcome_idx * 2) + (is_asset ? 0 : 1)
    balances: vector<u64>,
}

// === Creation ===

/// Create new balance object for a proposal
///
/// Initializes with zero balances for all outcomes.
/// Used when starting arbitrage or when user wants to track positions.
///
/// # Arguments
/// * `outcome_count` - Number of outcomes (must be between 2 and 200)
///
/// # Panics
/// * If outcome_count < 2 or > 200
public fun new<AssetType, StableType>(
    market_id: ID,
    outcome_count: u8,
    ctx: &mut TxContext,
): ConditionalMarketBalance<AssetType, StableType> {
    // Validate outcome count
    assert!(outcome_count >= MIN_OUTCOMES, EInvalidOutcomeCount);
    assert!(outcome_count <= MAX_OUTCOMES, EOutcomeCountExceedsMax);

    // Initialize with zeros for all outcomes
    // Each outcome has 2 slots: asset (even idx) and stable (odd idx)
    let size = (outcome_count as u64) * 2;
    let balances = vector::tabulate!(size, |_| 0u64);

    ConditionalMarketBalance {
        id: object::new(ctx),
        market_id,
        outcome_count,
        version: VERSION,
        balances,
    }
}

// === Balance Access ===

/// Get balance for specific outcome + type
///
/// # Arguments
/// * `outcome_idx` - Which outcome (0, 1, 2, ...)
/// * `is_asset` - true for asset balance, false for stable balance
public fun get_balance<AssetType, StableType>(
    balance: &ConditionalMarketBalance<AssetType, StableType>,
    outcome_idx: u8,
    is_asset: bool,
): u64 {
    assert!((outcome_idx as u64) < (balance.outcome_count as u64), EInvalidOutcomeIndex);
    let idx = calculate_index(outcome_idx, is_asset);
    *vector::borrow(&balance.balances, idx)
}

/// Set balance for specific outcome + type
///
/// Directly replaces the balance value.
public fun set_balance<AssetType, StableType>(
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    outcome_idx: u8,
    is_asset: bool,
    amount: u64,
) {
    assert!((outcome_idx as u64) < (balance.outcome_count as u64), EInvalidOutcomeIndex);
    let idx = calculate_index(outcome_idx, is_asset);
    *vector::borrow_mut(&mut balance.balances, idx) = amount;
}

/// Add to balance (quantum mint pattern)
///
/// Used when depositing coins for quantum liquidity.
/// The same amount gets added to ALL outcomes simultaneously.
public fun add_to_balance<AssetType, StableType>(
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    outcome_idx: u8,
    is_asset: bool,
    amount: u64,
) {
    assert!((outcome_idx as u64) < (balance.outcome_count as u64), EInvalidOutcomeIndex);
    let idx = calculate_index(outcome_idx, is_asset);
    let current = vector::borrow_mut(&mut balance.balances, idx);
    *current = *current + amount;
}

/// Subtract from balance
///
/// Used when swapping or burning conditional coins.
/// Aborts if insufficient balance.
public fun sub_from_balance<AssetType, StableType>(
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    outcome_idx: u8,
    is_asset: bool,
    amount: u64,
) {
    assert!((outcome_idx as u64) < (balance.outcome_count as u64), EInvalidOutcomeIndex);
    let idx = calculate_index(outcome_idx, is_asset);
    let current = vector::borrow_mut(&mut balance.balances, idx);
    assert!(*current >= amount, EInsufficientBalance);
    *current = *current - amount;
}

// === Utility Functions ===

/// Find minimum balance across all outcomes for given type
///
/// Used to determine complete set size (can only burn/redeem complete sets).
/// In arbitrage, this represents the maximum amount we can withdraw as profit.
///
/// Returns 0 if all balances are 0 (correct behavior for empty balance).
public fun find_min_balance<AssetType, StableType>(
    balance: &ConditionalMarketBalance<AssetType, StableType>,
    is_asset: bool,
): u64 {
    // Start with first outcome's balance instead of u64::max to handle empty case
    let mut min = get_balance(balance, 0, is_asset);
    let mut i = 1u8;

    while ((i as u64) < (balance.outcome_count as u64)) {
        let bal = get_balance(balance, i, is_asset);
        if (bal < min) {
            min = bal;
        };
        i = i + 1;
    };

    min
}

/// Check if all balances are zero
///
/// Used before destroying the balance object.
public fun is_empty<AssetType, StableType>(
    balance: &ConditionalMarketBalance<AssetType, StableType>
): bool {
    is_empty_vector(&balance.balances)
}

/// Destroy balance object (must be empty)
///
/// Aborts if any balance is non-zero.
/// This ensures we don't accidentally lose funds.
public fun destroy_empty<AssetType, StableType>(
    balance: ConditionalMarketBalance<AssetType, StableType>
) {
    let ConditionalMarketBalance { id, market_id: _, outcome_count: _, version: _, balances } = balance;
    assert!(is_empty_vector(&balances), ENotEmpty);
    object::delete(id);
}

// === Getters ===

/// Get the market ID this balance tracks
public fun market_id<AssetType, StableType>(
    balance: &ConditionalMarketBalance<AssetType, StableType>
): ID {
    balance.market_id
}

/// Get the number of outcomes
public fun outcome_count<AssetType, StableType>(
    balance: &ConditionalMarketBalance<AssetType, StableType>
): u8 {
    balance.outcome_count
}

/// Get immutable reference to balance vector (for advanced operations)
public fun borrow_balances<AssetType, StableType>(
    balance: &ConditionalMarketBalance<AssetType, StableType>
): &vector<u64> {
    &balance.balances
}

/// Get object ID
public fun id<AssetType, StableType>(
    balance: &ConditionalMarketBalance<AssetType, StableType>
): ID {
    object::uid_to_inner(&balance.id)
}

// === Internal Helpers ===

/// Calculate vector index from outcome + type
///
/// Formula: idx = (outcome_idx * 2) + (is_asset ? 0 : 1)
/// - Even indices (0, 2, 4, ...) = asset balances
/// - Odd indices (1, 3, 5, ...) = stable balances
fun calculate_index(outcome_idx: u8, is_asset: bool): u64 {
    (outcome_idx as u64) * 2 + (if (is_asset) { 0 } else { 1 })
}

/// Check if vector is all zeros
fun is_empty_vector(vec: &vector<u64>): bool {
    let mut i = 0;
    while (i < vector::length(vec)) {
        if (*vector::borrow(vec, i) != 0) {
            return false
        };
        i = i + 1;
    };
    true
}

// === Unwrap/Wrap Functions ===

/// Unwrap balance to get actual Coin<ConditionalType>
///
/// PUBLIC: Users need this to convert balances to typed coins for external DeFi protocols.
///
/// This converts a balance amount into a real typed Coin that can be used
/// in external DeFi protocols or traded on DEXes.
///
/// # Security
/// * Validates escrow matches balance's proposal_id (prevents cross-market minting)
/// * Validates outcome is registered in escrow
/// * Emits event for off-chain tracking
///
/// # Arguments
/// * `balance` - The balance object to unwrap from
/// * `escrow` - Token escrow to mint the conditional coin (MUST match balance's proposal)
/// * `outcome_idx` - Which outcome to unwrap
/// * `is_asset` - true for asset, false for stable
///
/// # Returns
/// * Typed Coin<ConditionalCoinType> that can be used externally
///
/// # Aborts
/// * `EProposalMismatch` - If escrow doesn't match balance's proposal_id
/// * `EOutcomeNotRegistered` - If outcome_idx not registered in escrow
/// * `EInvalidBalanceAccess` - If balance is zero or outcome_idx invalid
///
/// # Example
/// ```move
/// // User has outcome 0 asset balance of 1000
/// let coin = conditional_balance::unwrap_to_coin<SUI, USDC, Cond0Asset>(
///     &mut balance,
///     &mut escrow,
///     0,      // outcome_idx
///     true,   // is_asset
///     ctx
/// );
/// // Now user has a Coin<Cond0Asset> worth 1000
/// ```
public fun unwrap_to_coin<AssetType, StableType, ConditionalCoinType>(
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    escrow: &mut coin_escrow::TokenEscrow<AssetType, StableType>,
    outcome_idx: u8,
    is_asset: bool,
    ctx: &mut TxContext,
): Coin<ConditionalCoinType> {
    // CRITICAL: Validate escrow matches balance's market
    let escrow_market_id = coin_escrow::market_state_id(escrow);
    assert!(balance.market_id == escrow_market_id, EProposalMismatch);

    // Validate outcome is registered in escrow
    let registered_count = coin_escrow::caps_registered_count(escrow);
    assert!((outcome_idx as u64) < registered_count, EOutcomeNotRegistered);

    // Get current balance
    let amount = get_balance(balance, outcome_idx, is_asset);
    assert!(amount > 0, EInvalidBalanceAccess);

    // CORRECT ORDER: Mint first, then clear balance
    // This ensures if minting fails, balance isn't lost
    let coin = coin_escrow::mint_conditional<AssetType, StableType, ConditionalCoinType>(
        escrow,
        (outcome_idx as u64),
        is_asset,
        amount,
        ctx
    );

    // Only clear balance after successful mint
    set_balance(balance, outcome_idx, is_asset, 0);

    // Emit event for off-chain tracking
    event::emit(BalanceUnwrapped {
        balance_id: id(balance),
        outcome_idx,
        is_asset,
        amount,
    });

    coin
}

/// Wrap coin back into balance
///
/// PUBLIC: Users need this to convert typed coins back to balances from external DeFi.
///
/// This converts a typed Coin back into a balance amount.
/// Useful when bringing coins back from external DeFi protocols.
///
/// # Security
/// * Validates escrow matches balance's proposal_id (prevents cross-market burning)
/// * Validates outcome is registered in escrow
/// * Validates coin amount is non-zero
/// * Emits event for off-chain tracking
///
/// # Arguments
/// * `balance` - The balance object to add to
/// * `escrow` - Token escrow to burn the conditional coin (MUST match balance's proposal)
/// * `coin` - The conditional coin to wrap
/// * `outcome_idx` - Which outcome this coin belongs to
/// * `is_asset` - true for asset, false for stable
///
/// # Aborts
/// * `EProposalMismatch` - If escrow doesn't match balance's proposal_id
/// * `EOutcomeNotRegistered` - If outcome_idx not registered in escrow
/// * `EInvalidBalanceAccess` - If coin amount is zero or outcome_idx invalid
///
/// # Example
/// ```move
/// // User receives Coin<Cond0Asset> from external DEX
/// conditional_balance::wrap_coin<SUI, USDC, Cond0Asset>(
///     &mut balance,
///     &mut escrow,
///     coin,
///     0,      // outcome_idx
///     true,   // is_asset
/// );
/// // Now balance has been increased by coin amount
/// ```
public fun wrap_coin<AssetType, StableType, ConditionalCoinType>(
    balance: &mut ConditionalMarketBalance<AssetType, StableType>,
    escrow: &mut coin_escrow::TokenEscrow<AssetType, StableType>,
    coin: Coin<ConditionalCoinType>,
    outcome_idx: u8,
    is_asset: bool,
) {
    // CRITICAL: Validate escrow matches balance's market
    let escrow_market_id = coin_escrow::market_state_id(escrow);
    assert!(balance.market_id == escrow_market_id, EProposalMismatch);

    // Validate outcome is registered in escrow
    let registered_count = coin_escrow::caps_registered_count(escrow);
    assert!((outcome_idx as u64) < registered_count, EOutcomeNotRegistered);

    let amount = coin.value();
    assert!(amount > 0, EInvalidBalanceAccess);  // Consistency with unwrap

    // Burn coin back to escrow
    coin_escrow::burn_conditional<AssetType, StableType, ConditionalCoinType>(
        escrow,
        (outcome_idx as u64),
        is_asset,
        coin
    );

    // Add to balance
    add_to_balance(balance, outcome_idx, is_asset, amount);

    // Emit event for off-chain tracking
    event::emit(BalanceWrapped {
        balance_id: id(balance),
        outcome_idx,
        is_asset,
        amount,
    });
}

// === Test Helpers ===

#[test_only]
/// Create balance with non-zero initial amounts (for testing)
public fun new_with_amounts<AssetType, StableType>(
    market_id: ID,
    outcome_count: u8,
    initial_amounts: vector<u64>,
    ctx: &mut TxContext,
): ConditionalMarketBalance<AssetType, StableType> {
    assert!(vector::length(&initial_amounts) == (outcome_count as u64) * 2, 0);

    ConditionalMarketBalance {
        id: object::new(ctx),
        market_id,
        outcome_count,
        version: VERSION,
        balances: initial_amounts,
    }
}

#[test_only]
/// Get mutable reference to balances (for testing)
public fun borrow_balances_mut_for_testing<AssetType, StableType>(
    balance: &mut ConditionalMarketBalance<AssetType, StableType>
): &mut vector<u64> {
    &mut balance.balances
}
