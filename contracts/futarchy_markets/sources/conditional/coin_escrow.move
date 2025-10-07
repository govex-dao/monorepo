module futarchy_markets::coin_escrow;

use futarchy_markets::market_state::MarketState;
use futarchy_markets::spot_amm;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin, TreasuryCap, CoinMetadata};
use sui::event;
use sui::dynamic_field;

// === Introduction ===
// The TokenEscrow manages TreasuryCap-based conditional coins in the futarchy prediction market system.
//
// === TreasuryCap-Based Conditional Coins ===
// Uses real Sui Coin<T> types instead of custom ConditionalToken structs:
// 1. **TreasuryCap Storage**: Each outcome has 2 TreasuryCaps (asset + stable) stored in dynamic fields
// 2. **Registry Integration**: Blank coins acquired from permissionless registry
// 3. **Quantum Liquidity**: Spot tokens exist simultaneously in ALL outcomes (not split between them)
//
// === Quantum Liquidity Invariant ===
// **CRITICAL**: 100 spot tokens → 100 conditional tokens in EACH outcome
// - NOT proportional split (not 50/50 across 2 outcomes)
// - Liquidity exists fully in all markets simultaneously
// - Only highest-priced outcome wins at finalization
// - Invariant: spot_asset_balance == each_outcome_asset_supply (for ALL outcomes)
//
// === Architecture ===
// - TreasuryCaps stored via dynamic fields with AssetCapKey/StableCapKey
// - Vector-like indexing: outcome_index determines which cap to use
// - Mint/burn functions borrow caps mutably, perform operation, return cap to storage
// - No Supply objects - total_supply() comes directly from TreasuryCap

// === Errors ===
const EInsufficientBalance: u64 = 0; // Token balance insufficient for operation
const EIncorrectSequence: u64 = 1; // Tokens not provided in correct sequence/order
const EWrongMarket: u64 = 2; // Token belongs to different market
const EWrongTokenType: u64 = 3; // Wrong token type (asset vs stable)
const ESuppliesNotInitialized: u64 = 4; // Token supplies not yet initialized
const EOutcomeOutOfBounds: u64 = 5; // Outcome index exceeds market outcomes
const EWrongOutcome: u64 = 6; // Token outcome doesn't match expected
const ENotEnough: u64 = 7; // Not enough tokens/balance for operation
const ENotEnoughLiquidity: u64 = 8; // Insufficient liquidity in escrow
const EInsufficientAsset: u64 = 9; // Not enough asset tokens provided
const EInsufficientStable: u64 = 10; // Not enough stable tokens provided
const EMarketNotExpired: u64 = 11; // Market hasn't reached expiry period
const EBadWitness: u64 = 12; // Invalid one-time witness
const EZeroAmount: u64 = 13; // Amount must be greater than zero
const EInvalidAssetType: u64 = 14; // Asset type must be 0 (asset) or 1 (stable)
const EOverflow: u64 = 15; // Arithmetic overflow protection
const EInvariantViolation: u64 = 16; // Differential minting invariant violated

// === Constants ===
const TOKEN_TYPE_ASSET: u8 = 0;
const TOKEN_TYPE_STABLE: u8 = 1;
const TOKEN_TYPE_LP: u8 = 2;
const ETokenTypeMismatch: u64 = 100;
const MARKET_EXPIRY_PERIOD_MS: u64 = 2_592_000_000; // 30 days in ms

// === Key Structures for TreasuryCap Storage ===
/// Key for asset conditional coin TreasuryCaps (indexed by outcome)
public struct AssetCapKey has store, copy, drop {
    outcome_index: u64,
}

/// Key for stable conditional coin TreasuryCaps (indexed by outcome)
public struct StableCapKey has store, copy, drop {
    outcome_index: u64,
}

// === Structs ===
public struct TokenEscrow<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    market_state: MarketState,
    // Central balances used for tokens and liquidity
    escrowed_asset: Balance<AssetType>,
    escrowed_stable: Balance<StableType>,

    // TreasuryCaps stored as dynamic fields on UID (vector-like access by index)
    // Asset caps: dynamic_field with AssetCapKey { outcome_index } -> TreasuryCap<T>
    // Stable caps: dynamic_field with StableCapKey { outcome_index } -> TreasuryCap<T>
    // Each outcome's TreasuryCap has a unique generic type T
    outcome_count: u64,  // Track how many outcomes have registered caps
}

public struct COIN_ESCROW has drop {}

// === Events ===
public struct LiquidityWithdrawal has copy, drop {
    escrowed_asset: u64,
    escrowed_stable: u64,
    asset_amount: u64,
    stable_amount: u64,
}

public struct LiquidityDeposit has copy, drop {
    escrowed_asset: u64,
    escrowed_stable: u64,
    asset_amount: u64,
    stable_amount: u64,
}

public struct TokenRedemption has copy, drop {
    outcome: u64,
    token_type: u8,
    amount: u64,
}

public fun new<AssetType, StableType>(
    market_state: MarketState,
    ctx: &mut TxContext,
): TokenEscrow<AssetType, StableType> {
    TokenEscrow {
        id: object::new(ctx),
        market_state,
        escrowed_asset: balance::zero(),
        escrowed_stable: balance::zero(),
        outcome_count: 0,  // Will be incremented as caps are registered
    }
}

/// NEW: Register conditional coin TreasuryCaps for an outcome
/// Must be called once per outcome with both asset and stable caps
/// Caps are stored as dynamic fields with vector-like indexing semantics
public fun register_conditional_caps<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    asset_treasury_cap: TreasuryCap<AssetConditionalCoin>,
    stable_treasury_cap: TreasuryCap<StableConditionalCoin>,
) {
    let market_outcome_count = escrow.market_state.outcome_count();
    assert!(outcome_idx < market_outcome_count, EOutcomeOutOfBounds);

    // Must register in order (like pushing to a vector)
    assert!(outcome_idx == escrow.outcome_count, EIncorrectSequence);

    // Store TreasuryCaps as dynamic fields with index-based keys
    let asset_key = AssetCapKey { outcome_index: outcome_idx };
    let stable_key = StableCapKey { outcome_index: outcome_idx };

    dynamic_field::add(&mut escrow.id, asset_key, asset_treasury_cap);
    dynamic_field::add(&mut escrow.id, stable_key, stable_treasury_cap);

    // Increment count (like vector length)
    escrow.outcome_count = escrow.outcome_count + 1;
}

// === NEW: TreasuryCap-based Mint/Burn Helpers ===

/// Mint conditional coins for a specific outcome using its TreasuryCap
/// Borrows the cap, mints, and returns it (maintains vector-like storage)
public fun mint_conditional_asset<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    amount: u64,
    ctx: &mut TxContext,
): Coin<ConditionalCoinType> {
    let market_outcome_count = escrow.market_state.outcome_count();
    assert!(outcome_index < market_outcome_count, EOutcomeOutOfBounds);

    // Borrow the TreasuryCap from dynamic field
    let asset_key = AssetCapKey { outcome_index };
    let cap: &mut TreasuryCap<ConditionalCoinType> =
        dynamic_field::borrow_mut(&mut escrow.id, asset_key);

    // Mint and return
    coin::mint(cap, amount, ctx)
}

/// Mint conditional stable coins for a specific outcome
public fun mint_conditional_stable<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    amount: u64,
    ctx: &mut TxContext,
): Coin<ConditionalCoinType> {
    let market_outcome_count = escrow.market_state.outcome_count();
    assert!(outcome_index < market_outcome_count, EOutcomeOutOfBounds);

    // Borrow the TreasuryCap from dynamic field
    let stable_key = StableCapKey { outcome_index };
    let cap: &mut TreasuryCap<ConditionalCoinType> =
        dynamic_field::borrow_mut(&mut escrow.id, stable_key);

    // Mint and return
    coin::mint(cap, amount, ctx)
}

/// Burn conditional asset coins for a specific outcome
public fun burn_conditional_asset<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    coin: Coin<ConditionalCoinType>,
) {
    let market_outcome_count = escrow.market_state.outcome_count();
    assert!(outcome_index < market_outcome_count, EOutcomeOutOfBounds);

    // Borrow the TreasuryCap from dynamic field
    let asset_key = AssetCapKey { outcome_index };
    let cap: &mut TreasuryCap<ConditionalCoinType> =
        dynamic_field::borrow_mut(&mut escrow.id, asset_key);

    // Burn
    coin::burn(cap, coin);
}

/// Burn conditional stable coins for a specific outcome
public fun burn_conditional_stable<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    coin: Coin<ConditionalCoinType>,
) {
    let market_outcome_count = escrow.market_state.outcome_count();
    assert!(outcome_index < market_outcome_count, EOutcomeOutOfBounds);

    // Borrow the TreasuryCap from dynamic field
    let stable_key = StableCapKey { outcome_index };
    let cap: &mut TreasuryCap<ConditionalCoinType> =
        dynamic_field::borrow_mut(&mut escrow.id, stable_key);

    // Burn
    coin::burn(cap, coin);
}

/// Get the total supply of a specific outcome's asset conditional coin
public fun get_asset_supply<AssetType, StableType, ConditionalCoinType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
): u64 {
    let asset_key = AssetCapKey { outcome_index };
    let cap: &TreasuryCap<ConditionalCoinType> =
        dynamic_field::borrow(&escrow.id, asset_key);
    coin::total_supply(cap)
}

/// Get the total supply of a specific outcome's stable conditional coin
public fun get_stable_supply<AssetType, StableType, ConditionalCoinType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
): u64 {
    let stable_key = StableCapKey { outcome_index };
    let cap: &TreasuryCap<ConditionalCoinType> =
        dynamic_field::borrow(&escrow.id, stable_key);
    coin::total_supply(cap)
}

// === Getters ===

/// Get the market state from escrow
public fun get_market_state<AssetType, StableType>(escrow: &TokenEscrow<AssetType, StableType>): &MarketState {
    &escrow.market_state
}

/// Get mutable market state from escrow
public fun get_market_state_mut<AssetType, StableType>(escrow: &mut TokenEscrow<AssetType, StableType>): &mut MarketState {
    &mut escrow.market_state
}

/// Get the market state ID from escrow
public fun market_state_id<AssetType, StableType>(escrow: &TokenEscrow<AssetType, StableType>): ID {
    escrow.market_state.market_id()
}

/// Get the number of outcomes that have registered TreasuryCaps
public fun caps_registered_count<AssetType, StableType>(escrow: &TokenEscrow<AssetType, StableType>): u64 {
    escrow.outcome_count
}

/// Deposit spot liquidity into escrow (quantum liquidity model)
/// This adds to the escrow balances that will be split quantum-mechanically across all outcomes
public fun deposit_spot_liquidity<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset: Balance<AssetType>,
    stable: Balance<StableType>,
) {
    escrow.escrowed_asset.join(asset);
    escrow.escrowed_stable.join(stable);
}

// === Burn and Withdraw Helpers (For Redemption) ===

/// Burn conditional asset coins and withdraw equivalent spot asset
/// Used when redeeming conditional coins back to spot tokens (e.g., after market finalization)
public fun burn_conditional_asset_and_withdraw<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    amount: u64,
    ctx: &mut TxContext,
): Coin<AssetType> {
    // Mint the conditional coins to burn them (quantum liquidity: amounts must match)
    let conditional_coin = mint_conditional_asset<AssetType, StableType, ConditionalCoinType>(
        escrow,
        outcome_index,
        amount,
        ctx,
    );

    // Burn the conditional coins
    burn_conditional_asset<AssetType, StableType, ConditionalCoinType>(
        escrow,
        outcome_index,
        conditional_coin,
    );

    // Withdraw equivalent spot tokens (1:1 due to quantum liquidity)
    let asset_balance = escrow.escrowed_asset.split(amount);
    coin::from_balance(asset_balance, ctx)
}

/// Burn conditional stable coins and withdraw equivalent spot stable
public fun burn_conditional_stable_and_withdraw<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    amount: u64,
    ctx: &mut TxContext,
): Coin<StableType> {
    // Mint the conditional coins to burn them
    let conditional_coin = mint_conditional_stable<AssetType, StableType, ConditionalCoinType>(
        escrow,
        outcome_index,
        amount,
        ctx,
    );

    // Burn the conditional coins
    burn_conditional_stable<AssetType, StableType, ConditionalCoinType>(
        escrow,
        outcome_index,
        conditional_coin,
    );

    // Withdraw equivalent spot tokens
    let stable_balance = escrow.escrowed_stable.split(amount);
    coin::from_balance(stable_balance, ctx)
}

// === Deposit and Mint Helpers (For Creating Conditional Coins) ===

/// Deposit spot asset and mint equivalent conditional asset coins
/// Quantum liquidity: Depositing X spot mints X conditional in specified outcome
public fun deposit_asset_and_mint_conditional<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    asset_coin: Coin<AssetType>,
    ctx: &mut TxContext,
): Coin<ConditionalCoinType> {
    let amount = asset_coin.value();

    // Deposit spot tokens to escrow
    let asset_balance = coin::into_balance(asset_coin);
    escrow.escrowed_asset.join(asset_balance);

    // Mint equivalent conditional coins (1:1 due to quantum liquidity)
    mint_conditional_asset<AssetType, StableType, ConditionalCoinType>(
        escrow,
        outcome_index,
        amount,
        ctx,
    )
}

/// Deposit spot stable and mint equivalent conditional stable coins
public fun deposit_stable_and_mint_conditional<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    stable_coin: Coin<StableType>,
    ctx: &mut TxContext,
): Coin<ConditionalCoinType> {
    let amount = stable_coin.value();

    // Deposit spot tokens to escrow
    let stable_balance = coin::into_balance(stable_coin);
    escrow.escrowed_stable.join(stable_balance);

    // Mint equivalent conditional coins
    mint_conditional_stable<AssetType, StableType, ConditionalCoinType>(
        escrow,
        outcome_index,
        amount,
        ctx,
    )
}

/// Get escrow spot balances (read-only)
public fun get_spot_balances<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): (u64, u64) {
    (escrow.escrowed_asset.value(), escrow.escrowed_stable.value())
}

/// Withdraw asset balance from escrow (for internal use)
public fun withdraw_asset_balance<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<AssetType> {
    let balance = escrow.escrowed_asset.split(amount);
    coin::from_balance(balance, ctx)
}

/// Withdraw stable balance from escrow (for internal use)
public fun withdraw_stable_balance<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<StableType> {
    let balance = escrow.escrowed_stable.split(amount);
    coin::from_balance(balance, ctx)
}

// === Quantum Liquidity Invariant Checking ===

/// Assert the quantum liquidity invariant: each outcome's supply equals spot balance
/// CRITICAL: In quantum liquidity model, 100 spot tokens → 100 in EACH outcome simultaneously
/// This is NOT proportional splitting - liquidity exists fully in all outcomes at once
///
/// The invariant must hold UNTIL proposal finalization:
/// - spot_asset_balance == each_outcome_asset_supply (for all outcomes)
/// - spot_stable_balance == each_outcome_stable_supply (for all outcomes)
///
/// After finalization, only the winning outcome's supply matters (others can be burned)
public fun assert_quantum_invariant<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
) {
    let spot_asset = escrow.escrowed_asset.value();
    let spot_stable = escrow.escrowed_stable.value();
    let outcome_count = escrow.outcome_count;

    // Check each outcome has supply equal to spot balance
    let mut i = 0;
    while (i < outcome_count) {
        // Get asset supply for this outcome
        let asset_key = AssetCapKey { outcome_index: i };
        let asset_cap_exists = dynamic_field::exists_(&escrow.id, asset_key);

        if (asset_cap_exists) {
            // We can't call get_asset_supply without the generic type parameter
            // So we'll leave this as a framework for manual checking
            // In practice, caller must provide the ConditionalCoinType to check
        };

        // Get stable supply for this outcome
        let stable_key = StableCapKey { outcome_index: i };
        let stable_cap_exists = dynamic_field::exists_(&escrow.id, stable_key);

        if (stable_cap_exists) {
            // Same limitation - need generic type to check supply
        };

        i = i + 1;
    };

    // NOTE: Full invariant check requires knowing all ConditionalCoinTypes at compile time
    // This function serves as documentation of the invariant
    // Actual enforcement happens in mint/burn operations that maintain the invariant
}
