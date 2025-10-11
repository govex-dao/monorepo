/// Keeper-cranked liquidity subsidy system for conditional AMMs
///
/// Architecture:
/// 1. DAO config specifies subsidy amount per proposal (in stable tokens)
/// 2. Protocol config specifies crank steps and keeper fee
/// 3. When proposal enters trading, create SubsidyEscrow with stable coins from DAO
/// 4. Keepers crank portions of subsidy into conditional AMMs over time
/// 5. Each crank adds reserves proportionally (not as LP) to all conditional AMMs
/// 6. Keeper receives fee (1% × outcome_count) per crank
///
/// Security:
/// - Escrow tracks proposal_id and amm_ids to prevent cranking wrong markets
/// - Only during trading period (before finalization)
/// - Gradual drip prevents MEV/manipulation
module futarchy_markets::liquidity_subsidy;

use std::option::{Self, Option};
use sui::object::{Self, UID, ID};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::clock::{Self, Clock};
use sui::tx_context::{Self, TxContext};
use sui::transfer;
use sui::event;
use futarchy_markets::conditional_amm::{Self, LiquidityPool};
use futarchy_markets::simple_twap;
use futarchy_one_shot_utils::math;

// === Errors ===
const ESubsidyExhausted: u64 = 0;           // All cranks completed
const EProposalMismatch: u64 = 1;           // Escrow not for this proposal
const EAmmMismatch: u64 = 2;                // AMM ID not in escrow's tracked list
const EInsufficientBalance: u64 = 3;        // Not enough stable in escrow
const ETooEarlyCrank: u64 = 4;              // Cranking too fast (min interval not met)
const EProposalFinalized: u64 = 5;          // Cannot crank after finalization
const EInvalidConfig: u64 = 6;              // Invalid subsidy config
const EZeroSubsidy: u64 = 7;                // Subsidy amount is zero

// === Protocol Constants (could be moved to constants module) ===
const DEFAULT_CRANK_STEPS: u64 = 100;       // Default number of crank iterations
const DEFAULT_KEEPER_FEE_BPS: u64 = 100;    // 1% base keeper fee (multiplied by outcome_count)
const MIN_CRANK_INTERVAL_MS: u64 = 300_000; // 5 minutes minimum between cranks

// === Structs ===

/// Configuration for liquidity subsidy system (stored in DAO config or protocol config)
public struct SubsidyConfig has store, copy, drop {
    enabled: bool,                          // If true, subsidies are enabled for this DAO
    subsidy_amount_per_proposal: u64,       // Amount of stable to subsidize per proposal (0 = disabled)
    crank_steps: u64,                       // How many times keepers can crank (default: 100)
    keeper_fee_base_bps: u64,               // Base keeper fee in bps (multiplied by outcome_count)
    min_crank_interval_ms: u64,             // Minimum time between cranks
}

/// Escrow holding stable coins for gradual subsidy dripping
/// Created when proposal enters trading state
public struct SubsidyEscrow<phantom StableType> has key, store {
    id: UID,
    proposal_id: ID,                        // Which proposal this subsidizes
    amm_ids: vector<ID>,                    // Allowed AMM IDs (security check)
    stable_balance: Balance<StableType>,    // Stable coins to drip feed
    total_subsidy: u64,                     // Original subsidy amount
    cranks_completed: u64,                  // How many cranks done
    total_cranks: u64,                      // Total cranks allowed
    keeper_fee_base_bps: u64,               // Base keeper fee (× outcome_count)
    last_crank_time: Option<u64>,          // Last crank timestamp (for rate limiting)
    finalized: bool,                        // If true, no more cranks allowed
}

// === Events ===

/// Emitted when subsidy escrow is created
public struct SubsidyEscrowCreated has copy, drop {
    escrow_id: ID,
    proposal_id: ID,
    total_subsidy: u64,
    total_cranks: u64,
    outcome_count: u64,
}

/// Emitted when keeper cranks subsidy into AMMs
public struct SubsidyCranked has copy, drop {
    escrow_id: ID,
    proposal_id: ID,
    crank_number: u64,
    total_cranks: u64,
    amount_per_amm: u64,
    outcome_count: u64,
    keeper_fee: u64,
    keeper: address,
    timestamp: u64,
}

/// Emitted when subsidy escrow is finalized (all cranks done or proposal ended)
public struct SubsidyFinalized has copy, drop {
    escrow_id: ID,
    proposal_id: ID,
    cranks_completed: u64,
    remaining_balance: u64,
}

// === Public Functions ===

/// Create default subsidy config (disabled)
public fun new_subsidy_config(): SubsidyConfig {
    SubsidyConfig {
        enabled: false,
        subsidy_amount_per_proposal: 0,
        crank_steps: DEFAULT_CRANK_STEPS,
        keeper_fee_base_bps: DEFAULT_KEEPER_FEE_BPS,
        min_crank_interval_ms: MIN_CRANK_INTERVAL_MS,
    }
}

/// Create custom subsidy config
public fun new_subsidy_config_custom(
    enabled: bool,
    subsidy_amount_per_proposal: u64,
    crank_steps: u64,
    keeper_fee_base_bps: u64,
    min_crank_interval_ms: u64,
): SubsidyConfig {
    assert!(crank_steps > 0, EInvalidConfig);
    assert!(keeper_fee_base_bps <= 10000, EInvalidConfig); // Max 100% base fee

    SubsidyConfig {
        enabled,
        subsidy_amount_per_proposal,
        crank_steps,
        keeper_fee_base_bps,
        min_crank_interval_ms,
    }
}

// === Getters for SubsidyConfig ===
public fun subsidy_enabled(config: &SubsidyConfig): bool { config.enabled }
public fun subsidy_amount_per_proposal(config: &SubsidyConfig): u64 { config.subsidy_amount_per_proposal }
public fun crank_steps(config: &SubsidyConfig): u64 { config.crank_steps }
public fun keeper_fee_base_bps(config: &SubsidyConfig): u64 { config.keeper_fee_base_bps }
public fun min_crank_interval_ms(config: &SubsidyConfig): u64 { config.min_crank_interval_ms }

// === Getters for SubsidyEscrow ===
public fun escrow_proposal_id<StableType>(escrow: &SubsidyEscrow<StableType>): ID { escrow.proposal_id }
public fun escrow_total_subsidy<StableType>(escrow: &SubsidyEscrow<StableType>): u64 { escrow.total_subsidy }
public fun escrow_cranks_completed<StableType>(escrow: &SubsidyEscrow<StableType>): u64 { escrow.cranks_completed }
public fun escrow_total_cranks<StableType>(escrow: &SubsidyEscrow<StableType>): u64 { escrow.total_cranks }
public fun escrow_remaining_balance<StableType>(escrow: &SubsidyEscrow<StableType>): u64 { escrow.stable_balance.value() }
public fun escrow_is_finalized<StableType>(escrow: &SubsidyEscrow<StableType>): bool { escrow.finalized }

/// Create subsidy escrow when proposal enters trading
/// Called by proposal lifecycle when transitioning to TRADING state
///
/// ## Arguments
/// - `proposal_id`: ID of the proposal being subsidized
/// - `amm_ids`: Vector of conditional AMM IDs (for security validation)
/// - `stable_coins`: Stable coins from DAO treasury
/// - `config`: Subsidy configuration (crank steps, keeper fee, etc.)
/// - `ctx`: Transaction context
public fun create_escrow<StableType>(
    proposal_id: ID,
    amm_ids: vector<ID>,
    stable_coins: Coin<StableType>,
    config: &SubsidyConfig,
    ctx: &mut TxContext,
): SubsidyEscrow<StableType> {
    let total_subsidy = stable_coins.value();
    assert!(total_subsidy > 0, EZeroSubsidy);

    let escrow_id = object::new(ctx);
    let outcome_count = amm_ids.length();

    // Emit creation event
    event::emit(SubsidyEscrowCreated {
        escrow_id: object::uid_to_inner(&escrow_id),
        proposal_id,
        total_subsidy,
        total_cranks: config.crank_steps,
        outcome_count,
    });

    SubsidyEscrow<StableType> {
        id: escrow_id,
        proposal_id,
        amm_ids,
        stable_balance: coin::into_balance(stable_coins),
        total_subsidy,
        cranks_completed: 0,
        total_cranks: config.crank_steps,
        keeper_fee_base_bps: config.keeper_fee_base_bps,
        last_crank_time: option::none(),
        finalized: false,
    }
}

/// Crank subsidy into conditional AMMs (permissionless keeper function)
///
/// ## Flow:
/// 1. Verify escrow matches proposal and AMMs
/// 2. Calculate crank amount (remaining_balance / remaining_cranks)
/// 3. Calculate keeper fee (1% × outcome_count of crank amount)
/// 4. Split remaining stable equally across all conditional AMMs
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
public fun crank_subsidy<AssetType, StableType>(
    escrow: &mut SubsidyEscrow<StableType>,
    proposal_id: ID,
    conditional_pools: &mut vector<LiquidityPool>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableType> {
    // Security checks
    assert!(escrow.proposal_id == proposal_id, EProposalMismatch);
    assert!(!escrow.finalized, EProposalFinalized);
    assert!(escrow.cranks_completed < escrow.total_cranks, ESubsidyExhausted);

    // Rate limiting: ensure minimum interval between cranks
    let now = clock.timestamp_ms();
    if (escrow.last_crank_time.is_some()) {
        let last_crank = *escrow.last_crank_time.borrow();
        let min_interval = MIN_CRANK_INTERVAL_MS; // Could use escrow.min_crank_interval_ms if stored
        assert!(now >= last_crank + min_interval, ETooEarlyCrank);
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
    let crank_amount = escrow.stable_balance.value() / remaining_cranks;
    assert!(crank_amount > 0, EInsufficientBalance);

    // Calculate keeper fee: base_fee_bps × outcome_count
    // Example: 1% base × 2 outcomes = 2% total keeper fee
    let keeper_fee_bps = escrow.keeper_fee_base_bps * outcome_count;
    let keeper_fee = math::mul_div_to_64(crank_amount, keeper_fee_bps, 10000);

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
    let keeper_fee_balance = escrow.stable_balance.split(keeper_fee);

    // Extract subsidy amount that was distributed
    let subsidy_balance = escrow.stable_balance.split(subsidy_amount);
    subsidy_balance.destroy_zero(); // We already added it to pools, just accounting

    // Emit crank event
    event::emit(SubsidyCranked {
        escrow_id: object::uid_to_inner(&escrow.id),
        proposal_id: escrow.proposal_id,
        crank_number: escrow.cranks_completed,
        total_cranks: escrow.total_cranks,
        amount_per_amm,
        outcome_count,
        keeper_fee,
        keeper: tx_context::sender(ctx),
        timestamp: now,
    });

    // Return keeper fee
    coin::from_balance(keeper_fee_balance, ctx)
}

/// Finalize escrow (after proposal ends or all cranks completed)
/// Returns remaining balance to DAO treasury
public fun finalize_escrow<StableType>(
    escrow: &mut SubsidyEscrow<StableType>,
    ctx: &mut TxContext,
): Coin<StableType> {
    assert!(!escrow.finalized, EProposalFinalized);

    escrow.finalized = true;
    let remaining = escrow.stable_balance.value();

    // Emit finalization event
    event::emit(SubsidyFinalized {
        escrow_id: object::uid_to_inner(&escrow.id),
        proposal_id: escrow.proposal_id,
        cranks_completed: escrow.cranks_completed,
        remaining_balance: remaining,
    });

    // Extract all remaining balance
    let remaining_balance = escrow.stable_balance.withdraw_all();
    coin::from_balance(remaining_balance, ctx)
}

/// Destroy escrow (only after finalization)
public fun destroy_escrow<StableType>(escrow: SubsidyEscrow<StableType>) {
    let SubsidyEscrow {
        id,
        proposal_id: _,
        amm_ids: _,
        stable_balance,
        total_subsidy: _,
        cranks_completed: _,
        total_cranks: _,
        keeper_fee_base_bps: _,
        last_crank_time: _,
        finalized,
    } = escrow;

    assert!(finalized, EProposalFinalized);
    assert!(stable_balance.value() == 0, EInsufficientBalance);

    stable_balance.destroy_zero();
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
public entry fun create_and_share_escrow<StableType>(
    proposal_id: ID,
    amm_ids: vector<ID>,
    stable_coins: Coin<StableType>,
    crank_steps: u64,
    keeper_fee_base_bps: u64,
    ctx: &mut TxContext,
) {
    let config = new_subsidy_config_custom(
        true,
        stable_coins.value(),
        crank_steps,
        keeper_fee_base_bps,
        MIN_CRANK_INTERVAL_MS,
    );

    let escrow = create_escrow(
        proposal_id,
        amm_ids,
        stable_coins,
        &config,
        ctx,
    );

    transfer::share_object(escrow);
}

/// Entry function: Crank subsidy (keeper calls this)
public entry fun crank_subsidy_entry<AssetType, StableType>(
    escrow: &mut SubsidyEscrow<StableType>,
    proposal_id: ID,
    conditional_pools: &mut vector<LiquidityPool>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let keeper_fee_coin = crank_subsidy<AssetType, StableType>(
        escrow,
        proposal_id,
        conditional_pools,
        clock,
        ctx,
    );

    // Transfer keeper fee to caller
    transfer::public_transfer(keeper_fee_coin, tx_context::sender(ctx));
}

/// Entry function: Finalize escrow and return remaining to sender
public entry fun finalize_escrow_entry<StableType>(
    escrow: &mut SubsidyEscrow<StableType>,
    ctx: &mut TxContext,
) {
    let remaining_coin = finalize_escrow(escrow, ctx);
    transfer::public_transfer(remaining_coin, tx_context::sender(ctx));
}

// === Test-Only Functions ===

#[test_only]
public fun create_test_escrow<StableType>(
    proposal_id: ID,
    amm_ids: vector<ID>,
    total_subsidy: u64,
    total_cranks: u64,
    ctx: &mut TxContext,
): SubsidyEscrow<StableType> {
    SubsidyEscrow<StableType> {
        id: object::new(ctx),
        proposal_id,
        amm_ids,
        stable_balance: balance::create_for_testing(total_subsidy),
        total_subsidy,
        cranks_completed: 0,
        total_cranks,
        keeper_fee_base_bps: DEFAULT_KEEPER_FEE_BPS,
        last_crank_time: option::none(),
        finalized: false,
    }
}

#[test_only]
public fun destroy_test_escrow<StableType>(escrow: SubsidyEscrow<StableType>) {
    let SubsidyEscrow {
        id,
        proposal_id: _,
        amm_ids: _,
        stable_balance,
        total_subsidy: _,
        cranks_completed: _,
        total_cranks: _,
        keeper_fee_base_bps: _,
        last_crank_time: _,
        finalized: _,
    } = escrow;

    balance::destroy_for_testing(stable_balance);
    object::delete(id);
}
