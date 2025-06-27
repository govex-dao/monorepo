module futarchy::conditional_token;

use futarchy::market_state;
use sui::clock::Clock;
use sui::event;

// === Introduction ===
// This is an implementation of a custom psuedo coin.
// New coins (types) can't be created dynamically in Move

// Long term using a table will likely be more scalable
// market_amounts: Table<(ID, ID), Table<address, u64>>,

// === Errors ===
const EInvalidAssetType: u64 = 0;
const EWrongMarket: u64 = 1;
const EWrongTokenType: u64 = 2;
const EWrongOutcome: u64 = 3;
const EZeroAmount: u64 = 4;
const EInsufficientBalance: u64 = 5;
const EEmptyVector: u64 = 6;
const ENoTokenFound: u64 = 7;
const ENonzeroBalance: u64 = 8;

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
    asset_type: u8, // 0 for asset, 1 for stable
    outcome: u8, // outcome index
    balance: u64,
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
    assert!(asset_type <= 1, EInvalidAssetType);

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
    let ConditionalToken { id, market_id: _, asset_type: _, outcome: _, balance } = token;
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

public fun total_supply(supply: &Supply): u64 {
    supply.total_supply
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
    }
}
