module futarchy::liquidity_interact;

use futarchy::amm;
use futarchy::coin_escrow::{Self, TokenEscrow};
use futarchy::conditional_token::{Self as token, ConditionalToken};
use futarchy::fee::{Self, FeeManager};
use futarchy::market_state;
use futarchy::proposal::{Self, Proposal};
use sui::balance::Balance;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;

// === Introduction ===
// Methods to interact with AMM liquidity and escrow balances

// ====== Error Codes ======
const EINVALID_OUTCOME: u64 = 0;
const EINVALID_LIQUIDITY_TRANSFER: u64 = 1;
const EWRONG_OUTCOME: u64 = 2;
const EINVALID_STATE: u64 = 3;
const EMARKET_ID_MISMATCH: u64 = 4;
const EASSET_RESERVES_MISMATCH: u64 = 5;
const ESTABLE_RESERVES_MISMATCH: u64 = 6;

// === Events ===
public struct ProtocolFeesCollected has copy, drop {
    proposal_id: ID,
    winning_outcome: u64,
    fee_amount: u64,
    timestamp_ms: u64,
}

public entry fun empty_all_amm_liquidity<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    ctx: &mut TxContext,
) {
    assert!(outcome_idx < proposal::outcome_count(proposal), EINVALID_OUTCOME);
    assert!(proposal::is_finalized(proposal), EINVALID_STATE);
    assert!(tx_context::sender(ctx) == proposal::proposer(proposal), EINVALID_LIQUIDITY_TRANSFER);
    assert!(outcome_idx == proposal::get_winning_outcome(proposal), EWRONG_OUTCOME);

    // Validate that proposal and escrow belong to the same market
    let market_id = proposal::market_state_id(proposal);
    let escrow_market_id = coin_escrow::get_market_state_id(escrow);
    assert!(market_id == escrow_market_id, EMARKET_ID_MISMATCH);

    let market_state = coin_escrow::get_market_state(escrow);
    market_state::assert_market_finalized(market_state);

    let pool = proposal::get_pool_mut_by_outcome(proposal, (outcome_idx as u8));
    let (asset_out, stable_out) = amm::empty_all_amm_liquidity(pool, ctx);

    // Call remove_liquidity and capture the returned coins
    let (asset_coin_out, stable_coin_out) = coin_escrow::remove_liquidity(
        escrow,
        asset_out,
        stable_out,
        ctx,
    );
    // Transfer the withdrawn coins back to the proposer (the sender)
    transfer::public_transfer(asset_coin_out, tx_context::sender(ctx));
    transfer::public_transfer(stable_coin_out, tx_context::sender(ctx));

    assert_winning_reserves_consistency(proposal, escrow);
}

public fun assert_all_reserves_consistency<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
) {
    // Get outcome count
    let outcome_count = proposal::outcome_count(proposal);

    // Get escrow balances
    let (escrow_asset, escrow_stable) = coin_escrow::get_balances(escrow);

    // Check each outcome
    let mut i = 0;
    while (i < outcome_count) {
        // Get pool for this outcome
        let pool = vector::borrow(proposal::get_amm_pools(proposal), i);

        // Get reserves and fees
        let (amm_asset, amm_stable) = amm::get_reserves(pool);
        let protocol_fees = amm::get_protocol_fees(pool);

        // Get token supplies
        let (_, _, asset_supply, stable_supply) = coin_escrow::get_escrow_balances_and_supply(
            escrow,
            i,
        );

        assert!(amm_asset + asset_supply == escrow_asset, EASSET_RESERVES_MISMATCH);

        // Verify stable equation: AMM stable reserves + protocol fees + stable token supply = escrow stable
        assert!(
            amm_stable + protocol_fees + stable_supply == escrow_stable,
            ESTABLE_RESERVES_MISMATCH,
        );

        i = i + 1;
    };
}

public fun assert_winning_reserves_consistency<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
) {
    let winning_outcome = proposal::get_winning_outcome(proposal);

    // Get escrow balances
    let (escrow_asset, escrow_stable) = coin_escrow::get_balances(escrow);

    // Get pool for this outcome
    let pool = vector::borrow(proposal::get_amm_pools(proposal), winning_outcome);

    // Get reserves and fees
    let (amm_asset, amm_stable) = amm::get_reserves(pool);
    let protocol_fees = amm::get_protocol_fees(pool);

    // Get token supplies
    let (_, _, asset_supply, stable_supply) = coin_escrow::get_escrow_balances_and_supply(
        escrow,
        winning_outcome,
    );

    assert!(amm_asset + asset_supply == escrow_asset, EASSET_RESERVES_MISMATCH);

    // Verify stable equation: AMM stable reserves + protocol fees + stable token supply = escrow stable
    assert!(amm_stable + protocol_fees + stable_supply == escrow_stable, ESTABLE_RESERVES_MISMATCH);
}

/// Wrapper for redeeming winning stable tokens.
public entry fun redeem_winning_tokens_stable_entry<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Added
    escrow: &mut TokenEscrow<AssetType, StableType>,
    token: ConditionalToken,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let balance_out = coin_escrow::redeem_winning_tokens_stable(escrow, token, clock, ctx);

    assert_winning_reserves_consistency(proposal, escrow);

    let coin_out = coin::from_balance(balance_out, ctx);
    transfer::public_transfer(coin_out, tx_context::sender(ctx));
}

/// Wrapper for minting a complete set of asset tokens.
public entry fun mint_complete_set_asset_entry<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Added
    escrow: &mut TokenEscrow<AssetType, StableType>,
    coin_in: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut tokens_out = coin_escrow::mint_complete_set_asset(escrow, coin_in, clock, ctx);

    // Assert consistency
    assert_all_reserves_consistency(proposal, escrow);

    let recipient = tx_context::sender(ctx);
    while (!vector::is_empty(&tokens_out)) {
        let token = vector::pop_back(&mut tokens_out);
        transfer::public_transfer(token, recipient);
    };
    vector::destroy_empty(tokens_out);
}

/// Wrapper for minting a complete set of stable tokens.
public entry fun mint_complete_set_stable_entry<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Added
    escrow: &mut TokenEscrow<AssetType, StableType>,
    coin_in: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut tokens_out = coin_escrow::mint_complete_set_stable(escrow, coin_in, clock, ctx);

    assert_all_reserves_consistency(proposal, escrow);

    // Handle result (transfer tokens)
    let recipient = tx_context::sender(ctx);
    while (!vector::is_empty(&tokens_out)) {
        let token = vector::pop_back(&mut tokens_out);
        transfer::public_transfer(token, recipient);
    };
    vector::destroy_empty(tokens_out);
}

/// Wrapper for redeeming a complete set of asset tokens.
public entry fun redeem_complete_set_asset_entry<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Added
    escrow: &mut TokenEscrow<AssetType, StableType>,
    tokens: vector<ConditionalToken>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Call the underlying package function from coin_escrow
    let balance_out = coin_escrow::redeem_complete_set_asset(escrow, tokens, clock, ctx);

    // Assert consistency
    assert_all_reserves_consistency(proposal, escrow);

    // Handle result (transfer coin)
    let coin_out = coin::from_balance(balance_out, ctx);
    transfer::public_transfer(coin_out, tx_context::sender(ctx));
}

/// Wrapper for redeeming a complete set of stable tokens.
public entry fun redeem_complete_set_stable_entry<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Added
    escrow: &mut TokenEscrow<AssetType, StableType>,
    tokens: vector<ConditionalToken>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let balance_out = coin_escrow::redeem_complete_set_stable(escrow, tokens, clock, ctx);

    assert_all_reserves_consistency(proposal, escrow);

    // Handle result (transfer coin)
    let coin_out = coin::from_balance(balance_out, ctx);
    transfer::public_transfer(coin_out, tx_context::sender(ctx));
}

public entry fun redeem_winning_tokens_asset_entry<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Added
    escrow: &mut TokenEscrow<AssetType, StableType>,
    token: ConditionalToken,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let balance_out = coin_escrow::redeem_winning_tokens_asset(escrow, token, clock, ctx);

    // Pass ctx only if the assert function requires it
    assert_winning_reserves_consistency(proposal, escrow);

    // Handle result (transfer coin)
    let coin_out = coin::from_balance(balance_out, ctx);
    transfer::public_transfer(coin_out, tx_context::sender(ctx));
}

public fun redeem_winning_tokens_stable<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Read-only needed for assertion & checks
    escrow: &mut TokenEscrow<AssetType, StableType>,
    token: ConditionalToken,
    clock: &Clock,
    ctx: &mut TxContext, // Still needed for coin_escrow call
): Balance<StableType> {
    // Pre-checks using proposal state
    assert!(proposal::is_finalized(proposal), EINVALID_STATE);
    let winning_outcome = proposal::get_winning_outcome(proposal);
    assert!(token::outcome(&token) == (winning_outcome as u8), EWRONG_OUTCOME);

    // Call the core logic in coin_escrow
    let balance_out = coin_escrow::redeem_winning_tokens_stable(escrow, token, clock, ctx);

    assert_winning_reserves_consistency(proposal, escrow);

    // Return the result
    balance_out
}

/// Redeems a winning asset token after the market has finalized.
/// Returns the Balance<AssetType> for use in PTBs.
public fun redeem_winning_tokens_asset<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Read-only needed for assertion & checks
    escrow: &mut TokenEscrow<AssetType, StableType>,
    token: ConditionalToken,
    clock: &Clock,
    ctx: &mut TxContext, // Still needed for coin_escrow call
): Balance<AssetType> {
    // Pre-checks using proposal state
    assert!(proposal::is_finalized(proposal), EINVALID_STATE);
    let winning_outcome = proposal::get_winning_outcome(proposal);
    assert!(token::outcome(&token) == (winning_outcome as u8), EWRONG_OUTCOME);

    // Call the core logic in coin_escrow
    let balance_out = coin_escrow::redeem_winning_tokens_asset(escrow, token, clock, ctx);

    assert_winning_reserves_consistency(proposal, escrow);

    // Return the result
    balance_out
}

/// Mints a complete set of asset tokens by depositing the base asset.
/// Returns the vector<ConditionalToken> for use in PTBs.
public fun mint_complete_set_asset<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Read-only needed for assertion
    escrow: &mut TokenEscrow<AssetType, StableType>,
    coin_in: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext, // Still needed for coin_escrow call
): vector<ConditionalToken> {
    // Optional pre-checks using proposal state
    assert!(!proposal::is_finalized(proposal), EINVALID_STATE);

    // Call the core logic in coin_escrow
    let tokens_out = coin_escrow::mint_complete_set_asset(escrow, coin_in, clock, ctx);

    assert_all_reserves_consistency(proposal, escrow);

    // Return the result
    tokens_out
}

/// Mints a complete set of stable tokens by depositing the stable coin.
/// Returns the vector<ConditionalToken> for use in PTBs.
public fun mint_complete_set_stable<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Read-only needed for assertion
    escrow: &mut TokenEscrow<AssetType, StableType>,
    coin_in: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext, // Still needed for coin_escrow call
): vector<ConditionalToken> {
    // Optional pre-checks using proposal state
    assert!(!proposal::is_finalized(proposal), EINVALID_STATE);

    // Call the core logic in coin_escrow
    let tokens_out = coin_escrow::mint_complete_set_stable(escrow, coin_in, clock, ctx);

    assert_all_reserves_consistency(proposal, escrow);

    // Return the result
    tokens_out
}

/// Redeems a complete set of asset tokens for the base asset.
/// Returns the Balance<AssetType> for use in PTBs.
public fun redeem_complete_set_asset<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Read-only needed for assertion
    escrow: &mut TokenEscrow<AssetType, StableType>,
    tokens: vector<ConditionalToken>, // Consumed by the call
    clock: &Clock,
    ctx: &mut TxContext, // Still needed for coin_escrow call
): Balance<AssetType> {
    // Optional pre-checks using proposal state
    assert!(!proposal::is_finalized(proposal), EINVALID_STATE);

    // Call the core logic in coin_escrow
    let balance_out = coin_escrow::redeem_complete_set_asset(escrow, tokens, clock, ctx);

    assert_all_reserves_consistency(proposal, escrow);

    // Return the result
    balance_out
}

/// Redeems a complete set of stable tokens for the stable coin.
/// Returns the Balance<StableType> for use in PTBs.
public fun redeem_complete_set_stable<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Read-only needed for assertion
    escrow: &mut TokenEscrow<AssetType, StableType>,
    tokens: vector<ConditionalToken>, // Consumed by the call
    clock: &Clock,
    ctx: &mut TxContext, // Still needed for coin_escrow call
): Balance<StableType> {
    // Optional pre-checks using proposal state
    assert!(!proposal::is_finalized(proposal), EINVALID_STATE);

    // Call the core logic in coin_escrow
    let balance_out = coin_escrow::redeem_complete_set_stable(escrow, tokens, clock, ctx);

    // Assert consistency AFTER the operation
    assert_all_reserves_consistency(proposal, escrow);

    // Return the result
    balance_out
}

public entry fun burn_unused_tokens_entry<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Read-only for checks and assert
    escrow: &mut TokenEscrow<AssetType, StableType>, // Mutable for burning
    tokens_to_burn: vector<ConditionalToken>, // Consumed by the call
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // 1. Pre-check: Ensure the proposal (and thus market) is finalized
    // This aligns with the check inside coin_escrow::burn_unused_tokens
    assert!(proposal::is_finalized(proposal), EINVALID_STATE);

    // 2. Call the package-private burn function in coin_escrow
    // This function will handle all individual token checks and burning.
    coin_escrow::burn_unused_tokens(
        escrow,
        tokens_to_burn, // The vector is consumed here
        clock,
        ctx,
    );

    // 3. Assert reserve consistency for the winning outcome AFTER burning
    // Burning non-winning tokens should not affect the winning outcome's
    // reserves or its supply, so this check should pass if the state was
    // consistent before the call.
    assert_winning_reserves_consistency(proposal, escrow);
}

public(package) fun collect_protocol_fees<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    fee_manager: &mut FeeManager,
    clock: &Clock,
) {
    // Can only collect fees if the proposal is finalized
    assert!(proposal::is_finalized(proposal), EINVALID_STATE);
    assert!(proposal::is_winning_outcome_set(proposal), EINVALID_STATE);

    assert!(
        coin_escrow::get_market_state_id(escrow) == proposal::market_state_id(proposal),
        EINVALID_STATE,
    );

    let winning_outcome = proposal::get_winning_outcome(proposal);
    let winning_pool = proposal::get_pool_mut_by_outcome(proposal, (winning_outcome as u8));
    let protocol_fee_amount = amm::get_protocol_fees(winning_pool);

    if (protocol_fee_amount > 0) {
        // Reset fees in the pool
        amm::reset_protocol_fees(winning_pool);

        // Extract the fees from escrow
        let fee_balance = coin_escrow::extract_stable_fees<AssetType, StableType>(
            escrow,
            protocol_fee_amount,
        );

        // Deposit to fee manager
        fee::deposit_stable_fees<StableType>(
            fee_manager,
            fee_balance,
            proposal::get_id(proposal),
            clock,
        );

        assert_winning_reserves_consistency(proposal, escrow);

        // Emit event
        event::emit(ProtocolFeesCollected {
            proposal_id: proposal::get_id(proposal),
            winning_outcome,
            fee_amount: protocol_fee_amount,
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }
}

#[test_only]
public(package) fun get_liquidity_for_proposal<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): vector<u64> {
    let pools = proposal::get_amm_pools(proposal);
    let mut liquidity = vector::empty<u64>();
    let mut i = 0;
    while (i < vector::length(pools)) {
        let pool = vector::borrow(pools, i);
        let (asset, stable) = amm::get_reserves(pool);
        vector::push_back(&mut liquidity, asset);
        vector::push_back(&mut liquidity, stable);
        i = i + 1;
    };
    liquidity
}
