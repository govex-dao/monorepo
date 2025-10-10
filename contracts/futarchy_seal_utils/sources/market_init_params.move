/// Market initialization parameter types for SEAL encryption
///
/// These types define the parameters that can be hidden via SEAL commit-reveal
/// to prevent front-running attacks on market initialization strategies.
///
/// ## Market Initialization Modes
///
/// - `MODE_NONE (0)`: No market initialization (standard governance proposal)
/// - `MODE_CONDITIONAL_RAISE (1)`: Mint tokens and sell in one outcome's AMM
/// - `MODE_CONDITIONAL_BUYBACK (2)`: Buy tokens across multiple outcome AMMs
///
/// ## Outcome Indexing
///
/// Outcomes are 0-indexed:
/// - Outcome 0: Usually NO
/// - Outcome 1: Usually YES
/// - For binary proposals, valid indices are 0 and 1
///
/// ## Error Codes
///
/// - `EInvalidMode (0)`: Mode value is invalid (unused, reserved for future validation)
/// - `EZeroAmount (1)`: Amount is zero or all amounts are zero
/// - `EAmountMismatch (2)`: Vector lengths don't match (outcome_amounts vs min_asset_outs)
module futarchy_seal_utils::market_init_params;

use std::vector;
use std::option::{Self, Option};

// === Errors ===
const EInvalidMode: u64 = 0;
const EZeroAmount: u64 = 1;
const EAmountMismatch: u64 = 2;

// === Constants ===

/// No market initialization (standard governance proposal)
const MODE_NONE: u8 = 0;

/// Conditional raise: mint and sell tokens in one outcome
const MODE_CONDITIONAL_RAISE: u8 = 1;

/// Conditional buyback: buy tokens across multiple outcomes
const MODE_CONDITIONAL_BUYBACK: u8 = 2;

// === Structs ===

/// Configuration for conditional raise market initialization
/// Mints tokens and sells them in one outcome's AMM to simulate raising capital
public struct ConditionalRaiseParams has store, drop, copy {
    target_outcome: u8,        // Which outcome gets the mint+swap (usually 1 for YES)
    mint_amount: u64,          // How much to mint
    min_stable_out: u64,       // Minimum STABLE received (slippage protection)
}

/// Configuration for conditional buyback market initialization
/// Withdraws treasury and buys tokens across multiple outcome AMMs
public struct ConditionalBuybackParams has store, drop, copy {
    // Per-outcome buyback amounts (index = outcome, value = STABLE to spend)
    outcome_amounts: vector<u64>,
    // Minimum asset tokens received per outcome (slippage protection)
    min_asset_outs: vector<u64>,
}

/// Union type for all market init strategies
/// Can represent any strategy or none
public struct MarketInitParams has store, drop, copy {
    mode: u8,  // MODE_NONE, MODE_CONDITIONAL_RAISE, MODE_CONDITIONAL_BUYBACK

    // Only one of these is populated based on mode
    raise_params: Option<ConditionalRaiseParams>,
    buyback_params: Option<ConditionalBuybackParams>,
}

// === Constructor Functions ===

/// Create params for no market initialization
public fun new_none(): MarketInitParams {
    MarketInitParams {
        mode: MODE_NONE,
        raise_params: option::none(),
        buyback_params: option::none(),
    }
}

/// Create conditional raise params
public fun new_conditional_raise(
    target_outcome: u8,
    mint_amount: u64,
    min_stable_out: u64,
): MarketInitParams {
    assert!(mint_amount > 0, EZeroAmount);
    assert!(min_stable_out > 0, EZeroAmount);

    MarketInitParams {
        mode: MODE_CONDITIONAL_RAISE,
        raise_params: option::some(ConditionalRaiseParams {
            target_outcome,
            mint_amount,
            min_stable_out,
        }),
        buyback_params: option::none(),
    }
}

/// Create conditional buyback params
///
/// # Validation
/// - Validates total amount doesn't overflow u64
/// - Ensures at least one non-zero buyback amount
/// - Ensures outcome_amounts and min_asset_outs have matching lengths
///
/// # Aborts
/// - EZeroAmount if no outcomes or all amounts are zero
/// - EAmountMismatch if vector lengths don't match
/// - Aborts on u64 overflow when summing amounts
public fun new_conditional_buyback(
    outcome_amounts: vector<u64>,
    min_asset_outs: vector<u64>,
): MarketInitParams {
    assert!(vector::length(&outcome_amounts) > 0, EZeroAmount);
    assert!(vector::length(&outcome_amounts) == vector::length(&min_asset_outs), EAmountMismatch);

    // Validate at least one outcome has non-zero buyback
    // AND calculate total to ensure no overflow (fail-fast validation)
    let mut has_buyback = false;
    let mut total: u64 = 0;
    let mut i = 0;
    while (i < vector::length(&outcome_amounts)) {
        let amount = *vector::borrow(&outcome_amounts, i);
        if (amount > 0) {
            has_buyback = true;
        };
        // Validate total doesn't overflow (Move will abort on overflow)
        // This ensures buyback_total_withdraw_amount() can never fail
        total = total + amount;
        i = i + 1;
    };
    assert!(has_buyback, EZeroAmount);

    MarketInitParams {
        mode: MODE_CONDITIONAL_BUYBACK,
        raise_params: option::none(),
        buyback_params: option::some(ConditionalBuybackParams {
            outcome_amounts,
            min_asset_outs,
        }),
    }
}

// === Getter Functions ===

public fun mode(params: &MarketInitParams): u8 {
    params.mode
}

public fun is_none(params: &MarketInitParams): bool {
    params.mode == MODE_NONE
}

public fun is_raise(params: &MarketInitParams): bool {
    params.mode == MODE_CONDITIONAL_RAISE
}

public fun is_buyback(params: &MarketInitParams): bool {
    params.mode == MODE_CONDITIONAL_BUYBACK
}

/// Get raise params by value (copies struct)
/// For read-only access, prefer `borrow_raise_params()` to avoid copying
public fun get_raise_params(params: &MarketInitParams): Option<ConditionalRaiseParams> {
    params.raise_params
}

/// Get buyback params by value (copies struct with vectors)
/// For read-only access, prefer `borrow_buyback_params()` to avoid copying
public fun get_buyback_params(params: &MarketInitParams): Option<ConditionalBuybackParams> {
    params.buyback_params
}

/// Borrow raise params (zero-copy access)
/// Recommended for read-only operations to save gas
public fun borrow_raise_params(params: &MarketInitParams): &Option<ConditionalRaiseParams> {
    &params.raise_params
}

/// Borrow buyback params (zero-copy access)
/// Recommended for read-only operations to save gas
public fun borrow_buyback_params(params: &MarketInitParams): &Option<ConditionalBuybackParams> {
    &params.buyback_params
}

// ConditionalRaiseParams getters
public fun raise_target_outcome(params: &ConditionalRaiseParams): u8 {
    params.target_outcome
}

public fun raise_mint_amount(params: &ConditionalRaiseParams): u64 {
    params.mint_amount
}

public fun raise_min_stable_out(params: &ConditionalRaiseParams): u64 {
    params.min_stable_out
}

// ConditionalBuybackParams getters
public fun buyback_outcome_amounts(params: &ConditionalBuybackParams): &vector<u64> {
    &params.outcome_amounts
}

public fun buyback_min_asset_outs(params: &ConditionalBuybackParams): &vector<u64> {
    &params.min_asset_outs
}

public fun buyback_total_withdraw_amount(params: &ConditionalBuybackParams): u64 {
    let mut total = 0;
    let mut i = 0;
    while (i < vector::length(&params.outcome_amounts)) {
        total = total + *vector::borrow(&params.outcome_amounts, i);
        i = i + 1;
    };
    total
}

// === Constants (Public Access) ===

public fun mode_none(): u8 { MODE_NONE }
public fun mode_conditional_raise(): u8 { MODE_CONDITIONAL_RAISE }
public fun mode_conditional_buyback(): u8 { MODE_CONDITIONAL_BUYBACK }
