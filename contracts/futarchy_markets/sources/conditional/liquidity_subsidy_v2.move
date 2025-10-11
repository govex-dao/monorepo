/// Proposer-fee-funded liquidity subsidy system for conditional AMMs
///
/// Architecture:
/// 1. Proposer pays proposal fee (proposal_fee_per_outcome × outcome_count)
/// 2. Instead of going to FeeManager, fee funds SubsidyEscrow for THEIR proposal
/// 3. Keepers crank portions of subsidy into conditional AMMs over time
/// 4. If proposal PASSES: Refund remaining subsidy to proposer from DAO treasury
/// 5. If proposal FAILS: Keep subsidy (spam tax)
///
/// Economics:
/// - Proposer invests in their own proposal's market depth
/// - Good proposals get refunded (incentive alignment)
/// - Bad proposals lose fee (spam prevention)
/// - DAO treasury only pays refunds for winning proposals
///
/// Security:
/// - Escrow tracks proposal_id and amm_ids to prevent cranking wrong markets
/// - Only during trading period (before finalization)
/// - Gradual drip prevents MEV/manipulation
/// - If treasury empty, refund silently fails (proposer still pays, no grief)
module futarchy_markets::liquidity_subsidy_v2;

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
const EAlreadyRefunded: u64 = 8;            // Refund already processed

// === Protocol Constants ===
const DEFAULT_CRANK_STEPS: u64 = 100;       // Default number of crank iterations
const KEEPER_FEE_PER_CRANK_SUI: u64 = 100_000_000;  // 0.1 SUI per crank (flat fee)
const MIN_CRANK_INTERVAL_MS: u64 = 300_000; // 5 minutes minimum between cranks

// === Structs ===

/// Configuration for liquidity subsidy system (stored in DAO config)
public struct SubsidyConfig has store, copy, drop {
    enabled: bool,                          // If true, proposer fees fund subsidies
    crank_steps: u64,                       // How many times keepers can crank (default: 100)
    keeper_fee_per_crank: u64,              // Flat SUI fee per crank (default: 0.1 SUI)
    min_crank_interval_ms: u64,             // Minimum time between cranks
    refund_on_pass: bool,                   // If true, refund proposer when proposal passes
}

/// Escrow holding proposer's fee for gradual subsidy dripping
/// Created when proposal enters trading state
public struct ProposerFeeEscrow has key, store {
    id: UID,
    proposal_id: ID,                        // Which proposal this subsidizes
    proposer: address,                      // Who paid the fee (for refund)
    amm_ids: vector<ID>,                    // Allowed AMM IDs (security check)
    subsidy_balance: Balance<SUI>,          // Proposer's fee to drip feed
    total_subsidy: u64,                     // Original fee amount
    cranks_completed: u64,                  // How many cranks done
    total_cranks: u64,                      // Total cranks allowed
    keeper_fee_per_crank: u64,              // Flat keeper fee
    last_crank_time: Option<u64>,          // Last crank timestamp (for rate limiting)
    refund_processed: bool,                 // If true, refund already done
    finalized: bool,                        // If true, no more cranks allowed
}

// === Events ===

/// Emitted when proposer fee escrow is created
public struct ProposerFeeEscrowCreated has copy, drop {
    escrow_id: ID,
    proposal_id: ID,
    proposer: address,
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
    subsidy_distributed: u64,       // Amount added to AMMs (after keeper fee)
    amount_per_amm: u64,
    outcome_count: u64,
    keeper_fee: u64,
    keeper: address,
    timestamp: u64,
}

/// Emitted when proposer is refunded after proposal passes
public struct ProposerRefunded has copy, drop {
    escrow_id: ID,
    proposal_id: ID,
    proposer: address,
    refund_amount: u64,             // What was refunded
    from_treasury: bool,            // True if from treasury, false if escrow remainder
    timestamp: u64,
}

/// Emitted when subsidy is finalized without refund (proposal failed)
public struct SubsidyBurned has copy, drop {
    escrow_id: ID,
    proposal_id: ID,
    burned_amount: u64,             // Fee kept as spam tax
    timestamp: u64,
}

// === Public Functions ===

/// Create default subsidy config (enabled, proposer-funded)
public fun new_subsidy_config(): SubsidyConfig {
    SubsidyConfig {
        enabled: true,
        crank_steps: DEFAULT_CRANK_STEPS,
        keeper_fee_per_crank: KEEPER_FEE_PER_CRANK_SUI,
        min_crank_interval_ms: MIN_CRANK_INTERVAL_MS,
        refund_on_pass: true,
    }
}

/// Create custom subsidy config
public fun new_subsidy_config_custom(
    enabled: bool,
    crank_steps: u64,
    keeper_fee_per_crank: u64,
    min_crank_interval_ms: u64,
    refund_on_pass: bool,
): SubsidyConfig {
    assert!(crank_steps > 0, EInvalidConfig);

    SubsidyConfig {
        enabled,
        crank_steps,
        keeper_fee_per_crank,
        min_crank_interval_ms,
        refund_on_pass,
    }
}

// === Getters for SubsidyConfig ===
public fun subsidy_enabled(config: &SubsidyConfig): bool { config.enabled }
public fun crank_steps(config: &SubsidyConfig): u64 { config.crank_steps }
public fun keeper_fee_per_crank(config: &SubsidyConfig): u64 { config.keeper_fee_per_crank }
public fun min_crank_interval_ms(config: &SubsidyConfig): u64 { config.min_crank_interval_ms }
public fun refund_on_pass(config: &SubsidyConfig): bool { config.refund_on_pass }

// === Getters for ProposerFeeEscrow ===
public fun escrow_proposal_id(escrow: &ProposerFeeEscrow): ID { escrow.proposal_id }
public fun escrow_proposer(escrow: &ProposerFeeEscrow): address { escrow.proposer }
public fun escrow_total_subsidy(escrow: &ProposerFeeEscrow): u64 { escrow.total_subsidy }
public fun escrow_cranks_completed(escrow: &ProposerFeeEscrow): u64 { escrow.cranks_completed }
public fun escrow_total_cranks(escrow: &ProposerFeeEscrow): u64 { escrow.total_cranks }
public fun escrow_remaining_balance(escrow: &ProposerFeeEscrow): u64 { escrow.subsidy_balance.value() }
public fun escrow_is_finalized(escrow: &ProposerFeeEscrow): bool { escrow.finalized }
public fun escrow_refund_processed(escrow: &ProposerFeeEscrow): bool { escrow.refund_processed }

/// Create proposer fee escrow when proposal enters trading
/// Called by proposal lifecycle when transitioning to TRADING state
///
/// ## Arguments
/// - `proposal_id`: ID of the proposal being subsidized
/// - `proposer`: Address who paid the fee (for refund)
/// - `amm_ids`: Vector of conditional AMM IDs (for security validation)
/// - `proposer_fee`: Proposer's fee (instead of going to FeeManager)
/// - `config`: Subsidy configuration (crank steps, keeper fee, etc.)
/// - `ctx`: Transaction context
public fun create_escrow(
    proposal_id: ID,
    proposer: address,
    amm_ids: vector<ID>,
    proposer_fee: Coin<SUI>,
    config: &SubsidyConfig,
    ctx: &mut TxContext,
): ProposerFeeEscrow {
    let total_subsidy = proposer_fee.value();
    assert!(total_subsidy > 0, EZeroSubsidy);

    let escrow_id = object::new(ctx);
    let outcome_count = amm_ids.length();

    // Emit creation event
    event::emit(ProposerFeeEscrowCreated {
        escrow_id: object::uid_to_inner(&escrow_id),
        proposal_id,
        proposer,
        total_subsidy,
        total_cranks: config.crank_steps,
        outcome_count,
    });

    ProposerFeeEscrow {
        id: escrow_id,
        proposal_id,
        proposer,
        amm_ids,
        subsidy_balance: coin::into_balance(proposer_fee),
        total_subsidy,
        cranks_completed: 0,
        total_cranks: config.crank_steps,
        keeper_fee_per_crank: config.keeper_fee_per_crank,
        last_crank_time: option::none(),
        refund_processed: false,
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
/// - `escrow`: Proposer fee escrow to crank from
/// - `proposal_id`: Proposal ID (security check)
/// - `conditional_pools`: Vector of conditional AMM pools (must match escrow.amm_ids)
/// - `clock`: For timestamp and rate limiting
/// - `ctx`: Transaction context (to pay keeper)
///
/// ## Returns
/// - Keeper fee coin
public fun crank_subsidy(
    escrow: &mut ProposerFeeEscrow,
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

/// Refund proposer after proposal passes
/// Tries to refund from DAO treasury first, then from escrow remainder
/// If treasury empty, silently fails (proposer still paid fee, no grief)
///
/// ## Arguments
/// - `escrow`: Proposer fee escrow
/// - `treasury_refund`: Optional coin from DAO treasury (if available)
/// - `clock`: For timestamp
/// - `ctx`: Transaction context
///
/// ## Returns
/// - Refund coin to proposer (may be zero if treasury empty)
public fun refund_proposer(
    escrow: &mut ProposerFeeEscrow,
    treasury_refund: Option<Coin<SUI>>,  // From DAO treasury if available
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert!(!escrow.refund_processed, EAlreadyRefunded);

    escrow.refund_processed = true;
    escrow.finalized = true;

    // Calculate refund amount
    let escrow_remainder = escrow.subsidy_balance.value();
    let mut total_refund = escrow_remainder;
    let mut from_treasury = false;

    // If treasury provided refund, use it
    let mut refund_coin = if (treasury_refund.is_some()) {
        from_treasury = true;
        let treasury_coin = option::destroy_some(treasury_refund);
        total_refund = total_refund + treasury_coin.value();

        // Combine treasury refund + escrow remainder
        if (escrow_remainder > 0) {
            let escrow_coin = coin::from_balance(escrow.subsidy_balance.withdraw_all(), ctx);
            treasury_coin.join(escrow_coin);
        };

        treasury_coin
    } else {
        // No treasury refund, just return escrow remainder (if any)
        if (escrow_remainder > 0) {
            coin::from_balance(escrow.subsidy_balance.withdraw_all(), ctx)
        } else {
            coin::zero(ctx)
        }
    };

    // Emit refund event
    if (total_refund > 0) {
        event::emit(ProposerRefunded {
            escrow_id: object::uid_to_inner(&escrow.id),
            proposal_id: escrow.proposal_id,
            proposer: escrow.proposer,
            refund_amount: total_refund,
            from_treasury,
            timestamp: clock.timestamp_ms(),
        });
    };

    refund_coin
}

/// Burn remaining subsidy (proposal failed, keep fee as spam tax)
/// Returns remaining balance to protocol revenue
public fun burn_subsidy(
    escrow: &mut ProposerFeeEscrow,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert!(!escrow.finalized, EProposalFinalized);

    escrow.finalized = true;
    let burned_amount = escrow.subsidy_balance.value();

    // Emit burn event
    if (burned_amount > 0) {
        event::emit(SubsidyBurned {
            escrow_id: object::uid_to_inner(&escrow.id),
            proposal_id: escrow.proposal_id,
            burned_amount,
            timestamp: clock.timestamp_ms(),
        });
    };

    // Extract all remaining balance as "burned" (goes to protocol revenue)
    let burned_balance = escrow.subsidy_balance.withdraw_all();
    coin::from_balance(burned_balance, ctx)
}

/// Destroy escrow (only after finalization)
public fun destroy_escrow(escrow: ProposerFeeEscrow) {
    let ProposerFeeEscrow {
        id,
        proposal_id: _,
        proposer: _,
        amm_ids: _,
        subsidy_balance,
        total_subsidy: _,
        cranks_completed: _,
        total_cranks: _,
        keeper_fee_per_crank: _,
        last_crank_time: _,
        refund_processed: _,
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

/// Entry function: Create proposer fee escrow and share
public entry fun create_and_share_escrow(
    proposal_id: ID,
    proposer: address,
    amm_ids: vector<ID>,
    proposer_fee: Coin<SUI>,
    crank_steps: u64,
    keeper_fee_per_crank: u64,
    refund_on_pass: bool,
    ctx: &mut TxContext,
) {
    let config = new_subsidy_config_custom(
        true,
        crank_steps,
        keeper_fee_per_crank,
        MIN_CRANK_INTERVAL_MS,
        refund_on_pass,
    );

    let escrow = create_escrow(
        proposal_id,
        proposer,
        amm_ids,
        proposer_fee,
        &config,
        ctx,
    );

    transfer::share_object(escrow);
}

/// Entry function: Crank subsidy (keeper calls this)
public entry fun crank_subsidy_entry(
    escrow: &mut ProposerFeeEscrow,
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

/// Entry function: Refund proposer (when proposal passes)
public entry fun refund_proposer_entry(
    escrow: &mut ProposerFeeEscrow,
    treasury_refund: Option<Coin<SUI>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let refund_coin = refund_proposer(escrow, treasury_refund, clock, ctx);

    // Transfer refund to proposer
    if (refund_coin.value() > 0) {
        transfer::public_transfer(refund_coin, escrow.proposer);
    } else {
        refund_coin.destroy_zero();
    }
}

// === Test-Only Functions ===

#[test_only]
public fun create_test_escrow(
    proposal_id: ID,
    proposer: address,
    amm_ids: vector<ID>,
    total_subsidy: u64,
    total_cranks: u64,
    ctx: &mut TxContext,
): ProposerFeeEscrow {
    ProposerFeeEscrow {
        id: object::new(ctx),
        proposal_id,
        proposer,
        amm_ids,
        subsidy_balance: balance::create_for_testing(total_subsidy),
        total_subsidy,
        cranks_completed: 0,
        total_cranks,
        keeper_fee_per_crank: KEEPER_FEE_PER_CRANK_SUI,
        last_crank_time: option::none(),
        refund_processed: false,
        finalized: false,
    }
}

#[test_only]
public fun destroy_test_escrow(escrow: ProposerFeeEscrow) {
    let ProposerFeeEscrow {
        id,
        proposal_id: _,
        proposer: _,
        amm_ids: _,
        subsidy_balance,
        total_subsidy: _,
        cranks_completed: _,
        total_cranks: _,
        keeper_fee_per_crank: _,
        last_crank_time: _,
        refund_processed: _,
        finalized: _,
    } = escrow;

    balance::destroy_for_testing(subsidy_balance);
    object::delete(id);
}
