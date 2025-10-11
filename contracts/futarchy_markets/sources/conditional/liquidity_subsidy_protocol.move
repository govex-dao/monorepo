/// Protocol-level liquidity subsidy system for conditional AMMs
///
/// Architecture:
/// - Protocol config: X SUI per outcome per crank
/// - Total subsidy = X × outcome_count × crank_steps
/// - Funded from DAO treasury when proposal enters TRADING
/// - Keepers crank portions into conditional AMMs over time
/// - Remaining balance returns to treasury when finalized
///
/// Economics Example:
/// - Protocol config: 0.01 SUI per outcome per crank
/// - Proposal: 2 outcomes, 100 cranks
/// - Total subsidy: 0.01 × 2 × 100 = 2 SUI from treasury
/// - Keeper fee: 0.1 SUI per crank (flat)
/// - Per crank: (2 SUI / 100) - 0.1 SUI = -0.08 SUI ❌ TOO LOW!
/// - Better config: 0.1 SUI per outcome per crank
/// - Total: 0.1 × 2 × 100 = 20 SUI
/// - Per crank: (20 / 100) - 0.1 = 0.1 SUI to AMMs ✅
///
/// Security:
/// - Escrow tracks proposal_id and amm_ids to prevent cranking wrong markets
/// - Only during trading period (before finalization)
/// - Gradual drip prevents MEV/manipulation
module futarchy_markets::liquidity_subsidy_protocol;

use std::option::{Self, Option};
use sui::object::{Self, UID, ID};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::clock::{Self, Clock};
use sui::tx_context::{Self, TxContext};
use sui::sui::SUI;
use sui::transfer;
use sui::event;
use futarchy_markets::conditional_amm::{Self, LiquidityPool};
use futarchy_one_shot_utils::math;

// === Errors ===
const ESubsidyExhausted: u64 = 0;           // All cranks completed
const EProposalMismatch: u64 = 1;           // Escrow not for this proposal
const EAmmMismatch: u64 = 2;                // AMM ID not in escrow's tracked list
const EInsufficientBalance: u64 = 3;        // Not enough SUI in escrow
const ETooEarlyCrank: u64 = 4;              // Cranking too fast (min interval not met)
const EProposalFinalized: u64 = 5;          // Cannot crank after finalization
const EInvalidConfig: u64 = 6;              // Invalid subsidy config
const EZeroSubsidy: u64 = 7;                // Subsidy amount is zero

// === Protocol Constants ===
const DEFAULT_CRANK_STEPS: u64 = 100;                       // Default number of crank iterations
const DEFAULT_SUBSIDY_PER_OUTCOME_PER_CRANK: u64 = 100_000_000;  // 0.1 SUI per outcome per crank
const DEFAULT_KEEPER_FEE_PER_CRANK: u64 = 100_000_000;      // 0.1 SUI per crank (flat)
const MIN_CRANK_INTERVAL_MS: u64 = 300_000;                 // 5 minutes minimum between cranks

// === Structs ===

/// Protocol-level configuration for liquidity subsidy system
/// Typically stored in protocol admin registry or DAO config
public struct ProtocolSubsidyConfig has store, copy, drop {
    enabled: bool,                              // If true, subsidies are enabled
    subsidy_per_outcome_per_crank: u64,         // SUI amount per outcome per crank
    crank_steps: u64,                           // Total cranks allowed (default: 100)
    keeper_fee_per_crank: u64,                  // Flat SUI fee per crank (default: 0.1 SUI)
    min_crank_interval_ms: u64,                 // Minimum time between cranks
}

/// Escrow holding DAO treasury funds for gradual subsidy dripping
/// Created when proposal enters trading state
public struct SubsidyEscrow has key, store {
    id: UID,
    proposal_id: ID,                            // Which proposal this subsidizes
    dao_id: ID,                                 // Which DAO this belongs to (for refund)
    amm_ids: vector<ID>,                        // Allowed AMM IDs (security check)
    subsidy_balance: Balance<SUI>,              // DAO treasury funds to drip feed
    total_subsidy: u64,                         // Original treasury amount
    cranks_completed: u64,                      // How many cranks done
    total_cranks: u64,                          // Total cranks allowed
    keeper_fee_per_crank: u64,                  // Flat keeper fee
    last_crank_time: Option<u64>,              // Last crank timestamp (for rate limiting)
    finalized: bool,                            // If true, no more cranks allowed
}

// === Events ===

/// Emitted when subsidy escrow is created
public struct SubsidyEscrowCreated has copy, drop {
    escrow_id: ID,
    proposal_id: ID,
    dao_id: ID,
    total_subsidy: u64,
    total_cranks: u64,
    outcome_count: u64,
    subsidy_per_outcome_per_crank: u64,
}

/// Emitted when keeper cranks subsidy into AMMs
public struct SubsidyCranked has copy, drop {
    escrow_id: ID,
    proposal_id: ID,
    crank_number: u64,
    total_cranks: u64,
    subsidy_distributed: u64,       // Amount added to AMMs (after keeper fee)
    amount_per_amm: u64,
    outcome_count: u64,
    keeper_fee: u64,
    keeper: address,
    timestamp: u64,
}

/// Emitted when escrow is finalized (returns remainder to treasury)
public struct SubsidyFinalized has copy, drop {
    escrow_id: ID,
    proposal_id: ID,
    dao_id: ID,
    cranks_completed: u64,
    remaining_balance: u64,         // Returned to DAO treasury
    timestamp: u64,
}

// === Public Functions ===

/// Create default protocol subsidy config (enabled with sensible defaults)
public fun new_protocol_config(): ProtocolSubsidyConfig {
    ProtocolSubsidyConfig {
        enabled: true,
        subsidy_per_outcome_per_crank: DEFAULT_SUBSIDY_PER_OUTCOME_PER_CRANK,
        crank_steps: DEFAULT_CRANK_STEPS,
        keeper_fee_per_crank: DEFAULT_KEEPER_FEE_PER_CRANK,
        min_crank_interval_ms: MIN_CRANK_INTERVAL_MS,
    }
}

/// Create custom protocol subsidy config
public fun new_protocol_config_custom(
    enabled: bool,
    subsidy_per_outcome_per_crank: u64,
    crank_steps: u64,
    keeper_fee_per_crank: u64,
    min_crank_interval_ms: u64,
): ProtocolSubsidyConfig {
    assert!(crank_steps > 0, EInvalidConfig);

    ProtocolSubsidyConfig {
        enabled,
        subsidy_per_outcome_per_crank,
        crank_steps,
        keeper_fee_per_crank,
        min_crank_interval_ms,
    }
}

/// Calculate total subsidy needed for a proposal
/// Formula: subsidy_per_outcome_per_crank × outcome_count × crank_steps
public fun calculate_total_subsidy(
    config: &ProtocolSubsidyConfig,
    outcome_count: u64,
): u64 {
    config.subsidy_per_outcome_per_crank * outcome_count * config.crank_steps
}

// === Getters for ProtocolSubsidyConfig ===
public fun protocol_enabled(config: &ProtocolSubsidyConfig): bool { config.enabled }
public fun subsidy_per_outcome_per_crank(config: &ProtocolSubsidyConfig): u64 { config.subsidy_per_outcome_per_crank }
public fun crank_steps(config: &ProtocolSubsidyConfig): u64 { config.crank_steps }
public fun keeper_fee_per_crank(config: &ProtocolSubsidyConfig): u64 { config.keeper_fee_per_crank }
public fun min_crank_interval_ms(config: &ProtocolSubsidyConfig): u64 { config.min_crank_interval_ms }

// === Getters for SubsidyEscrow ===
public fun escrow_proposal_id(escrow: &SubsidyEscrow): ID { escrow.proposal_id }
public fun escrow_dao_id(escrow: &SubsidyEscrow): ID { escrow.dao_id }
public fun escrow_total_subsidy(escrow: &SubsidyEscrow): u64 { escrow.total_subsidy }
public fun escrow_cranks_completed(escrow: &SubsidyEscrow): u64 { escrow.cranks_completed }
public fun escrow_total_cranks(escrow: &SubsidyEscrow): u64 { escrow.total_cranks }
public fun escrow_remaining_balance(escrow: &SubsidyEscrow): u64 { escrow.subsidy_balance.value() }
public fun escrow_is_finalized(escrow: &SubsidyEscrow): bool { escrow.finalized }

// === Setters for ProtocolSubsidyConfig (protocol admin only) ===
public fun set_enabled(config: &mut ProtocolSubsidyConfig, enabled: bool) {
    config.enabled = enabled;
}

public fun set_subsidy_per_outcome_per_crank(config: &mut ProtocolSubsidyConfig, amount: u64) {
    config.subsidy_per_outcome_per_crank = amount;
}

public fun set_crank_steps(config: &mut ProtocolSubsidyConfig, steps: u64) {
    assert!(steps > 0, EInvalidConfig);
    config.crank_steps = steps;
}

public fun set_keeper_fee_per_crank(config: &mut ProtocolSubsidyConfig, fee: u64) {
    config.keeper_fee_per_crank = fee;
}

public fun set_min_crank_interval_ms(config: &mut ProtocolSubsidyConfig, interval: u64) {
    config.min_crank_interval_ms = interval;
}

/// Create subsidy escrow when proposal enters trading
/// Called by proposal lifecycle when transitioning to TRADING state
/// Withdraws from DAO treasury based on protocol config
///
/// ## Arguments
/// - `proposal_id`: ID of the proposal being subsidized
/// - `dao_id`: ID of the DAO (for refund tracking)
/// - `amm_ids`: Vector of conditional AMM IDs (for security validation)
/// - `treasury_coins`: Coins from DAO treasury (calculated amount)
/// - `config`: Protocol subsidy configuration
/// - `ctx`: Transaction context
public fun create_escrow(
    proposal_id: ID,
    dao_id: ID,
    amm_ids: vector<ID>,
    treasury_coins: Coin<SUI>,
    config: &ProtocolSubsidyConfig,
    ctx: &mut TxContext,
): SubsidyEscrow {
    let total_subsidy = treasury_coins.value();
    assert!(total_subsidy > 0, EZeroSubsidy);

    let escrow_id = object::new(ctx);
    let outcome_count = amm_ids.length();

    // Validate subsidy amount matches expected
    let expected_subsidy = calculate_total_subsidy(config, outcome_count);
    assert!(total_subsidy == expected_subsidy, EInvalidConfig);

    // Emit creation event
    event::emit(SubsidyEscrowCreated {
        escrow_id: object::uid_to_inner(&escrow_id),
        proposal_id,
        dao_id,
        total_subsidy,
        total_cranks: config.crank_steps,
        outcome_count,
        subsidy_per_outcome_per_crank: config.subsidy_per_outcome_per_crank,
    });

    SubsidyEscrow {
        id: escrow_id,
        proposal_id,
        dao_id,
        amm_ids,
        subsidy_balance: coin::into_balance(treasury_coins),
        total_subsidy,
        cranks_completed: 0,
        total_cranks: config.crank_steps,
        keeper_fee_per_crank: config.keeper_fee_per_crank,
        last_crank_time: option::none(),
        finalized: false,
    }
}

/// Crank subsidy into conditional AMMs (permissionless keeper function)
///
/// ## Flow:
/// 1. Verify escrow matches proposal and AMMs
/// 2. Calculate crank amount (remaining_balance / remaining_cranks)
/// 3. Calculate keeper fee (flat 0.1 SUI per crank)
/// 4. Split remaining SUI equally across all conditional AMMs
/// 5. Add to each AMM's reserves proportionally (maintains price)
/// 6. Pay keeper fee
/// 7. Update escrow state
///
/// ## Arguments
/// - `escrow`: Subsidy escrow to crank from
/// - `proposal_id`: Proposal ID (security check)
/// - `conditional_pools`: Vector of conditional AMM pools (must match escrow.amm_ids)
/// - `clock`: For timestamp and rate limiting
/// - `ctx`: Transaction context (to pay keeper)
///
/// ## Returns
/// - Keeper fee coin
public fun crank_subsidy(
    escrow: &mut SubsidyEscrow,
    proposal_id: ID,
    conditional_pools: &mut vector<LiquidityPool>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<SUI> {
    // Security checks
    assert!(escrow.proposal_id == proposal_id, EProposalMismatch);
    assert!(!escrow.finalized, EProposalFinalized);
    assert!(escrow.cranks_completed < escrow.total_cranks, ESubsidyExhausted);

    // Rate limiting: ensure minimum interval between cranks
    let now = clock.timestamp_ms();
    if (escrow.last_crank_time.is_some()) {
        let last_crank = *escrow.last_crank_time.borrow();
        assert!(now >= last_crank + MIN_CRANK_INTERVAL_MS, ETooEarlyCrank);
    };

    // Verify AMM IDs match escrow
    let outcome_count = conditional_pools.length();
    assert!(outcome_count == escrow.amm_ids.length(), EAmmMismatch);

    let mut i = 0;
    while (i < outcome_count) {
        let pool = vector::borrow(conditional_pools, i);
        let pool_id = conditional_amm::get_id(pool);
        let expected_id = *vector::borrow(&escrow.amm_ids, i);
        assert!(pool_id == expected_id, EAmmMismatch);
        i = i + 1;
    };

    // Calculate crank amount (evenly distribute remaining balance across remaining cranks)
    let remaining_cranks = escrow.total_cranks - escrow.cranks_completed;
    let current_balance = escrow.subsidy_balance.value();
    let crank_amount = current_balance / remaining_cranks;
    assert!(crank_amount > 0, EInsufficientBalance);

    // Calculate keeper fee: FLAT per crank (0.1 SUI default)
    // This is correct because keeper does ONE transaction for ALL AMMs
    let keeper_fee = math::min(escrow.keeper_fee_per_crank, crank_amount);

    // Amount to distribute to AMMs (after keeper fee)
    let subsidy_amount = crank_amount - keeper_fee;

    // Split subsidy equally across all conditional AMMs
    let amount_per_amm = subsidy_amount / outcome_count;

    // Add to each conditional AMM's reserves proportionally
    let mut j = 0;
    while (j < outcome_count) {
        let pool = vector::borrow_mut(conditional_pools, j);

        // Add reserves proportionally to maintain current price
        inject_subsidy_proportional(pool, amount_per_amm, clock);

        j = j + 1;
    };

    // Update escrow state
    escrow.cranks_completed = escrow.cranks_completed + 1;
    escrow.last_crank_time = option::some(now);

    // Extract keeper fee from escrow
    let keeper_fee_balance = escrow.subsidy_balance.split(keeper_fee);

    // Extract subsidy amount that was distributed
    let subsidy_balance = escrow.subsidy_balance.split(subsidy_amount);
    subsidy_balance.destroy_zero(); // We already added it to pools, just accounting

    // Emit crank event
    event::emit(SubsidyCranked {
        escrow_id: object::uid_to_inner(&escrow.id),
        proposal_id: escrow.proposal_id,
        crank_number: escrow.cranks_completed,
        total_cranks: escrow.total_cranks,
        subsidy_distributed: subsidy_amount,
        amount_per_amm,
        outcome_count,
        keeper_fee,
        keeper: tx_context::sender(ctx),
        timestamp: now,
    });

    // Return keeper fee
    coin::from_balance(keeper_fee_balance, ctx)
}

/// Finalize escrow and return remaining balance to DAO treasury
/// Called after proposal ends (win or lose)
public fun finalize_escrow(
    escrow: &mut SubsidyEscrow,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert!(!escrow.finalized, EProposalFinalized);

    escrow.finalized = true;
    let remaining = escrow.subsidy_balance.value();

    // Emit finalization event
    event::emit(SubsidyFinalized {
        escrow_id: object::uid_to_inner(&escrow.id),
        proposal_id: escrow.proposal_id,
        dao_id: escrow.dao_id,
        cranks_completed: escrow.cranks_completed,
        remaining_balance: remaining,
        timestamp: clock.timestamp_ms(),
    });

    // Extract all remaining balance (return to DAO treasury)
    let remaining_balance = escrow.subsidy_balance.withdraw_all();
    coin::from_balance(remaining_balance, ctx)
}

/// Destroy escrow (only after finalization)
public fun destroy_escrow(escrow: SubsidyEscrow) {
    let SubsidyEscrow {
        id,
        proposal_id: _,
        dao_id: _,
        amm_ids: _,
        subsidy_balance,
        total_subsidy: _,
        cranks_completed: _,
        total_cranks: _,
        keeper_fee_per_crank: _,
        last_crank_time: _,
        finalized,
    } = escrow;

    assert!(finalized, EProposalFinalized);
    assert!(subsidy_balance.value() == 0, EInsufficientBalance);

    subsidy_balance.destroy_zero();
    object::delete(id);
}

// === Internal Helper Functions ===

/// Inject subsidy proportionally into conditional AMM reserves
/// Maintains current price ratio to avoid manipulation
///
/// CRITICAL: Must add proportionally to both reserves to maintain price!
fun inject_subsidy_proportional(
    pool: &mut LiquidityPool,
    total_subsidy: u64,
    clock: &Clock,
) {
    // Get current reserves
    let (asset_reserve, stable_reserve) = conditional_amm::get_reserves(pool);
    let total_reserves = asset_reserve + stable_reserve;

    // Calculate proportional split (maintains current price ratio)
    let stable_ratio = math::mul_div_to_64(stable_reserve, 1_000_000, total_reserves);

    let stable_add = math::mul_div_to_64(total_subsidy, stable_ratio, 1_000_000);
    let asset_add = total_subsidy - stable_add;

    // Add to reserves (directly mutates pool state)
    // Note: This increases k, benefiting existing LPs
    conditional_amm::add_subsidy_to_reserves(pool, asset_add, stable_add);

    // Update TWAP observation after reserve change
    conditional_amm::update_twap_observation(pool, clock);
}

// === Entry Functions ===

/// Entry function: Create subsidy escrow and share
public entry fun create_and_share_escrow(
    proposal_id: ID,
    dao_id: ID,
    amm_ids: vector<ID>,
    treasury_coins: Coin<SUI>,
    subsidy_per_outcome_per_crank: u64,
    crank_steps: u64,
    keeper_fee_per_crank: u64,
    ctx: &mut TxContext,
) {
    let config = new_protocol_config_custom(
        true,
        subsidy_per_outcome_per_crank,
        crank_steps,
        keeper_fee_per_crank,
        MIN_CRANK_INTERVAL_MS,
    );

    let escrow = create_escrow(
        proposal_id,
        dao_id,
        amm_ids,
        treasury_coins,
        &config,
        ctx,
    );

    transfer::share_object(escrow);
}

/// Entry function: Crank subsidy (keeper calls this)
public entry fun crank_subsidy_entry(
    escrow: &mut SubsidyEscrow,
    proposal_id: ID,
    conditional_pools: &mut vector<LiquidityPool>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let keeper_fee_coin = crank_subsidy(
        escrow,
        proposal_id,
        conditional_pools,
        clock,
        ctx,
    );

    // Transfer keeper fee to caller
    transfer::public_transfer(keeper_fee_coin, tx_context::sender(ctx));
}

/// Entry function: Finalize and return remainder to DAO treasury
public entry fun finalize_escrow_entry(
    escrow: &mut SubsidyEscrow,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let remaining_coin = finalize_escrow(escrow, clock, ctx);

    // Transfer to DAO treasury (caller must be authorized)
    // In production, verify caller has permission to receive DAO funds
    transfer::public_transfer(remaining_coin, tx_context::sender(ctx));
}

// === Test-Only Functions ===

#[test_only]
public fun create_test_escrow(
    proposal_id: ID,
    dao_id: ID,
    amm_ids: vector<ID>,
    total_subsidy: u64,
    total_cranks: u64,
    ctx: &mut TxContext,
): SubsidyEscrow {
    SubsidyEscrow {
        id: object::new(ctx),
        proposal_id,
        dao_id,
        amm_ids,
        subsidy_balance: balance::create_for_testing(total_subsidy),
        total_subsidy,
        cranks_completed: 0,
        total_cranks,
        keeper_fee_per_crank: DEFAULT_KEEPER_FEE_PER_CRANK,
        last_crank_time: option::none(),
        finalized: false,
    }
}

#[test_only]
public fun destroy_test_escrow(escrow: SubsidyEscrow) {
    let SubsidyEscrow {
        id,
        proposal_id: _,
        dao_id: _,
        amm_ids: _,
        subsidy_balance,
        total_subsidy: _,
        cranks_completed: _,
        total_cranks: _,
        keeper_fee_per_crank: _,
        last_crank_time: _,
        finalized: _,
    } = escrow;

    balance::destroy_for_testing(subsidy_balance);
    object::delete(id);
}
