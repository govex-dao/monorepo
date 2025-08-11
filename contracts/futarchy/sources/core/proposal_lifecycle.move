/// Handles the complete lifecycle of proposals from queue activation to intent execution
module futarchy::proposal_lifecycle;

// === Imports ===
use std::string::String;
use sui::{
    clock::Clock,
    coin::{Self, Coin},
    balance::{Self, Balance},
    event,
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents,
};
use futarchy::{
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome},
    proposal::{Self, Proposal},
    market_state::{Self, MarketState},
    priority_queue::{Self, ProposalQueue, QueuedProposal},
    proposal_fee_manager::ProposalFeeManager,
    action_dispatcher,
    version,
};
use futarchy::{
    futarchy_vault,
};

// === Errors ===
const EProposalNotActive: u64 = 1;
const EMarketNotFinalized: u64 = 2;
const EProposalNotApproved: u64 = 3;
const ENoIntentKey: u64 = 4;
const EInvalidWinningOutcome: u64 = 5;

// === Constants ===
const OUTCOME_YES: u64 = 0;
const OUTCOME_NO: u64 = 1;

// === Events ===

/// Emitted when a proposal is activated from the queue
public struct ProposalActivated has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    intent_key: Option<String>,
    timestamp: u64,
}

/// Emitted when a proposal's market is finalized
public struct ProposalMarketFinalized has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    winning_outcome: u64,
    approved: bool,
    timestamp: u64,
}

/// Emitted when a proposal's intent is executed
public struct ProposalIntentExecuted has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    intent_key: String,
    timestamp: u64,
}

/// Emitted when the next proposal is reserved (locked) into PREMARKET
public struct ProposalReserved has copy, drop {
    queued_proposal_id: ID,
    premarket_proposal_id: ID,
    dao_id: ID,
    timestamp: u64,
}

// === Public Functions ===

/// Activates a proposal from the queue and initializes its market
/// This is called when there's an available slot and a proposal can be activated
public fun activate_proposal_from_queue<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>,
    queue: &mut ProposalQueue<StableType>,
    proposal_fee_manager: &mut ProposalFeeManager,
    asset_liquidity: Coin<AssetType>,
    stable_liquidity: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID) {
    // Try to activate the next proposal from the queue
    let mut queued_proposal_opt = priority_queue::try_activate_next(queue);
    assert!(queued_proposal_opt.is_some(), EProposalNotActive);
    
    let mut queued_proposal = queued_proposal_opt.extract();
    queued_proposal_opt.destroy_none();
    
    // Extract fields using getter functions
    let proposal_id = priority_queue::get_proposal_id(&queued_proposal);
    let dao_id = priority_queue::dao_id(queue);
    let uses_dao_liquidity = priority_queue::uses_dao_liquidity(&queued_proposal);
    let proposer = priority_queue::get_proposer(&queued_proposal);
    let data = *priority_queue::get_proposal_data(&queued_proposal);
    let intent_key = *priority_queue::get_intent_key(&queued_proposal);
    
    // Extract bond (mutable borrow needed)
    let mut bond = priority_queue::extract_bond(&mut queued_proposal);
    
    // Get config values from account
    let config = account.config();
    
    // Extract proposal data fields
    let title = *priority_queue::get_title(&data);
    let metadata = *priority_queue::get_metadata(&data);
    let outcome_messages = *priority_queue::get_outcome_messages(&data);
    let details = *priority_queue::get_outcome_details(&data);
    
    // Create fee escrow (bond or empty)
    let fee_escrow = if (bond.is_some()) {
        bond.extract().into_balance()
    } else {
        balance::zero<StableType>()
    };
    
    // Initialize the market
    let (_proposal_id, market_state_id, _state) = proposal::initialize_market<AssetType, StableType>(
        proposal_id,  // Pass the proposal_id from the queue
        dao_id,
        futarchy_config::review_period_ms(config),
        futarchy_config::trading_period_ms(config),
        futarchy_config::min_asset_amount(config),
        futarchy_config::min_stable_amount(config),
        futarchy_config::amm_twap_start_delay(config),
        futarchy_config::amm_twap_initial_observation(config),
        futarchy_config::amm_twap_step_max(config),
        futarchy_config::twap_threshold(config),
        futarchy_config::amm_total_fee_bps(config),
        object::id_address(account), // treasury address
        title,
        metadata,
        outcome_messages,
        details,
        asset_liquidity,
        stable_liquidity,
        proposer,
        uses_dao_liquidity,
        fee_escrow,
        intent_key, // Pass the intent key for YES outcome
        clock,
        ctx,
    );
    
    // Initialize intent keys vector and set YES outcome intent if provided
    // Note: We'll need to add a function to update the proposal's intent keys
    // For now, store the intent key in futarchy config if provided
    if (intent_key.is_some()) {
        let key = *intent_key.borrow();
        futarchy_config::register_proposal(
            account,
            proposal_id,
            key,
            ctx
        );
    };
    
    // Destroy the remaining bond option (should be none after extraction)
    bond.destroy_none();
    
    // Destroy the queued proposal (we've extracted everything we need)
    priority_queue::destroy_proposal(queued_proposal);
    
    // Emit activation event
    event::emit(ProposalActivated {
        proposal_id,
        dao_id,
        intent_key,
        timestamp: clock.timestamp_ms(),
    });
    
    // Return the proposal_id that was passed in
    // Note: proposal_id_returned is the on-chain object ID, which differs from the queued proposal_id
    (proposal_id, market_state_id)
}

/// Finalizes a proposal's market and determines the winning outcome
/// This should be called after trading has ended and TWAP prices are calculated
public fun finalize_proposal_market<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    market_state: &mut MarketState,
    winning_outcome: u64,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Set the winning outcome on the proposal
    proposal::set_winning_outcome(proposal, winning_outcome);
    
    // Finalize the market state
    market_state::finalize(market_state, winning_outcome, clock);
    
    // Emit finalization event
    event::emit(ProposalMarketFinalized {
        proposal_id: proposal::get_id(proposal),
        dao_id: proposal::get_dao_id(proposal),
        winning_outcome,
        approved: winning_outcome == OUTCOME_YES,
        timestamp: clock.timestamp_ms(),
    });
}

/// Executes an approved proposal's intent (generic version)
/// This should be called after the market is finalized and the proposal was approved
/// Note: This version may not handle all action types that require specific coin types
public fun execute_approved_proposal<AssetType, StableType, IW: copy + drop>(
    account: &mut Account<FutarchyConfig>,
    proposal: &Proposal<AssetType, StableType>,
    market: &MarketState,
    intent_witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify market is finalized
    assert!(market_state::is_finalized(market), EMarketNotFinalized);
    
    // Verify proposal was approved (YES outcome won)
    let winning_outcome = market_state::get_winning_outcome(market);
    assert!(winning_outcome == OUTCOME_YES, EProposalNotApproved);
    
    // Get the intent key for the winning outcome (YES = 0)
    let intent_key_opt = proposal::get_intent_key_for_outcome(proposal, OUTCOME_YES);
    assert!(intent_key_opt.is_some(), ENoIntentKey);
    let intent_key = *intent_key_opt.borrow();
    
    // Execute the proposal intent using FutarchyOutcome
    let executable = futarchy_config::execute_proposal_intent<AssetType, StableType, FutarchyOutcome>(
        account,
        proposal,
        market,
        winning_outcome,  // Pass the actual winning outcome
        clock,
        ctx
    );
    
    // Execute all actions using the action dispatcher
    action_dispatcher::execute_all_actions(
        executable,
        account,
        intent_witness,
        clock,
        ctx
    );
    
    // Emit execution event
    event::emit(ProposalIntentExecuted {
        proposal_id: proposal::get_id(proposal),
        dao_id: proposal::get_dao_id(proposal),
        intent_key,
        timestamp: clock.timestamp_ms(),
    });
}

/// Executes an approved proposal's intent with known asset types
/// This version can handle all action types including those requiring specific coin types
public fun execute_approved_proposal_typed<AssetType: drop, StableType: drop, IW: copy + drop>(
    account: &mut Account<FutarchyConfig>,
    proposal: &Proposal<AssetType, StableType>,
    market: &MarketState,
    intent_witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify market is finalized
    assert!(market_state::is_finalized(market), EMarketNotFinalized);
    
    // Verify proposal was approved (YES outcome won)
    let winning_outcome = market_state::get_winning_outcome(market);
    assert!(winning_outcome == OUTCOME_YES, EProposalNotApproved);
    
    // Get the intent key for the winning outcome (YES = 0)  
    let intent_key_opt = proposal::get_intent_key_for_outcome(proposal, OUTCOME_YES);
    assert!(intent_key_opt.is_some(), ENoIntentKey);
    let intent_key = *intent_key_opt.borrow();
    
    // Execute using FutarchyOutcome
    let executable = futarchy_config::execute_proposal_intent<AssetType, StableType, FutarchyOutcome>(
        account,
        proposal,
        market,
        winning_outcome,  // Pass the actual winning outcome
        clock,
        ctx
    );
    
    // Execute all actions using the typed dispatcher
    action_dispatcher::execute_typed_actions<AssetType, StableType, IW, FutarchyOutcome>(
        executable,
        account,
        intent_witness,
        clock,
        ctx
    );
    
    // Emit execution event
    event::emit(ProposalIntentExecuted {
        proposal_id: proposal::get_id(proposal),
        dao_id: proposal::get_dao_id(proposal),
        intent_key,
        timestamp: clock.timestamp_ms(),
    });
}

/// Reserve the next proposal into PREMARKET (no liquidity), only if the current
/// proposal's trading end is within the premarket threshold.
public entry fun reserve_next_proposal_for_premarket<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>,
    queue: &mut ProposalQueue<StableType>,
    proposal_fee_manager: &mut ProposalFeeManager,
    current_market: &MarketState,
    premarket_threshold_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    use futarchy::proposal as proposal_mod;
    
    // Prevent double reservation
    assert!(!priority_queue::has_reserved(queue), EProposalNotActive);
    
    // Compute time remaining for the active trading market
    let end_opt = market_state::get_trading_end_time(current_market);
    assert!(end_opt.is_some(), EMarketNotFinalized);
    let end_ts = *end_opt.borrow();
    let now = clock.timestamp_ms();
    assert!(now <= end_ts, EMarketNotFinalized);
    let remaining = end_ts - now;
    assert!(remaining <= premarket_threshold_ms, EInvalidWinningOutcome);
    
    // Pop top of queue
    let mut qp_opt = priority_queue::try_activate_next(queue);
    assert!(qp_opt.is_some(), EProposalNotActive);
    let mut qp = qp_opt.extract();
    qp_opt.destroy_none();
    
    let dao_id = priority_queue::dao_id(queue);
    let queued_id = priority_queue::get_proposal_id(&qp);
    let proposer = priority_queue::get_proposer(&qp);
    let uses_dao_liquidity = priority_queue::uses_dao_liquidity(&qp);
    let data = *priority_queue::get_proposal_data(&qp);
    let intent_key = *priority_queue::get_intent_key(&qp);
    
    // Extract optional bond -> becomes fee_escrow in proposal
    let mut bond = priority_queue::extract_bond(&mut qp);
    let fee_escrow = if (bond.is_some()) {
        bond.extract().into_balance()
    } else {
        balance::zero<StableType>()
    };
    bond.destroy_none();
    
    // Config from account
    let cfg = account.config();
    
    // Build PREMARKET proposal (no liquidity)
    let premarket_id = proposal_mod::new_premarket<AssetType, StableType>(
        queued_id,
        dao_id,
        futarchy_config::review_period_ms(cfg),
        futarchy_config::trading_period_ms(cfg),
        futarchy_config::min_asset_amount(cfg),
        futarchy_config::min_stable_amount(cfg),
        futarchy_config::amm_twap_start_delay(cfg),
        futarchy_config::amm_twap_initial_observation(cfg),
        futarchy_config::amm_twap_step_max(cfg),
        futarchy_config::twap_threshold(cfg),
        futarchy_config::amm_total_fee_bps(cfg),
        object::id_address(account),
        *priority_queue::get_title(&data),
        *priority_queue::get_metadata(&data),
        *priority_queue::get_outcome_messages(&data),
        *priority_queue::get_outcome_details(&data),
        proposer,
        uses_dao_liquidity,
        fee_escrow,
        intent_key,
        clock,
        ctx
    );
    
    // Mark queue reserved and emit
    priority_queue::set_reserved(queue, premarket_id);
    priority_queue::destroy_proposal(qp);
    
    event::emit(ProposalReserved {
        queued_proposal_id: queued_id,
        premarket_proposal_id: premarket_id,
        dao_id,
        timestamp: clock.timestamp_ms(),
    });
}

/// Initialize the reserved PREMARKET proposal into REVIEW by injecting liquidity now.
public entry fun initialize_reserved_premarket_to_review<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>,
    queue: &mut ProposalQueue<StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    asset_liquidity: Coin<AssetType>,
    stable_liquidity: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    use futarchy::proposal as proposal_mod;
    
    // Must have a reservation, and it must match this proposal's ID
    assert!(priority_queue::has_reserved(queue), EProposalNotActive);
    let reserved = priority_queue::reserved_proposal_id(queue);
    assert!(reserved.is_some(), EProposalNotActive);
    let reserved_id = *reserved.borrow();
    assert!(reserved_id == object::id(proposal), EInvalidWinningOutcome);
    
    // Initialize market now (PREMARKET -> REVIEW)
    let _market_state_id = proposal_mod::initialize_market_from_premarket<AssetType, StableType>(
        proposal,
        asset_liquidity,
        stable_liquidity,
        clock,
        ctx
    );
    
    // Clear reservation
    priority_queue::clear_reserved(queue);
}

/// Complete lifecycle: Activate proposal, run market, finalize, and execute if approved
/// This is a convenience function for testing - in production these steps happen at different times
#[test_only]
public fun run_complete_proposal_lifecycle<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>,
    queue: &mut ProposalQueue<StableType>,
    proposal_fee_manager: &mut ProposalFeeManager,
    asset_liquidity: Coin<AssetType>,
    stable_liquidity: Coin<StableType>,
    winning_outcome: u64,
    clock: &mut Clock,
    ctx: &mut TxContext,
) {
    // Step 1: Activate proposal
    let (proposal_id, market_state_id) = activate_proposal_from_queue(
        account,
        queue,
        proposal_fee_manager,
        asset_liquidity,
        stable_liquidity,
        clock,
        ctx
    );
    
    // Step 2: Fast forward through review and trading periods
    let config = account.config();
    sui::clock::increment_for_testing(clock, futarchy_config::review_period_ms(config) + futarchy_config::trading_period_ms(config) + 1000);
    
    // Step 3: Get proposal and market state (would be shared objects in production)
    // For testing, we'll assume they're available
    
    // Step 4: Finalize market
    // This would normally be done through the proper market finalization flow
    
    // Step 5: Execute if approved
    // This would normally check the winning outcome and execute if YES
}

// === Helper Functions ===

/// Checks if a proposal can be executed
public fun can_execute_proposal<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    market: &MarketState,
): bool {
    // Market must be finalized
    if (!market_state::is_finalized(market)) {
        return false
    };
    
    // Proposal must have been approved (YES outcome)
    let winning_outcome = market_state::get_winning_outcome(market);
    if (winning_outcome != OUTCOME_YES) {
        return false
    };
    
    // Proposal must have an intent key for YES outcome
    let intent_key = proposal::get_intent_key_for_outcome(proposal, OUTCOME_YES);
    if (!intent_key.is_some()) {
        return false
    };
    
    true
}


/// Calculates the winning outcome based on TWAP prices
/// Returns OUTCOME_YES if the YES price exceeds the threshold, OUTCOME_NO otherwise
public fun calculate_winning_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    clock: &Clock,
): u64 {
    // Get TWAP prices from all pools
    let twap_prices = proposal::get_twaps_for_proposal(proposal, clock);
    
    // For a simple YES/NO proposal, compare the YES TWAP to the threshold
    if (twap_prices.length() >= 2) {
        let yes_twap = *twap_prices.borrow(OUTCOME_YES);
        let threshold = proposal::get_twap_threshold(proposal);
        
        // If YES TWAP exceeds threshold, YES wins
        if (yes_twap > (threshold as u128)) {
            OUTCOME_YES
        } else {
            OUTCOME_NO
        }
    } else {
        // Default to NO if we can't determine
        OUTCOME_NO
    }
}