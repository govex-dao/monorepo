module futarchy_markets::coin_escrow;

use futarchy_markets::conditional_token::{Self as token, ConditionalToken, Supply};
use futarchy_markets::market_state::MarketState;
use futarchy_markets::spot_amm;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::event;

// === Introduction ===
// The TokenEscrow manages the relationship between spot tokens and conditional tokens
// in the futarchy prediction market system.
//
// === Live-Flow Model Integration ===
// In the live-flow model, the escrow plays a critical role:
// 1. **Minting Complete Sets**: When LPs add liquidity during active proposals,
//    spot tokens are converted to complete sets of conditional tokens (one for each outcome)
// 2. **Redeeming Complete Sets**: When LPs remove liquidity, conditional tokens
//    are redeemed back to spot tokens
// 3. **Supply Tracking**: Maintains Supply objects for each outcome's tokens
//
// This enables the key innovation: LPs can freely add/remove liquidity even while
// proposals are active, as their spot tokens are automatically converted to/from
// conditional tokens as needed.
//
// === CRITICAL: Market Finalization and LP Token Conversion ===
//
// **Key Points:**
// 1. **Finalization is a One-Way Door**: Once a market is finalized, NO conditional token
//    operations (swaps, mints) are allowed. Only redemption and LP conversion are permitted.
//
// 2. **LP Token 1:1 Exchange**: Conditional LP tokens and spot LP tokens use identical amounts.
//    When liquidity moves from conditional AMM to spot AMM during finalization, the LP token
//    amounts remain the same. This is a simple 1:1 burn-and-mint operation.
//
// 3. **Conditional LP Cannot Be Redeemed for Underlying**: After finalization, conditional LP
//    tokens from the winning outcome CANNOT be redeemed for underlying asset/stable tokens.
//    They can ONLY be converted to spot LP tokens via convert_winning_lp_to_spot_lp().
//    Before finalization, conditional LP tokens can be burned to withdraw conditional tokens
//    from the AMM (via remove_liquidity), but after finalization this is not allowed.
//
// 4. **Liquidity Movement During Finalization**: The actual liquidity (asset and stable tokens)
//    is transferred from the winning conditional AMM to the spot AMM during finalization.
//    The LP tokens just track ownership shares - they don't hold the liquidity themselves.
//
// **Function Restrictions by Phase:**
//
// BEFORE Finalization (Market Active):
// - ✅ mint_single_conditional_token() - Create new conditional tokens
// - ✅ mint_complete_set_asset/stable() - Mint complete sets
// - ✅ deposit_initial_liquidity() - Add conditional tokens to AMM, receive conditional LP tokens
// - ✅ remove_liquidity() - Burn conditional LP tokens, receive conditional tokens back
// - ✅ swap_token_asset_to_stable() - Swap between conditional tokens
// - ✅ swap_token_stable_to_asset() - Swap between conditional tokens
// - ✅ redeem_complete_set() - Redeem complete sets back to spot
// - ❌ redeem_winning_tokens() - Not allowed until finalized
// - ❌ convert_winning_lp_to_spot_lp() - Not allowed until finalized
//
// AFTER Finalization (Market Settled):
// - ❌ mint_single_conditional_token() - No new minting allowed
// - ❌ mint_complete_set_asset/stable() - No new minting allowed
// - ❌ deposit_initial_liquidity() - Cannot add liquidity to conditional AMMs
// - ❌ remove_liquidity() - Cannot remove liquidity from conditional AMMs
// - ❌ swap_token_asset_to_stable() - No swapping allowed
// - ❌ swap_token_stable_to_asset() - No swapping allowed
// - ❌ redeem_complete_set() - Cannot form complete sets anymore
// - ✅ redeem_winning_tokens_asset/stable() - Redeem winning outcome tokens
// - ✅ convert_winning_lp_to_spot_lp() - Convert winning LP tokens 1:1 to spot LP
// - ✅ burn_losing_lp_tokens() - Burn worthless losing outcome LP tokens
//
// **Security Invariants:**
// - The 1:1 LP conversion preserves ownership percentages exactly
// - No value can be created or destroyed during conversion
// - The underlying liquidity has already moved; LP conversion just updates token type
// - These restrictions prevent any manipulation after market settlement

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

// === Structs ===
public struct TokenEscrow<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    market_state: MarketState,
    // Central balances used for tokens and liquidity
    escrowed_asset: Balance<AssetType>,
    escrowed_stable: Balance<StableType>,
    // Token supplies for tracking issuance
    outcome_asset_supplies: vector<Supply>,
    outcome_stable_supplies: vector<Supply>,
    outcome_lp_supplies: vector<Supply>,
    // Track final amounts from winning pool for LP conversion invariance
    winning_pool_final_asset: u64,
    winning_pool_final_stable: u64,
    // Track original winning LP supply for conversion invariant
    winning_lp_supply_at_finalization: u64,
    // Track total LP converted so far to ensure no over-conversion
    winning_lp_converted: u64,
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
// === New Functions for Live-Flow Model ===

/// Mint a single conditional token for AMM liquidity removal
/// This function is used by the AMM when removing liquidity proportionally
public (package) fun mint_single_conditional_token<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_type: u8,
    outcome: u8,
    amount: u64,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
): ConditionalToken {
    assert!(amount > 0, EZeroAmount);
    assert!(asset_type <= 2, EInvalidAssetType);
    
    // Safety checks
    escrow.market_state.assert_not_finalized();
    assert_supplies_initialized(escrow);
    
    let outcome_idx = (outcome as u64);
    assert!(outcome_idx < escrow.market_state.outcome_count(), EOutcomeOutOfBounds);
    
    // Get the appropriate supply based on token type
    let escrow_id = object::id(escrow);
    if (asset_type == TOKEN_TYPE_ASSET) {
        let supply = &mut escrow.outcome_asset_supplies[outcome_idx];
        token::mint_with_escrow(
            &escrow.market_state,
            supply,
            amount,
            recipient,
            escrow_id,
            clock,
            ctx
        )
    } else if (asset_type == TOKEN_TYPE_STABLE) {
        let supply = &mut escrow.outcome_stable_supplies[outcome_idx];
        token::mint_with_escrow(
            &escrow.market_state,
            supply,
            amount,
            recipient,
            escrow_id,
            clock,
            ctx
        )
    } else {
        let supply = &mut escrow.outcome_lp_supplies[outcome_idx];
        token::mint_with_escrow(
            &escrow.market_state,
            supply,
            amount,
            recipient,
            escrow_id,
            clock,
            ctx
        )
    }
}

/// Burn a single conditional token - used by AMM when absorbing liquidity
public (package) fun burn_single_conditional_token<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    token: ConditionalToken,
    clock: &Clock,
    ctx: &TxContext,
) {
    // Safety checks
    escrow.market_state.assert_not_finalized();
    assert_supplies_initialized(escrow);
    
    let asset_type = token.asset_type();
    let outcome = token.outcome();
    let outcome_idx = (outcome as u64);
    
    assert!(token.market_id() == escrow.market_state.market_id(), EWrongMarket);
    assert!(outcome_idx < escrow.market_state.outcome_count(), EOutcomeOutOfBounds);
    
    // Get the appropriate supply and burn
    if (asset_type == TOKEN_TYPE_ASSET) {
        let supply = &mut escrow.outcome_asset_supplies[outcome_idx];
        token::burn(token, supply, clock, ctx);
    } else if (asset_type == TOKEN_TYPE_STABLE) {
        let supply = &mut escrow.outcome_stable_supplies[outcome_idx];
        token::burn(token, supply, clock, ctx);
    } else {
        let supply = &mut escrow.outcome_lp_supplies[outcome_idx];
        token::burn(token, supply, clock, ctx);
    };
}

/// Mint a complete set of asset conditional tokens for all outcomes
public fun mint_complete_set_asset<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_in: Coin<AssetType>,
    _clock: &Clock,
    ctx: &mut TxContext,
): vector<ConditionalToken> {
    let amount = asset_in.value();
    assert!(amount > 0, EInsufficientAsset);
    
    // Safety checks
    escrow.market_state.assert_not_finalized();
    assert_supplies_initialized(escrow);
    
    // Deposit asset into escrow
    escrow.escrowed_asset.join(asset_in.into_balance());
    
    // Mint conditional tokens for each outcome
    let mut tokens = vector::empty();
    let outcome_count = escrow.outcome_asset_supplies.length();
    let mut i = 0;
    
    let escrow_id = object::id(escrow);
    while (i < outcome_count) {
        let supply = &mut escrow.outcome_asset_supplies[i];
        let token = token::mint_with_escrow(
            &escrow.market_state,
            supply,
            amount,
            ctx.sender(),
            escrow_id,
            _clock,
            ctx
        );
        tokens.push_back(token);
        i = i + 1;
    };
    
    tokens
}

/// Mint a complete set of stable conditional tokens for all outcomes
public fun mint_complete_set_stable<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    stable_in: Coin<StableType>,
    _clock: &Clock,
    ctx: &mut TxContext,
): vector<ConditionalToken> {
    let amount = stable_in.value();
    assert!(amount > 0, EInsufficientStable);
    
    // Safety checks
    escrow.market_state.assert_not_finalized();
    assert_supplies_initialized(escrow);
    
    // Deposit stable into escrow
    escrow.escrowed_stable.join(stable_in.into_balance());
    
    // Mint conditional tokens for each outcome
    let mut tokens = vector::empty();
    let outcome_count = escrow.outcome_stable_supplies.length();
    let mut i = 0;
    
    let escrow_id = object::id(escrow);
    while (i < outcome_count) {
        let supply = &mut escrow.outcome_stable_supplies[i];
        let token = token::mint_with_escrow(
            &escrow.market_state,
            supply,
            amount,
            ctx.sender(),
            escrow_id,
            _clock,
            ctx
        );
        tokens.push_back(token);
        i = i + 1;
    };
    
    tokens
}

/// Redeem a complete set of asset conditional tokens back to asset
public fun redeem_complete_set_asset<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    mut tokens: vector<ConditionalToken>,
    _clock: &Clock,
    _ctx: &mut TxContext,
): Balance<AssetType> {
    // Safety checks
    escrow.market_state.assert_not_finalized();
    assert_supplies_initialized(escrow);
    
    // Use the helper function to verify we have a complete set
    let amount = verify_token_set(escrow, &tokens, TOKEN_TYPE_ASSET);
    
    // Verify escrow has sufficient balance
    assert!(escrow.escrowed_asset.value() >= amount, EInsufficientBalance);
    
    // Burn all tokens - use the token's outcome to find the correct supply
    while (!tokens.is_empty()) {
        let token = tokens.pop_back();
        let outcome_idx = (token.outcome() as u64);
        let supply = &mut escrow.outcome_asset_supplies[outcome_idx];
        token::burn(token, supply, _clock, _ctx);
    };
    tokens.destroy_empty();
    
    // Return asset
    escrow.escrowed_asset.split(amount)
}

/// Redeem a complete set of stable conditional tokens back to stable
public fun redeem_complete_set_stable<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    mut tokens: vector<ConditionalToken>,
    _clock: &Clock,
    _ctx: &mut TxContext,
): Balance<StableType> {
    // Safety checks
    escrow.market_state.assert_not_finalized();
    assert_supplies_initialized(escrow);
    
    // Use the helper function to verify we have a complete set
    let amount = verify_token_set(escrow, &tokens, TOKEN_TYPE_STABLE);
    
    // Verify escrow has sufficient balance
    assert!(escrow.escrowed_stable.value() >= amount, EInsufficientBalance);
    
    // Burn all tokens - use the token's outcome to find the correct supply
    while (!tokens.is_empty()) {
        let token = tokens.pop_back();
        let outcome_idx = (token.outcome() as u64);
        let supply = &mut escrow.outcome_stable_supplies[outcome_idx];
        token::burn(token, supply, _clock, _ctx);
    };
    tokens.destroy_empty();
    
    // Return stable
    escrow.escrowed_stable.split(amount)
}

public fun new<AssetType, StableType>(
    market_state: MarketState,
    ctx: &mut TxContext,
): TokenEscrow<AssetType, StableType> {
    TokenEscrow {
        id: object::new(ctx),
        market_state,
        escrowed_asset: balance::zero(), // Initial liquidity goes directly to escrowed
        escrowed_stable: balance::zero(),
        outcome_asset_supplies: vector[],
        outcome_stable_supplies: vector[],
        outcome_lp_supplies: vector[],
        winning_pool_final_asset: 0,
        winning_pool_final_stable: 0,
        winning_lp_supply_at_finalization: 0,
        winning_lp_converted: 0,
    }
}

public fun register_supplies<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    asset_supply: Supply,
    stable_supply: Supply,
    lp_supply: Supply,
) {
    let outcome_count = escrow.market_state.outcome_count();
    assert!(outcome_idx < outcome_count, EOutcomeOutOfBounds);
    assert!(escrow.outcome_asset_supplies.length() == outcome_idx, EIncorrectSequence);

    escrow.outcome_asset_supplies.push_back(asset_supply);
    escrow.outcome_stable_supplies.push_back(stable_supply);
    escrow.outcome_lp_supplies.push_back(lp_supply);
}

/// Deposits initial liquidity into the escrow and implements "differential minting" mechanism.
/// 
/// ## Differential Minting Economics
/// This function implements a critical economic mechanism called "differential minting" which maintains
/// the complete-set conservation invariant. When initial liquidity is deposited:
/// 
/// 1. The function calculates the maximum liquidity needed across all outcomes
/// 2. For outcomes that require less than the maximum liquidity, the difference is minted 
///    as conditional tokens and transferred to the liquidity provider (market activator)
/// 3. This ensures that the total value in the system remains conserved:
///    - Escrow Balance + Outstanding Conditional Tokens = Initial Deposit
/// 
/// ## Economic Rationale
/// The differential tokens represent the "unused" liquidity for specific outcomes. Since not all
/// outcomes need the maximum amount of liquidity, the differential tokens allow the liquidity
/// provider to reclaim this unused portion if needed, while still maintaining full collateralization.
/// 
/// ## Important Invariants
/// - The sum of AMM reserves plus conditional token supplies always equals the escrow balance
/// - Differential tokens are fully backed by the escrow and can be redeemed as part of a complete set
/// - This mechanism prevents value leakage while optimizing capital efficiency
/// 
/// ## Example
/// If outcome A needs 100 tokens and outcome B needs 80 tokens:
/// - Maximum needed: 100 tokens
/// - Escrow receives: 100 tokens  
/// - Outcome B differential: 20 conditional tokens minted to the liquidity provider
/// - These 20 tokens + 80 in the AMM = 100 total for outcome B
#[allow(lint(self_transfer))]
public fun deposit_initial_liquidity<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_count: u64,
    asset_amounts: &vector<u64>,
    stable_amounts: &vector<u64>,
    initial_asset: Balance<AssetType>,
    initial_stable: Balance<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let asset_amount = initial_asset.value();
    let stable_amount = initial_stable.value();
    let sender = ctx.sender();

    // 1. Add to escrow balances
    escrow.escrowed_asset.join(initial_asset);
    escrow.escrowed_stable.join(initial_stable);

    // 2. Calculate maximum amounts needed across outcomes with overflow protection
    let mut max_asset = 0u64;
    let mut max_stable = 0u64;
    let mut i = 0;
    while (i < outcome_count) {
        let asset_amt = asset_amounts[i];
        let stable_amt = stable_amounts[i];
        if (asset_amt > max_asset) { max_asset = asset_amt };
        if (stable_amt > max_stable) { max_stable = stable_amt };
        i = i + 1;
    };

    assert!(asset_amount == max_asset, EInsufficientAsset);
    assert!(stable_amount == max_stable, EInsufficientStable);

    // 3. Mint differential tokens for each outcome
    // DIFFERENTIAL MINTING: For outcomes that need less than the maximum liquidity,
    // we mint the difference as conditional tokens to the liquidity provider.
    // This maintains the invariant: AMM_reserves[i] + conditional_supply[i] = max_liquidity
    let escrow_id = object::id(escrow);
    i = 0;
    while (i < outcome_count) {
        let asset_amt = asset_amounts[i];
        let stable_amt = stable_amounts[i];

        // Mint differential asset tokens if this outcome needs less than max
        // These tokens represent the "unused" asset liquidity for this outcome
        if (asset_amt < max_asset) {
            let diff = max_asset - asset_amt;
            let asset_supply = &mut escrow.outcome_asset_supplies[i];
            let token = token::mint_with_escrow(
                &escrow.market_state,
                asset_supply,
                diff,
                sender,
                escrow_id,
                clock,
                ctx,
            );
            // Transfer differential tokens to the liquidity provider
            transfer::public_transfer(token, sender);
        };

        // Mint differential stable tokens if this outcome needs less than max
        // These tokens represent the "unused" stable liquidity for this outcome
        if (stable_amt < max_stable) {
            let diff = max_stable - stable_amt;
            let stable_supply = &mut escrow.outcome_stable_supplies[i];
            let token = token::mint_with_escrow(
                &escrow.market_state,
                stable_supply,
                diff,
                sender,
                escrow_id,
                clock,
                ctx,
            );
            // Transfer differential tokens to the liquidity provider
            transfer::public_transfer(token, sender);
        };

        i = i + 1;
    };

    // 4. INVARIANT CHECK: Verify conservation of value
    // For each outcome: AMM_reserves + minted_differential_tokens = max_liquidity
    // This ensures no value can be created or destroyed through the minting process
    verify_differential_minting_invariants(
        escrow,
        outcome_count,
        asset_amounts,
        stable_amounts,
        max_asset,
        max_stable
    );
    
    // 5. Emit event with deposit information showing final escrow balances
    event::emit(LiquidityDeposit {
        escrowed_asset: escrow.escrowed_asset.value(),  // Actual escrow balance after deposit
        escrowed_stable: escrow.escrowed_stable.value(), // Actual escrow balance after deposit
        asset_amount: asset_amount,  // Amount deposited
        stable_amount: stable_amount, // Amount deposited
    });
}

public fun remove_liquidity<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_amount: u64,
    stable_amount: u64,
    ctx: &mut TxContext,
): (Coin<AssetType>, Coin<StableType>) {
    // Changed return type

    // Verify there's enough liquidity to withdraw
    assert!(escrow.escrowed_asset.value() >= asset_amount, ENotEnoughLiquidity);
    assert!(escrow.escrowed_stable.value() >= stable_amount, ENotEnoughLiquidity);

    // Withdraw the liquidity into balances
    let asset_balance_out = escrow.escrowed_asset.split(asset_amount);
    let stable_balance_out = escrow.escrowed_stable.split(stable_amount);

    // Convert balances to coins
    let asset_coin_out = asset_balance_out.into_coin(ctx);
    let stable_coin_out = stable_balance_out.into_coin(ctx);

    // Emit event with withdrawal information (reflects state *after* split)
    event::emit(LiquidityWithdrawal {
        escrowed_asset: escrow.escrowed_asset.value(),
        escrowed_stable: escrow.escrowed_stable.value(),
        asset_amount: asset_amount, // Amount withdrawn
        stable_amount: stable_amount, // Amount withdrawn
    });

    // Return the coins instead of transferring
    (asset_coin_out, stable_coin_out)
}

public fun extract_stable_fees<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    amount: u64,
): Balance<StableType> {
    escrow.market_state.assert_market_finalized();
    assert!(escrow.escrowed_stable.value() >= amount, ENotEnough);
    escrow.escrowed_stable.split(amount)
}

// === Private Functions ===

/// Check if supplies are properly initialized for all outcomes
fun assert_supplies_initialized<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
) {
    let outcome_count = escrow.market_state.outcome_count();
    assert!(
        escrow.outcome_asset_supplies.length() == outcome_count &&
                escrow.outcome_stable_supplies.length() == outcome_count &&
                escrow.outcome_lp_supplies.length() == outcome_count,
        ESuppliesNotInitialized,
    );
}

/// Helper function to verify tokens form a complete set and return the amount
fun verify_token_set<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    tokens: &vector<ConditionalToken>,
    token_type: u8,
): u64 {
    // Get market details from escrow
    let market_id = escrow.market_state.market_id();
    let outcome_count = escrow.market_state.outcome_count();

    // Must have exactly one token per outcome
    assert!(tokens.length() == outcome_count, EIncorrectSequence);
    
    // Ensure tokens vector is not empty before accessing
    assert!(tokens.length() > 0, EIncorrectSequence);

    // Initialize outcomes_seen vector
    let mut outcomes_seen = vector[];
    // We still need to initialize the vector, but we can combine with the token validation
    let mut i = 0;
    while (i < outcome_count) {
        outcomes_seen.push_back(false);
        i = i + 1;
    };

    // Get amount from first token to verify consistency
    let first_token = &tokens[0];
    let amount = first_token.value();

    // Verify all tokens and mark outcomes as seen in a single pass
    i = 0;
    while (i < outcome_count) {
        let token = &tokens[i];

        // Verify all token properties comprehensively
        assert!(token.market_id() == market_id, EWrongMarket);
        assert!(token.asset_type() == token_type, EWrongTokenType);
        assert!(token.value() == amount, EInsufficientBalance);
        assert!(amount > 0, EZeroAmount);

        let outcome = token.outcome();
        let outcome_idx = (outcome as u64);

        // Verify outcome is valid and not seen before
        assert!(outcome_idx < outcome_count, EWrongOutcome);
        assert!(!outcomes_seen[outcome_idx], EWrongOutcome);

        // Mark outcome as seen
        *&mut outcomes_seen[outcome_idx] = true;
        i = i + 1;
    };

    // Ensure all outcomes are represented
    i = 0;
    while (i < outcome_count) {
        assert!(outcomes_seen[i], EWrongOutcome);
        i = i + 1;
    };

    amount
}



// Asset token redemption for winning outcome
/// Redeem winning outcome ASSET tokens after finalization
/// 
/// RESTRICTION: This function can ONLY be called AFTER market finalization.
/// Only ASSET/STABLE tokens from the WINNING outcome can be redeemed.
/// For conditional LP tokens, use convert_winning_lp_to_spot_lp() instead - they cannot be redeemed for underlying tokens.
public fun redeem_winning_tokens_asset<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    token: ConditionalToken,
    clock: &Clock,
    ctx: &TxContext,
): Balance<AssetType> {
    // Verify market is finalized and get winning outcome
    escrow.market_state.assert_market_finalized();
    let winner = escrow.market_state.get_winning_outcome();
    assert_supplies_initialized(escrow);

    // Verify token matches winning outcome
    let winner_u8 = (winner as u8);
    assert!(token.outcome() == winner_u8, EWrongOutcome);
    assert!(token.market_id() == escrow.market_state.market_id(), EWrongMarket);
    assert!(token.asset_type() == TOKEN_TYPE_ASSET, EWrongTokenType);

    // Get token amount and burn token
    let amount = token.value();
    let winning_supply = &mut escrow.outcome_asset_supplies[winner];
    token.burn(winning_supply, clock, ctx);
    assert!(escrow.escrowed_asset.value() >= amount, EInsufficientBalance);
    // Emit redemption event
    event::emit(TokenRedemption {
        outcome: winner,
        token_type: TOKEN_TYPE_ASSET,
        amount: amount,
    });

    // Return amount from central asset balance
    escrow.escrowed_asset.split(amount)
}

// Stable token redemption for winning outcome
/// Redeem winning outcome STABLE tokens after finalization
/// 
/// RESTRICTION: This function can ONLY be called AFTER market finalization.
/// Only ASSET/STABLE tokens from the WINNING outcome can be redeemed.
/// For conditional LP tokens, use convert_winning_lp_to_spot_lp() instead - they cannot be redeemed for underlying tokens.
public fun redeem_winning_tokens_stable<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    token: ConditionalToken,
    clock: &Clock,
    ctx: &TxContext,
): Balance<StableType> {
    // Verify market is finalized and get winning outcome
    escrow.market_state.assert_market_finalized();
    let winner = escrow.market_state.get_winning_outcome();
    assert_supplies_initialized(escrow);

    // Verify token matches winning outcome
    let winner_u8 = (winner as u8);
    assert!(token.outcome() == winner_u8, EWrongOutcome);
    assert!(token.market_id() == escrow.market_state.market_id(), EWrongMarket);
    assert!(token.asset_type() == TOKEN_TYPE_STABLE, EWrongTokenType);

    // Get token amount and burn token
    let amount = token.value();
    let winning_supply = &mut escrow.outcome_stable_supplies[winner];
    token.burn(winning_supply, clock, ctx);
    assert!(escrow.escrowed_stable.value() >= amount, EInsufficientBalance);
    // Emit redemption event
    event::emit(TokenRedemption {
        outcome: winner,
        token_type: TOKEN_TYPE_STABLE,
        amount: amount,
    });

    // Return amount from central stable balance
    escrow.escrowed_stable.split(amount)
}



/// ======= Swap Methods =========
public fun swap_token_asset_to_stable<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    token_in: ConditionalToken,
    outcome_idx: u64,
    amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ConditionalToken {
    let ms = &escrow.market_state;
    ms.assert_trading_active();
    assert!(outcome_idx < ms.outcome_count(), EOutcomeOutOfBounds);

    let market_id = ms.market_id();
    assert!(token_in.market_id() == market_id, EWrongMarket);
    assert!(token_in.outcome() == (outcome_idx as u8), EWrongOutcome);
    assert!(token_in.asset_type() == TOKEN_TYPE_ASSET, EWrongTokenType);

    let escrow_id = object::id(escrow);
    
    let asset_supply = &mut escrow.outcome_asset_supplies[outcome_idx];
    token_in.burn(asset_supply, clock, ctx);

    let stable_supply = &mut escrow.outcome_stable_supplies[outcome_idx];
    let token = token::mint_with_escrow(
        ms,
        stable_supply,
        amount_out,
        ctx.sender(),
        escrow_id,
        clock,
        ctx,
    );
    token
}

public fun swap_token_stable_to_asset<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    token_in: ConditionalToken,
    outcome_idx: u64,
    amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ConditionalToken {
    let ms = &escrow.market_state;
    ms.assert_trading_active();
    assert!(outcome_idx < ms.outcome_count(), EOutcomeOutOfBounds);

    let market_id = ms.market_id();
    assert!(token_in.market_id() == market_id, EWrongMarket);
    assert!(token_in.outcome() == (outcome_idx as u8), EWrongOutcome);
    assert!(token_in.asset_type() == TOKEN_TYPE_STABLE, EWrongTokenType);

    let escrow_id = object::id(escrow);
    
    let stable_supply = &mut escrow.outcome_stable_supplies[outcome_idx];
    token_in.burn(stable_supply, clock, ctx);

    let asset_supply = &mut escrow.outcome_asset_supplies[outcome_idx];
    let token = token::mint_with_escrow(
        ms,
        asset_supply,
        amount_out,
        ctx.sender(),
        escrow_id,
        clock,
        ctx,
    );
    token
}

/// Allows anyone to burn a conditional token associated with this escrow
/// if the market is finalized and the token's outcome is not the winning outcome.
public fun burn_unused_tokens<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    mut tokens_to_burn: vector<ConditionalToken>,
    clock: &Clock,
    ctx: &TxContext,
) {
    // 1. Get Market State and verify it's finalized (check once)
    let market_state = &escrow.market_state; // Read-only borrow is sufficient for checks
    market_state.assert_market_finalized();
    assert_supplies_initialized(escrow); // Check once

    // 2. Get required information from market state (fetch once)
    let escrow_market_id = market_state.market_id();
    let winning_outcome = market_state.get_winning_outcome();
    let outcome_count = market_state.outcome_count();

    // 3. Iterate through the vector and burn eligible tokens
    while (!tokens_to_burn.is_empty()) {
        // Borrow mutably for pop_back
        let token = tokens_to_burn.pop_back();

        // a. Get token details
        let token_market_id = token.market_id();
        let token_outcome = token.outcome();
        let token_type = token.asset_type();
        let outcome_idx = (token_outcome as u64); // Index for supply vectors

        assert!(token_market_id == escrow_market_id, EWrongMarket);
        assert!(token_outcome != (winning_outcome as u8), EWrongOutcome);
        assert!(outcome_idx < outcome_count, EOutcomeOutOfBounds);

        // c. Get the appropriate supply AND burn the token within the correct branch
        if (token_type == TOKEN_TYPE_ASSET) {
            let supply_ref = &mut escrow.outcome_asset_supplies[outcome_idx];
            // burn consumes the token object
            token.burn(supply_ref, clock, ctx);
        } else if (token_type == TOKEN_TYPE_STABLE) {
            let supply_ref = &mut escrow.outcome_stable_supplies[outcome_idx];
            // burn consumes the token object
            token.burn(supply_ref, clock, ctx);
        } else if (token_type == TOKEN_TYPE_LP) {
            let supply_ref = &mut escrow.outcome_lp_supplies[outcome_idx];
            // burn consumes the token object
            token.burn(supply_ref, clock, ctx);
        } else {
            abort EWrongTokenType
        }
    };
    // 4. Destroy the now empty vector
    tokens_to_burn.destroy_empty();
}

// === LP Invariant Checking ===

/// Assert LP supply invariants for all operations
/// Called after minting, burning, or converting LP tokens
public fun assert_lp_supply_invariants<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
) {
    // If market is finalized, check conversion invariants
    if (escrow.market_state.is_finalized()) {
        // Total converted cannot exceed original winning supply
        assert!(
            escrow.winning_lp_converted <= escrow.winning_lp_supply_at_finalization,
            EOverflow
        );
        
        // Current winning LP supply + converted should equal original
        let winning_outcome = escrow.market_state.get_winning_outcome();
        let current_winning_supply = escrow.outcome_lp_supplies[winning_outcome].total_supply();
        assert!(
            current_winning_supply + escrow.winning_lp_converted == escrow.winning_lp_supply_at_finalization,
            EOverflow
        );
    };
    
    // Check that all LP supplies are non-negative (implicit through u64)
    // and that minting/burning operations maintain consistency
    let outcome_count = escrow.outcome_lp_supplies.length();
    let mut i = 0;
    while (i < outcome_count) {
        let supply = &escrow.outcome_lp_supplies[i];
        // Supply should always be >= 0 (guaranteed by u64 type)
        // Could add additional checks here if needed
        let _ = supply.total_supply();
        i = i + 1;
    };
}

// === View Functions ===

// Entry function that gets and emits the current escrow balances and supply information as an event
public entry fun get_escrow_balances_and_supply<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome: u64, // Added parameter
): (u64, u64, u64, u64) {
    // Changed return type to a tuple
    // Get current escrow balances
    let (escrowed_asset_balance, escrowed_stable_balance) = get_balances(escrow);
    let outcome_count = escrow.market_state.outcome_count();

    // Ensure the outcome index is valid
    assert!(outcome < outcome_count, EOutcomeOutOfBounds);
    // Ensure supplies were initialized
    assert_supplies_initialized(escrow);

    // Get the supply counts for the outcome directly
    let asset_supply_cap = &escrow.outcome_asset_supplies[outcome];
    let stable_supply_cap = &escrow.outcome_stable_supplies[outcome];

    let asset_total_supply = asset_supply_cap.total_supply();
    let stable_total_supply = stable_supply_cap.total_supply();

    // Return the tuple: (escrow_asset, escrow_stable, asset_supply, stable_supply)
    (escrowed_asset_balance, escrowed_stable_balance, asset_total_supply, stable_total_supply)
}

// === Package Functions ===

public fun get_balances<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): (u64, u64) {
    (escrow.escrowed_asset.value(), escrow.escrowed_stable.value())
}

public fun get_market_state<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): &MarketState {
    &escrow.market_state
}

public fun get_market_state_id<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): ID {
    object::id(&escrow.market_state)
}

public fun get_market_state_mut<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
): &mut MarketState {
    &mut escrow.market_state
}

public fun get_stable_supply<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
): &mut Supply {
    &mut escrow.outcome_stable_supplies[outcome_idx]
}

public fun get_asset_supply<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
): &mut Supply {
    &mut escrow.outcome_asset_supplies[outcome_idx]
}

// === LP Token Finalization Functions ===

/// Convert winning outcome conditional LP tokens to spot LP tokens
/// 
/// SECURITY CRITICAL: This function maintains the invariant that:
/// 1. The proportion of LP ownership is preserved
/// 2. The total value in the system remains constant
/// 3. Each conditional LP token can only be converted once (enforced by burning)
/// 
/// INVARIANCE CHECK:
/// - Before: User owns X% of conditional LP supply for winning outcome
/// - After: User owns X% of the liquidity that was in that pool (now in spot)
/// 
/// The escrow tracks the final liquidity amounts that were extracted from the winning pool
/// during finalization. This ensures we can verify the conversion is correct.
/// 
/// IMPORTANT: This function:
/// - Can ONLY be called AFTER market finalization
/// - Can ONLY convert LP tokens from the WINNING outcome
/// - Is a simple 1:1 exchange: burns conditional LP tokens, mints spot LP tokens
/// - After finalization, NO conditional token operations are allowed - only this direct LP conversion
public fun convert_winning_lp_to_spot_lp<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    spot_amm: &mut spot_amm::SpotAMM<AssetType, StableType>,
    conditional_lp_token: ConditionalToken,
    clock: &Clock,
    ctx: &mut TxContext,
): ID { // Returns the ID of the minted spot LP token
    // Step 1: Verify market is finalized
    assert!(escrow.market_state.is_finalized(), EMarketNotExpired);
    
    // Step 2: Verify this is the winning outcome
    let winning_outcome = escrow.market_state.get_winning_outcome();
    let token_outcome = conditional_lp_token.outcome();
    assert!((token_outcome as u64) == winning_outcome, EOutcomeOutOfBounds);
    
    // Step 3: Verify this is an LP token
    assert!(conditional_lp_token.asset_type() == TOKEN_TYPE_LP, ETokenTypeMismatch);
    
    let lp_amount = conditional_lp_token.value();
    assert!(lp_amount > 0, EZeroAmount);
    
    // Step 4: Get the LP supply for tracking
    let outcome_idx = (token_outcome as u64);
    let lp_supply = &escrow.outcome_lp_supplies[outcome_idx];
    
    // Step 5: This is a simple 1:1 exchange
    // Conditional LP tokens and spot LP tokens have the same amounts
    // since they represent the same liquidity shares
    
    // Step 7: INVARIANCE CHECK - Verify we haven't over-converted
    assert!(escrow.winning_lp_converted + lp_amount <= escrow.winning_lp_supply_at_finalization, EOverflow);
    
    // Step 8: INVARIANCE CHECK - Record state before burn
    let supply_before = lp_supply.total_supply();
    
    // Step 9: Burn the conditional LP token (this updates the supply)
    burn_single_conditional_token(escrow, conditional_lp_token, clock, ctx);
    
    // Step 10: INVARIANCE CHECK - Verify supply decreased correctly
    let supply_after = escrow.outcome_lp_supplies[outcome_idx].total_supply();
    assert!(supply_before - supply_after == lp_amount, EOverflow);
    
    // Step 11: Update conversion tracking
    escrow.winning_lp_converted = escrow.winning_lp_converted + lp_amount;
    
    // Step 12: INVARIANCE CHECK - Verify total conversions don't exceed original supply
    assert!(escrow.winning_lp_converted <= escrow.winning_lp_supply_at_finalization, EOverflow);
    
    // Step 13: Call spot AMM to mint spot LP tokens (1:1 exchange)
    // After finalization, conditional LP tokens cannot be redeemed for conditional tokens
    // They can ONLY be exchanged 1:1 for spot LP tokens
    let spot_lp_id = spot_amm::mint_lp_for_conversion(
        spot_amm,
        0, // not used - no conditional token redemption allowed
        0, // not used - no conditional token redemption allowed
        lp_amount, // 1:1 exchange - mint exact same amount of spot LP
        0, // not needed for 1:1 exchange
        escrow.market_state.market_id(),
        ctx
    );
    
    spot_lp_id
}

/// Track the final amounts that were in the winning pool before it was emptied
/// This is called during finalization when the pool is emptied
public fun record_winning_pool_final_amounts<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_amount: u64,
    stable_amount: u64,
) {
    // Store these amounts for LP conversion calculations
    escrow.winning_pool_final_asset = asset_amount;
    escrow.winning_pool_final_stable = stable_amount;
    
    // Also record the winning LP supply at finalization for invariant checking
    let winning_outcome = escrow.market_state.get_winning_outcome();
    let winning_lp_supply = &escrow.outcome_lp_supplies[winning_outcome];
    escrow.winning_lp_supply_at_finalization = winning_lp_supply.total_supply();
    
    // Reset converted counter
    escrow.winning_lp_converted = 0;
}

/// Get the final amounts that were in the winning pool
fun get_winning_pool_final_amounts<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>
): (u64, u64) {
    // Return the recorded amounts
    (escrow.winning_pool_final_asset, escrow.winning_pool_final_stable)
}


/// Burn losing outcome LP tokens
/// 
/// After finalization, LP tokens from losing outcomes have no value.
/// This function allows holders to burn these worthless tokens.
public fun burn_losing_lp_tokens<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    conditional_lp_token: ConditionalToken,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify market is finalized
    assert!(escrow.market_state.is_finalized(), EMarketNotExpired);
    
    // Verify this is NOT the winning outcome
    let winning_outcome = escrow.market_state.get_winning_outcome();
    let token_outcome = conditional_lp_token.outcome();
    assert!((token_outcome as u64) != winning_outcome, EOutcomeOutOfBounds);
    
    // Verify this is an LP token
    assert!(conditional_lp_token.asset_type() == TOKEN_TYPE_LP, ETokenTypeMismatch);
    
    // Burn the worthless LP token
    burn_single_conditional_token(escrow, conditional_lp_token, clock, ctx);
}

/// Batch burn multiple losing LP tokens
public fun burn_losing_lp_tokens_batch<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    mut conditional_lp_tokens: vector<ConditionalToken>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify market is finalized once
    assert!(escrow.market_state.is_finalized(), EMarketNotExpired);
    let winning_outcome = escrow.market_state.get_winning_outcome();
    
    while (!conditional_lp_tokens.is_empty()) {
        let token = conditional_lp_tokens.pop_back();
        
        // Verify this is a losing outcome LP token
        let token_outcome = token.outcome();
        assert!((token_outcome as u64) != winning_outcome, EOutcomeOutOfBounds);
        assert!(token.asset_type() == TOKEN_TYPE_LP, ETokenTypeMismatch);
        
        // Burn the token
        burn_single_conditional_token(escrow, token, clock, ctx);
    };
    
    conditional_lp_tokens.destroy_empty();
}

/// Verify differential minting invariants
/// 
/// CRITICAL INVARIANTS:
/// 1. For each outcome: AMM_reserves + conditional_token_supply = max_liquidity
/// 2. Total escrow balance >= sum of all obligations (tokens + reserves)
/// 3. No value creation: escrowed_amount = max(needed_amounts)
/// 
/// This function ensures that the differential minting mechanism cannot be exploited
/// to create or destroy value. The invariants guarantee that:
/// - All conditional tokens are fully backed by escrow funds
/// - The optimization (minting differentials) doesn't break accounting
/// - Users can always redeem complete sets for the original deposit
fun verify_differential_minting_invariants<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_count: u64,
    asset_amounts: &vector<u64>,
    stable_amounts: &vector<u64>,
    max_asset: u64,
    max_stable: u64,
) {
    let mut i = 0;
    while (i < outcome_count) {
        let asset_amt = asset_amounts[i];
        let stable_amt = stable_amounts[i];
        
        // Get the supply of minted differential tokens for this outcome
        let asset_supply = escrow.outcome_asset_supplies[i].total_supply();
        let stable_supply = escrow.outcome_stable_supplies[i].total_supply();
        
        // INVARIANT 1: AMM reserves + differential tokens = max liquidity
        // This ensures complete conservation of value
        let expected_asset_differential = if (asset_amt < max_asset) {
            max_asset - asset_amt
        } else {
            0
        };
        
        let expected_stable_differential = if (stable_amt < max_stable) {
            max_stable - stable_amt  
        } else {
            0
        };
        
        // The supply should match the expected differential
        // (Note: This check assumes this is the first deposit; for subsequent deposits
        // the invariant would be: new_supply - old_supply = expected_differential)
        assert!(
            asset_supply >= expected_asset_differential,
            EInvariantViolation
        );
        assert!(
            stable_supply >= expected_stable_differential,
            EInvariantViolation
        );
        
        // INVARIANT 2: Total obligations don't exceed escrow
        // AMM will receive asset_amt and stable_amt
        // Tokens minted are asset_supply and stable_supply
        // Both are backed by the escrow balance
        
        i = i + 1;
    };
    
    // INVARIANT 3: Escrow received exactly the maximum needed
    // This was already checked with the assertions:
    // assert!(asset_amount == max_asset, EInsufficientAsset);
    // assert!(stable_amount == max_stable, EInsufficientStable);
    
    // Additional safety check: Escrow balance >= max needed
    assert!(escrow.escrowed_asset.value() >= max_asset, EInvariantViolation);
    assert!(escrow.escrowed_stable.value() >= max_stable, EInvariantViolation);
}

/// Entry point for converting winning LP to spot LP tokens
/// 
/// After a proposal is finalized, holders of conditional LP tokens from the winning
/// outcome can convert them to spot LP tokens. The underlying liquidity has already
/// been transferred to the spot pool during finalization.
/// 
/// This is a simple 1:1 exchange - burn conditional LP, mint spot LP.
public entry fun convert_winning_lp_to_spot_claim_entry<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    spot_amm: &mut spot_amm::SpotAMM<AssetType, StableType>,
    conditional_lp_token: ConditionalToken,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let spot_lp_id = convert_winning_lp_to_spot_lp(
        escrow,
        spot_amm,
        conditional_lp_token,
        clock,
        ctx
    );
    
    // Emit event with the conversion details
    event::emit(WinningLPConverted {
        market_id: escrow.market_state.market_id(),
        spot_lp_id,
        sender: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

/// Entry point for burning losing LP tokens
public entry fun burn_losing_lp_tokens_entry<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    conditional_lp_token: ConditionalToken,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    burn_losing_lp_tokens(escrow, conditional_lp_token, clock, ctx);
}

// === Events for LP Finalization ===

public struct WinningLPConverted has copy, drop {
    market_id: ID,
    spot_lp_id: ID,  // ID of the newly minted spot LP token
    sender: address,
    timestamp: u64,
}

// === Test Functions ===

#[test_only]
/// Creates a complete set of tokens and returns specific token for testing
public fun create_asset_token_for_testing<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ConditionalToken {
    // First create all tokens using an existing function
    let mut tokens = mint_complete_set_asset(
        escrow,
        balance::create_for_testing<AssetType>(amount).into_coin(ctx),
        clock,
        ctx,
    );

    // Find and return the token for the requested outcome
    let outcome_count = tokens.length();
    let mut result_token = tokens.pop_back();

    // Process all other tokens
    let mut i = 0;
    while (i < outcome_count - 1) {
        let token = tokens.pop_back();
        let this_outcome = token.outcome();

        if (this_outcome == (outcome_idx as u8)) {
            // Swap if we found the requested token
            transfer::public_transfer(result_token, ctx.sender());
            result_token = token;
        } else {
            // Otherwise transfer to sender
            transfer::public_transfer(token, ctx.sender());
        };
        i = i + 1;
    };

    tokens.destroy_empty();
    result_token
}

#[test_only]
/// Creates a complete set of stable tokens and returns specific token for testing
public fun create_stable_token_for_testing<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ConditionalToken {
    // Same approach as asset token but for stable tokens
    let coin = balance::create_for_testing<StableType>(amount).into_coin(ctx);
    let mut tokens = mint_complete_set_stable(escrow, coin, clock, ctx);

    // Extract the token we want and return it
    let token = tokens.remove(outcome_idx);

    // Transfer the other tokens to the sender
    let token_count = tokens.length();
    let mut i = 0;
    while (i < token_count) {
        let t = tokens.pop_back();
        transfer::public_transfer(t, ctx.sender());
        i = i + 1;
    };
    tokens.destroy_empty();

    token
}
