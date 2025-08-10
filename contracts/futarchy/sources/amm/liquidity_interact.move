module futarchy::liquidity_interact;

use futarchy::amm;
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

// === Helper Functions ===
/// Efficiently transfers all tokens in a vector to the recipient
fun transfer_tokens_to_recipient(mut tokens: vector<ConditionalToken>, recipient: address) {
    while (!tokens.is_empty()) {
        transfer::public_transfer(tokens.pop_back(), recipient);
    };
    tokens.destroy_empty();
}

/// Empties the winning AMM pool and transfers the underlying liquidity to the original provider.
/// Called internally by `advance_stage` when a user-funded proposal finalizes.
public(package) fun empty_amm_and_return_to_provider<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    ctx: &mut TxContext,
) {
    assert!(proposal.is_finalized(), EInvalidState);
    assert!(!proposal.uses_dao_liquidity(), EInvalidState);

    // Validate that proposal and escrow belong to the same market
    let market_id = proposal.market_state_id();
    let escrow_market_id = escrow.get_market_state_id();
    assert!(market_id == escrow_market_id, EMarketIdMismatch);
    let market_state = escrow.get_market_state();
    let winning_outcome = proposal.get_winning_outcome();
    market_state.assert_market_finalized();

    let pool = proposal.get_pool_mut_by_outcome((winning_outcome as u8));
    let (asset_out, stable_out) = pool.empty_all_amm_liquidity(ctx);

    let (asset_coin, stable_coin) = escrow.remove_liquidity(asset_out, stable_out, ctx);
    
    let provider = *proposal.get_liquidity_provider().borrow();
    transfer::public_transfer(asset_coin, provider);
    transfer::public_transfer(stable_coin, provider);

    assert_winning_reserves_consistency(proposal, escrow);
}

/// Empties the winning AMM pool and returns the liquidity.
/// Called internally by `advance_stage` when a DAO-funded proposal finalizes.
/// Returns the asset and stable coins for the DAO to handle (e.g., deposit to vault).
public(package) fun empty_amm_and_return_to_dao<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    ctx: &mut TxContext,
): (Coin<AssetType>, Coin<StableType>) {
    assert!(proposal.is_finalized(), EInvalidState);
    assert!(proposal.uses_dao_liquidity(), EInvalidState);

    let market_id = proposal.market_state_id();
    let escrow_market_id = escrow.get_market_state_id();
    assert!(market_id == escrow_market_id, EMarketIdMismatch);
    escrow.get_market_state().assert_market_finalized();

    let winning_outcome = proposal.get_winning_outcome();
    let pool = proposal.get_pool_mut_by_outcome((winning_outcome as u8));
    let (asset_out, stable_out) = pool.empty_all_amm_liquidity(ctx);

    let (asset_coin, stable_coin) = escrow.remove_liquidity(asset_out, stable_out, ctx);
    
    // Return coins for the caller to handle (deposit to vault, add to spot pool, etc.)
    (asset_coin, stable_coin)
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
        // Protocol fees are explicitly collected and held outside the AMM's stable reserve.
        // Note: protocol_fees are tracked separately in pool.protocol_fees and are NOT included in amm_stable
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
    // Note: protocol_fees are tracked separately in pool.protocol_fees and are NOT included in amm_stable
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
    let tokens_out = escrow.mint_complete_set_asset(coin_in, clock, ctx);

    // Assert consistency
    assert_all_reserves_consistency(proposal, escrow);

    transfer_tokens_to_recipient(tokens_out, ctx.sender());
}

/// Wrapper for minting a complete set of stable tokens.
public entry fun mint_complete_set_stable_entry<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>, // Added
    escrow: &mut TokenEscrow<AssetType, StableType>,
    coin_in: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let tokens_out = escrow.mint_complete_set_stable(coin_in, clock, ctx);

    assert_all_reserves_consistency(proposal, escrow);

    transfer_tokens_to_recipient(tokens_out, ctx.sender());
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

// === AMM Liquidity Management Entry Points ===

/// Add liquidity to an AMM pool for a specific outcome
/// Takes asset and stable conditional tokens and returns LP tokens
public entry fun add_liquidity_entry<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    asset_in: ConditionalToken,
    stable_in: ConditionalToken,
    min_lp_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify market state consistency
    assert!(proposal.market_state_id() == escrow.get_market_state_id(), EMarketIdMismatch);
    assert!(!proposal.is_finalized(), EInvalidState);
    
    // Verify tokens match the pool's outcome
    assert!(asset_in.market_id() == proposal.market_state_id(), EMarketIdMismatch);
    assert!(stable_in.market_id() == proposal.market_state_id(), EMarketIdMismatch);
    assert!(asset_in.outcome() == (outcome_idx as u8), EWrongOutcome);
    assert!(stable_in.outcome() == (outcome_idx as u8), EWrongOutcome);
    assert!(asset_in.asset_type() == 0, EInvalidState); // Must be asset token
    assert!(stable_in.asset_type() == 1, EInvalidState); // Must be stable token
    
    let asset_amount = asset_in.value();
    let stable_amount = stable_in.value();
    
    // Burn the conditional tokens (they'll be absorbed into the pool)
    escrow.burn_single_conditional_token(asset_in, clock, ctx);
    escrow.burn_single_conditional_token(stable_in, clock, ctx);
    
    // Get the pool for this outcome
    let pool = proposal.get_pool_mut_by_outcome((outcome_idx as u8));
    
    // Add liquidity through the AMM (only calculations and reserve updates)
    let lp_amount = amm::add_liquidity_proportional(
        pool,
        asset_amount,
        stable_amount,
        min_lp_out,
        clock,
        ctx
    );
    
    // Mint LP tokens
    let lp_token = escrow.mint_single_conditional_token(
        2, // TOKEN_TYPE_LP
        (outcome_idx as u8),
        lp_amount,
        ctx.sender(),
        clock,
        ctx
    );
    
    // Assert consistency after operation
    assert_all_reserves_consistency(proposal, escrow);
    
    // Transfer LP token to the sender
    transfer::public_transfer(lp_token, ctx.sender());
}

/// Remove liquidity from an AMM pool proportionally
/// Takes LP tokens and returns asset and stable conditional tokens
public entry fun remove_liquidity_entry<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    lp_token: ConditionalToken,
    min_asset_out: u64,
    min_stable_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify market state consistency
    assert!(proposal.market_state_id() == escrow.get_market_state_id(), EMarketIdMismatch);
    assert!(!proposal.is_finalized(), EInvalidState);
    
    // Verify LP token is for the correct outcome and market
    assert!(lp_token.market_id() == proposal.market_state_id(), EMarketIdMismatch);
    assert!(lp_token.outcome() == (outcome_idx as u8), EWrongOutcome);
    assert!(lp_token.asset_type() == 2, EInvalidState); // Must be LP token
    
    let lp_amount = lp_token.value();
    
    // Burn the LP token
    escrow.burn_single_conditional_token(lp_token, clock, ctx);
    
    // Get the pool for this outcome
    let pool = proposal.get_pool_mut_by_outcome((outcome_idx as u8));
    
    // Remove liquidity through the AMM (only calculations and reserve updates)
    let (asset_amount, stable_amount) = amm::remove_liquidity_proportional(
        pool,
        lp_amount,
        clock,
        ctx
    );
    
    // Verify slippage protection
    assert!(asset_amount >= min_asset_out, EInvalidState);
    assert!(stable_amount >= min_stable_out, EInvalidState);
    
    // Mint the asset and stable tokens
    let asset_token = escrow.mint_single_conditional_token(
        0, // TOKEN_TYPE_ASSET
        (outcome_idx as u8),
        asset_amount,
        ctx.sender(),
        clock,
        ctx
    );
    
    let stable_token = escrow.mint_single_conditional_token(
        1, // TOKEN_TYPE_STABLE
        (outcome_idx as u8),
        stable_amount,
        ctx.sender(),
        clock,
        ctx
    );
    
    // Assert consistency after operation
    assert_all_reserves_consistency(proposal, escrow);
    
    // Transfer tokens to the sender
    transfer::public_transfer(asset_token, ctx.sender());
    transfer::public_transfer(stable_token, ctx.sender());
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
