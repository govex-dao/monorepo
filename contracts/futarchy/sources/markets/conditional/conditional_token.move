module futarchy::conditional_token;

use futarchy::market_state;
use sui::clock::Clock;
use sui::event;

// === Introduction ===
// This module implements conditional tokens for prediction markets.
// Conditional tokens represent claims on specific outcomes in a futarchy proposal.
//
// === Live-Flow Model Integration ===
// Conditional tokens are central to the live-flow liquidity model:
// - Each outcome has two token types: asset-based and stable-based
// - Tokens can only be minted in "complete sets" (all outcomes together)
// - Complete sets can be redeemed back to spot tokens at any time
// - This ensures conservation of value: 1 spot token = 1 complete set
//
// The key innovation is that these tokens trade in outcome-specific AMMs,
// while LPs interact only with spot tokens, with automatic conversion handled
// by the protocol.

// === Constants ===
const TOKEN_TYPE_ASSET: u8 = 0;
const TOKEN_TYPE_STABLE: u8 = 1;
const TOKEN_TYPE_LP: u8 = 2;

// === Errors ===
const EInvalidAssetType: u64 = 0; // Asset type must be 0 (asset), 1 (stable), or 2 (LP)
const EWrongMarket: u64 = 1; // Token doesn't belong to expected market
const EWrongTokenType: u64 = 2; // Wrong token type for operation
const EWrongOutcome: u64 = 3; // Token outcome doesn't match expected
const EZeroAmount: u64 = 4; // Amount must be greater than zero
const EInsufficientBalance: u64 = 5; // Insufficient token balance
const EEmptyVector: u64 = 6; // Vector is empty when it shouldn't be
const ENoTokenFound: u64 = 7; // Expected token not found in Option
const ENonzeroBalance: u64 = 8; // Token must have zero balance to destroy

// === Structs ===
/// Supply tracking object for a specific conditional token type.
/// Total supply is tracked to aid with testing, it is not a source of truth. Token balances are the source of truth.
public struct Supply has key, store {
    id: UID,
    market_id: ID,
    asset_type: u8,
    outcome: u8,
    total_supply: u64,
}

/// The conditional token representing a position in a prediction market
public struct ConditionalToken has key, store {
    id: UID,
    market_id: ID,
    asset_type: u8, // 0 for asset, 1 for stable, 2 for LP
    outcome: u8, // outcome index
    balance: u64,
    escrow_id: Option<ID>, // Optional escrow ID for auto-reclaim
}

// === Events ===
/// Event emitted when tokens are minted
public struct TokenMinted has copy, drop {
    id: ID,
    market_id: ID,
    asset_type: u8,
    outcome: u8,
    amount: u64,
    recipient: address,
    timestamp: u64,
}

/// Event emitted when tokens are burned
public struct TokenBurned has copy, drop {
    id: ID,
    market_id: ID,
    asset_type: u8,
    outcome: u8,
    amount: u64,
    sender: address,
    timestamp: u64,
}

/// Event emitted when a token is split
public struct TokenSplit has copy, drop {
    original_token_id: ID,
    new_token_id: ID,
    market_id: ID,
    asset_type: u8,
    outcome: u8,
    original_amount: u64,
    split_amount: u64,
    owner: address,
    timestamp: u64,
}

/// Event emitted when multiple tokens are merged
public struct TokenMergeMany has copy, drop {
    base_token_id: ID,
    merged_token_ids: vector<ID>,
    market_id: ID,
    asset_type: u8,
    outcome: u8,
    base_amount: u64,
    merged_amount: u64,
    owner: address,
    timestamp: u64,
}

// === Package Functions ===
/// Create a new supply tracker for a specific conditional token type
public(package) fun new_supply(
    state: &market_state::MarketState,
    asset_type: u8,
    outcome: u8,
    ctx: &mut TxContext,
): Supply {
    // Verify authority and market state
    state.validate_outcome((outcome as u64));
    assert!(asset_type <= 2, EInvalidAssetType);

    Supply {
        id: object::new(ctx),
        market_id: state.market_id(),
        asset_type,
        outcome,
        total_supply: 0,
    }
}

/// Update the total supply by increasing or decreasing the amount
public(package) fun update_supply(supply: &mut Supply, amount: u64, increase: bool) {
    assert!(amount > 0, EZeroAmount);
    if (increase) {
        supply.total_supply = supply.total_supply + amount;
    } else {
        assert!(supply.total_supply >= amount, EInsufficientBalance);
        supply.total_supply = supply.total_supply - amount;
    };
}

/// Destroys a ConditionalToken. The token's balance must be zero.
public(package) fun destroy(token: ConditionalToken) {
    let ConditionalToken { id, market_id: _, asset_type: _, outcome: _, balance, escrow_id: _ } = token;
    assert!(balance == 0, ENonzeroBalance);
    id.delete();
}

/// Split a conditional token into two parts, transferring the split amount to a recipient
public(package) fun split(
    token: &mut ConditionalToken,
    amount: u64,
    recipient: address,
    clock: &Clock, // new parameter
    ctx: &mut TxContext,
) {
    assert!(amount > 0, EZeroAmount);
    assert!(token.balance > amount, EInsufficientBalance);

    token.balance = token.balance - amount;

    let new_token = ConditionalToken {
        id: object::new(ctx),
        market_id: token.market_id,
        asset_type: token.asset_type,
        outcome: token.outcome,
        balance: amount,
        escrow_id: token.escrow_id,
    };

    // Emit split event
    event::emit(TokenSplit {
        original_token_id: token.id.to_inner(),
        new_token_id: object::id(&new_token),
        market_id: token.market_id,
        asset_type: token.asset_type,
        outcome: token.outcome,
        original_amount: token.balance,
        split_amount: amount,
        owner: recipient,
        timestamp: clock.timestamp_ms(),
    });

    transfer::transfer(new_token, recipient);
}

/// Split a conditional token and return the new token instead of transferring it
/// This is useful when the caller needs to process the split token further
public(package) fun split_and_return(
    token: &mut ConditionalToken,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ConditionalToken {
    assert!(amount > 0, EZeroAmount);
    assert!(token.balance > amount, EInsufficientBalance);

    token.balance = token.balance - amount;

    let new_token = ConditionalToken {
        id: object::new(ctx),
        market_id: token.market_id,
        asset_type: token.asset_type,
        outcome: token.outcome,
        balance: amount,
        escrow_id: token.escrow_id,
    };

    // Emit split event
    event::emit(TokenSplit {
        original_token_id: token.id.to_inner(),
        new_token_id: object::id(&new_token),
        market_id: token.market_id,
        asset_type: token.asset_type,
        outcome: token.outcome,
        original_amount: token.balance,
        split_amount: amount,
        owner: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });

    new_token
}

/// Split tokens for the sender
entry fun split_entry(
    token: &mut ConditionalToken,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let sender = ctx.sender();
    split(token, amount, sender, clock, ctx);
}

/// Merge multiple conditional tokens of the same type into the base token
public(package) fun merge_many(
    base_token: &mut ConditionalToken,
    mut tokens: vector<ConditionalToken>,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(!tokens.is_empty(), EEmptyVector);

    let mut total_merged_amount = 0;
    let mut token_ids = vector[];
    // Iterate by popping from the end - O(1) operation per element
    while (!tokens.is_empty()) {
        // Remove the last token from the vector
        let token = tokens.pop_back();
        // Verify token matches
        assert!(token.market_id == base_token.market_id, EWrongMarket);
        assert!(token.asset_type == base_token.asset_type, EWrongTokenType);
        assert!(token.outcome == base_token.outcome, EWrongOutcome);

        let merged_token_object_id = object::id(&token);

        let ConditionalToken {
            id,
            market_id: _,
            asset_type: _,
            outcome: _,
            balance,
            escrow_id: _,
        } = token;

        // Add to totals and the ID list
        token_ids.push_back(merged_token_object_id);
        total_merged_amount = total_merged_amount + balance;

        base_token.balance = base_token.balance + balance;
        id.delete();
    };

    // Emit merge event with all token IDs
    event::emit(TokenMergeMany {
        base_token_id: base_token.id.to_inner(),
        merged_token_ids: token_ids,
        market_id: base_token.market_id,
        asset_type: base_token.asset_type,
        outcome: base_token.outcome,
        base_amount: base_token.balance - total_merged_amount,
        merged_amount: total_merged_amount,
        owner: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });

    tokens.destroy_empty();
}

/// Merge multiple tokens for the sender
entry fun merge_many_entry(
    base_token: &mut ConditionalToken,
    tokens: vector<ConditionalToken>,
    clock: &Clock,
    ctx: &TxContext,
) {
    merge_many(base_token, tokens, clock, ctx);
}

/// Burn a conditional token and update the supply tracker
public(package) fun burn(
    token: ConditionalToken,
    supply: &mut Supply,
    clock: &Clock,
    ctx: &TxContext,
) {
    // Verify token matches supply
    assert!(token.market_id == supply.market_id, EWrongMarket);
    assert!(token.asset_type == supply.asset_type, EWrongTokenType);
    assert!(token.outcome == supply.outcome, EWrongOutcome);

    let ConditionalToken {
        id,
        market_id,
        asset_type,
        outcome,
        balance,
        escrow_id: _,
    } = token;

    // Update supply
    update_supply(supply, balance, false);

    // Emit event
    event::emit(TokenBurned {
        id: id.to_inner(),
        market_id,
        asset_type,
        outcome,
        amount: balance,
        sender: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });

    // Clean up
    id.delete();
}

/// Mint new conditional tokens and update the supply tracker
public(package) fun mint(
    state: &market_state::MarketState,
    supply: &mut Supply,
    amount: u64,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
): ConditionalToken {
    // Verify market state and trading period
    market_state::assert_in_trading_or_pre_trading(state);
    assert!(amount > 0, EZeroAmount);

    assert!(state.market_id() == supply.market_id, EWrongMarket);
    // Update supply
    update_supply(supply, amount, true);

    // Create new token
    let token = ConditionalToken {
        id: object::new(ctx),
        market_id: supply.market_id,
        asset_type: supply.asset_type,
        outcome: supply.outcome,
        balance: amount,
        escrow_id: option::none(),
    };

    // Emit event
    event::emit(TokenMinted {
        id: object::id(&token),
        market_id: supply.market_id,
        asset_type: supply.asset_type,
        outcome: supply.outcome,
        amount,
        recipient,
        timestamp: clock.timestamp_ms(),
    });

    // Return token instead of transferring
    token
}

/// Extract a conditional token from an Option, asserting it exists
public(package) fun extract(option: &mut Option<ConditionalToken>): ConditionalToken {
    assert!(option.is_some(), ENoTokenFound);
    let token = option.extract();
    token
}


// === View Functions ===

public fun market_id(token: &ConditionalToken): ID {
    token.market_id
}

public fun asset_type(token: &ConditionalToken): u8 {
    token.asset_type
}

public fun outcome(token: &ConditionalToken): u8 {
    token.outcome
}

public fun value(token: &ConditionalToken): u64 {
    token.balance
}

public fun escrow_id(token: &ConditionalToken): Option<ID> {
    token.escrow_id
}

public fun total_supply(supply: &Supply): u64 {
    supply.total_supply
}

// === Package Functions for Escrow Management ===

/// Set the escrow ID for a conditional token (can only be set once)
public(package) fun set_escrow_id(token: &mut ConditionalToken, escrow_id: ID) {
    assert!(token.escrow_id.is_none(), 0); // Can only set once
    token.escrow_id = option::some(escrow_id);
}

/// Create a token with a specific escrow ID
public(package) fun mint_with_escrow(
    state: &market_state::MarketState,
    supply: &mut Supply,
    amount: u64,
    recipient: address,
    escrow_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
): ConditionalToken {
    // Verify market state and trading period
    market_state::assert_in_trading_or_pre_trading(state);
    assert!(amount > 0, EZeroAmount);

    assert!(state.market_id() == supply.market_id, EWrongMarket);
    // Update supply
    update_supply(supply, amount, true);

    // Create new token with escrow ID
    let token = ConditionalToken {
        id: object::new(ctx),
        market_id: supply.market_id,
        asset_type: supply.asset_type,
        outcome: supply.outcome,
        balance: amount,
        escrow_id: option::some(escrow_id),
    };

    // Emit event
    event::emit(TokenMinted {
        id: object::id(&token),
        market_id: supply.market_id,
        asset_type: supply.asset_type,
        outcome: supply.outcome,
        amount,
        recipient,
        timestamp: clock.timestamp_ms(),
    });

    // Return token instead of transferring
    token
}

// === Test Functions ===

#[test_only]
/// Creates a ConditionalToken with specified values for testing purposes.
/// This function bypasses normal validation checks and is only available in test code.
public fun mint_for_testing(
    market_id: ID,
    asset_type: u8,
    outcome: u8,
    balance: u64,
    ctx: &mut TxContext,
): ConditionalToken {
    ConditionalToken {
        id: object::new(ctx),
        market_id,
        asset_type,
        outcome,
        balance,
        escrow_id: option::none(),
    }
}
