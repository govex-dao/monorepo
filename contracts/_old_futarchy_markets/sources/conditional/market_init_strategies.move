/// Market initialization strategies for futarchy prediction markets
/// Provides different ways to seed initial liquidity and create price discovery mechanisms
///
/// These strategies execute during proposal creation using coins obtained via Intent execution:
/// 1. Proposal creation builds Intent for mint/withdraw
/// 2. Intent executes immediately via Executable
/// 3. Resulting coins are passed to these strategy functions
/// 4. Strategy performs conditional swaps to create asymmetric markets
module futarchy_markets::market_init_strategies;

use futarchy_markets::swap_core;
use futarchy_markets::coin_escrow::{Self, TokenEscrow};
use futarchy_markets::proposal::Proposal;
use sui::coin::{Self, Coin};
use sui::balance;
use sui::clock::Clock;
use sui::object::ID;

// === Errors ===
const EInvalidOutcome: u64 = 0;
const EZeroAmount: u64 = 1;
const EExcessiveSlippage: u64 = 2;
const EAmountMismatch: u64 = 3;
const EInvalidConfig: u64 = 4;

// === Strategy Configuration Structs ===

/// Configuration for conditional raise market initialization
/// Mints tokens and sells them in one outcome's AMM to simulate raising capital
public struct ConditionalRaiseConfig has store, drop, copy {
    target_outcome: u8,        // Which outcome gets the mint+swap (usually 1 for YES)
    mint_amount: u64,          // How much to mint
    min_stable_out: u64,       // Minimum STABLE received (slippage protection)
}

/// Configuration for conditional buyback market initialization
/// Withdraws treasury and buys tokens across multiple outcome AMMs
/// Allows customized buyback amounts per outcome to create asymmetric markets
public struct ConditionalBuybackConfig has store, drop, copy {
    // Per-outcome buyback amounts (index = outcome, value = STABLE to spend)
    // Example: [0, 1000, 500] means:
    //   - Outcome 0: no buyback
    //   - Outcome 1: buy 1000 STABLE worth of tokens
    //   - Outcome 2: buy 500 STABLE worth of tokens
    outcome_amounts: vector<u64>,
    // Minimum asset tokens received per outcome (slippage protection)
    // Must have same length as outcome_amounts
    min_asset_outs: vector<u64>,
}

// === Constructor Functions ===

/// Create conditional raise configuration
public fun new_conditional_raise_config(
    target_outcome: u8,
    mint_amount: u64,
    min_stable_out: u64,
): ConditionalRaiseConfig {
    assert!(mint_amount > 0, EZeroAmount);
    assert!(min_stable_out > 0, EZeroAmount);

    ConditionalRaiseConfig {
        target_outcome,
        mint_amount,
        min_stable_out,
    }
}

/// Create conditional buyback configuration with per-outcome amounts
public fun new_conditional_buyback_config(
    outcome_amounts: vector<u64>,
    min_asset_outs: vector<u64>,
): ConditionalBuybackConfig {
    assert!(outcome_amounts.length() > 0, EZeroAmount);
    assert!(outcome_amounts.length() == min_asset_outs.length(), EAmountMismatch);

    // Validate at least one outcome has non-zero buyback
    let mut has_buyback = false;
    let mut i = 0;
    while (i < outcome_amounts.length()) {
        if (*outcome_amounts.borrow(i) > 0) {
            has_buyback = true;
        };
        i = i + 1;
    };
    assert!(has_buyback, EZeroAmount);

    ConditionalBuybackConfig {
        outcome_amounts,
        min_asset_outs,
    }
}

// === Getter Functions ===

// ConditionalRaiseConfig getters
public fun raise_target_outcome(config: &ConditionalRaiseConfig): u8 {
    config.target_outcome
}

public fun raise_mint_amount(config: &ConditionalRaiseConfig): u64 {
    config.mint_amount
}

public fun raise_min_stable_out(config: &ConditionalRaiseConfig): u64 {
    config.min_stable_out
}

// ConditionalBuybackConfig getters
public fun buyback_outcome_amounts(config: &ConditionalBuybackConfig): &vector<u64> {
    &config.outcome_amounts
}

public fun buyback_min_asset_outs(config: &ConditionalBuybackConfig): &vector<u64> {
    &config.min_asset_outs
}

public fun buyback_total_withdraw_amount(config: &ConditionalBuybackConfig): u64 {
    let mut total = 0;
    let mut i = 0;
    while (i < config.outcome_amounts.length()) {
        total = total + *config.outcome_amounts.borrow(i);
        i = i + 1;
    };
    total
}

// === Strategy 1: Conditional Raise ===

/// Execute conditional raise strategy
///
/// Flow:
/// 1. Deposit minted asset coins to escrow → get conditional asset
/// 2. Swap conditional asset → conditional stable in target outcome's AMM
/// 3. Burn conditional stable and withdraw spot stable
/// 4. Return spot stable (caller deposits back to DAO vault)
///
/// ## Parameters
/// - `proposal`: The proposal being initialized
/// - `escrow`: Token escrow for conditional token minting/burning
/// - `minted_coins`: Asset coins obtained from mint intent execution
/// - `config`: Strategy configuration (target outcome, amounts, slippage)
/// - `outcome_count`: Total number of outcomes (for validation)
/// - `clock`: For timestamp-based operations
/// - `ctx`: Transaction context
///
/// ## Returns
/// - Spot stable coins (to be deposited to DAO vault by caller)
public fun execute_conditional_raise<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    minted_coins: Coin<AssetType>,
    config: ConditionalRaiseConfig,
    outcome_count: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableType> {
    // Validate configuration
    assert!((config.target_outcome as u64) < outcome_count, EInvalidOutcome);
    assert!(config.target_outcome >= 1, EInvalidOutcome); // Outcome 0 is REJECT
    assert!(minted_coins.value() == config.mint_amount, EAmountMismatch);

    // Step 1: Deposit spot asset to escrow → mint conditional asset for target outcome
    let conditional_asset = coin_escrow::deposit_asset_and_mint_conditional<AssetType, StableType, AssetConditionalCoin>(
        escrow,
        (config.target_outcome as u64),
        minted_coins,
        ctx,
    );

    // Step 2: Swap conditional asset → conditional stable in AMM
    // This uses swap_core.move which:
    // - Burns conditional asset coins
    // - Updates AMM reserves (sell asset, making it cheaper)
    // - Mints conditional stable coins (output)
    let session = swap_core::begin_swap_session(escrow);
    let conditional_stable = swap_core::swap_asset_to_stable<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
        &session,
        proposal,
        escrow,
        (config.target_outcome as u64),
        conditional_asset,
        config.min_stable_out,
        clock,
        ctx,
    );
    swap_core::finalize_swap_session(session, proposal, escrow, clock);

    // Validate slippage protection
    let conditional_amount = conditional_stable.value();
    assert!(conditional_amount >= config.min_stable_out, EExcessiveSlippage);

    // Step 3: Burn conditional stable coins
    coin_escrow::burn_conditional_stable<AssetType, StableType, StableConditionalCoin>(
        escrow,
        (config.target_outcome as u64),
        conditional_stable,
    );

    // Step 4: Withdraw equivalent spot stable from escrow
    let spot_stable = coin_escrow::withdraw_stable_balance<AssetType, StableType>(
        escrow,
        conditional_amount,
        ctx,
    );

    // Return spot stable to caller (will be deposited to DAO vault)
    spot_stable
}

// === Strategy 2: Conditional Buyback ===

/// Execute conditional buyback strategy across multiple outcomes
///
/// Flow (per outcome with non-zero buyback):
/// 1. Split withdrawn stable for this outcome
/// 2. Deposit spot stable → get conditional stable
/// 3. Swap conditional stable → conditional asset in AMM
/// 4. Burn conditional asset and withdraw spot asset
/// 5. Collect all spot assets and return
///
/// ## Parameters
/// - `proposal`: The proposal being initialized
/// - `escrow`: Token escrow for conditional token minting/burning
/// - `withdrawn_stable`: Stable coins obtained from vault withdraw intent
/// - `config`: Strategy configuration (per-outcome amounts and slippage)
/// - `outcome_count`: Total number of outcomes (for validation)
/// - `clock`: For timestamp-based operations
/// - `ctx`: Transaction context
///
/// ## Returns
/// - Vector of spot asset coins (one per outcome, some may be zero-value)
/// - Caller can burn these or deposit to vault
public fun execute_conditional_buyback<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    withdrawn_stable: Coin<StableType>,
    config: ConditionalBuybackConfig,
    outcome_count: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<Coin<AssetType>> {
    // Validate configuration
    assert!(config.outcome_amounts.length() == outcome_count, EInvalidConfig);

    let total_amount = buyback_total_withdraw_amount(&config);
    assert!(withdrawn_stable.value() == total_amount, EAmountMismatch);

    // Convert withdrawn stable to balance for splitting
    let mut stable_balance = withdrawn_stable.into_balance();
    let mut asset_coins = vector::empty<Coin<AssetType>>();

    // Begin swap session once for all swaps in this function
    let session = swap_core::begin_swap_session(escrow);

    // Process each outcome
    let mut outcome_idx = 0;
    while (outcome_idx < config.outcome_amounts.length()) {
        let outcome_amount = *config.outcome_amounts.borrow(outcome_idx);
        let min_asset_out = *config.min_asset_outs.borrow(outcome_idx);

        if (outcome_amount > 0) {
            // Step 1: Split stable for this outcome
            let outcome_stable_balance = stable_balance.split(outcome_amount);
            let outcome_stable_coin = coin::from_balance(outcome_stable_balance, ctx);

            // Step 2: Deposit spot stable → mint conditional stable for this outcome
            let conditional_stable = coin_escrow::deposit_stable_and_mint_conditional<AssetType, StableType, StableConditionalCoin>(
                escrow,
                outcome_idx,
                outcome_stable_coin,
                ctx,
            );

            // Step 3: Swap conditional stable → conditional asset in AMM
            let conditional_asset = swap_core::swap_stable_to_asset<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
                &session,
                proposal,
                escrow,
                outcome_idx,
                conditional_stable,
                min_asset_out,
                clock,
                ctx,
            );

            // Validate slippage protection
            let conditional_amount = conditional_asset.value();
            assert!(conditional_amount >= min_asset_out, EExcessiveSlippage);

            // Step 4: Burn conditional asset coins
            coin_escrow::burn_conditional_asset<AssetType, StableType, AssetConditionalCoin>(
                escrow,
                outcome_idx,
                conditional_asset,
            );

            // Step 5: Withdraw equivalent spot asset from escrow
            let spot_asset = coin_escrow::withdraw_asset_balance<AssetType, StableType>(
                escrow,
                conditional_amount,
                ctx,
            );

            asset_coins.push_back(spot_asset);
        } else {
            // No buyback for this outcome, push zero coin
            asset_coins.push_back(coin::zero<AssetType>(ctx));
        };

        outcome_idx = outcome_idx + 1;
    };

    // Finalize swap session after all swaps complete
    swap_core::finalize_swap_session(session, proposal, escrow, clock);

    // Ensure all stable was used
    assert!(stable_balance.value() == 0, EAmountMismatch);
    stable_balance.destroy_zero();

    // Return asset coins per outcome (caller can burn or deposit to vault)
    asset_coins
}
