module futarchy::conditional_token;

use futarchy::market_state;
use sui::clock::{Self, Clock};
use sui::event;

// === Introduction ===
// This is an implementation of a custom psuedo coin.
// New coins (types) can't be created dynamically in Move

// Long term using a table will likely be more scalable
// market_amounts: Table<(ID, ID), Table<address, u64>>,

// === Errors ===
const EINVALID_ASSET_TYPE: u64 = 0;
const EWRONG_MARKET: u64 = 1;
const EWRONG_TOKEN_TYPE: u64 = 2;
const EWRONG_OUTCOME: u64 = 3;
const EZERO_AMOUNT: u64 = 4;
const EINSUFFICIENT_BALANCE: u64 = 5;
const EEMPTY_VECTOR: u64 = 6;
const ENO_TOKEN_FOUND: u64 = 7;
const ENONZERO_BALANCE: u64 = 8;

// === Structs ===
// Supply tracking object for a specific conditional token type
public struct Supply has key, store {
    id: UID,
    market_id: ID,
    asset_type: u8,
    outcome: u8,
    total_supply: u64,
}

// The conditional token itself
public struct ConditionalToken has key, store {
    id: UID,
    market_id: ID,
    asset_type: u8, // 0 for asset, 1 for stable
    outcome: u8, // outcome index
    balance: u64,
}

// === Events ===
public struct TokenMinted has copy, drop {
    id: ID,
    market_id: ID,
    asset_type: u8,
    outcome: u8,
    amount: u64,
    recipient: address,
    timestamp: u64,
}

public struct TokenBurned has copy, drop {
    id: ID,
    market_id: ID,
    asset_type: u8,
    outcome: u8,
    amount: u64,
    sender: address,
    timestamp: u64,
}

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

// ======== Supply Functions ========
public(package) fun new_supply(
    state: &market_state::MarketState,
    asset_type: u8,
    outcome: u8,
    ctx: &mut TxContext,
): Supply {
    // Verify authority and market state
    market_state::validate_outcome(state, (outcome as u64));
    assert!(asset_type <= 1, EINVALID_ASSET_TYPE);

    Supply {
        id: object::new(ctx),
        market_id: market_state::market_id(state),
        asset_type,
        outcome,
        total_supply: 0,
    }
}

public(package) fun update_supply(supply: &mut Supply, amount: u64, increase: bool) {
    assert!(amount > 0, EZERO_AMOUNT);
    if (increase) {
        supply.total_supply = supply.total_supply + amount;
    } else {
        assert!(supply.total_supply >= amount, EINSUFFICIENT_BALANCE);
        supply.total_supply = supply.total_supply - amount;
    };
}

// ======== Token Functions ========
// Destroys a ConditionalToken. The token's balance must be zero.
public(package) fun destroy(token: ConditionalToken) {
    let ConditionalToken { id, market_id: _, asset_type: _, outcome: _, balance } = token;
    assert!(balance == 0, ENONZERO_BALANCE);
    object::delete(id);
}

public(package) fun split(
    token: &mut ConditionalToken,
    amount: u64,
    recipient: address,
    clock: &Clock, // new parameter
    ctx: &mut TxContext,
) {
    assert!(amount > 0, EZERO_AMOUNT);
    assert!(token.balance >= amount, EINSUFFICIENT_BALANCE);

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
        original_token_id: object::uid_to_inner(&token.id),
        new_token_id: object::id(&new_token),
        market_id: token.market_id,
        asset_type: token.asset_type,
        outcome: token.outcome,
        original_amount: token.balance,
        split_amount: amount,
        owner: recipient,
        timestamp: clock::timestamp_ms(clock),
    });

    transfer::transfer(new_token, recipient);
}

public entry fun split_entry(
    token: &mut ConditionalToken,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let sender = tx_context::sender(ctx);
    split(token, amount, sender, clock, ctx);
}

public(package) fun merge_many(
    base_token: &mut ConditionalToken,
    mut tokens: vector<ConditionalToken>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let len = vector::length(&tokens);
    assert!(len > 0, EEMPTY_VECTOR);

    let mut i = 0;
    let mut total_merged_amount = 0;
    let mut token_ids = vector::empty();

    while (i < len) {
        let token = vector::remove(&mut tokens, 0);
        // Verify token matches
        assert!(token.market_id == base_token.market_id, EWRONG_MARKET);
        assert!(token.asset_type == base_token.asset_type, EWRONG_TOKEN_TYPE);
        assert!(token.outcome == base_token.outcome, EWRONG_OUTCOME);

        vector::push_back(&mut token_ids, object::id(&token));
        total_merged_amount = total_merged_amount + token.balance;

        let ConditionalToken {
            id,
            market_id: _,
            asset_type: _,
            outcome: _,
            balance,
        } = token;

        base_token.balance = base_token.balance + balance;
        object::delete(id);
        i = i + 1;
    };

    // Emit merge event with all token IDs
    event::emit(TokenMergeMany {
        base_token_id: object::uid_to_inner(&base_token.id),
        merged_token_ids: token_ids,
        market_id: base_token.market_id,
        asset_type: base_token.asset_type,
        outcome: base_token.outcome,
        base_amount: base_token.balance - total_merged_amount,
        merged_amount: total_merged_amount,
        owner: tx_context::sender(ctx),
        timestamp: clock::timestamp_ms(clock),
    });

    vector::destroy_empty(tokens);
}

public entry fun merge_many_entry(
    base_token: &mut ConditionalToken,
    tokens: vector<ConditionalToken>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    merge_many(base_token, tokens, clock, ctx);
}

public(package) fun burn(
    supply: &mut Supply,
    token: ConditionalToken,
    clock: &Clock,
    ctx: &TxContext,
) {
    // Verify token matches supply
    assert!(token.market_id == supply.market_id, EWRONG_MARKET);
    assert!(token.asset_type == supply.asset_type, EWRONG_TOKEN_TYPE);
    assert!(token.outcome == supply.outcome, EWRONG_OUTCOME);

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
        id: object::uid_to_inner(&id), // Convert UID to ID
        market_id,
        asset_type,
        outcome,
        amount: balance,
        sender: tx_context::sender(ctx),
        timestamp: clock::timestamp_ms(clock),
    });

    // Clean up
    object::delete(id);
}

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
    assert!(amount > 0, EZERO_AMOUNT);

    assert!(market_state::market_id(state) == supply.market_id, EWRONG_MARKET);
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
        timestamp: clock::timestamp_ms(clock),
    });

    // Return token instead of transferring
    token
}

public(package) fun extract(option: &mut Option<ConditionalToken>): ConditionalToken {
    assert!(option::is_some(option), ENO_TOKEN_FOUND);
    let token = option::extract(option);
    token
}

// === Getters ===

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
