module futarchy::advance_stage;

use futarchy::coin_escrow;
use futarchy::dao::{Self, DAO};
use futarchy::dao_liquidity_pool::{Self, DAOLiquidityPool};
use futarchy::fee::{Self, FeeManager};
use futarchy::liquidity_interact;
use futarchy::market_state::MarketState;
use futarchy::proposal::{Self, Proposal};
use std::option;
use std::vector;
use sui::clock::Clock;
use sui::coin;
use sui::event;
use sui::transfer;
use sui::object::{Self, UID, ID};
use sui::tx_context::TxContext;

// === Introduction ===
// This handles advancing proposal stages

// === Errors ===
const EInvalidStateTransition: u64 = 0;
const EInvalidState: u64 = 1;
const EInTradingPeriod: u64 = 2;

// === Constants ===
const TWAP_BASIS_POINTS: u256 = 100_000;
const STATE_PREMARKET: u8 = 0; // New state before market is live
const STATE_REVIEW: u8 = 1; // Market initialized but not trading
const STATE_TRADING: u8 = 2; // Market live and trading
const STATE_FINALIZED: u8 = 3; // Market resolved

// === Structs ===
public struct ProposalStateChanged has copy, drop {
    proposal_id: ID,
    old_state: u8,
    new_state: u8,
    winning_outcome: Option<u64>,
    timestamp: u64,
}

public struct TWAPHistoryEvent has copy, drop {
    proposal_id: ID,
    outcome_idx: u64,
    twap_price: u128,
    timestamp: u64,
}

public struct MarketFinalizedEvent has copy, drop {
    proposal_id: ID,
    winning_outcome: u64,
    timestamp_ms: u64,
}


// === Public Package Functions ===
public(package) fun try_advance_state<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    state: &mut MarketState,
    clock: &Clock,
): bool {
    // Validate the proposal and market state are for the same market
    assert!(object::id(state) == proposal.market_state_id(), EInvalidState);
    assert!(state.market_id() == proposal.get_id(), EInvalidState);
    // Validate DAO ID matches
    assert!(state.dao_id() == proposal.get_dao_id(), EInvalidState);

    let current_time = clock.timestamp_ms();
    let old_state = proposal.state();

    if (proposal.state() == STATE_REVIEW && current_time >= proposal.get_market_initialized_at() + proposal.get_review_period_ms()) {
        proposal.set_state(STATE_TRADING); // Now transitions from REVIEW to TRADING
        state.start_trading(proposal.get_trading_period_ms(), clock);
    } else if (proposal.state() == STATE_TRADING) {
        let configured_trading_end_option = state.get_trading_end_time();
        assert!(current_time >= configured_trading_end_option.destroy_some(), EInTradingPeriod);
        state.end_trading(clock);

        // Get oracle from first pool for validation
        finalize(
            proposal,
            state,
            clock,
        );
        return true
    } else {
        abort EInvalidStateTransition
    };

    // Emit state change event if state changed
    if (old_state != proposal.state()) {
        // Get winning outcome if we just transitioned to finalized state
        let winning_outcome = if (proposal.state() == STATE_FINALIZED && proposal.is_winning_outcome_set()) {
            option::some(proposal.get_winning_outcome())
        } else {
            option::none()
        };
        
        event::emit(ProposalStateChanged {
            proposal_id: proposal.get_id(),
            old_state,
            new_state: proposal.state(),
            winning_outcome,
            timestamp: current_time,
        });
    };
    false
}

/// Entry point for advancing proposal state. If the proposal becomes finalized,
/// atomically handles liquidity redemption and DAO state updates.
public entry fun try_advance_state_entry<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut coin_escrow::TokenEscrow<AssetType, StableType>,
    fee_manager: &mut FeeManager,
    dao_pool: &mut DAOLiquidityPool<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(escrow.get_market_state_id() == proposal.market_state_id(), EInvalidState);

    let market_state = escrow.get_market_state_mut();
    let just_finalized = try_advance_state(proposal, market_state, clock);

    if (just_finalized) {
        // 1. Collect protocol fees and distribute DAO proposal fees.
        liquidity_interact::collect_protocol_fees(proposal, escrow, fee_manager, clock);

        let fee_balance = proposal.take_fee_escrow();
        if (fee_balance.value() > 0) {
            let fee_coin = fee_balance.into_coin(ctx);
            let winning_outcome = proposal.get_winning_outcome();
            if (winning_outcome == 0) { // Proposal was rejected or failed to meet threshold
                transfer::public_transfer(fee_coin, proposal.treasury_address());
            } else { // An outcome other than Reject won.
                let outcome_creators = proposal.get_outcome_creators();
                let rebate_recipient = *vector::borrow(outcome_creators, winning_outcome);
                transfer::public_transfer(fee_coin, rebate_recipient);
            }
        } else {
            fee_balance.destroy_zero();
        };

        // 2. Atomically redeem liquidity based on proposal type
        if (proposal::uses_dao_liquidity(proposal)) {
            liquidity_interact::empty_amm_and_return_to_dao_pool(proposal, escrow, dao_pool, ctx);
        } else {
            liquidity_interact::empty_amm_and_return_to_provider(proposal, escrow, ctx);
        };
        
        // 3. Mark the proposal as completed in the DAO
        dao::mark_proposal_completed(dao, proposal::get_id(proposal), proposal);
    }
}


public(package) fun finalize<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    state: &mut MarketState,
    clock: &Clock,
) {
    assert!(proposal.state() == STATE_TRADING, EInvalidState);
    // Validate state belongs to this proposal
    assert!(object::id(state) == proposal.market_state_id(), EInvalidState);
    assert!(state.market_id() == proposal.get_id(), EInvalidState);
    // Validate DAO ID matches
    assert!(state.dao_id() == proposal.get_dao_id(), EInvalidState);

    // Record final TWAP prices and find winner
    let timestamp = clock.timestamp_ms();
    let mut final_twap_prices = vector[];

    let mut i = 0;
    let mut highest_twap = 0;
    let mut winning_outcome = 0;
    let mut base_twap = 0;

    // Get a mutable reference to pools and iterate
    let pools = proposal.get_amm_pools();
    let pools_count = pools.length();
    while (i < pools_count) {
        let pool = proposal.get_pool_mut_by_outcome((i as u8));
        let twap = pool.get_twap(clock);
        final_twap_prices.push_back(twap);

        if (i == 0) {
            base_twap = twap; // Store outcome 0's TWAP
        } else {
            // For non-zero outcomes, check if this TWAP beats the current highest
            // and exceeds the threshold compared to outcome 0
            let threshold_price =
                ((base_twap as u256) * (TWAP_BASIS_POINTS + (proposal.get_twap_threshold() as u256))) / TWAP_BASIS_POINTS;
            if (twap > highest_twap && twap > (threshold_price as u128)) {
                highest_twap = twap;
                winning_outcome = i;
            };
        };

        event::emit(TWAPHistoryEvent {
            proposal_id: proposal.get_id(),
            outcome_idx: i,
            twap_price: twap,
            timestamp,
        });

        i = i + 1;
    };

    // If no outcome beats the threshold, outcome 0 wins
    if (highest_twap == 0) {
        winning_outcome = 0;
    };

    proposal.set_twap_prices(final_twap_prices);
    proposal.set_last_twap_update(timestamp);

    state.finalize(winning_outcome, clock);

    event::emit(MarketFinalizedEvent {
        proposal_id: proposal.get_id(),
        winning_outcome: winning_outcome,
        timestamp_ms: timestamp,
    });

    proposal.set_winning_outcome(winning_outcome);
    proposal.set_state(STATE_FINALIZED);
}
