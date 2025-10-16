module futarchy_markets_primitives::coin_escrow;

use futarchy_markets_primitives::market_state::MarketState;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin, TreasuryCap, CoinMetadata};
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

// === Constants ===
const TOKEN_TYPE_ASSET: u8 = 0;
const TOKEN_TYPE_STABLE: u8 = 1;
const TOKEN_TYPE_LP: u8 = 2;
const ETokenTypeMismatch: u64 = 100;
const MARKET_EXPIRY_PERIOD_MS: u64 = 2_592_000_000; // 30 days in ms

// === Key Structures for TreasuryCap Storage ===
/// Key for asset conditional coin TreasuryCaps (indexed by outcome)
public struct AssetCapKey has copy, drop, store {
    outcome_index: u64,
}

/// Key for stable conditional coin TreasuryCaps (indexed by outcome)
public struct StableCapKey has copy, drop, store {
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
    outcome_count: u64, // Track how many outcomes have registered caps
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
        outcome_count: 0, // Will be incremented as caps are registered
    }
}

/// NEW: Register conditional coin TreasuryCaps for an outcome
/// Must be called once per outcome with both asset and stable caps
/// Caps are stored as dynamic fields with vector-like indexing semantics
public fun register_conditional_caps<
    AssetType,
    StableType,
    AssetConditionalCoin,
    StableConditionalCoin,
>(
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
    let cap: &mut TreasuryCap<ConditionalCoinType> = dynamic_field::borrow_mut(
        &mut escrow.id,
        asset_key,
    );

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
    let cap: &mut TreasuryCap<ConditionalCoinType> = dynamic_field::borrow_mut(
        &mut escrow.id,
        stable_key,
    );

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
    let cap: &mut TreasuryCap<ConditionalCoinType> = dynamic_field::borrow_mut(
        &mut escrow.id,
        asset_key,
    );

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
    let cap: &mut TreasuryCap<ConditionalCoinType> = dynamic_field::borrow_mut(
        &mut escrow.id,
        stable_key,
    );

    // Burn
    coin::burn(cap, coin);
}

// === NEW: Generic Mint/Burn for Balance-Based Operations ===

/// Generic mint function for conditional coins (used by balance unwrap)
/// Takes outcome_index and is_asset to determine which TreasuryCap to use
public(package) fun mint_conditional<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    amount: u64,
    ctx: &mut TxContext,
): Coin<ConditionalCoinType> {
    if (is_asset) {
        mint_conditional_asset<AssetType, StableType, ConditionalCoinType>(
            escrow,
            outcome_index,
            amount,
            ctx,
        )
    } else {
        mint_conditional_stable<AssetType, StableType, ConditionalCoinType>(
            escrow,
            outcome_index,
            amount,
            ctx,
        )
    }
}

/// Generic burn function for conditional coins (used by balance wrap)
public(package) fun burn_conditional<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,
    coin: Coin<ConditionalCoinType>,
) {
    if (is_asset) {
        burn_conditional_asset<AssetType, StableType, ConditionalCoinType>(
            escrow,
            outcome_index,
            coin,
        )
    } else {
        burn_conditional_stable<AssetType, StableType, ConditionalCoinType>(
            escrow,
            outcome_index,
            coin,
        )
    }
}

/// Deposit spot coins to escrow (for balance-based operations)
/// Returns amounts deposited (for balance tracking)
public fun deposit_spot_coins<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
): (u64, u64) {
    let asset_amt = asset_coin.value();
    let stable_amt = stable_coin.value();

    // Require at least one non-zero amount
    assert!(asset_amt > 0 || stable_amt > 0, EZeroAmount);

    // Add to escrow reserves
    balance::join(&mut escrow.escrowed_asset, coin::into_balance(asset_coin));
    balance::join(&mut escrow.escrowed_stable, coin::into_balance(stable_coin));

    (asset_amt, stable_amt)
}

/// Withdraw spot coins from escrow (for complete set burn)
public fun withdraw_from_escrow<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_amount: u64,
    stable_amount: u64,
    ctx: &mut TxContext,
): (Coin<AssetType>, Coin<StableType>) {
    assert!(balance::value(&escrow.escrowed_asset) >= asset_amount, ENotEnoughLiquidity);
    assert!(balance::value(&escrow.escrowed_stable) >= stable_amount, ENotEnoughLiquidity);

    let asset_bal = balance::split(&mut escrow.escrowed_asset, asset_amount);
    let stable_bal = balance::split(&mut escrow.escrowed_stable, stable_amount);

    (coin::from_balance(asset_bal, ctx), coin::from_balance(stable_bal, ctx))
}

/// Get the total supply of a specific outcome's asset conditional coin
public fun get_asset_supply<AssetType, StableType, ConditionalCoinType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
): u64 {
    let asset_key = AssetCapKey { outcome_index };
    let cap: &TreasuryCap<ConditionalCoinType> = dynamic_field::borrow(&escrow.id, asset_key);
    coin::total_supply(cap)
}

/// Get the total supply of a specific outcome's stable conditional coin
public fun get_stable_supply<AssetType, StableType, ConditionalCoinType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
): u64 {
    let stable_key = StableCapKey { outcome_index };
    let cap: &TreasuryCap<ConditionalCoinType> = dynamic_field::borrow(&escrow.id, stable_key);
    coin::total_supply(cap)
}

// === Getters ===

/// Get the market state from escrow
public fun get_market_state<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): &MarketState {
    &escrow.market_state
}

/// Get mutable market state from escrow
public fun get_market_state_mut<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
): &mut MarketState {
    &mut escrow.market_state
}

/// Get the market state ID from escrow
public fun market_state_id<AssetType, StableType>(escrow: &TokenEscrow<AssetType, StableType>): ID {
    escrow.market_state.market_id()
}

/// Get the number of outcomes that have registered TreasuryCaps
public fun caps_registered_count<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): u64 {
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

// === Quantum Liquidity Invariant ===
//
// INVARIANT (enforced by construction):
// - spot_asset_balance == each_outcome_asset_supply (for ALL outcomes)
// - spot_stable_balance == each_outcome_stable_supply (for ALL outcomes)
//
// This invariant is maintained by the mint/burn operations:
// - deposit_and_mint: deposit X spot → mint X conditional (1:1)
// - burn_and_withdraw: burn X conditional → withdraw X spot (1:1)
// - split operations: deposit spot → mint conditional in all outcomes
// - recombine operations: burn conditional from all outcomes → withdraw spot
//
// No validation function needed - operations enforce invariant by construction.

// === Complete Set Operations (Split/Recombine) ===
// Uses PTB hot potato pattern - see TYPE_PARAMETER_EXPLOSION_PROBLEM.md

/// Progress tracker for splitting a spot asset coin into a complete set of conditional asset coins.
/// This struct MUST be fully consumed via `finish_split_asset_progress` to preserve the quantum invariant.
public struct SplitAssetProgress<phantom AssetType, phantom StableType> has drop {
    market_id: ID,
    amount: u64,
    outcome_count: u64,
    next_outcome: u64,
}

public fun drop_split_asset_progress<AssetType, StableType>(
    progress: SplitAssetProgress<AssetType, StableType>,
) {
    let SplitAssetProgress { market_id: _, amount: _, outcome_count, next_outcome } = progress;
    assert!(next_outcome == outcome_count, EIncorrectSequence);
}

/// Progress tracker for splitting a spot stable coin into a complete set of conditional stable coins.
public struct SplitStableProgress<phantom AssetType, phantom StableType> has drop {
    market_id: ID,
    amount: u64,
    outcome_count: u64,
    next_outcome: u64,
}

public fun drop_split_stable_progress<AssetType, StableType>(
    progress: SplitStableProgress<AssetType, StableType>,
) {
    let SplitStableProgress { market_id: _, amount: _, outcome_count, next_outcome } = progress;
    assert!(next_outcome == outcome_count, EIncorrectSequence);
}

/// Progress tracker for recombining conditional asset coins back into a spot asset coin.
/// All outcomes must be processed sequentially from 0 → outcome_count - 1.
public struct RecombineAssetProgress<phantom AssetType, phantom StableType> has drop {
    market_id: ID,
    amount: u64,
    outcome_count: u64,
    next_outcome: u64,
}

public fun drop_recombine_asset_progress<AssetType, StableType>(
    progress: RecombineAssetProgress<AssetType, StableType>,
) {
    let RecombineAssetProgress { market_id: _, amount: _, outcome_count, next_outcome } = progress;
    assert!(next_outcome == outcome_count, EIncorrectSequence);
}

/// Progress tracker for recombining conditional stable coins back into a spot stable coin.
public struct RecombineStableProgress<phantom AssetType, phantom StableType> has drop {
    market_id: ID,
    amount: u64,
    outcome_count: u64,
    next_outcome: u64,
}

public fun drop_recombine_stable_progress<AssetType, StableType>(
    progress: RecombineStableProgress<AssetType, StableType>,
) {
    let RecombineStableProgress { market_id: _, amount: _, outcome_count, next_outcome } = progress;
    assert!(next_outcome == outcome_count, EIncorrectSequence);
}

/// Begin splitting a spot asset coin into a complete set of conditional assets.
/// Returns a progress object that must be passed through `split_asset_progress_step`
/// for each outcome, then finalized with `finish_split_asset_progress`.
public fun start_split_asset_progress<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    spot_asset: Coin<AssetType>,
): SplitAssetProgress<AssetType, StableType> {
    let amount = spot_asset.value();
    assert!(amount > 0, EZeroAmount);

    let outcome_count = caps_registered_count(escrow);
    assert!(outcome_count > 0, ESuppliesNotInitialized);

    let asset_balance = coin::into_balance(spot_asset);
    escrow.escrowed_asset.join(asset_balance);

    SplitAssetProgress {
        market_id: market_state_id(escrow),
        amount,
        outcome_count,
        next_outcome: 0,
    }
}

/// Mint the next conditional asset coin in the sequence.
/// Caller is responsible for transferring or otherwise handling the returned coin.
public fun split_asset_progress_step<AssetType, StableType, ConditionalCoinType>(
    mut progress: SplitAssetProgress<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u8,
    ctx: &mut TxContext,
): (SplitAssetProgress<AssetType, StableType>, Coin<ConditionalCoinType>) {
    assert!(market_state_id(escrow) == progress.market_id, EWrongMarket);

    let index = (outcome_index as u64);
    assert!(progress.next_outcome < progress.outcome_count, EOutcomeOutOfBounds);
    assert!(index == progress.next_outcome, EIncorrectSequence);

    let coin = mint_conditional_asset<AssetType, StableType, ConditionalCoinType>(
        escrow,
        index,
        progress.amount,
        ctx,
    );

    progress.next_outcome = progress.next_outcome + 1;

    (progress, coin)
}

/// Ensure the split operation covered all outcomes. Must be called exactly once per progress object.
public fun finish_split_asset_progress<AssetType, StableType>(
    progress: SplitAssetProgress<AssetType, StableType>,
) {
    let SplitAssetProgress { market_id: _, amount: _, outcome_count, next_outcome } = progress;
    assert!(next_outcome == outcome_count, EIncorrectSequence);
}

/// Begin splitting a spot stable coin into a complete set of conditional stables.
public fun start_split_stable_progress<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    spot_stable: Coin<StableType>,
): SplitStableProgress<AssetType, StableType> {
    let amount = spot_stable.value();
    assert!(amount > 0, EZeroAmount);

    let outcome_count = caps_registered_count(escrow);
    assert!(outcome_count > 0, ESuppliesNotInitialized);

    let stable_balance = coin::into_balance(spot_stable);
    escrow.escrowed_stable.join(stable_balance);

    SplitStableProgress {
        market_id: market_state_id(escrow),
        amount,
        outcome_count,
        next_outcome: 0,
    }
}

/// Mint the next conditional stable coin in the sequence.
public fun split_stable_progress_step<AssetType, StableType, ConditionalCoinType>(
    mut progress: SplitStableProgress<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u8,
    ctx: &mut TxContext,
): (SplitStableProgress<AssetType, StableType>, Coin<ConditionalCoinType>) {
    assert!(market_state_id(escrow) == progress.market_id, EWrongMarket);

    let index = (outcome_index as u64);
    assert!(progress.next_outcome < progress.outcome_count, EOutcomeOutOfBounds);
    assert!(index == progress.next_outcome, EIncorrectSequence);

    let coin = mint_conditional_stable<AssetType, StableType, ConditionalCoinType>(
        escrow,
        index,
        progress.amount,
        ctx,
    );

    progress.next_outcome = progress.next_outcome + 1;

    (progress, coin)
}

/// Ensure the stable split operation covered all outcomes.
public fun finish_split_stable_progress<AssetType, StableType>(
    progress: SplitStableProgress<AssetType, StableType>,
) {
    let SplitStableProgress { market_id: _, amount: _, outcome_count, next_outcome } = progress;
    assert!(next_outcome == outcome_count, EIncorrectSequence);
}

/// Begin recombining conditional asset coins into a spot asset coin.
/// Consumes and burns the first coin (must be outcome index 0).
public fun start_recombine_asset_progress<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u8,
    coin: Coin<ConditionalCoinType>,
): RecombineAssetProgress<AssetType, StableType> {
    let index = (outcome_index as u64);
    assert!(index == 0, EIncorrectSequence);

    let outcome_count = caps_registered_count(escrow);
    assert!(outcome_count > 0, ESuppliesNotInitialized);
    assert!(index < outcome_count, EOutcomeOutOfBounds);

    let amount = coin.value();
    assert!(amount > 0, EZeroAmount);

    burn_conditional_asset<AssetType, StableType, ConditionalCoinType>(
        escrow,
        index,
        coin,
    );

    RecombineAssetProgress {
        market_id: market_state_id(escrow),
        amount,
        outcome_count,
        next_outcome: 1,
    }
}

/// Burn the next conditional asset coin in the recombination sequence.
public fun recombine_asset_progress_step<AssetType, StableType, ConditionalCoinType>(
    mut progress: RecombineAssetProgress<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u8,
    coin: Coin<ConditionalCoinType>,
): RecombineAssetProgress<AssetType, StableType> {
    assert!(market_state_id(escrow) == progress.market_id, EWrongMarket);

    let index = (outcome_index as u64);
    assert!(progress.next_outcome < progress.outcome_count, EOutcomeOutOfBounds);
    assert!(index == progress.next_outcome, EIncorrectSequence);

    let amount = coin.value();
    assert!(amount == progress.amount, EInsufficientBalance);

    burn_conditional_asset<AssetType, StableType, ConditionalCoinType>(
        escrow,
        index,
        coin,
    );

    progress.next_outcome = progress.next_outcome + 1;
    progress
}

/// Finish recombination and withdraw the corresponding spot asset coin.
public fun finish_recombine_asset_progress<AssetType, StableType>(
    progress: RecombineAssetProgress<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    ctx: &mut TxContext,
): Coin<AssetType> {
    let RecombineAssetProgress { market_id: _, amount, outcome_count, next_outcome } = progress;
    assert!(next_outcome == outcome_count, EIncorrectSequence);
    withdraw_asset_balance(escrow, amount, ctx)
}

/// Begin recombining conditional stable coins into spot stable.
public fun start_recombine_stable_progress<AssetType, StableType, ConditionalCoinType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u8,
    coin: Coin<ConditionalCoinType>,
): RecombineStableProgress<AssetType, StableType> {
    let index = (outcome_index as u64);
    assert!(index == 0, EIncorrectSequence);

    let outcome_count = caps_registered_count(escrow);
    assert!(outcome_count > 0, ESuppliesNotInitialized);
    assert!(index < outcome_count, EOutcomeOutOfBounds);

    let amount = coin.value();
    assert!(amount > 0, EZeroAmount);

    burn_conditional_stable<AssetType, StableType, ConditionalCoinType>(
        escrow,
        index,
        coin,
    );

    RecombineStableProgress {
        market_id: market_state_id(escrow),
        amount,
        outcome_count,
        next_outcome: 1,
    }
}

/// Burn the next conditional stable coin in the recombination sequence.
public fun recombine_stable_progress_step<AssetType, StableType, ConditionalCoinType>(
    mut progress: RecombineStableProgress<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u8,
    coin: Coin<ConditionalCoinType>,
): RecombineStableProgress<AssetType, StableType> {
    assert!(market_state_id(escrow) == progress.market_id, EWrongMarket);

    let index = (outcome_index as u64);
    assert!(progress.next_outcome < progress.outcome_count, EOutcomeOutOfBounds);
    assert!(index == progress.next_outcome, EIncorrectSequence);

    let amount = coin.value();
    assert!(amount == progress.amount, EInsufficientBalance);

    burn_conditional_stable<AssetType, StableType, ConditionalCoinType>(
        escrow,
        index,
        coin,
    );

    progress.next_outcome = progress.next_outcome + 1;
    progress
}

/// Finish recombination and withdraw the corresponding spot stable coin.
public fun finish_recombine_stable_progress<AssetType, StableType>(
    progress: RecombineStableProgress<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    ctx: &mut TxContext,
): Coin<StableType> {
    let RecombineStableProgress { market_id: _, amount, outcome_count, next_outcome } = progress;
    assert!(next_outcome == outcome_count, EIncorrectSequence);
    withdraw_stable_balance(escrow, amount, ctx)
}

// === Test Helpers ===

#[test_only]
/// Create a blank TreasuryCap for testing (zero supply, blank metadata)
/// This simulates getting a blank coin from the registry
public fun create_test_treasury_cap<CoinType: drop>(
    otw: CoinType,
    ctx: &mut TxContext,
): (TreasuryCap<CoinType>, CoinMetadata<CoinType>) {
    // Create coin with blank metadata
    let (treasury_cap, metadata) = coin::create_currency(
        otw,
        0, // decimals
        b"", // symbol (empty)
        b"", // name (empty)
        b"", // description (empty)
        option::none(), // icon_url (empty)
        ctx,
    );

    (treasury_cap, metadata)
}

#[test_only]
/// Create a test escrow with a real MarketState (not a mock)
/// This is a simplified helper that creates an actual TokenEscrow with sensible defaults
public fun create_test_escrow<AssetType, StableType>(
    outcome_count: u64,
    ctx: &mut TxContext,
): TokenEscrow<AssetType, StableType> {
    // Create a real MarketState using existing test infrastructure
    let market_state = futarchy_markets_primitives::market_state::create_for_testing(
        outcome_count,
        ctx,
    );

    // Create and return the TokenEscrow with the real MarketState
    new<AssetType, StableType>(market_state, ctx)
}

#[test_only]
/// Create a test escrow with a provided MarketState
/// Useful when you need to customize the market state before creating the escrow
public fun create_test_escrow_with_market_state<AssetType, StableType>(
    _outcome_count: u64, // Not used, but kept for API compatibility
    market_state: MarketState,
    ctx: &mut TxContext,
): TokenEscrow<AssetType, StableType> {
    new<AssetType, StableType>(market_state, ctx)
}

#[test_only]
/// Destroy escrow for testing (with remaining balances)
/// Useful for cleaning up test state
public fun destroy_for_testing<AssetType, StableType>(escrow: TokenEscrow<AssetType, StableType>) {
    let TokenEscrow {
        id,
        market_state,
        escrowed_asset,
        escrowed_stable,
        outcome_count: _,
    } = escrow;

    // Destroy balances
    balance::destroy_for_testing(escrowed_asset);
    balance::destroy_for_testing(escrowed_stable);

    // Destroy market state
    futarchy_markets_primitives::market_state::destroy_for_testing(market_state);

    // Delete UID (TreasuryCaps in dynamic fields will be destroyed automatically)
    object::delete(id);
}
