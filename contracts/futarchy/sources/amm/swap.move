module futarchy::swap;

use futarchy::amm;
use futarchy::coin_escrow::{Self, TokenEscrow};
use futarchy::conditional_token::{Self as token, ConditionalToken};
use futarchy::market_state::{Self, MarketState};
use futarchy::proposal::{Self, Proposal};
use sui::clock::Clock;
use sui::coin::Coin;

// === Introduction ===
// Defines entry methods for swaping and combining coins and conditional tokens

// === Errors ===
const EINVALID_OUTCOME: u64 = 0;
const EWRONG_TOKEN_TYPE: u64 = 1;
const EWRONG_OUTCOME: u64 = 2;
const EINVALID_STATE: u64 = 3;
const EMARKET_ID_MISMATCH: u64 = 4;
const EDAO_ID_MISMATCH: u64 = 5;

// === Constants ===
const STATE_TRADING: u8 = 1;

// ==== AMM Operations ====
fun swap_asset_to_stable<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    state: &MarketState,
    outcome_idx: u64,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    assert!(proposal::proposal_id(proposal) == market_state::market_id(state), EMARKET_ID_MISMATCH);
    assert!(proposal::get_dao_id(proposal) == market_state::dao_id(state), EDAO_ID_MISMATCH);

    assert!(outcome_idx < proposal::outcome_count(proposal), EINVALID_OUTCOME);
    assert!(proposal::state(proposal) == STATE_TRADING, EINVALID_STATE);

    let pool = proposal::get_pool_mut_by_outcome(proposal, (outcome_idx as u8));
    amm::swap_asset_to_stable(pool, state, amount_in, min_amount_out, clock, ctx)
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
    assert!(proposal::market_state_id(proposal) == coin_escrow::get_market_state_id(escrow), EMARKET_ID_MISMATCH);
    let amount_in = token::value(&token_to_swap);

    // Calculate the swap amount using AMM
    let amount_out = swap_asset_to_stable(
        proposal,
        coin_escrow::get_market_state(escrow),
        outcome_idx,
        amount_in,
        min_amount_out,
        clock,
        ctx,
    );

    // Handle token swap atomically in escrow - tokens will be minted directly to sender
    let stable_token = coin_escrow::swap_token_asset_to_stable(
        escrow,
        token_to_swap,
        outcome_idx,
        amount_out,
        clock,
        ctx,
    );

    let sender = tx_context::sender(ctx);
    transfer::public_transfer(stable_token, sender);
}

fun swap_stable_to_asset<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    state: &MarketState,
    outcome_idx: u64,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    assert!(proposal::proposal_id(proposal) == market_state::market_id(state), EMARKET_ID_MISMATCH);
    assert!(proposal::get_dao_id(proposal) == market_state::dao_id(state), EDAO_ID_MISMATCH);
    assert!(outcome_idx < proposal::outcome_count(proposal), EINVALID_OUTCOME);
    assert!(proposal::state(proposal) == STATE_TRADING, EINVALID_STATE);

    let pool = proposal::get_pool_mut_by_outcome(proposal, (outcome_idx as u8));
    amm::swap_stable_to_asset(pool, state, amount_in, min_amount_out, clock, ctx)
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
    assert!(proposal::market_state_id(proposal) == coin_escrow::get_market_state_id(escrow), EMARKET_ID_MISMATCH);
    let amount_in = token::value(&token_to_swap);

    // Calculate the swap amount using AMM
    let amount_out = swap_stable_to_asset(
        proposal,
        coin_escrow::get_market_state(escrow),
        outcome_idx,
        amount_in,
        min_amount_out,
        clock,
        ctx,
    );

    // Handle token swap atomically in escrow - tokens will be minted directly to sender
    let asset_token = coin_escrow::swap_token_stable_to_asset(
        escrow,
        token_to_swap,
        outcome_idx,
        amount_out,
        clock,
        ctx,
    );

    let sender = tx_context::sender(ctx);
    transfer::public_transfer(asset_token, sender);
}

#[allow(lint(self_transfer))]
public entry fun create_and_swap_stable_to_asset_with_existing<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    existing_token: ConditionalToken,
    min_amount_out: u64,
    coin_in: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(proposal::market_state_id(proposal) == coin_escrow::get_market_state_id(escrow), EMARKET_ID_MISMATCH);
    let mut tokens = coin_escrow::mint_complete_set_stable(escrow, coin_in, clock, ctx);

    let mut swap_token = vector::remove(&mut tokens, outcome_idx);

    // Merge existing token if present

    assert!(token::outcome(&existing_token) == (outcome_idx as u8), EWRONG_OUTCOME);
    assert!(token::asset_type(&existing_token) == 1, EWRONG_TOKEN_TYPE);
       assert!(token::market_id(&existing_token) == market_state::market_id(coin_escrow::get_market_state(escrow)), EMARKET_ID_MISMATCH);

    assert!(token::outcome(&swap_token) == (outcome_idx as u8), EWRONG_OUTCOME);
    let mut existing_token_in_vector = vector::empty();
    vector::push_back(&mut existing_token_in_vector, existing_token);
    token::merge_many(&mut swap_token, existing_token_in_vector, clock, ctx);

    let recipient = tx_context::sender(ctx);

    // Swap the selected token
    swap_stable_to_asset_entry(
        proposal,
        escrow,
        outcome_idx,
        swap_token,
        min_amount_out,
        clock,
        ctx,
    );

    // Transfer the remaining tokens to the recipient
    while (!vector::is_empty(&tokens)) {
        let token = vector::pop_back(&mut tokens);
        transfer::public_transfer(token, recipient);
    };

    // Clean up the vector
    vector::destroy_empty(tokens);
}

#[allow(lint(self_transfer))]
public entry fun create_and_swap_asset_to_stable_with_existing<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    existing_token: ConditionalToken,
    min_amount_out: u64,
    coin_in: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(proposal::market_state_id(proposal) == coin_escrow::get_market_state_id(escrow), EMARKET_ID_MISMATCH);
    let mut tokens = coin_escrow::mint_complete_set_asset(escrow, coin_in, clock, ctx);

    let mut swap_token = vector::remove(&mut tokens, outcome_idx);

    assert!(token::outcome(&existing_token) == (outcome_idx as u8), EWRONG_OUTCOME);
    assert!(token::asset_type(&existing_token) == 0, EWRONG_TOKEN_TYPE);
    assert!(token::market_id(&existing_token) == market_state::market_id(coin_escrow::get_market_state(escrow)), EMARKET_ID_MISMATCH);

    assert!(token::outcome(&swap_token) == (outcome_idx as u8), EWRONG_OUTCOME);
    let mut existing_token_in_vector = vector::empty();
    vector::push_back(&mut existing_token_in_vector, existing_token);
    token::merge_many(&mut swap_token, existing_token_in_vector, clock, ctx);

    let recipient = tx_context::sender(ctx);

    // Swap the selected token
    swap_asset_to_stable_entry(
        proposal,
        escrow,
        outcome_idx,
        swap_token,
        min_amount_out,
        clock,
        ctx,
    );

    // Transfer the remaining tokens to the recipient
    while (!vector::is_empty(&tokens)) {
        let token = vector::pop_back(&mut tokens);
        transfer::public_transfer(token, recipient);
    };

    // Clean up the vector
    vector::destroy_empty(tokens);
}

/// Entry function for creating and swapping asset to stable without an existing token
public entry fun create_and_swap_asset_to_stable_entry<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    min_amount_out: u64,
    coin_in: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(proposal::market_state_id(proposal) == coin_escrow::get_market_state_id(escrow), EMARKET_ID_MISMATCH);
    let mut tokens = coin_escrow::mint_complete_set_asset(escrow, coin_in, clock, ctx);

    let token_to_swap = vector::remove(&mut tokens, outcome_idx);

    let recipient = tx_context::sender(ctx);

    // Swap the selected token
    swap_asset_to_stable_entry(
        proposal,
        escrow,
        outcome_idx,
        token_to_swap,
        min_amount_out,
        clock,
        ctx,
    );

    // Transfer the remaining tokens to the recipient
    while (!vector::is_empty(&tokens)) {
        let token = vector::pop_back(&mut tokens);
        transfer::public_transfer(token, recipient);
    };

    // Clean up the vector
    vector::destroy_empty(tokens);
}

/// Entry function for creating and swapping stable to asset without an existing token
public entry fun create_and_swap_stable_to_asset_entry<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    min_amount_out: u64,
    coin_in: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(proposal::market_state_id(proposal) == coin_escrow::get_market_state_id(escrow), EMARKET_ID_MISMATCH);
    let mut tokens = coin_escrow::mint_complete_set_stable(escrow, coin_in, clock, ctx);

    let token_to_swap = vector::remove(&mut tokens, outcome_idx);

    let recipient = tx_context::sender(ctx);

    // Swap the selected token
    swap_stable_to_asset_entry(
        proposal,
        escrow,
        outcome_idx,
        token_to_swap,
        min_amount_out,
        clock,
        ctx,
    );

    // Transfer the remaining tokens to the recipient
    while (!vector::is_empty(&tokens)) {
        let token = vector::pop_back(&mut tokens);
        transfer::public_transfer(token, recipient);
    };

    // Clean up the vector
    vector::destroy_empty(tokens);
}
