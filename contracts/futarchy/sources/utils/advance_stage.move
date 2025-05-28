module futarchy::advance_stage;

use futarchy::amm;
use futarchy::coin_escrow;
use futarchy::fee::FeeManager;
use futarchy::liquidity_interact;
use futarchy::market_state::{Self, MarketState};
use futarchy::proposal::{Self, Proposal};
use sui::clock::{Self, Clock};
use sui::event;

// === Introduction ===
// This handles advancing proposal stages

// === Errors ===
const EINVALID_STATE_TRANSITION: u64 = 0;
const EINVALID_STATE: u64 = 1;
const EIN_TRADIG_PERIOD: u64 = 2;

// === Constants ===
const TWAP_BASIS_POINTS: u256 = 100_000;
const STATE_REVIEW: u8 = 0;
const STATE_TRADING: u8 = 1;
const STATE_FINALIZED: u8 = 2;

// === Events ===
public struct ProposalStateChanged has copy, drop {
    proposal_id: ID,
    old_state: u8,
    new_state: u8,
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

// === Public Functions ===
public(package) fun try_advance_state<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    state: &mut MarketState,
    clock: &Clock,
) {
    // Validate the proposal and market state are for the same market
    assert!(object::id(state) == proposal::market_state_id(proposal), EINVALID_STATE);
    assert!(market_state::market_id(state) == proposal::get_id(proposal), EINVALID_STATE);
    // Validate DAO ID matches
    assert!(market_state::dao_id(state) == proposal::get_dao_id(proposal), EINVALID_STATE);

    let current_time = clock::timestamp_ms(clock);
    let old_state = proposal::state(proposal);

    if (
        proposal::state(proposal) == STATE_REVIEW && 
                current_time >= proposal::get_created_at(proposal) + proposal::get_review_period_ms(proposal)
    ) {
        proposal::set_state(proposal, STATE_TRADING);
        market_state::start_trading(state, proposal::get_trading_period_ms(proposal), clock);
        initialize_oracles_for_trading(proposal, state, clock);
    } else if (proposal::state(proposal) == STATE_TRADING) {
        let configured_trading_end_option = market_state::get_trading_end_time(state);
        assert!(current_time >= *option::borrow(&configured_trading_end_option), EIN_TRADIG_PERIOD);
        market_state::end_trading(state, clock);

        // Get oracle from first pool for validation
        finalize(
            proposal,
            state,
            clock,
        );
    } else {
        abort EINVALID_STATE_TRANSITION
    };

    // Emit state change event if state changed
    if (old_state != proposal::state(proposal)) {
        event::emit(ProposalStateChanged {
            proposal_id: proposal::get_id(proposal),
            old_state,
            new_state: proposal::state(proposal),
            timestamp: current_time,
        });
    }
}

public entry fun try_advance_state_entry<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut coin_escrow::TokenEscrow<AssetType, StableType>,
    fee_manager: &mut FeeManager,
    clock: &Clock,
) {
    assert!(
        coin_escrow::get_market_state_id(escrow) == proposal::market_state_id(proposal),
        EINVALID_STATE,
    );

    let market_state = coin_escrow::get_market_state_mut(escrow);
    try_advance_state(
        proposal,
        market_state,
        clock,
    );

    // If the proposal is finalized, collect fees before anyone can call empty_all_amm_liquidity
    if (proposal::state(proposal) == STATE_FINALIZED) {
        liquidity_interact::collect_protocol_fees(proposal, escrow, fee_manager, clock);
    }
}

fun initialize_oracles_for_trading<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    state: &MarketState,
    clock: &Clock,
) {
    let trading_start = market_state::get_trading_start(state);
    let pools_count = vector::length(proposal::get_amm_pools(proposal));
    let mut i = 0;
    while (i < pools_count) {
        let pool = proposal::get_pool_mut_by_outcome(proposal, (i as u8));
        amm::set_oracle_start_time(pool, trading_start);
        i = i + 1;
    };
}

public(package) fun finalize<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    state: &mut MarketState,
    clock: &Clock,
) {
    assert!(proposal::state(proposal) == STATE_TRADING, EINVALID_STATE);
    // Validate state belongs to this proposal
    assert!(object::id(state) == proposal::market_state_id(proposal), EINVALID_STATE);
    assert!(market_state::market_id(state) == proposal::get_id(proposal), EINVALID_STATE);
    // Validate DAO ID matches
    assert!(market_state::dao_id(state) == proposal::get_dao_id(proposal), EINVALID_STATE);

    // Record final TWAP prices and find winner
    let timestamp = clock::timestamp_ms(clock);
    let mut final_twap_prices = vector::empty<u128>();

    let mut i = 0;
    let mut highest_twap = 0;
    let mut winning_outcome = 0;
    let mut base_twap = 0;

    // Get a mutable reference to pools and iterate
    let pools_count = vector::length(proposal::get_amm_pools(proposal));
    while (i < pools_count) {
        let pool = proposal::get_pool_mut_by_outcome(proposal, (i as u8));
        let twap = amm::get_twap(pool, clock);
        vector::push_back(&mut final_twap_prices, twap);

        if (i == 0) {
            base_twap = twap; // Store outcome 0's TWAP
        } else {
            // For non-zero outcomes, check if this TWAP beats the current highest
            // and exceeds the threshold compared to outcome 0
            let threshold_price =
                ((base_twap as u256) * (TWAP_BASIS_POINTS + (proposal::get_twap_threshold(proposal) as u256))) / TWAP_BASIS_POINTS;
            if (twap > highest_twap && twap > (threshold_price as u128)) {
                highest_twap = twap;
                winning_outcome = i;
            };
        };

        event::emit(TWAPHistoryEvent {
            proposal_id: proposal::get_id(proposal),
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

    proposal::set_twap_prices(proposal, final_twap_prices);
    proposal::set_last_twap_update(proposal, timestamp);

    market_state::finalize(state, winning_outcome, clock);

    event::emit(MarketFinalizedEvent {
        proposal_id: proposal::get_id(proposal),
        winning_outcome: winning_outcome,
        timestamp_ms: timestamp,
    });

    proposal::set_winning_outcome(proposal, winning_outcome);
    proposal::set_state(proposal, STATE_FINALIZED);
}
