/// Helper functions for building market initialization Intents
///
/// These helpers calculate Intent parameters for conditional raise and buyback strategies.
/// The actual Intent execution is done via PTB composition using Account Protocol functions.
///
/// ## Review Period Enforcement
///
/// When creating a proposal with market init, use `market_op_review_period_ms` from DaoConfig
/// as the review_period parameter (NOT the regular review_period_ms). This allows DAOs to set
/// a shorter (or zero) review period for market initialization operations.
///
/// The enforcement happens automatically in the proposal state machine - it uses whatever
/// review_period was passed during proposal creation.
module futarchy_markets_core::market_init_helpers;

use futarchy_markets_core::market_init_strategies::{
    ConditionalRaiseConfig,
    ConditionalBuybackConfig,
    Self as strategies
};

// === Helper Functions for Conditional Raise ===

/// Get the mint amount needed for a conditional raise strategy
///
/// This is the amount that should be minted via a mint Intent.
public fun raise_mint_amount(config: &ConditionalRaiseConfig): u64 {
    strategies::raise_mint_amount(config)
}

/// Get the target outcome for a conditional raise
///
/// This is the outcome index where the mint+swap will execute.
public fun raise_target_outcome(config: &ConditionalRaiseConfig): u8 {
    strategies::raise_target_outcome(config)
}

/// Get the minimum stable output for slippage protection
public fun raise_min_stable_out(config: &ConditionalRaiseConfig): u64 {
    strategies::raise_min_stable_out(config)
}

// === Helper Functions for Conditional Buyback ===

/// Get the total withdraw amount needed for a conditional buyback strategy
///
/// This is the amount that should be withdrawn from vault via a withdraw Intent.
/// It's the sum of all per-outcome buyback amounts.
public fun buyback_total_withdraw_amount(config: &ConditionalBuybackConfig): u64 {
    strategies::buyback_total_withdraw_amount(config)
}

/// Get the per-outcome buyback amounts
///
/// Returns a reference to the vector of amounts to spend in each outcome's AMM.
public fun buyback_outcome_amounts(config: &ConditionalBuybackConfig): &vector<u64> {
    strategies::buyback_outcome_amounts(config)
}

/// Get the per-outcome minimum asset outputs for slippage protection
public fun buyback_min_asset_outs(config: &ConditionalBuybackConfig): &vector<u64> {
    strategies::buyback_min_asset_outs(config)
}

// === Config Construction Helpers ===

/// Create a conditional raise config with validation
///
/// ## Parameters
/// - `target_outcome`: Which outcome AMM to trade in (usually 1 for YES)
/// - `mint_amount`: Amount of asset tokens to mint
/// - `min_stable_out`: Minimum STABLE to receive (slippage protection)
public fun new_raise_config(
    target_outcome: u8,
    mint_amount: u64,
    min_stable_out: u64,
): ConditionalRaiseConfig {
    strategies::new_conditional_raise_config(
        target_outcome,
        mint_amount,
        min_stable_out,
    )
}

/// Create a conditional buyback config with per-outcome amounts
///
/// ## Parameters
/// - `outcome_amounts`: Vector of STABLE amounts to spend per outcome
///   Example: [0, 1000, 500] for 3 outcomes
/// - `min_asset_outs`: Vector of minimum asset outputs per outcome (slippage)
public fun new_buyback_config(
    outcome_amounts: vector<u64>,
    min_asset_outs: vector<u64>,
): ConditionalBuybackConfig {
    strategies::new_conditional_buyback_config(
        outcome_amounts,
        min_asset_outs,
    )
}

// === Validation Helpers ===

/// Validate that a raise config is compatible with outcome count
///
/// Returns true if the target outcome is valid for the given outcome count.
public fun validate_raise_config(config: &ConditionalRaiseConfig, outcome_count: u64): bool {
    let target = (strategies::raise_target_outcome(config) as u64);
    target < outcome_count && target >= 1  // Outcome 0 is REJECT
}

/// Validate that a buyback config is compatible with outcome count
///
/// Returns true if the config has the correct number of outcomes.
public fun validate_buyback_config(config: &ConditionalBuybackConfig, outcome_count: u64): bool {
    let amounts = strategies::buyback_outcome_amounts(config);
    amounts.length() == outcome_count
}
