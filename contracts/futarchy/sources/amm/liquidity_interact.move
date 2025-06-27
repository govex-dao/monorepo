module futarchy::liquidity_interact;

use futarchy::coin_escrow::TokenEscrow;
use futarchy::conditional_token::ConditionalToken;
use futarchy::fee::FeeManager;
use futarchy::proposal::Proposal;
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;

// === Introduction ===
// Methods to interact with AMM liquidity and escrow balances

// === Errors ===
const EInvalidOutcome: u64 = 0;
const EInvalidLiquidityTransfer: u64 = 1;
const EWrongOutcome: u64 = 2;
const EInvalidState: u64 = 3;
const EMarketIdMismatch: u64 = 4;
const EAssetReservesMismatch: u64 = 5;
const EStableReservesMismatch: u64 = 6;

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
    assert!(outcome_idx < proposal.outcome_count(), EInvalidOutcome);
    assert!(proposal.is_finalized(), EInvalidState);
    assert!(ctx.sender() == proposal.proposer(), EInvalidLiquidityTransfer);
    assert!(outcome_idx == proposal.get_winning_outcome(), EWrongOutcome);

    // Validate that proposal and escrow belong to the same market
    let market_id = proposal.market_state_id();
    let escrow_market_id = escrow.get_market_state_id();
    assert!(market_id == escrow_market_id, EMarketIdMismatch);

    let market_state = escrow.get_market_state();
    market_state.assert_market_finalized();

    let pool = proposal.get_pool_mut_by_outcome((outcome_idx as u8));
    let (asset_out, stable_out) = pool.empty_all_amm_liquidity(ctx);

    // Call remove_liquidity and capture the returned coins
    let (asset_coin_out, stable_coin_out) = escrow.remove_liquidity(
        asset_out,
        stable_out,
        ctx,
    );
    // Transfer the withdrawn coins back to the proposer (the sender)
    transfer::public_transfer(asset_coin_out, ctx.sender());
    transfer::public_transfer(stable_coin_out, ctx.sender());

    assert_winning_reserves_consistency(proposal, escrow);
}

public fun assert_all_reserves_consistency<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
) {
    // Get outcome count
    let outcome_count = proposal.outcome_count();

    // Get escrow balances
    let (escrow_asset, escrow_stable) = escrow.get_balances();

    // Check each outcome
    let mut i = 0;
    while (i < outcome_count) {
        // Get pool for this outcome
        let pool = &proposal.get_amm_pools()[i];

        // Get reserves and fees
        let (amm_asset, amm_stable) = pool.get_reserves();
        let protocol_fees = pool.get_protocol_fees();

        // Get token supplies
        let (_, _, asset_supply, stable_supply) = escrow.get_escrow_balances_and_supply(
            i,
        );

        assert!(amm_asset + asset_supply == escrow_asset, EAssetReservesMismatch);

        // Verify stable equation: AMM stable reserves + protocol fees + stable token supply = escrow stable
        assert!(
            amm_stable + protocol_fees + stable_supply == escrow_stable,
            EStableReservesMismatch,
        );

        i = i + 1;
    };
}

public fun assert_winning_reserves_consistency<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
) {
    let winning_outcome = proposal.get_winning_outcome();

    // Get escrow balances
    let (escrow_asset, escrow_stable) = escrow.get_balances();

    // Get pool for this outcome
    let pool = &proposal.get_amm_pools()[winning_outcome];

    // Get reserves and fees
    let (amm_asset, amm_stable) = pool.get_reserves();
    let protocol_fees = pool.get_protocol_fees();

    // Get token supplies
    let (_, _, asset_supply, stable_supply) = escrow.get_escrow_balances_and_supply(
        winning_outcome,
    );

    assert!(amm_asset + asset_supply == escrow_asset, EAssetReservesMismatch);

    // Verify stable equation: AMM stable reserves + protocol fees + stable token supply = escrow stable
    assert!(amm_stable + protocol_fees + stable_supply == escrow_stable, EStableReservesMismatch);
}

/// Wrapper for redeeming winning stable tokens.
public entry fun redeem_winning_tokens_stable_entry<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Added
    escrow: &mut TokenEscrow<AssetType, StableType>,
    token: ConditionalToken,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let balance_out = escrow.redeem_winning_tokens_stable(token, clock, ctx);

    assert_winning_reserves_consistency(proposal, escrow);

    let coin_out = coin::from_balance(balance_out, ctx);
    transfer::public_transfer(coin_out, ctx.sender());
}

/// Wrapper for minting a complete set of asset tokens.
public entry fun mint_complete_set_asset_entry<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Added
    escrow: &mut TokenEscrow<AssetType, StableType>,
    coin_in: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut tokens_out = escrow.mint_complete_set_asset(coin_in, clock, ctx);

    // Assert consistency
    assert_all_reserves_consistency(proposal, escrow);

    let recipient = ctx.sender();
    while (!tokens_out.is_empty()) {
        let token = tokens_out.pop_back();
        transfer::public_transfer(token, recipient);
    };
    tokens_out.destroy_empty();
}

/// Wrapper for minting a complete set of stable tokens.
public entry fun mint_complete_set_stable_entry<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Added
    escrow: &mut TokenEscrow<AssetType, StableType>,
    coin_in: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut tokens_out = escrow.mint_complete_set_stable(coin_in, clock, ctx);

    assert_all_reserves_consistency(proposal, escrow);

    // Handle result (transfer tokens)
    let recipient = ctx.sender();
    while (!tokens_out.is_empty()) {
        let token = tokens_out.pop_back();
        transfer::public_transfer(token, recipient);
    };
    tokens_out.destroy_empty();
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
    let balance_out = escrow.redeem_complete_set_asset(tokens, clock, ctx);

    // Assert consistency
    assert_all_reserves_consistency(proposal, escrow);

    // Handle result (transfer coin)
    let coin_out = coin::from_balance(balance_out, ctx);
    transfer::public_transfer(coin_out, ctx.sender());
}

/// Wrapper for redeeming a complete set of stable tokens.
public entry fun redeem_complete_set_stable_entry<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Added
    escrow: &mut TokenEscrow<AssetType, StableType>,
    tokens: vector<ConditionalToken>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let balance_out = escrow.redeem_complete_set_stable(tokens, clock, ctx);

    assert_all_reserves_consistency(proposal, escrow);

    // Handle result (transfer coin)
    let coin_out = coin::from_balance(balance_out, ctx);
    transfer::public_transfer(coin_out, ctx.sender());
}

public entry fun redeem_winning_tokens_asset_entry<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Added
    escrow: &mut TokenEscrow<AssetType, StableType>,
    token: ConditionalToken,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let balance_out = escrow.redeem_winning_tokens_asset(token, clock, ctx);

    // Pass ctx only if the assert function requires it
    assert_winning_reserves_consistency(proposal, escrow);

    // Handle result (transfer coin)
    let coin_out = coin::from_balance(balance_out, ctx);
    transfer::public_transfer(coin_out, ctx.sender());
}

public fun redeem_winning_tokens_stable<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Read-only needed for assertion & checks
    escrow: &mut TokenEscrow<AssetType, StableType>,
    token: ConditionalToken,
    clock: &Clock,
    ctx: &mut TxContext, // Still needed for coin_escrow call
): Balance<StableType> {
    // Pre-checks using proposal state
    assert!(proposal.is_finalized(), EInvalidState);
    let winning_outcome = proposal.get_winning_outcome();
    assert!(token.outcome() == (winning_outcome as u8), EWrongOutcome);

    // Call the core logic in coin_escrow
    let balance_out = escrow.redeem_winning_tokens_stable(token, clock, ctx);

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
    assert!(proposal.is_finalized(), EInvalidState);
    let winning_outcome = proposal.get_winning_outcome();
    assert!(token.outcome() == (winning_outcome as u8), EWrongOutcome);

    // Call the core logic in coin_escrow
    let balance_out = escrow.redeem_winning_tokens_asset(token, clock, ctx);

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
    assert!(!proposal.is_finalized(), EInvalidState);

    // Call the core logic in coin_escrow
    let tokens_out = escrow.mint_complete_set_asset(coin_in, clock, ctx);

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
    assert!(!proposal.is_finalized(), EInvalidState);

    // Call the core logic in coin_escrow
    let tokens_out = escrow.mint_complete_set_stable(coin_in, clock, ctx);

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
    assert!(!proposal.is_finalized(), EInvalidState);

    // Call the core logic in coin_escrow
    let balance_out = escrow.redeem_complete_set_asset(tokens, clock, ctx);

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
    assert!(!proposal.is_finalized(), EInvalidState);

    // Call the core logic in coin_escrow
    let balance_out = escrow.redeem_complete_set_stable(tokens, clock, ctx);

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
    assert!(proposal.is_finalized(), EInvalidState);

    // 2. Call the package-private burn function in coin_escrow
    // This function will handle all individual token checks and burning.
    escrow.burn_unused_tokens(
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
    assert!(proposal.is_finalized(), EInvalidState);
    assert!(proposal.is_winning_outcome_set(), EInvalidState);

    assert!(escrow.get_market_state_id() == proposal.market_state_id(), EInvalidState);

    let winning_outcome = proposal.get_winning_outcome();
    let winning_pool = proposal.get_pool_mut_by_outcome((winning_outcome as u8));
    let protocol_fee_amount = winning_pool.get_protocol_fees();

    if (protocol_fee_amount > 0) {
        // Reset fees in the pool
        winning_pool.reset_protocol_fees();

        // Extract the fees from escrow
        let fee_balance = escrow.extract_stable_fees<AssetType, StableType>(
            protocol_fee_amount,
        );

        // Deposit to fee manager
        fee_manager.deposit_stable_fees<StableType>(
            fee_balance,
            proposal.get_id(),
            clock,
        );

        assert_winning_reserves_consistency(proposal, escrow);

        // Emit event
        event::emit(ProtocolFeesCollected {
            proposal_id: proposal.get_id(),
            winning_outcome,
            fee_amount: protocol_fee_amount,
            timestamp_ms: clock.timestamp_ms(),
        });
    }
}

#[test_only]
public(package) fun get_liquidity_for_proposal<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): vector<u64> {
    let pools = proposal.get_amm_pools();
    let mut liquidity = vector[];
    let mut i = 0;
    while (i < pools.length()) {
        let pool = &pools[i];
        let (asset, stable) = pool.get_reserves();
        liquidity.push_back(asset);
        liquidity.push_back(stable);
        i = i + 1;
    };
    liquidity
}
