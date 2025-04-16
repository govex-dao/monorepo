module futarchy::coin_escrow;

use futarchy::conditional_token::{Self as token, ConditionalToken, Supply};
use futarchy::market_state::{Self, MarketState};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;

// === Introduction ===
// Tracks and stores coins

// === Errors ===
const EINSUFFICIENT_BALANCE: u64 = 0;
const EINCORRECT_SEQUENCE: u64 = 1;
const EWRONG_MARKET: u64 = 2;
const EWRONG_TOKEN_TYPE: u64 = 3;
const ESUPPLIES_NOT_INITIALIZED: u64 = 4;
const EOUTCOME_OUT_OF_BOUNDS: u64 = 5;
const EWRONG_OUTCOME: u64 = 6;
const ENOT_ENOUGH: u64 = 7;
const ENOT_ENOUGH_LIQUIDITY: u64 = 8;

// === Constants ===
const TOKEN_TYPE_STABLE: u8 = 1;
const TOKEN_TYPE_ASSET: u8 = 0;

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
}

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

// === Public Functions ===
public(package) fun new<AssetType, StableType>(
    market_state: MarketState,
    ctx: &mut TxContext,
): TokenEscrow<AssetType, StableType> {
    TokenEscrow {
        id: object::new(ctx),
        market_state,
        escrowed_asset: balance::zero(), // Initial liquidity goes directly to escrowed
        escrowed_stable: balance::zero(),
        outcome_asset_supplies: vector::empty(),
        outcome_stable_supplies: vector::empty(),
    }
}

public(package) fun register_supplies<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    asset_supply: Supply,
    stable_supply: Supply,
) {
    let outcome_count = market_state::outcome_count(&escrow.market_state);
    assert!(outcome_idx < outcome_count, EOUTCOME_OUT_OF_BOUNDS);
    assert!(vector::length(&escrow.outcome_asset_supplies) == outcome_idx, EINCORRECT_SEQUENCE);

    vector::push_back(&mut escrow.outcome_asset_supplies, asset_supply);
    vector::push_back(&mut escrow.outcome_stable_supplies, stable_supply);
}

#[allow(lint(self_transfer))]
public(package) fun deposit_initial_liquidity<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_count: u64,
    asset_amounts: &vector<u64>,
    stable_amounts: &vector<u64>,
    initial_asset: Balance<AssetType>,
    initial_stable: Balance<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let asset_amount = balance::value(&initial_asset);
    let stable_amount = balance::value(&initial_stable);
    let sender = tx_context::sender(ctx);

    // 1. Add to escrow balances
    balance::join(&mut escrow.escrowed_asset, initial_asset);
    balance::join(&mut escrow.escrowed_stable, initial_stable);

    // 2. Calculate maximum amounts needed across outcomes
    let mut max_asset = 0;
    let mut max_stable = 0;
    let mut i = 0;
    while (i < outcome_count) {
        let asset_amt = *vector::borrow(asset_amounts, i);
        let stable_amt = *vector::borrow(stable_amounts, i);
        if (asset_amt > max_asset) { max_asset = asset_amt };
        if (stable_amt > max_stable) { max_stable = stable_amt };
        i = i + 1;
    };

    // 3. Mint differential tokens for each outcome
    i = 0;
    while (i < outcome_count) {
        let asset_amt = *vector::borrow(asset_amounts, i);
        let stable_amt = *vector::borrow(stable_amounts, i);

        // Mint asset tokens if necessary
        if (asset_amt < max_asset) {
            let diff = max_asset - asset_amt;
            let asset_supply = vector::borrow_mut(&mut escrow.outcome_asset_supplies, i);
            let token = token::mint(
                &escrow.market_state,
                asset_supply,
                diff,
                sender,
                clock,
                ctx,
            );
            transfer::public_transfer(token, sender);
        };

        // Mint stable tokens if necessary
        if (stable_amt < max_stable) {
            let diff = max_stable - stable_amt;
            let stable_supply = vector::borrow_mut(&mut escrow.outcome_stable_supplies, i);
            let token = token::mint(
                &escrow.market_state,
                stable_supply,
                diff,
                sender,
                clock,
                ctx,
            );
            transfer::public_transfer(token, sender);
        };

        i = i + 1;
    };

    // 4. Emit event with deposit information
    event::emit(LiquidityDeposit {
        escrowed_asset: asset_amount,
        escrowed_stable: stable_amount,
        asset_amount: asset_amount,
        stable_amount: stable_amount,
    });
}

// TODO: This implementation has known atomicity issues and will be refactored in v2
// Current risk is mitigated by restricted access controls
#[allow(lint(self_transfer))]
public fun remove_liquidity<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    asset_amount: u64,
    stable_amount: u64,
    ctx: &mut TxContext,
) {
    let sender = tx_context::sender(ctx);

    // Verify there's enough liquidity to withdraw
    assert!(balance::value(&escrow.escrowed_asset) >= asset_amount, ENOT_ENOUGH_LIQUIDITY);
    assert!(balance::value(&escrow.escrowed_stable) >= stable_amount, ENOT_ENOUGH_LIQUIDITY);

    // Withdraw the liquidity
    let asset_coin = coin::from_balance(
        balance::split<AssetType>(&mut escrow.escrowed_asset, asset_amount),
        ctx,
    );
    let stable_coin = coin::from_balance(
        balance::split<StableType>(&mut escrow.escrowed_stable, stable_amount),
        ctx,
    );

    // Transfer coins back to sender
    transfer::public_transfer(asset_coin, sender);
    transfer::public_transfer(stable_coin, sender);

    // Emit event with withdrawal information
    event::emit(LiquidityWithdrawal {
        escrowed_asset: balance::value(&escrow.escrowed_asset),
        escrowed_stable: balance::value(&escrow.escrowed_stable),
        asset_amount: asset_amount,
        stable_amount: stable_amount,
    });
}

// TODO: This implementation has known atomicity issues and will be refactored in v2
// Current risk is mitigated by restricted access controls
public(package) fun extract_stable_fees<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    amount: u64,
): Balance<StableType> {
    assert!(balance::value(&escrow.escrowed_stable) >= amount, ENOT_ENOUGH);
    balance::split(&mut escrow.escrowed_stable, amount)
}

/// Check if supplies are properly initialized for all outcomes
fun assert_supplies_initialized<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
) {
    let outcome_count = market_state::outcome_count(&escrow.market_state);
    assert!(
        vector::length(&escrow.outcome_asset_supplies) == outcome_count &&
                vector::length(&escrow.outcome_stable_supplies) == outcome_count,
        ESUPPLIES_NOT_INITIALIZED,
    );
}

/// Helper function to verify tokens form a complete set and return the amount
fun verify_token_set<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
    tokens: &vector<ConditionalToken>,
    token_type: u8,
): u64 {
    // Get market details from escrow
    let market_id = market_state::market_id(&escrow.market_state);
    let outcome_count = market_state::outcome_count(&escrow.market_state);

    // Must have exactly one token per outcome
    assert!(vector::length(tokens) == outcome_count, EINCORRECT_SEQUENCE);

    // Check first token for basic validation
    let first_token = vector::borrow(tokens, 0);
    assert!(token::market_id(first_token) == market_id, EWRONG_MARKET);
    assert!(token::asset_type(first_token) == token_type, EWRONG_TOKEN_TYPE);
    let amount = token::value(first_token);

    // Track which outcomes we've seen
    let mut outcomes_seen = vector::empty<bool>();
    let mut i = 0;
    while (i < outcome_count) {
        vector::push_back(&mut outcomes_seen, false);
        i = i + 1;
    };

    // Verify all tokens and mark outcomes as seen
    i = 0;
    while (i < outcome_count) {
        let token = vector::borrow(tokens, i);

        // Verify token properties
        assert!(token::market_id(token) == market_id, EWRONG_MARKET);
        assert!(token::asset_type(token) == token_type, EWRONG_TOKEN_TYPE);
        assert!(token::value(token) == amount, EINSUFFICIENT_BALANCE);

        let outcome = token::outcome(token);
        let outcome_idx = (outcome as u64);

        // Verify outcome is valid and not seen before
        assert!(outcome_idx < outcome_count, EWRONG_OUTCOME);
        assert!(!*vector::borrow(&outcomes_seen, outcome_idx), EWRONG_OUTCOME);

        // Mark outcome as seen
        *vector::borrow_mut(&mut outcomes_seen, outcome_idx) = true;
        i = i + 1;
    };

    // Ensure all outcomes are represented
    i = 0;
    while (i < outcome_count) {
        assert!(*vector::borrow(&outcomes_seen, i), EWRONG_OUTCOME);
        i = i + 1;
    };

    amount
}

// Asset token redemption implementation
public(package) fun redeem_complete_set_asset<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    mut tokens: vector<ConditionalToken>,
    clock: &Clock,
    ctx: &mut TxContext,
): Balance<AssetType> {
    market_state::assert_not_finalized(&escrow.market_state);
    assert_supplies_initialized(escrow);

    // Verify tokens form a complete set and get common amount
    let amount = verify_token_set(escrow, &tokens, TOKEN_TYPE_ASSET);

    // Burn all tokens
    let outcome_count = market_state::outcome_count(&escrow.market_state);
    let mut i = 0;
    while (i < outcome_count) {
        let token = vector::pop_back(&mut tokens);
        let outcome = token::outcome(&token);
        let supply = vector::borrow_mut(&mut escrow.outcome_asset_supplies, (outcome as u64));
        token::burn(supply, token, clock, ctx);
        i = i + 1;
    };

    vector::destroy_empty(tokens);

    // Return the redeemed assets
    balance::split(&mut escrow.escrowed_asset, amount)
}

// Stable token redemption implementation
public(package) fun redeem_complete_set_stable<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    mut tokens: vector<ConditionalToken>,
    clock: &Clock,
    ctx: &mut TxContext,
): Balance<StableType> {
    market_state::assert_not_finalized(&escrow.market_state);
    assert_supplies_initialized(escrow);

    // Verify tokens form a complete set and get common amount
    let amount = verify_token_set(escrow, &tokens, TOKEN_TYPE_STABLE);

    // Burn all tokens
    let outcome_count = market_state::outcome_count(&escrow.market_state);
    let mut i = 0;
    while (i < outcome_count) {
        let token = vector::pop_back(&mut tokens);
        let outcome = token::outcome(&token);
        let supply = vector::borrow_mut(&mut escrow.outcome_stable_supplies, (outcome as u64));
        token::burn(supply, token, clock, ctx);
        i = i + 1;
    };

    vector::destroy_empty(tokens);

    // Return the redeemed stable tokens
    balance::split(&mut escrow.escrowed_stable, amount)
}

// Entry function for asset redemption
public entry fun redeem_complete_set_asset_entry<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    tokens: vector<ConditionalToken>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let balance = redeem_complete_set_asset(escrow, tokens, clock, ctx);
    let coin = coin::from_balance(balance, ctx);
    transfer::public_transfer(coin, tx_context::sender(ctx));
}

// Entry function for stable redemption
public entry fun redeem_complete_set_stable_entry<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    tokens: vector<ConditionalToken>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let balance = redeem_complete_set_stable(escrow, tokens, clock, ctx);
    let coin = coin::from_balance(balance, ctx);
    transfer::public_transfer(coin, tx_context::sender(ctx));
}

// Asset token redemption for winning outcome
public(package) fun redeem_winning_tokens_asset<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    token: ConditionalToken,
    clock: &Clock,
    ctx: &mut TxContext,
): Balance<AssetType> {
    // Verify market is finalized and get winning outcome
    market_state::assert_market_finalized(&escrow.market_state);
    let winner = market_state::get_winning_outcome(&escrow.market_state);
    assert_supplies_initialized(escrow);

    // Verify token matches winning outcome
    let winner_u8 = (winner as u8);
    assert!(token::outcome(&token) == winner_u8, EWRONG_OUTCOME);
    assert!(
        token::market_id(&token) == market_state::market_id(&escrow.market_state),
        EWRONG_MARKET,
    );
    assert!(token::asset_type(&token) == TOKEN_TYPE_ASSET, EWRONG_TOKEN_TYPE);

    // Get token amount and burn token
    let amount = token::value(&token);
    let winning_supply = vector::borrow_mut(&mut escrow.outcome_asset_supplies, winner);
    token::burn(winning_supply, token, clock, ctx);

    // Emit redemption event
    event::emit(TokenRedemption {
        outcome: winner,
        token_type: TOKEN_TYPE_ASSET,
        amount: amount,
    });

    // Return amount from central asset balance
    balance::split(&mut escrow.escrowed_asset, amount)
}

// Stable token redemption for winning outcome
public(package) fun redeem_winning_tokens_stable<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    token: ConditionalToken,
    clock: &Clock,
    ctx: &mut TxContext,
): Balance<StableType> {
    // Verify market is finalized and get winning outcome
    market_state::assert_market_finalized(&escrow.market_state);
    let winner = market_state::get_winning_outcome(&escrow.market_state);
    assert_supplies_initialized(escrow);

    // Verify token matches winning outcome
    let winner_u8 = (winner as u8);
    assert!(token::outcome(&token) == winner_u8, EWRONG_OUTCOME);
    assert!(
        token::market_id(&token) == market_state::market_id(&escrow.market_state),
        EWRONG_MARKET,
    );
    assert!(token::asset_type(&token) == TOKEN_TYPE_STABLE, EWRONG_TOKEN_TYPE);

    // Get token amount and burn token
    let amount = token::value(&token);
    let winning_supply = vector::borrow_mut(&mut escrow.outcome_stable_supplies, winner);
    token::burn(winning_supply, token, clock, ctx);

    // Emit redemption event
    event::emit(TokenRedemption {
        outcome: winner,
        token_type: TOKEN_TYPE_STABLE,
        amount: amount,
    });

    // Return amount from central stable balance
    balance::split(&mut escrow.escrowed_stable, amount)
}

// Entry function for asset winning token redemption
public entry fun redeem_winning_tokens_asset_entry<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    token: ConditionalToken,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let balance = redeem_winning_tokens_asset(escrow, token, clock, ctx);
    let coin = coin::from_balance(balance, ctx);
    transfer::public_transfer(coin, tx_context::sender(ctx));
}

// Entry function for stable winning token redemption
public entry fun redeem_winning_tokens_stable_entry<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    token: ConditionalToken,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let balance = redeem_winning_tokens_stable(escrow, token, clock, ctx);
    let coin = coin::from_balance(balance, ctx);
    transfer::public_transfer(coin, tx_context::sender(ctx));
}

// Event for token redemption
public struct TokenRedemption has copy, drop {
    outcome: u64,
    token_type: u8,
    amount: u64,
}

public(package) fun mint_complete_set_asset<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    coin_in: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<token::ConditionalToken> {
    let outcome_count = market_state::outcome_count(&escrow.market_state);
    assert_supplies_initialized(escrow);
    market_state::assert_not_finalized(&escrow.market_state);

    // Get amount and convert coin to balance
    let amount = coin::value(&coin_in);
    let balance_in = coin::into_balance(coin_in);

    // Deposit into escrow
    balance::join(&mut escrow.escrowed_asset, balance_in);

    // Mint tokens for each outcome
    let recipient = tx_context::sender(ctx);
    let mut tokens = vector::empty<token::ConditionalToken>();
    let mut i = 0;
    while (i < outcome_count) {
        let supply = vector::borrow_mut(&mut escrow.outcome_asset_supplies, i);
        let token = token::mint(
            &escrow.market_state,
            supply,
            amount,
            recipient,
            clock,
            ctx,
        );
        vector::push_back(&mut tokens, token);
        i = i + 1;
    };

    tokens
}

public entry fun mint_complete_set_asset_entry<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    coin_in: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut tokens = mint_complete_set_asset(escrow, coin_in, clock, ctx);
    let recipient = tx_context::sender(ctx);
    let tokens_count = vector::length(&tokens);
    let mut i = 0;
    while (i < tokens_count) {
        let token = vector::pop_back(&mut tokens);
        transfer::public_transfer(token, recipient);
        i = i + 1;
    };
    vector::destroy_empty(tokens);
}

/// Mint a complete set of stable tokens by depositing stable coins
/// Returns the minted tokens instead of transferring them directly
public(package) fun mint_complete_set_stable<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    coin_in: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<token::ConditionalToken> {
    let outcome_count = market_state::outcome_count(&escrow.market_state);
    assert_supplies_initialized(escrow);
    market_state::assert_not_finalized(&escrow.market_state);

    // Get amount and convert coin to balance
    let amount = coin::value(&coin_in);
    let balance_in = coin::into_balance(coin_in);

    // Deposit into escrow
    balance::join(&mut escrow.escrowed_stable, balance_in);

    // Mint tokens for each outcome
    let recipient = tx_context::sender(ctx);
    let mut tokens = vector::empty<token::ConditionalToken>();
    let mut i = 0;
    while (i < outcome_count) {
        let supply = vector::borrow_mut(&mut escrow.outcome_stable_supplies, i);
        let token = token::mint(
            &escrow.market_state,
            supply,
            amount,
            recipient,
            clock,
            ctx,
        );
        vector::push_back(&mut tokens, token);
        i = i + 1;
    };

    tokens
}

/// Entry function for minting stable tokens
public(package) entry fun mint_complete_set_stable_entry<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    coin_in: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut tokens = mint_complete_set_stable(escrow, coin_in, clock, ctx);
    let recipient = tx_context::sender(ctx);

    let len = vector::length(&tokens);
    let mut i = 0;
    while (i < len) {
        let token = vector::pop_back(&mut tokens);
        transfer::public_transfer(token, recipient);
        i = i + 1;
    };

    vector::destroy_empty(tokens);
}

/// ======= Swap Methods =========
public(package) fun swap_token_asset_to_stable<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    token_in: ConditionalToken,
    outcome_idx: u64,
    amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ConditionalToken {
    let ms = &escrow.market_state;
    market_state::assert_trading_active(ms);
    assert!(outcome_idx < market_state::outcome_count(ms), EOUTCOME_OUT_OF_BOUNDS);

    let market_id = market_state::market_id(ms);
    assert!(token::market_id(&token_in) == market_id, EWRONG_MARKET);
    assert!(token::outcome(&token_in) == (outcome_idx as u8), EWRONG_OUTCOME);
    assert!(token::asset_type(&token_in) == TOKEN_TYPE_ASSET, EWRONG_TOKEN_TYPE);

    let asset_supply = vector::borrow_mut(&mut escrow.outcome_asset_supplies, outcome_idx);
    token::burn(asset_supply, token_in, clock, ctx);

    let stable_supply = vector::borrow_mut(&mut escrow.outcome_stable_supplies, outcome_idx);
    let token = token::mint(
        ms,
        stable_supply,
        amount_out,
        tx_context::sender(ctx),
        clock,
        ctx,
    );
    token
}

public(package) fun swap_token_stable_to_asset<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    token_in: ConditionalToken,
    outcome_idx: u64,
    amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ConditionalToken {
    let ms = &escrow.market_state;
    market_state::assert_trading_active(ms);
    assert!(outcome_idx < market_state::outcome_count(ms), EOUTCOME_OUT_OF_BOUNDS);

    let market_id = market_state::market_id(ms);
    assert!(token::market_id(&token_in) == market_id, EWRONG_MARKET);
    assert!(token::outcome(&token_in) == (outcome_idx as u8), EWRONG_OUTCOME);
    assert!(token::asset_type(&token_in) == TOKEN_TYPE_STABLE, EWRONG_TOKEN_TYPE);

    let stable_supply = vector::borrow_mut(&mut escrow.outcome_stable_supplies, outcome_idx);
    token::burn(stable_supply, token_in, clock, ctx);

    let asset_supply = vector::borrow_mut(&mut escrow.outcome_asset_supplies, outcome_idx);
    let token = token::mint(
        ms,
        asset_supply,
        amount_out,
        tx_context::sender(ctx),
        clock,
        ctx,
    );
    token
}

// === Internal Helpers ===
public fun get_balances<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): (u64, u64) {
    (balance::value(&escrow.escrowed_asset), balance::value(&escrow.escrowed_stable))
}

public fun get_market_state<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): &MarketState {
    &escrow.market_state
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
    vector::borrow_mut(&mut escrow.outcome_stable_supplies, outcome_idx)
}

public fun get_asset_supply<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
): &mut Supply {
    vector::borrow_mut(&mut escrow.outcome_asset_supplies, outcome_idx)
}

// === Test Helper Functions ===
// These functions help avoid borrow checker issues in tests

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
        coin::from_balance(balance::create_for_testing<AssetType>(amount), ctx),
        clock,
        ctx,
    );

    // Find and return the token for the requested outcome
    let outcome_count = vector::length(&tokens);
    let mut result_token = vector::pop_back(&mut tokens);

    // Process all other tokens
    let mut i = 0;
    while (i < outcome_count - 1) {
        let token = vector::pop_back(&mut tokens);
        let this_outcome = token::outcome(&token);

        if (this_outcome == (outcome_idx as u8)) {
            // Swap if we found the requested token
            transfer::public_transfer(result_token, tx_context::sender(ctx));
            result_token = token;
        } else {
            // Otherwise transfer to sender
            transfer::public_transfer(token, tx_context::sender(ctx));
        };
        i = i + 1;
    };

    vector::destroy_empty(tokens);
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
    let coin = coin::from_balance(balance::create_for_testing<StableType>(amount), ctx);
    let mut tokens = mint_complete_set_stable(escrow, coin, clock, ctx);

    // Extract the token we want and return it
    let token = vector::remove(&mut tokens, outcome_idx);

    // Transfer the other tokens to the sender
    let token_count = vector::length(&tokens);
    let mut i = 0;
    while (i < token_count) {
        let t = vector::pop_back(&mut tokens);
        transfer::public_transfer(t, tx_context::sender(ctx));
        i = i + 1;
    };
    vector::destroy_empty(tokens);

    token
}
