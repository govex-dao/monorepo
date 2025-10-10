/// Handles the complete lifecycle of proposals from queue activation to intent execution
module futarchy_dao::proposal_lifecycle;

// === Imports ===
use std::{
    string::String,
    option,
    vector,
};
use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    balance::{Self, Balance},
    event,
    object,
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents::{Self, Intent},
};
use futarchy_core::{
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome},
    priority_queue::{Self, ProposalQueue, QueuedProposal},
    proposal_fee_manager::{Self, ProposalFeeManager},
    dao_payment_tracker::DaoPaymentTracker,
    version,
};
use futarchy_types::action_specs::InitActionSpecs;
use futarchy_markets::{
    proposal::{Self, Proposal},
    market_state::{Self, MarketState},
};
use futarchy_actions::{
    governance_actions::{Self, ProposalReservationRegistry},
};
use futarchy_governance_actions::{
    governance_intents,
};
use futarchy_markets::{
    spot_amm::{Self, SpotAMM},
    conditional_amm,
};
use futarchy_vault::{
    futarchy_vault,
};
use futarchy_dao::{
    execute,
    gc_janitor,
};
use futarchy_one_shot_utils::strategy;

// === Errors ===
const EProposalNotActive: u64 = 1;
const EMarketNotFinalized: u64 = 2;
const EProposalNotApproved: u64 = 3;
const ENoIntentKey: u64 = 4;
const EInvalidWinningOutcome: u64 = 5;
const EIntentExpiryTooLong: u64 = 6;
const ENotEligibleForEarlyResolve: u64 = 7;
const EInsufficientSpread: u64 = 8;

// === Constants ===
const OUTCOME_ACCEPTED: u64 = 0;
const OUTCOME_REJECTED: u64 = 1;

// === Events ===

/// Emitted when a proposal is activated from the queue
public struct ProposalActivated has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    has_intent_spec: bool,
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

/// Execute approved proposal with fee coin for second-order proposals
public entry fun execute_approved_proposal_with_fee<AssetType, StableType, IW: copy + drop>(
    account: &mut Account<FutarchyConfig>,
    proposal: &mut Proposal<AssetType, StableType>,
    market: &MarketState,
    intent_witness: IW,
    queue: &mut priority_queue::ProposalQueue<FutarchyConfig>,
    fee_manager: &mut ProposalFeeManager,
    registry: &mut governance_actions::ProposalReservationRegistry,
    payment_tracker: &DaoPaymentTracker,
    fee_coin: Coin<sui::sui::SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify market is finalized
    assert!(market_state::is_finalized(market), EMarketNotFinalized);

    // Verify proposal was approved (YES outcome won)
    let winning_outcome = market_state::get_winning_outcome(market);
    assert!(winning_outcome == OUTCOME_ACCEPTED, EProposalNotApproved);

    // Deposit the execution fee for this proposal
    proposal_fee_manager::deposit_proposal_fee(
        fee_manager,
        proposal::get_id(proposal),
        fee_coin
    );

    // Create the outcome object (using existing FutarchyOutcome structure)
    let outcome = futarchy_config::new_futarchy_outcome(
        b"jit_execution".to_string(), // Temporary key for just-in-time execution
        clock.timestamp_ms() // min_execution_time
    );

    // Execute the proposal intent with IntentSpec
    let executable = governance_intents::execute_proposal_intent<AssetType, StableType, FutarchyOutcome>(
        account,
        proposal,
        market,
        winning_outcome,
        outcome,
        clock,
        ctx
    );
    
    // Get the parent proposal ID for second-order proposals
    let parent_proposal_id = proposal::get_id(proposal);
    
    execute::run_with_governance(
        executable,
        account,
        intent_witness,
        clock,
        ctx
    );
    
    // Cleanup all expired intents after execution
    gc_janitor::cleanup_all_expired_intents(account, clock, ctx);
    
    // Emit execution event
    event::emit(ProposalIntentExecuted {
        proposal_id: proposal::get_id(proposal),
        dao_id: proposal::get_dao_id(proposal),
        intent_key: b"executed".to_string(), // Placeholder since intent specs are now in proposals
        timestamp: clock.timestamp_ms(),
    });
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
    spot_pool: &mut SpotAMM<AssetType, StableType>, // Added: For marking liquidity movement
    asset_liquidity: Coin<AssetType>,
    stable_liquidity: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID) {
    // Try to activate the next proposal from the queue
    let auth = priority_queue::create_mutation_auth();
    let mut queued_proposal_opt = priority_queue::try_activate_next(auth, queue);
    assert!(queued_proposal_opt.is_some(), EProposalNotActive);

    let mut queued_proposal = queued_proposal_opt.extract();
    queued_proposal_opt.destroy_none();

    // Extract fields using getter functions
    let proposal_id = priority_queue::get_proposal_id(&queued_proposal);
    let dao_id = priority_queue::dao_id(queue);
    let uses_dao_liquidity = priority_queue::uses_dao_liquidity(&queued_proposal);
    let proposer = priority_queue::get_proposer(&queued_proposal);
    let data = *priority_queue::get_proposal_data(&queued_proposal);
    let intent_spec = *priority_queue::get_intent_spec(&queued_proposal);

    // Extract bond (mutable borrow needed)
    let auth2 = priority_queue::create_mutation_auth();
    let mut bond = priority_queue::extract_bond(auth2, &mut queued_proposal);
    
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

    // Track the proposer's fee amount for outcome creator refunds
    let proposer_fee_paid = fee_escrow.value();

    // Intent specs are now stored in proposals, no need to check intent keys

    // If this proposal uses DAO liquidity, mark the spot pool
    if (uses_dao_liquidity) {
        spot_amm::mark_liquidity_to_proposal(spot_pool, clock);
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
        futarchy_config::conditional_amm_fee_bps(config),
        futarchy_config::max_outcomes(config), // DAO's configured max outcomes
        object::id_address(account), // treasury address
        title,
        metadata,
        outcome_messages,
        details,
        asset_liquidity,
        stable_liquidity,
        proposer,
        proposer_fee_paid, // Track actual fee paid by proposer
        uses_dao_liquidity,
        fee_escrow,
        intent_spec, // Pass the IntentSpec from the queued proposal
        clock,
        ctx,
    );
    
    // IntentSpecs are stored directly in proposals now, no need for separate registration
    
    // Destroy the remaining bond option (should be none after extraction)
    bond.destroy_none();
    
    // Destroy the queued proposal (we've extracted everything we need)
    priority_queue::destroy_proposal(queued_proposal);
    
    // Emit activation event
    event::emit(ProposalActivated {
        proposal_id,
        dao_id,
        has_intent_spec: true, // Always true when activating with intent
        timestamp: clock.timestamp_ms(),
    });
    
    // Return the proposal_id that was passed in
    // Note: proposal_id_returned is the on-chain object ID, which differs from the queued proposal_id
    (proposal_id, market_state_id)
}

/// Finalizes a proposal's market and determines the winning outcome
/// This should be called after trading has ended and TWAP prices are calculated
public fun finalize_proposal_market<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>, // Added: Account needed for intent cleanup
    registry: &mut ProposalReservationRegistry, // Added: Registry for pruning
    proposal: &mut Proposal<AssetType, StableType>,
    market_state: &mut MarketState,
    spot_pool: &mut SpotAMM<AssetType, StableType>, // Added: For TWAP integration
    fee_manager: &mut ProposalFeeManager, // Added: For outcome creator fee refunds
    clock: &Clock,
    ctx: &mut TxContext, // Now needed for auth
) {
    // Calculate winning outcome and get TWAPs in single computation
    let (winning_outcome, twap_prices) = calculate_winning_outcome_with_twaps(proposal, clock);
    
    // Store the final TWAPs for third-party access
    proposal::set_twap_prices(proposal, twap_prices);
    
    // Set the winning outcome on the proposal
    proposal::set_winning_outcome(proposal, winning_outcome);
    
    // Finalize the market state
    market_state::finalize(market_state, winning_outcome, clock);
    
    // If this proposal used DAO liquidity, integrate the winning conditional TWAP
    if (proposal::uses_dao_liquidity(proposal)) {
        // Get the winning pool's SimpleTWAP oracle
        let winning_pool = proposal::get_pool_mut_by_outcome(proposal, winning_outcome as u8);
        let winning_conditional_oracle = conditional_amm::get_simple_twap(winning_pool);

        // Backfill spot's SimpleTWAP with winning conditional's oracle data
        // This fills the gap [proposal_start, proposal_end] with conditional's price history
        // Updates both window_cumulative and total_cumulative for seamless continuity
        spot_amm::backfill_from_winning_conditional(
            spot_pool,
            winning_conditional_oracle,
            clock
        );
    };
    
    // NEW: Cancel losing outcome intents in the hot path using a scoped witness.
    // This ensures per-proposal isolation and prevents cross-proposal cancellation
    let num_outcomes = proposal::get_num_outcomes(proposal);
    let mut i = 0u64;
    while (i < num_outcomes) {
        if (i != winning_outcome) {
            // Mint a scoped cancel witness for this specific proposal/outcome
            let mut cw_opt = proposal::make_cancel_witness(proposal, i);
            if (option::is_some(&cw_opt)) {
                let cw = option::extract(&mut cw_opt);
                // TODO: Intent cancellation logic needs to be updated for new InitActionSpecs design
                // The proposal now stores InitActionSpecs instead of intent keys
                // This code will need to be refactored once the intent creation flow is clarified
                let _ = cw;
            };
            // Properly destroy the empty option
            option::destroy_none(cw_opt);
        };
        i = i + 1;
    };
    
    // Also cleanup any other expired intents during finalization
    gc_janitor::cleanup_all_expired_intents(account, clock, ctx);
    
    // --- BEGIN REGISTRY PRUNING ---
    // Prune expired proposal reservations from the registry to prevent state bloat.
    // This is done at the end of finalization when we have time to do cleanup.
    let config = account::config(account);
    governance_actions::prune_oldest_expired_bucket(registry, config, clock, ctx);
    // --- END REGISTRY PRUNING ---

    // --- BEGIN OUTCOME CREATOR FEE REFUNDS & REWARDS ---
    // Economic model per user requirement:
    // - Outcome 0 wins: DAO keeps all fees (reject/no action taken)
    // - Outcomes 1-N win:
    //   1. Refund ALL creators of outcomes 1-N (collaborative model)
    //   2. Pay bonus reward to winning outcome creator (configurable)
    //
    // Game Theory Rationale:
    // - Eliminates fee-stealing attacks (both proposer and mutator get refunded)
    // - No incentive to hedge by creating trivial mutations
    // - Makes mutations collaborative rather than adversarial
    // - Original proposer always protected if any action is taken
    // - Encourages healthy debate without perverse incentives
    // - Winning creator gets bonus to incentivize quality
    if (winning_outcome > 0) {
        let config = account::config(account);
        let num_outcomes = proposal::get_num_outcomes(proposal);

        // 1. Refund fees to ALL creators of outcomes 1-N from proposal's fee escrow
        // SECURITY: Use per-proposal escrow instead of global protocol revenue
        // This ensures each proposal's fees are properly tracked and refunded
        let fee_escrow_balance = proposal::take_fee_escrow(proposal);
        let mut fee_escrow_coin = coin::from_balance(fee_escrow_balance, ctx);

        let mut i = 1u64;
        while (i < num_outcomes) {
            let creator_fee = proposal::get_outcome_creator_fee(proposal, i);
            if (creator_fee > 0 && fee_escrow_coin.value() >= creator_fee) {
                let creator = proposal::get_outcome_creator(proposal, i);
                let refund_coin = coin::split(&mut fee_escrow_coin, creator_fee, ctx);
                // Transfer refund to outcome creator
                transfer::public_transfer(refund_coin, creator);
            };
            i = i + 1;
        };

        // Any remaining escrow gets destroyed (no refund for outcome 0 creator/proposer)
        // Note: In StableType, not SUI, so cannot deposit to SUI-denominated protocol revenue
        if (fee_escrow_coin.value() > 0) {
            transfer::public_transfer(fee_escrow_coin, @0x0); // Burn by sending to null address
        } else {
            fee_escrow_coin.destroy_zero();
        };

        // 2. Pay bonus reward to WINNING outcome creator (if configured)
        // Note: Reward is paid in SUI from protocol revenue
        // DAOs can set this to 0 to disable, or any amount to incentivize quality outcomes
        let win_reward = futarchy_config::outcome_win_reward(config);
        if (win_reward > 0) {
            let winner = proposal::get_outcome_creator(proposal, winning_outcome);
            let reward_coin = proposal_fee_manager::pay_outcome_creator_reward(
                fee_manager,
                win_reward,
                ctx
            );
            if (reward_coin.value() > 0) {
                transfer::public_transfer(reward_coin, winner);
            } else {
                reward_coin.destroy_zero();
            };
        };
    };
    // If outcome 0 wins, DAO keeps all fees - no refunds or rewards
    // --- END OUTCOME CREATOR FEE REFUNDS & REWARDS ---

    // Emit finalization event
    event::emit(ProposalMarketFinalized {
        proposal_id: proposal::get_id(proposal),
        dao_id: proposal::get_dao_id(proposal),
        winning_outcome,
        approved: winning_outcome == OUTCOME_ACCEPTED,
        timestamp: clock.timestamp_ms(),
    });
}

/// Try to resolve a proposal early if it meets eligibility criteria
/// This function can be called by anyone (typically keepers) to trigger early resolution
/// and receive a keeper reward if the proposal is eligible
public entry fun try_early_resolve<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>,
    registry: &mut ProposalReservationRegistry,
    proposal: &mut Proposal<AssetType, StableType>,
    market_state: &mut MarketState,
    spot_pool: &mut SpotAMM<AssetType, StableType>,
    fee_manager: &mut ProposalFeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get DAO config
    let config = account::config(account);
    let early_resolve_config = futarchy_config::early_resolve_config(config);

    // Check basic eligibility (time-based checks, flip count, etc.)
    let (is_eligible, reason) = proposal::check_early_resolve_eligibility(
        proposal,
        early_resolve_config,
        clock
    );

    // Abort if not eligible with reason
    assert!(is_eligible, ENotEligibleForEarlyResolve);

    // Calculate current winner and check spread requirement
    let (winner_idx, _winner_twap, spread) = proposal::calculate_current_winner(proposal, clock);
    let min_spread = futarchy_config::early_resolve_min_spread(early_resolve_config);
    assert!(spread >= min_spread, EInsufficientSpread);

    // Get proposal age for event
    let start_time = if (proposal::get_market_initialized_at(proposal) > 0) {
        proposal::get_market_initialized_at(proposal)
    } else {
        proposal::get_created_at(proposal)
    };
    let proposal_age_ms = clock.timestamp_ms() - start_time;

    // Call standard finalization
    finalize_proposal_market(
        account,
        registry,
        proposal,
        market_state,
        spot_pool,
        fee_manager,
        clock,
        ctx
    );

    // Pay keeper reward
    let keeper_reward_bps = futarchy_config::early_resolve_keeper_reward_bps(early_resolve_config);
    let keeper_reward = if (keeper_reward_bps > 0) {
        // Calculate reward based on accumulated fees
        // TODO: Implement reward calculation based on protocol fees
        // For now, use a fixed reward
        let reward_coin = proposal_fee_manager::pay_keeper_reward(
            fee_manager,
            100_000_000, // 0.1 SUI as fixed reward
            ctx
        );
        let reward_amount = reward_coin.value();
        transfer::public_transfer(reward_coin, ctx.sender());
        reward_amount
    } else {
        0
    };

    // Emit early resolution event
    event::emit(proposal::ProposalEarlyResolved {
        proposal_id: proposal::get_id(proposal),
        winning_outcome: winner_idx,
        proposal_age_ms,
        flips_in_window: 0,  // Removed flip tracking
        keeper: ctx.sender(),
        keeper_reward,
        timestamp: clock.timestamp_ms(),
    });
}

/// Executes an approved proposal's intent (generic version)
/// This should be called after the market is finalized and the proposal was approved
/// Note: This version may not handle all action types that require specific coin types
public fun execute_approved_proposal<AssetType, StableType, IW: copy + drop>(
    account: &mut Account<FutarchyConfig>,
    proposal: &mut Proposal<AssetType, StableType>,
    market: &MarketState,
    intent_witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify market is finalized
    assert!(market_state::is_finalized(market), EMarketNotFinalized);

    // Verify proposal was approved (YES outcome won)
    let winning_outcome = market_state::get_winning_outcome(market);
    assert!(winning_outcome == OUTCOME_ACCEPTED, EProposalNotApproved);

    // Create the outcome object (using existing FutarchyOutcome structure)
    let outcome = futarchy_config::new_futarchy_outcome(
        b"jit_execution".to_string(), // Temporary key for just-in-time execution
        clock.timestamp_ms() // min_execution_time
    );

    // Execute the proposal intent with IntentSpec
    let executable = governance_intents::execute_proposal_intent<AssetType, StableType, FutarchyOutcome>(
        account,
        proposal,
        market,
        winning_outcome,
        outcome,
        clock,
        ctx
    );
    
    // Use the centralized execute::run_all with strategy gates
    // For approved proposals, both futarchy (ok_a) and any council requirements (ok_b) are satisfied
    // execute::run_all handles confirmation internally - consumes executable
    // This path doesn't create second-order proposals, so use run_all
    execute::run_all(
        executable,
        account,
        intent_witness,
        clock,
        ctx
    );
    
    // Cleanup all expired intents after execution
    gc_janitor::cleanup_all_expired_intents(account, clock, ctx);
    
    // Emit execution event
    event::emit(ProposalIntentExecuted {
        proposal_id: proposal::get_id(proposal),
        dao_id: proposal::get_dao_id(proposal),
        intent_key: b"executed".to_string(), // Placeholder since intent specs are now in proposals
        timestamp: clock.timestamp_ms(),
    });
}

/// Executes an approved proposal's intent with known asset types
/// This version can handle all action types including those requiring specific coin types
public fun execute_approved_proposal_typed<AssetType: drop + store, StableType: drop + store, IW: copy + drop>(
    account: &mut Account<FutarchyConfig>,
    proposal: &mut Proposal<AssetType, StableType>,
    market: &MarketState,
    intent_witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify market is finalized
    assert!(market_state::is_finalized(market), EMarketNotFinalized);

    // Verify proposal was approved (YES outcome won)
    let winning_outcome = market_state::get_winning_outcome(market);
    assert!(winning_outcome == OUTCOME_ACCEPTED, EProposalNotApproved);

    // Create the outcome object (using existing FutarchyOutcome structure)
    let outcome = futarchy_config::new_futarchy_outcome(
        b"jit_execution".to_string(), // Temporary key for just-in-time execution
        clock.timestamp_ms() // min_execution_time
    );

    // Execute the proposal intent with IntentSpec
    let executable = governance_intents::execute_proposal_intent<AssetType, StableType, FutarchyOutcome>(
        account,
        proposal,
        market,
        winning_outcome,
        outcome,
        clock,
        ctx
    );
    
    // For typed actions, we should use run_all since typed resources
    // should be provided through specialized entry points
    execute::run_all(
        executable,
        account,
        intent_witness,
        clock,
        ctx
    );
    
    // Cleanup all expired intents after execution
    gc_janitor::cleanup_all_expired_intents(account, clock, ctx);
    
    // Emit execution event
    event::emit(ProposalIntentExecuted {
        proposal_id: proposal::get_id(proposal),
        dao_id: proposal::get_dao_id(proposal),
        intent_key: b"executed".to_string(), // Placeholder since intent specs are now in proposals
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
    use futarchy_markets::proposal as proposal_mod;
    
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
    let auth = priority_queue::create_mutation_auth();
    let mut qp_opt = priority_queue::try_activate_next(auth, queue);
    assert!(qp_opt.is_some(), EProposalNotActive);
    let mut qp = qp_opt.extract();
    qp_opt.destroy_none();

    let dao_id = priority_queue::dao_id(queue);
    let queued_id = priority_queue::get_proposal_id(&qp);
    let proposer = priority_queue::get_proposer(&qp);
    let uses_dao_liquidity = priority_queue::uses_dao_liquidity(&qp);
    let data = *priority_queue::get_proposal_data(&qp);
    let intent_spec = *priority_queue::get_intent_spec(&qp);

    // Extract optional bond -> becomes fee_escrow in proposal
    let auth2 = priority_queue::create_mutation_auth();
    let mut bond = priority_queue::extract_bond(auth2, &mut qp);
    let fee_escrow = if (bond.is_some()) {
        bond.extract().into_balance()
    } else {
        balance::zero<StableType>()
    };
    bond.destroy_none();
    
    // Config from account
    let cfg = account.config();
    
    let amm_twap_start_delay = futarchy_config::amm_twap_start_delay(cfg);
    let amm_twap_initial_observation = futarchy_config::amm_twap_initial_observation(cfg);
    let amm_twap_step_max = futarchy_config::amm_twap_step_max(cfg);
    let twap_threshold = futarchy_config::twap_threshold(cfg);
    let amm_total_fee_bps = futarchy_config::amm_total_fee_bps(cfg);
    let max_outcomes = futarchy_config::max_outcomes(cfg); // DAO's configured max outcomes

    // Build PREMARKET proposal (no liquidity)
    let premarket_id = proposal::new_premarket<AssetType, StableType>(
        queued_id,
        dao_id,
        futarchy_config::market_op_review_period_ms(cfg),  // Use market op period for fast/atomic execution
        futarchy_config::trading_period_ms(cfg),
        futarchy_config::min_asset_amount(cfg),
        futarchy_config::min_stable_amount(cfg),
        amm_twap_start_delay,
        amm_twap_initial_observation,
        amm_twap_step_max,
        twap_threshold,
        amm_total_fee_bps,
        max_outcomes,
        object::id_address(account),
        *priority_queue::get_title(&data),
        *priority_queue::get_metadata(&data),
        *priority_queue::get_outcome_messages(&data),
        *priority_queue::get_outcome_details(&data),
        proposer,
        uses_dao_liquidity,
        fee_escrow,
        intent_spec, // Pass intent spec instead of intent key
        clock,
        ctx
    );

    // Mark queue reserved only if enabled in config
    if (futarchy_config::enable_premarket_reservation_lock(cfg)) {
        let auth3 = priority_queue::create_mutation_auth();
        priority_queue::set_reserved(auth3, queue, premarket_id);
    };
    priority_queue::destroy_proposal(qp);
    
    event::emit(ProposalReserved {
        queued_proposal_id: queued_id,
        premarket_proposal_id: premarket_id,
        dao_id,
        timestamp: clock.timestamp_ms(),
    });
}

/// REMOVED: initialize_reserved_premarket_to_review
///
/// With TreasuryCap-based conditional coins, market initialization requires knowing
/// the specific conditional coin types (which come from the registry).
///
/// Users must build a PTB that:
/// 1. escrow = proposal::create_escrow_for_market(proposal, clock)
/// 2. proposal::register_outcome_caps_with_escrow(proposal, escrow, 0, <Coin0Asset>, <Coin0Stable>)
/// 3. proposal::register_outcome_caps_with_escrow(proposal, escrow, 1, <Coin1Asset>, <Coin1Stable>)
///    ... repeat for N outcomes
/// 4. proposal::initialize_market_with_escrow(proposal, escrow, asset_liquidity, stable_liquidity, clock)
/// 5. proposal_lifecycle::finalize_premarket_initialization(queue, proposal)
///
/// The frontend/SDK must track which conditional coin types were used for each proposal.

/// Finalize premarket initialization by clearing the reservation
/// Call this after proposal::initialize_market_with_escrow() in the same PTB
public entry fun finalize_premarket_initialization<AssetType, StableType>(
    queue: &mut ProposalQueue<StableType>,
    proposal: &Proposal<AssetType, StableType>,
) {
    // Verify reservation matches this proposal
    assert!(priority_queue::has_reserved(queue), EProposalNotActive);
    let reserved = priority_queue::reserved_proposal_id(queue);
    assert!(reserved.is_some(), EProposalNotActive);
    let reserved_id = *reserved.borrow();
    assert!(reserved_id == object::id(proposal), EInvalidWinningOutcome);

    // Clear reservation
    let auth = priority_queue::create_mutation_auth();
    priority_queue::clear_reserved(auth, queue);
}

/// Complete lifecycle: Activate proposal, run market, finalize, and execute if approved
/// This is a convenience function for testing - in production these steps happen at different times
#[test_only]
public fun run_complete_proposal_lifecycle<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>,
    queue: &mut ProposalQueue<StableType>,
    proposal_fee_manager: &mut ProposalFeeManager,
    spot_pool: &mut SpotAMM<AssetType, StableType>,
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
        spot_pool,
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
    // Note: Updated to pass account parameter for intent cleanup
    
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
    if (winning_outcome != OUTCOME_ACCEPTED) {
        return false
    };
    
    // TODO: Update this check for new InitActionSpecs design
    // For now, just check if there are action specs
    // let intent_key = proposal::get_intent_key_for_outcome(proposal, OUTCOME_ACCEPTED);
    // if (!intent_key.is_some()) {
    //     return false
    // };
    
    true
}

/// Calculates the winning outcome and returns TWAP prices to avoid double computation
/// Returns (outcome, twap_prices) where outcome is OUTCOME_ACCEPTED or OUTCOME_REJECTED
public fun calculate_winning_outcome_with_twaps<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    clock: &Clock,
): (u64, vector<u128>) {
    // Get TWAP prices from all pools (only computed once now)
    let twap_prices = proposal::get_twaps_for_proposal(proposal, clock);
    
    // For a simple YES/NO proposal, compare the YES TWAP to the threshold
    let winning_outcome = if (twap_prices.length() >= 2) {
        let yes_twap = *twap_prices.borrow(OUTCOME_ACCEPTED);
        let threshold = proposal::get_twap_threshold(proposal);
        
        // If YES TWAP exceeds threshold, YES wins
        if (yes_twap > (threshold as u128)) {
            OUTCOME_ACCEPTED
        } else {
            OUTCOME_REJECTED
        }
    } else {
        // Default to NO if we can't determine
        OUTCOME_REJECTED
    };
    
    (winning_outcome, twap_prices)
}

// === Missing Helper Functions for execute_ptb ===

/// Check if a proposal has passed
public fun is_passed<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): bool {
    use futarchy_markets::proposal as proposal_mod;
    // A proposal is passed if its market is finalized and the winning outcome is ACCEPTED
    proposal_mod::is_finalized(proposal) && proposal_mod::get_winning_outcome(proposal) == OUTCOME_ACCEPTED
}

/// Check if a proposal has been executed
public fun is_executed<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): bool {
    // For now, always return false since we don't have execution tracking yet
    // TODO: Add execution tracking to proposal module
    let _ = proposal;
    false
}

/// Mark a proposal as executed
public fun mark_executed<AssetType, StableType>(proposal: &mut Proposal<AssetType, StableType>) {
    // For now, this is a no-op since we don't have execution tracking yet
    // TODO: Add execution tracking to proposal module
    let _ = proposal;
}

/// Get the intent key for a proposal's winning outcome
public fun intent_key<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): String {
    // For now, return a placeholder intent key
    // TODO: Add intent key tracking to proposal module
    let _ = proposal;
    b"proposal_intent".to_string()
}

/// Get intent spec from a queued proposal
public fun get_intent_spec<StableCoin>(qp: &QueuedProposal<StableCoin>): &Option<InitActionSpecs> {
    priority_queue::get_intent_spec(qp)
}