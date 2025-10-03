/// Conditional Token Holder - Stores extra tokens from swaps for auto-redemption
///
/// When users swap through conditional markets, price differences can result in extra
/// conditional tokens. Instead of returning these immediately, users can optionally
/// leave them in the holder for a fixed 0.01 SUI fee. When the proposal ends, keepers can:
/// - Redeem winning tokens for spot tokens and auto-crank to users (earn 0.01 SUI)
/// - Delete losing tokens for cleanup (earn 0.01 SUI)
///
/// Benefits:
/// - Simplifies aggregator integration (less complex token handling)
/// - Fixed, predictable cost for users (0.01 SUI per storage)
/// - Simple keeper incentive (0.01 SUI per crank/cleanup)
/// - Auto-settlement convenience for users
///
/// Architecture: Uses dynamic fields for scalability
/// - No hot shared object contention (each storage is independent)
/// - Lower gas costs compared to nested tables
/// - Better for high-throughput aggregator integrations
module futarchy_markets::conditional_token_holder;

use futarchy_markets::conditional_token::ConditionalToken;
use futarchy_markets::coin_escrow::TokenEscrow;
use futarchy_markets::proposal::Proposal;
use sui::coin::{Self, Coin};
use sui::balance::{Self, Balance};
use sui::dynamic_field as df;
use sui::event;

// === Errors ===
const EProposalNotFinalized: u64 = 0;
const ENoTokensStored: u64 = 1;
const EInsufficientFee: u64 = 2;
const ENotWinningOutcome: u64 = 3;
const EMarketIdMismatch: u64 = 4;
const EInsufficientKeeperFees: u64 = 5;

// === Constants ===
const HOLDER_FEE_PER_STORAGE: u64 = 10_000_000; // 0.01 SUI in MIST (1 SUI = 1e9 MIST)

// === Structs ===

/// Global registry for conditional token holdings
/// Uses dynamic fields to avoid nested table contention
public struct ConditionalTokenHolder has key {
    id: UID,
    /// Fees available for keepers to claim (in SUI)
    keeper_fees: Balance<sui::sui::SUI>,
}

/// Key for dynamic field lookup: (proposal_id, user, outcome)
public struct HoldingKey has store, copy, drop {
    proposal_id: ID,
    user: address,
    outcome: u8,
}

/// Value stored in dynamic field
public struct Holding has store {
    tokens: ConditionalToken,
}

// === Events ===

public struct TokensDeposited has copy, drop {
    proposal_id: ID,
    user: address,
    outcome: u8,
    amount: u64,
    fee_paid: u64,
}

public struct TokensRedeemed has copy, drop {
    proposal_id: ID,
    user: address,
    outcome: u8,
    amount: u64,
    keeper: address,
    keeper_reward: u64,
}

public struct LosingTokensDeleted has copy, drop {
    proposal_id: ID,
    user: address,
    outcome: u8,
    amount_deleted: u64,
    keeper: address,
}

// === Public Functions ===

/// Initialize a new ConditionalTokenHolder
fun init(ctx: &mut TxContext) {
    let holder = ConditionalTokenHolder {
        id: object::new(ctx),
        keeper_fees: balance::zero(),
    };
    transfer::share_object(holder);
}

/// Store extra conditional tokens from a swap for later auto-redemption
public fun store_tokens_with_fee<AssetType, StableType>(
    holder: &mut ConditionalTokenHolder,
    proposal: &Proposal<AssetType, StableType>,
    tokens: ConditionalToken,
    mut fee: Coin<sui::sui::SUI>,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
) {
    let proposal_id = proposal.proposal_id();
    let user = ctx.sender();
    let outcome = tokens.outcome();
    let amount = tokens.value();

    // P0.2: Validate tokens belong to this proposal
    assert!(tokens.market_id() == proposal_id, EMarketIdMismatch);

    // P0.1: Fix fee overpayment - take only required amount, return excess
    assert!(fee.value() >= HOLDER_FEE_PER_STORAGE, EInsufficientFee);

    let fee_to_take = if (fee.value() > HOLDER_FEE_PER_STORAGE) {
        let excess_amount = fee.value() - HOLDER_FEE_PER_STORAGE;
        let excess = fee.split(excess_amount, ctx);
        transfer::public_transfer(excess, user);
        fee.into_balance()
    } else {
        fee.into_balance()
    };

    holder.keeper_fees.join(fee_to_take);

    let key = HoldingKey { proposal_id, user, outcome };

    // Store or merge tokens using dynamic fields
    if (df::exists_(&holder.id, key)) {
        let holding: &mut Holding = df::borrow_mut(&mut holder.id, key);
        holding.tokens.merge_many(vector[tokens], clock, ctx);
    } else {
        df::add(&mut holder.id, key, Holding { tokens });
    };

    event::emit(TokensDeposited {
        proposal_id,
        user,
        outcome,
        amount,
        fee_paid: HOLDER_FEE_PER_STORAGE,
    });
}

/// Keeper function: Redeem winning tokens and auto-crank to user
/// Keeper gets 0.01 SUI fee, user gets 100% of their winning tokens redeemed
public fun keeper_redeem_winning_tokens<AssetType, StableType>(
    holder: &mut ConditionalTokenHolder,
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    user: address,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
) {
    let proposal_id = proposal.proposal_id();
    let market_state = escrow.get_market_state();

    // Ensure proposal is finalized
    assert!(market_state.is_finalized(), EProposalNotFinalized);

    let winning_outcome = (market_state.get_winning_outcome() as u8);
    let key = HoldingKey { proposal_id, user, outcome: winning_outcome };

    // Get user's tokens for winning outcome
    assert!(df::exists_(&holder.id, key), ENoTokensStored);
    let Holding { tokens } = df::remove(&mut holder.id, key);

    let total_amount = tokens.value();
    let asset_type = tokens.asset_type();

    // P0.3: Guarantee keeper payment with assert
    assert!(holder.keeper_fees.value() >= HOLDER_FEE_PER_STORAGE, EInsufficientKeeperFees);
    let reward = holder.keeper_fees.split(HOLDER_FEE_PER_STORAGE);
    transfer::public_transfer(coin::from_balance(reward, ctx), ctx.sender());

    // Redeem ALL tokens to user (no keeper taking from tokens)
    if (asset_type == 0) { // Asset type
        let user_balance = escrow.redeem_winning_tokens_asset(tokens, clock, ctx);
        transfer::public_transfer(coin::from_balance(user_balance, ctx), user);
    } else { // Stable type
        let user_balance = escrow.redeem_winning_tokens_stable(tokens, clock, ctx);
        transfer::public_transfer(coin::from_balance(user_balance, ctx), user);
    };

    event::emit(TokensRedeemed {
        proposal_id,
        user,
        outcome: winning_outcome,
        amount: total_amount,
        keeper: ctx.sender(),
        keeper_reward: HOLDER_FEE_PER_STORAGE,
    });
}

/// Keeper function: Delete losing outcome tokens for cleanup
/// Keeper gets 0.01 SUI fee for cleanup work
public fun keeper_delete_losing_tokens<AssetType, StableType>(
    holder: &mut ConditionalTokenHolder,
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    user: address,
    outcome: u8,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
) {
    let proposal_id = proposal.proposal_id();
    let market_state = escrow.get_market_state();

    // Ensure proposal is finalized
    assert!(market_state.is_finalized(), EProposalNotFinalized);

    let winning_outcome = (market_state.get_winning_outcome() as u8);
    assert!(outcome != winning_outcome, ENotWinningOutcome);

    let key = HoldingKey { proposal_id, user, outcome };

    // Get and delete losing tokens
    assert!(df::exists_(&holder.id, key), ENoTokensStored);
    let Holding { tokens } = df::remove(&mut holder.id, key);

    let amount = tokens.value();

    // Burn the losing tokens using escrow's burn function
    escrow.burn_unused_tokens(vector[tokens], clock, ctx);

    // P0.3: Guarantee keeper payment with assert
    assert!(holder.keeper_fees.value() >= HOLDER_FEE_PER_STORAGE, EInsufficientKeeperFees);
    let reward = holder.keeper_fees.split(HOLDER_FEE_PER_STORAGE);
    transfer::public_transfer(coin::from_balance(reward, ctx), ctx.sender());

    event::emit(LosingTokensDeleted {
        proposal_id,
        user,
        outcome,
        amount_deleted: amount,
        keeper: ctx.sender(),
    });
}

/// P1.6: Batch keeper redemption for gas efficiency
/// Redeems winning tokens for multiple users in a single transaction
public fun keeper_batch_redeem_winning_tokens<AssetType, StableType>(
    holder: &mut ConditionalTokenHolder,
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    users: vector<address>,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
) {
    let proposal_id = proposal.proposal_id();
    let market_state = escrow.get_market_state();

    // Ensure proposal is finalized
    assert!(market_state.is_finalized(), EProposalNotFinalized);

    let winning_outcome = (market_state.get_winning_outcome() as u8);
    let num_users = users.length();

    // Ensure sufficient keeper fees for all users
    let total_keeper_reward = HOLDER_FEE_PER_STORAGE * num_users;
    assert!(holder.keeper_fees.value() >= total_keeper_reward, EInsufficientKeeperFees);

    let mut i = 0;
    while (i < num_users) {
        let user = users[i];
        let key = HoldingKey { proposal_id, user, outcome: winning_outcome };

        // Skip if user has no tokens stored
        if (df::exists_(&holder.id, key)) {
            let Holding { tokens } = df::remove(&mut holder.id, key);
            let total_amount = tokens.value();
            let asset_type = tokens.asset_type();

            // Pay keeper
            let reward = holder.keeper_fees.split(HOLDER_FEE_PER_STORAGE);
            transfer::public_transfer(coin::from_balance(reward, ctx), ctx.sender());

            // Redeem to user
            if (asset_type == 0) {
                let user_balance = escrow.redeem_winning_tokens_asset(tokens, clock, ctx);
                transfer::public_transfer(coin::from_balance(user_balance, ctx), user);
            } else {
                let user_balance = escrow.redeem_winning_tokens_stable(tokens, clock, ctx);
                transfer::public_transfer(coin::from_balance(user_balance, ctx), user);
            };

            event::emit(TokensRedeemed {
                proposal_id,
                user,
                outcome: winning_outcome,
                amount: total_amount,
                keeper: ctx.sender(),
                keeper_reward: HOLDER_FEE_PER_STORAGE,
            });
        };

        i = i + 1;
    };
}

/// P1.6: Batch keeper deletion for gas efficiency
/// Deletes losing tokens for multiple users in a single transaction
public fun keeper_batch_delete_losing_tokens<AssetType, StableType>(
    holder: &mut ConditionalTokenHolder,
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    users: vector<address>,
    outcome: u8,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
) {
    let proposal_id = proposal.proposal_id();
    let market_state = escrow.get_market_state();

    // Ensure proposal is finalized
    assert!(market_state.is_finalized(), EProposalNotFinalized);

    let winning_outcome = (market_state.get_winning_outcome() as u8);
    assert!(outcome != winning_outcome, ENotWinningOutcome);

    let num_users = users.length();

    // Ensure sufficient keeper fees for all users
    let total_keeper_reward = HOLDER_FEE_PER_STORAGE * num_users;
    assert!(holder.keeper_fees.value() >= total_keeper_reward, EInsufficientKeeperFees);

    let mut i = 0;
    while (i < num_users) {
        let user = users[i];
        let key = HoldingKey { proposal_id, user, outcome };

        // Skip if user has no tokens stored
        if (df::exists_(&holder.id, key)) {
            let Holding { tokens } = df::remove(&mut holder.id, key);
            let amount = tokens.value();

            // Burn losing tokens using escrow's burn function
            escrow.burn_unused_tokens(vector[tokens], clock, ctx);

            // Pay keeper
            let reward = holder.keeper_fees.split(HOLDER_FEE_PER_STORAGE);
            transfer::public_transfer(coin::from_balance(reward, ctx), ctx.sender());

            event::emit(LosingTokensDeleted {
                proposal_id,
                user,
                outcome,
                amount_deleted: amount,
                keeper: ctx.sender(),
            });
        };

        i = i + 1;
    };
}

/// User can withdraw their tokens before proposal ends (no refund on fee)
public fun withdraw_tokens<AssetType, StableType>(
    holder: &mut ConditionalTokenHolder,
    proposal: &Proposal<AssetType, StableType>,
    outcome: u8,
    ctx: &mut TxContext,
) {
    let proposal_id = proposal.proposal_id();
    let user = ctx.sender();
    let key = HoldingKey { proposal_id, user, outcome };

    // Get user's tokens
    assert!(df::exists_(&holder.id, key), ENoTokensStored);
    let Holding { tokens } = df::remove(&mut holder.id, key);

    transfer::public_transfer(tokens, user);
}

// === View Functions ===

/// Check if user has tokens stored for a proposal/outcome
public fun has_stored_tokens(
    holder: &ConditionalTokenHolder,
    proposal_id: ID,
    user: address,
    outcome: u8,
): bool {
    let key = HoldingKey { proposal_id, user, outcome };
    df::exists_(&holder.id, key)
}

/// Get amount of tokens stored for user
public fun get_stored_amount(
    holder: &ConditionalTokenHolder,
    proposal_id: ID,
    user: address,
    outcome: u8,
): u64 {
    let key = HoldingKey { proposal_id, user, outcome };
    if (!df::exists_(&holder.id, key)) return 0;

    let holding: &Holding = df::borrow(&holder.id, key);
    holding.tokens.value()
}

/// Get total keeper fees available
public fun get_keeper_fees(holder: &ConditionalTokenHolder): u64 {
    holder.keeper_fees.value()
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
