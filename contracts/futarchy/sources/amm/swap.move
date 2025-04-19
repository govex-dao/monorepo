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

// === Constants ===
const STATE_TRADING: u8 = 1;

// ==== AMM Operations ====
fun swap_asset_to_stable_internal<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    state: &MarketState,
    outcome_idx: u64,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    assert!(proposal::proposal_id(proposal) == market_state::market_id(state), EMARKET_ID_MISMATCH);

    assert!(outcome_idx < proposal::outcome_count(proposal), EINVALID_OUTCOME);
    assert!(proposal::state(proposal) == STATE_TRADING, EINVALID_STATE);

    let pool = proposal::get_pool_mut_by_outcome(proposal, (outcome_idx as u8));
    amm::swap_asset_to_stable(pool, state, amount_in, min_amount_out, clock, ctx)
}

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
        proposal::market_state_id(proposal) == coin_escrow::get_market_state_id(escrow),
        EMARKET_ID_MISMATCH,
    );
    let amount_in = token::value(&token_to_swap);

    // Calculate the swap amount using AMM
    let amount_out = swap_asset_to_stable_internal(
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
    let recipient = tx_context::sender(ctx);
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

fun swap_stable_to_asset_internal<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    state: &MarketState,
    outcome_idx: u64,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    assert!(proposal::proposal_id(proposal) == market_state::market_id(state), EMARKET_ID_MISMATCH);
    assert!(outcome_idx < proposal::outcome_count(proposal), EINVALID_OUTCOME);
    assert!(proposal::state(proposal) == STATE_TRADING, EINVALID_STATE);

    let pool = proposal::get_pool_mut_by_outcome(proposal, (outcome_idx as u8));
    amm::swap_stable_to_asset(pool, state, amount_in, min_amount_out, clock, ctx)
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
        proposal::market_state_id(proposal) == coin_escrow::get_market_state_id(escrow),
        EMARKET_ID_MISMATCH,
    );
    let amount_in = token::value(&token_to_swap);

    // Calculate the swap amount using AMM
    let amount_out = swap_stable_to_asset_internal(
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
    let recipient = tx_context::sender(ctx);
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

// Public function that returns all tokens with swapped token at the end
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
        proposal::market_state_id(proposal) == coin_escrow::get_market_state_id(escrow),
        EMARKET_ID_MISMATCH,
    );
    let mut tokens = coin_escrow::mint_complete_set_stable(escrow, coin_in, clock, ctx);

    let mut swap_token = vector::remove(&mut tokens, outcome_idx);

    // Merge existing token if present
    assert!(token::outcome(&existing_token) == (outcome_idx as u8), EWRONG_OUTCOME);
    assert!(token::asset_type(&existing_token) == 1, EWRONG_TOKEN_TYPE);
    assert!(
        token::market_id(&existing_token) == market_state::market_id(coin_escrow::get_market_state(escrow)),
        EMARKET_ID_MISMATCH,
    );

    assert!(token::outcome(&swap_token) == (outcome_idx as u8), EWRONG_OUTCOME);
    let mut existing_token_in_vector = vector::empty();
    vector::push_back(&mut existing_token_in_vector, existing_token);
    token::merge_many(&mut swap_token, existing_token_in_vector, clock, ctx);

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

// Entry function that uses the public function and handles transfers
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

    let recipient = tx_context::sender(ctx);

    // Transfer all tokens to the recipient
    while (!vector::is_empty(&tokens)) {
        let token = vector::pop_back(&mut tokens);
        transfer::public_transfer(token, recipient);
    };
    transfer::public_transfer(asset_token, recipient);

    // Clean up the vector
    vector::destroy_empty(tokens);
}

// Public function that returns all tokens with swapped token at the end
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
        proposal::market_state_id(proposal) == coin_escrow::get_market_state_id(escrow),
        EMARKET_ID_MISMATCH,
    );
    let mut tokens = coin_escrow::mint_complete_set_asset(escrow, coin_in, clock, ctx);

    let mut swap_token = vector::remove(&mut tokens, outcome_idx);

    assert!(token::outcome(&existing_token) == (outcome_idx as u8), EWRONG_OUTCOME);
    assert!(token::asset_type(&existing_token) == 0, EWRONG_TOKEN_TYPE);
    assert!(
        token::market_id(&existing_token) == market_state::market_id(coin_escrow::get_market_state(escrow)),
        EMARKET_ID_MISMATCH,
    );

    assert!(token::outcome(&swap_token) == (outcome_idx as u8), EWRONG_OUTCOME);
    let mut existing_token_in_vector = vector::empty();
    vector::push_back(&mut existing_token_in_vector, existing_token);
    token::merge_many(&mut swap_token, existing_token_in_vector, clock, ctx);

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

// Entry function that uses the public function and handles transfers
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
    let (mut tokens, stable_token) =  create_and_swap_asset_to_stable_with_existing(
        proposal,
        escrow,
        outcome_idx,
        existing_token,
        min_amount_out,
        coin_in,
        clock,
        ctx,
    );

    let recipient = tx_context::sender(ctx);

    // Transfer all tokens to the recipient
    while (!vector::is_empty(&tokens)) {
        let token = vector::pop_back(&mut tokens);
        transfer::public_transfer(token, recipient);
    };
    transfer::public_transfer(stable_token, recipient);

    // Clean up the vector
    vector::destroy_empty(tokens);
}

// Public function that returns all tokens with swapped token at the end
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
        proposal::market_state_id(proposal) == coin_escrow::get_market_state_id(escrow),
        EMARKET_ID_MISMATCH,
    );
    let mut tokens = coin_escrow::mint_complete_set_asset(escrow, coin_in, clock, ctx);

    let token_to_swap = vector::remove(&mut tokens, outcome_idx);

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

// Entry function that uses the public function and handles transfers
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

    let recipient = tx_context::sender(ctx);

    // Transfer all tokens to the recipient
    while (!vector::is_empty(&tokens)) {
        let token = vector::pop_back(&mut tokens);
        transfer::public_transfer(token, recipient);
    };
    transfer::public_transfer(stable_token, recipient);

    // Clean up the vector
    vector::destroy_empty(tokens);
}

// Public function that returns all tokens with swapped token at the end
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
        proposal::market_state_id(proposal) == coin_escrow::get_market_state_id(escrow),
        EMARKET_ID_MISMATCH,
    );
    let mut tokens = coin_escrow::mint_complete_set_stable(escrow, coin_in, clock, ctx);

    let token_to_swap = vector::remove(&mut tokens, outcome_idx);

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

// Entry function that uses the public function and handles transfers
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

    let recipient = tx_context::sender(ctx);

    // Transfer all tokens to the recipient
    while (!vector::is_empty(&tokens)) {
        let token = vector::pop_back(&mut tokens);
        transfer::public_transfer(token, recipient);
    };
    transfer::public_transfer(asset_token, recipient);

    // Clean up the vector
    vector::destroy_empty(tokens);
}
