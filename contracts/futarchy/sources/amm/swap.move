module futarchy::swap;

// === Introduction ===
// Defines entry methods for swaping and combining coins and conditional tokens

// === Imports ===
use futarchy::{
    coin_escrow::TokenEscrow,
    conditional_token::ConditionalToken,
    liquidity_interact,
    market_state::MarketState,
    proposal::Proposal
};
use sui::{
    clock::Clock,
    coin::Coin
};

// === Errors ===
const EInvalidOutcome: u64 = 0;
const EWrongTokenType: u64 = 1;
const EWrongOutcome: u64 = 2;
const EInvalidState: u64 = 3;
const EMarketIdMismatch: u64 = 4;

// === Constants ===
const STATE_TRADING: u8 = 1;

// === Public Functions ===

public fun swap_asset_to_stable<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    token_to_swap: ConditionalToken,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ConditionalToken {
    assert!(
        proposal.market_state_id() == escrow.get_market_state_id(),
        EMarketIdMismatch,
    );
    let amount_in = token_to_swap.value();

    // Calculate the swap amount using AMM
    let amount_out = swap_asset_to_stable_internal(
        proposal,
        escrow.get_market_state(),
        outcome_idx,
        amount_in,
        min_amount_out,
        clock,
        ctx,
    );

    // Handle token swap atomically in escrow - tokens will be minted directly to sender
    let stable_token = escrow.swap_token_asset_to_stable(
        token_to_swap,
        outcome_idx,
        amount_out,
        clock,
        ctx,
    );

    liquidity_interact::assert_all_reserves_consistency(proposal, escrow);

    stable_token
}

public entry fun swap_asset_to_stable_entry<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    token_to_swap: ConditionalToken,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let recipient = ctx.sender();
    let result_token = swap_asset_to_stable(
        proposal,
        escrow,
        outcome_idx,
        token_to_swap,
        min_amount_out,
        clock,
        ctx,
    );
    transfer::public_transfer(result_token, recipient);
}

public fun swap_stable_to_asset<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    token_to_swap: ConditionalToken,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ConditionalToken {
    assert!(
        proposal.market_state_id() == escrow.get_market_state_id(),
        EMarketIdMismatch,
    );
    let amount_in = token_to_swap.value();

    // Calculate the swap amount using AMM
    let amount_out = swap_stable_to_asset_internal(
        proposal,
        escrow.get_market_state(),
        outcome_idx,
        amount_in,
        min_amount_out,
        clock,
        ctx,
    );

    // Handle token swap atomically in escrow - tokens will be minted directly to sender
    let asset_token = escrow.swap_token_stable_to_asset(
        token_to_swap,
        outcome_idx,
        amount_out,
        clock,
        ctx,
    );

    liquidity_interact::assert_all_reserves_consistency(proposal, escrow);

    asset_token
}

public entry fun swap_stable_to_asset_entry<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    token_to_swap: ConditionalToken,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let recipient = ctx.sender();
    let result_token = swap_stable_to_asset(
        proposal,
        escrow,
        outcome_idx,
        token_to_swap,
        min_amount_out,
        clock,
        ctx,
    );
    transfer::public_transfer(result_token, recipient);
}

/// Returns all tokens with swapped token at the end
public fun create_and_swap_stable_to_asset_with_existing<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    existing_token: ConditionalToken,
    min_amount_out: u64,
    coin_in: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (vector<ConditionalToken>, ConditionalToken) {
    assert!(
        proposal.market_state_id() == escrow.get_market_state_id(),
        EMarketIdMismatch,
    );
    let mut tokens = escrow.mint_complete_set_stable(coin_in, clock, ctx);

    assert!(outcome_idx < tokens.length(), EInvalidOutcome);
    let mut swap_token = tokens.remove(outcome_idx);

    // Merge existing token if present
    assert!(existing_token.outcome() == (outcome_idx as u8), EWrongOutcome);
    assert!(existing_token.asset_type() == 1, EWrongTokenType);
    assert!(
        existing_token.market_id() == escrow.get_market_state().market_id(),
        EMarketIdMismatch,
    );

    assert!(swap_token.outcome() == (outcome_idx as u8), EWrongOutcome);
    let mut existing_token_in_vector = vector[];
    existing_token_in_vector.push_back(existing_token);
    swap_token.merge_many(existing_token_in_vector, clock, ctx);

    // Swap the selected token
    let asset_token = swap_stable_to_asset(
        proposal,
        escrow,
        outcome_idx,
        swap_token,
        min_amount_out,
        clock,
        ctx,
    );

    // Add the swapped token to the end of the vector
    (tokens, asset_token)
}

#[allow(lint(self_transfer))]
public entry fun create_and_swap_stable_to_asset_with_existing_entry<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    existing_token: ConditionalToken,
    min_amount_out: u64,
    coin_in: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (mut tokens, asset_token) = create_and_swap_stable_to_asset_with_existing(
        proposal,
        escrow,
        outcome_idx,
        existing_token,
        min_amount_out,
        coin_in,
        clock,
        ctx,
    );

    let recipient = ctx.sender();

    // Transfer all tokens to the recipient
    while (!tokens.is_empty()) {
        let token = tokens.pop_back();
        transfer::public_transfer(token, recipient);
    };
    transfer::public_transfer(asset_token, recipient);

    tokens.destroy_empty();
}

/// Returns all tokens with swapped token at the end
public fun create_and_swap_asset_to_stable_with_existing<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    existing_token: ConditionalToken,
    min_amount_out: u64,
    coin_in: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (vector<ConditionalToken>, ConditionalToken) {
    assert!(
        proposal.market_state_id() == escrow.get_market_state_id(),
        EMarketIdMismatch,
    );
    let mut tokens = escrow.mint_complete_set_asset(coin_in, clock, ctx);

    assert!(outcome_idx < tokens.length(), EInvalidOutcome);
    let mut swap_token = tokens.remove(outcome_idx);

    assert!(existing_token.outcome() == (outcome_idx as u8), EWrongOutcome);
    assert!(existing_token.asset_type() == 0, EWrongTokenType);
    assert!(
        existing_token.market_id() == escrow.get_market_state().market_id(),
        EMarketIdMismatch,
    );

    assert!(swap_token.outcome() == (outcome_idx as u8), EWrongOutcome);
    let mut existing_token_in_vector = vector[];
    existing_token_in_vector.push_back(existing_token);
    swap_token.merge_many(existing_token_in_vector, clock, ctx);

    // Swap the selected token
    let stable_token = swap_asset_to_stable(
        proposal,
        escrow,
        outcome_idx,
        swap_token,
        min_amount_out,
        clock,
        ctx,
    );

    // Add the swapped token to the end of the vector
    (tokens, stable_token)
}

#[allow(lint(self_transfer))]
public entry fun create_and_swap_asset_to_stable_with_existing_entry<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    existing_token: ConditionalToken,
    min_amount_out: u64,
    coin_in: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (mut tokens, stable_token) = create_and_swap_asset_to_stable_with_existing(
        proposal,
        escrow,
        outcome_idx,
        existing_token,
        min_amount_out,
        coin_in,
        clock,
        ctx,
    );

    let recipient = ctx.sender();

    // Transfer all tokens to the recipient
    while (!tokens.is_empty()) {
        let token = tokens.pop_back();
        transfer::public_transfer(token, recipient);
    };
    transfer::public_transfer(stable_token, recipient);

    tokens.destroy_empty();
}

/// Returns all tokens with swapped token at the end
public fun create_and_swap_asset_to_stable<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    min_amount_out: u64,
    coin_in: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (vector<ConditionalToken>, ConditionalToken) {
    assert!(
        proposal.market_state_id() == escrow.get_market_state_id(),
        EMarketIdMismatch,
    );
    let mut tokens = escrow.mint_complete_set_asset(coin_in, clock, ctx);

    assert!(outcome_idx < tokens.length(), EInvalidOutcome);
    let token_to_swap = tokens.remove(outcome_idx);

    // Swap the selected token
    let stable_token = swap_asset_to_stable(
        proposal,
        escrow,
        outcome_idx,
        token_to_swap,
        min_amount_out,
        clock,
        ctx,
    );

    // Add the swapped token to the end of the vector
    (tokens, stable_token)
}

#[allow(lint(self_transfer))]
public entry fun create_and_swap_asset_to_stable_entry<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    min_amount_out: u64,
    coin_in: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (mut tokens, stable_token) = create_and_swap_asset_to_stable(
        proposal,
        escrow,
        outcome_idx,
        min_amount_out,
        coin_in,
        clock,
        ctx,
    );

    let recipient = ctx.sender();

    // Transfer all tokens to the recipient
    while (!tokens.is_empty()) {
        let token = tokens.pop_back();
        transfer::public_transfer(token, recipient);
    };
    transfer::public_transfer(stable_token, recipient);

    tokens.destroy_empty();
}

/// Returns all tokens with swapped token at the end
public fun create_and_swap_stable_to_asset<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    min_amount_out: u64,
    coin_in: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (vector<ConditionalToken>, ConditionalToken) {
    assert!(
        proposal.market_state_id() == escrow.get_market_state_id(),
        EMarketIdMismatch,
    );
    let mut tokens = escrow.mint_complete_set_stable(coin_in, clock, ctx);

    assert!(outcome_idx < tokens.length(), EInvalidOutcome);
    let token_to_swap = tokens.remove(outcome_idx);

    // Swap the selected token
    let asset_token = swap_stable_to_asset(
        proposal,
        escrow,
        outcome_idx,
        token_to_swap,
        min_amount_out,
        clock,
        ctx,
    );

    // Add the swapped token to the end of the vector
    (tokens, asset_token)
}

#[allow(lint(self_transfer))]
public entry fun create_and_swap_stable_to_asset_entry<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    min_amount_out: u64,
    coin_in: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (mut tokens, asset_token) = create_and_swap_stable_to_asset(
        proposal,
        escrow,
        outcome_idx,
        min_amount_out,
        coin_in,
        clock,
        ctx,
    );

    let recipient = ctx.sender();

    // Transfer all tokens to the recipient
    while (!tokens.is_empty()) {
        let token = tokens.pop_back();
        transfer::public_transfer(token, recipient);
    };
    transfer::public_transfer(asset_token, recipient);

    tokens.destroy_empty();
}

// === Private Functions ===

fun swap_asset_to_stable_internal<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    state: &MarketState,
    outcome_idx: u64,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    assert!(proposal.proposal_id() == state.market_id(), EMarketIdMismatch);

    assert!(outcome_idx < proposal.outcome_count(), EInvalidOutcome);
    assert!(proposal.state() == STATE_TRADING, EInvalidState);

    let pool = proposal.get_pool_mut_by_outcome((outcome_idx as u8));
    pool.swap_asset_to_stable(state, amount_in, min_amount_out, clock, ctx)
}

fun swap_stable_to_asset_internal<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    state: &MarketState,
    outcome_idx: u64,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    assert!(proposal.proposal_id() == state.market_id(), EMarketIdMismatch);
    assert!(outcome_idx < proposal.outcome_count(), EInvalidOutcome);
    assert!(proposal.state() == STATE_TRADING, EInvalidState);

    let pool = proposal.get_pool_mut_by_outcome((outcome_idx as u8));
    pool.swap_stable_to_asset(state, amount_in, min_amount_out, clock, ctx)
}