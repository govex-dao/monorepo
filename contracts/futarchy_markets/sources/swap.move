module futarchy_markets::swap;

use futarchy_markets::coin_escrow::TokenEscrow;
use futarchy_markets::conditional_token::ConditionalToken;
use futarchy_markets::conditional_token_holder::ConditionalTokenHolder;
use futarchy_markets::liquidity_interact;
use futarchy_markets::market_state::MarketState;
use futarchy_markets::proposal::{Self, Proposal};
use sui::clock::Clock;
use sui::coin::Coin;

// === Introduction ===
// Defines entry methods for swaping and combining coins and conditional tokens

// === Errors ===
const EInvalidOutcome: u64 = 0;
const EWrongTokenType: u64 = 1;
const EWrongOutcome: u64 = 2;
const EInvalidState: u64 = 3;
const EMarketIdMismatch: u64 = 4;

// === Constants ===
const STATE_TRADING: u8 = 2; // Must match proposal.move STATE_TRADING

// === Helper Functions ===
/// Efficiently transfers all tokens in a vector to the recipient
fun transfer_tokens_to_recipient(mut tokens: vector<ConditionalToken>, recipient: address) {
    while (!tokens.is_empty()) {
        transfer::public_transfer(tokens.pop_back(), recipient);
    };
    tokens.destroy_empty();
}

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
    assert!(proposal::market_state_id(proposal) == escrow.get_market_state_id(), EMarketIdMismatch);
    assert!(token_to_swap.asset_type() == 0, EWrongTokenType);
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
    assert!(proposal::market_state_id(proposal) == escrow.get_market_state_id(), EMarketIdMismatch);
    assert!(token_to_swap.asset_type() == 1, EWrongTokenType);
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
    assert!(proposal::market_state_id(proposal) == escrow.get_market_state_id(), EMarketIdMismatch);
    let mut tokens = escrow.mint_complete_set_stable(coin_in, clock, ctx);

    assert!(outcome_idx < tokens.length(), EInvalidOutcome);
    let mut swap_token = tokens.remove(outcome_idx);

    // Merge existing token if present
    assert!(existing_token.outcome() == (outcome_idx as u8), EWrongOutcome);
    assert!(existing_token.asset_type() == 1, EWrongTokenType);
    assert!(existing_token.market_id() == escrow.get_market_state().market_id(), EMarketIdMismatch);

    // swap_token.outcome() is guaranteed to be outcome_idx since it came from tokens[outcome_idx]
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
    transfer_tokens_to_recipient(tokens, recipient);
    transfer::public_transfer(asset_token, recipient);
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
    assert!(proposal::market_state_id(proposal) == escrow.get_market_state_id(), EMarketIdMismatch);
    let mut tokens = escrow.mint_complete_set_asset(coin_in, clock, ctx);

    assert!(outcome_idx < tokens.length(), EInvalidOutcome);
    let mut swap_token = tokens.remove(outcome_idx);

    assert!(existing_token.outcome() == (outcome_idx as u8), EWrongOutcome);
    assert!(existing_token.asset_type() == 0, EWrongTokenType);
    assert!(existing_token.market_id() == escrow.get_market_state().market_id(), EMarketIdMismatch);

    // swap_token.outcome() is guaranteed to be outcome_idx since it came from tokens[outcome_idx]
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
    transfer_tokens_to_recipient(tokens, recipient);
    transfer::public_transfer(stable_token, recipient);
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
    assert!(proposal::market_state_id(proposal) == escrow.get_market_state_id(), EMarketIdMismatch);
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
    transfer_tokens_to_recipient(tokens, recipient);
    transfer::public_transfer(stable_token, recipient);
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
    assert!(proposal::market_state_id(proposal) == escrow.get_market_state_id(), EMarketIdMismatch);
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
    transfer_tokens_to_recipient(tokens, recipient);
    transfer::public_transfer(asset_token, recipient);
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
    assert!(proposal::proposal_id(proposal) == state.market_id(), EMarketIdMismatch);

    assert!(outcome_idx < proposal::outcome_count(proposal), EInvalidOutcome);
    assert!(proposal::state(proposal) == STATE_TRADING, EInvalidState);

    let pool = proposal::get_pool_mut_by_outcome(proposal, (outcome_idx as u8));
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
    assert!(proposal::proposal_id(proposal) == state.market_id(), EMarketIdMismatch);
    assert!(outcome_idx < proposal::outcome_count(proposal), EInvalidOutcome);
    assert!(proposal::state(proposal) == STATE_TRADING, EInvalidState);

    let pool = proposal::get_pool_mut_by_outcome(proposal, (outcome_idx as u8));
    pool.swap_stable_to_asset(state, amount_in, min_amount_out, clock, ctx)
}

// === Swap with Optional Token Holder ===

/// Swap stable to asset with option to store extra tokens in holder
/// If holder is provided, extra tokens beyond expected amount go to holder for keeper redemption
public entry fun swap_stable_to_asset_with_holder<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    holder: &mut ConditionalTokenHolder,
    outcome_idx: u64,
    token_to_swap: ConditionalToken,
    min_amount_out: u64,
    expected_amount_out: u64,  // User's expected output
    holder_fee: Coin<sui::sui::SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Perform the swap
    let mut result_token = swap_stable_to_asset(
        proposal,
        escrow,
        outcome_idx,
        token_to_swap,
        min_amount_out,
        clock,
        ctx,
    );

    let actual_amount = result_token.value();
    let recipient = ctx.sender();

    // If we got more than expected, split and store extra in holder
    if (actual_amount > expected_amount_out) {
        let extra_amount = actual_amount - expected_amount_out;
        let extra_tokens = result_token.split_and_return(extra_amount, clock, ctx);

        // Store extra tokens in holder with fee
        holder.store_tokens_with_fee(
            proposal,
            extra_tokens,
            holder_fee,
            clock,
            ctx,
        );

        // Transfer expected amount to user
        transfer::public_transfer(result_token, recipient);
    } else {
        // No extra tokens, return fee and transfer all tokens to user
        transfer::public_transfer(holder_fee, recipient);
        transfer::public_transfer(result_token, recipient);
    };
}

/// Swap asset to stable with option to store extra tokens in holder
public entry fun swap_asset_to_stable_with_holder<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    holder: &mut ConditionalTokenHolder,
    outcome_idx: u64,
    token_to_swap: ConditionalToken,
    min_amount_out: u64,
    expected_amount_out: u64,
    holder_fee: Coin<sui::sui::SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Perform the swap
    let mut result_token = swap_asset_to_stable(
        proposal,
        escrow,
        outcome_idx,
        token_to_swap,
        min_amount_out,
        clock,
        ctx,
    );

    let actual_amount = result_token.value();
    let recipient = ctx.sender();

    // If we got more than expected, split and store extra in holder
    if (actual_amount > expected_amount_out) {
        let extra_amount = actual_amount - expected_amount_out;
        let extra_tokens = result_token.split_and_return(extra_amount, clock, ctx);

        // Store extra tokens in holder with fee
        holder.store_tokens_with_fee(
            proposal,
            extra_tokens,
            holder_fee,
            clock,
            ctx,
        );

        // Transfer expected amount to user
        transfer::public_transfer(result_token, recipient);
    } else {
        // No extra tokens, return fee and transfer all tokens to user
        transfer::public_transfer(holder_fee, recipient);
        transfer::public_transfer(result_token, recipient);
    };
}
