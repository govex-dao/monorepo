module futarchy::coin_escrow;

use futarchy::conditional_token::{Self as token, ConditionalToken, Supply};
use futarchy::market_state::MarketState;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::event;
use sui::types;

// === Introduction ===
// Tracks and stores coins

// === Errors ===
const EInsufficientBalance: u64 = 0;
const EIncorrectSequence: u64 = 1;
const EWrongMarket: u64 = 2;
const EWrongTokenType: u64 = 3;
const ESuppliesNotInitialized: u64 = 4;
const EOutcomeOutOfBounds: u64 = 5;
const EWrongOutcome: u64 = 6;
const ENotEnough: u64 = 7;
const ENotEnoughLiquidity: u64 = 8;
const EInsufficientAsset: u64 = 9;
const EInsufficientStable: u64 = 10;
const EMarketNotExpired: u64 = 11;
const EBadWitness: u64 = 12;

// === Constants ===
const TOKEN_TYPE_STABLE: u8 = 1;
const TOKEN_TYPE_ASSET: u8 = 0;
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
}

public struct EscrowAdminCap has key, store { id: UID }

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

public struct AdminEscrowSweep has copy, drop {
    market_id: ID,
    dao_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    admin: address,
    timestamp: u64,
}

// === Public Functions ===

// Module initialization function that runs when the module is published
fun init(witness: COIN_ESCROW, ctx: &mut TxContext) {
    // Verify this is a genuine one-time witness
    assert!(types::is_one_time_witness(&witness), EBadWitness);

    // Create admin capability
    let admin_cap = EscrowAdminCap {
        id: object::new(ctx),
    };
    transfer::public_transfer(admin_cap, ctx.sender());
}

public(package) fun new<AssetType, StableType>(
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
    }
}

public(package) fun register_supplies<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    asset_supply: Supply,
    stable_supply: Supply,
) {
    let outcome_count = escrow.market_state.outcome_count();
    assert!(outcome_idx < outcome_count, EOutcomeOutOfBounds);
    assert!(escrow.outcome_asset_supplies.length() == outcome_idx, EIncorrectSequence);

    escrow.outcome_asset_supplies.push_back(asset_supply);
    escrow.outcome_stable_supplies.push_back(stable_supply);
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
    let asset_amount = initial_asset.value();
    let stable_amount = initial_stable.value();
    let sender = ctx.sender();

    // 1. Add to escrow balances
    escrow.escrowed_asset.join(initial_asset);
    escrow.escrowed_stable.join(initial_stable);

    // 2. Calculate maximum amounts needed across outcomes
    let mut max_asset = 0;
    let mut max_stable = 0;
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
    i = 0;
    while (i < outcome_count) {
        let asset_amt = asset_amounts[i];
        let stable_amt = stable_amounts[i];

        // Mint asset tokens if necessary
        if (asset_amt < max_asset) {
            let diff = max_asset - asset_amt;
            let asset_supply = &mut escrow.outcome_asset_supplies[i];
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
            let stable_supply = &mut escrow.outcome_stable_supplies[i];
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

public(package) fun remove_liquidity<AssetType, StableType>(
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

public(package) fun extract_stable_fees<AssetType, StableType>(
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
                escrow.outcome_stable_supplies.length() == outcome_count,
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

        // Verify token properties
        // Verify token properties
        assert!(token.market_id() == market_id, EWrongMarket);
        assert!(token.asset_type() == token_type, EWrongTokenType);
        assert!(token.value() == amount, EInsufficientBalance);

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

// Asset token redemption implementation
public(package) fun redeem_complete_set_asset<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    mut tokens: vector<ConditionalToken>,
    clock: &Clock,
    ctx: &TxContext,
): Balance<AssetType> {
    escrow.market_state.assert_not_finalized();
    assert_supplies_initialized(escrow);

    // Verify tokens form a complete set and get common amount
    let amount = verify_token_set(escrow, &tokens, TOKEN_TYPE_ASSET);

    // Burn all tokens
    let outcome_count = escrow.market_state.outcome_count();
    let mut i = 0;
    while (i < outcome_count) {
        let token = tokens.pop_back();
        let outcome = token.outcome();

        let supply = &mut escrow.outcome_asset_supplies[(outcome as u64)];
        token.burn(supply, clock, ctx);
        i = i + 1;
    };

    tokens.destroy_empty();
    assert!(escrow.escrowed_asset.value() >= amount, EInsufficientBalance);
    // Return the redeemed assets
    escrow.escrowed_asset.split(amount)
}

// Stable token redemption implementation
public(package) fun redeem_complete_set_stable<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    mut tokens: vector<ConditionalToken>,
    clock: &Clock,
    ctx: &TxContext,
): Balance<StableType> {
    escrow.market_state.assert_not_finalized();
    assert_supplies_initialized(escrow);

    // Verify tokens form a complete set and get common amount
    let amount = verify_token_set(escrow, &tokens, TOKEN_TYPE_STABLE);

    // Burn all tokens
    let outcome_count = escrow.market_state.outcome_count();
    let mut i = 0;
    while (i < outcome_count) {
        let token = tokens.pop_back();
        let outcome = token.outcome();

        let supply = &mut escrow.outcome_stable_supplies[(outcome as u64)];
        token.burn(supply, clock, ctx);
        i = i + 1;
    };

    tokens.destroy_empty();
    assert!(escrow.escrowed_stable.value() >= amount, EInsufficientBalance);
    // Return the redeemed stable tokens
    escrow.escrowed_stable.split(amount)
}

// Asset token redemption for winning outcome
public(package) fun redeem_winning_tokens_asset<AssetType, StableType>(
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
public(package) fun redeem_winning_tokens_stable<AssetType, StableType>(
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

public(package) fun mint_complete_set_asset<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    coin_in: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<token::ConditionalToken> {
    let outcome_count = escrow.market_state.outcome_count();
    assert_supplies_initialized(escrow);
    escrow.market_state.assert_not_finalized();

    // Get amount and convert coin to balance
    let amount = coin_in.value();
    let balance_in = coin_in.into_balance();

    // Deposit into escrow
    escrow.escrowed_asset.join(balance_in);

    // Mint tokens for each outcome
    let recipient = ctx.sender();
    let mut tokens = vector[];
    let mut i = 0;
    while (i < outcome_count) {
        let supply = &mut escrow.outcome_asset_supplies[i];
        let token = token::mint(
            &escrow.market_state,
            supply,
            amount,
            recipient,
            clock,
            ctx,
        );
        tokens.push_back(token);
        i = i + 1;
    };

    tokens
}

/// Mint a complete set of stable tokens by depositing stable coins
/// Returns the minted tokens instead of transferring them directly
public(package) fun mint_complete_set_stable<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    coin_in: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<token::ConditionalToken> {
    let outcome_count = escrow.market_state.outcome_count();
    assert_supplies_initialized(escrow);
    escrow.market_state.assert_not_finalized();

    // Get amount and convert coin to balance
    let amount = coin_in.value();
    let balance_in = coin_in.into_balance();

    // Deposit into escrow
    escrow.escrowed_stable.join(balance_in);

    // Mint tokens for each outcome
    let recipient = ctx.sender();
    let mut tokens = vector[];
    let mut i = 0;
    while (i < outcome_count) {
        let supply = &mut escrow.outcome_stable_supplies[i];
        let token = token::mint(
            &escrow.market_state,
            supply,
            amount,
            recipient,
            clock,
            ctx,
        );
        tokens.push_back(token);
        i = i + 1;
    };

    tokens
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
    ms.assert_trading_active();
    assert!(outcome_idx < ms.outcome_count(), EOutcomeOutOfBounds);

    let market_id = ms.market_id();
    assert!(token_in.market_id() == market_id, EWrongMarket);
    assert!(token_in.outcome() == (outcome_idx as u8), EWrongOutcome);
    assert!(token_in.asset_type() == TOKEN_TYPE_ASSET, EWrongTokenType);

    let asset_supply = &mut escrow.outcome_asset_supplies[outcome_idx];
    token_in.burn(asset_supply, clock, ctx);

    let stable_supply = &mut escrow.outcome_stable_supplies[outcome_idx];
    let token = token::mint(
        ms,
        stable_supply,
        amount_out,
        ctx.sender(),
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
    ms.assert_trading_active();
    assert!(outcome_idx < ms.outcome_count(), EOutcomeOutOfBounds);

    let market_id = ms.market_id();
    assert!(token_in.market_id() == market_id, EWrongMarket);
    assert!(token_in.outcome() == (outcome_idx as u8), EWrongOutcome);
    assert!(token_in.asset_type() == TOKEN_TYPE_STABLE, EWrongTokenType);

    let stable_supply = &mut escrow.outcome_stable_supplies[outcome_idx];
    token_in.burn(stable_supply, clock, ctx);

    let asset_supply = &mut escrow.outcome_asset_supplies[outcome_idx];
    let token = token::mint(
        ms,
        asset_supply,
        amount_out,
        ctx.sender(),
        clock,
        ctx,
    );
    token
}

/// Allows anyone to burn a conditional token associated with this escrow
/// if the market is finalized and the token's outcome is not the winning outcome.
public(package) fun burn_unused_tokens<AssetType, StableType>(
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
        } else {
            abort EWrongTokenType
        }
    };
    // 4. Destroy the now empty vector
    tokens_to_burn.destroy_empty();
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

// === Admin Functions ===

// Admin function to sweep funds from an escrow after MARKET_EXPIRY_PERIOD_MS from market creation
public entry fun admin_sweep_escrow<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    _admin_cap: &EscrowAdminCap, // Assuming ownership check happens elsewhere or via admin signature
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // First extract all needed information from market_state
    let market_id = escrow.market_state.market_id();
    let dao_id = escrow.market_state.dao_id();
    let creation_time = escrow.market_state.get_creation_time();
    let current_time = clock.timestamp_ms();
    let admin = ctx.sender(); // Admin is the sender calling this

    // Check if expiry period has passed since market creation
    assert!(current_time >= creation_time + MARKET_EXPIRY_PERIOD_MS, EMarketNotExpired);

    // Get current escrow balances
    let (asset_amount, stable_amount) = get_balances(escrow);

    // Only process if there are funds to sweep
    if (asset_amount > 0 || stable_amount > 0) {
        // Call the updated remove_liquidity function, which returns coins
        let (asset_coin, stable_coin) = remove_liquidity(
            escrow,
            asset_amount,
            stable_amount,
            ctx,
        );

        // Transfer the returned coins to the admin (the caller)
        transfer::public_transfer(asset_coin, admin);
        transfer::public_transfer(stable_coin, admin);

        // Emit event for the admin sweep (log the amounts swept)
        event::emit(AdminEscrowSweep {
            market_id,
            dao_id,
            asset_amount, // Amount swept
            stable_amount, // Amount swept
            admin,
            timestamp: current_time,
        });
    }
    // If balances are zero, do nothing.
}

public entry fun burn_admin_sweep_cap(admin_cap: EscrowAdminCap) {
    // Destroy the admin cap by unpacking and deleting its ID
    let EscrowAdminCap { id } = admin_cap;
    id.delete();
}

// === Package Functions ===

public(package) fun get_balances<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): (u64, u64) {
    (escrow.escrowed_asset.value(), escrow.escrowed_stable.value())
}

public(package) fun get_market_state<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): &MarketState {
    &escrow.market_state
}

public(package) fun get_market_state_id<AssetType, StableType>(
    escrow: &TokenEscrow<AssetType, StableType>,
): ID {
    object::id(&escrow.market_state)
}

public(package) fun get_market_state_mut<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
): &mut MarketState {
    &mut escrow.market_state
}

public(package) fun get_stable_supply<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
): &mut Supply {
    &mut escrow.outcome_stable_supplies[outcome_idx]
}

public(package) fun get_asset_supply<AssetType, StableType>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
): &mut Supply {
    &mut escrow.outcome_asset_supplies[outcome_idx]
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
