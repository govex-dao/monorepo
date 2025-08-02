/// DAO Governance module - handles complete proposal lifecycle
/// Includes: creation, queuing, voting, execution, and finalization
module futarchy::dao_governance;

use futarchy::dao_state::{Self, DAO, ProposalInfo};
use futarchy::dao_liquidity_pool::{Self, DAOLiquidityPool};
use futarchy::fee::{Self, FeeManager};
use futarchy::proposal::{Self, Proposal};
use futarchy::proposal_fee_manager::{Self, ProposalFeeManager};
use futarchy::coin_escrow::{Self, TokenEscrow};
use futarchy::market_state::{Self};
use futarchy::liquidity_initialize;
use futarchy::execution_context::{Self, ProposalExecutionContext};
use futarchy::vectors;
use futarchy::priority_queue::{Self, ProposalQueue, QueuedProposal, ProposalData};
use futarchy::priority_queue_helpers;
use std::string::String;
use std::ascii::String as AsciiString;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::balance::{Self, Balance};
use sui::sui::SUI;
use sui::event;
use sui::table::Table;
use sui::transfer;

// === Errors ===

// Proposal creation errors
const EInvalidAmount: u64 = 0;
const EProposalExists: u64 = 1;
const EUnauthorized: u64 = 2;
const EInvalidOutcomeCount: u64 = 3;
const EProposalNotFound: u64 = 4;
const EInvalidMessages: u64 = 7;
const EInvalidAssetType: u64 = 8;
const EInvalidStableType: u64 = 9;
const EProposalCreationDisabled: u64 = 11;
const EInvalidOutcomeLengths: u64 = 12;
const EMetadataTooLong: u64 = 14;
const EDetailsTooLong: u64 = 15;
const ETitleTooShort: u64 = 16;
const ETitleTooLong: u64 = 17;
const EDetailsTooShort: u64 = 18;
const EOneOutcome: u64 = 19;
const EInvalidDetailsLength: u64 = 22;
const EInvalidState: u64 = 23;
const EDuplicateMessage: u64 = 25;

// DAO state errors
const E_DAO_NOT_ACTIVE: u64 = 38;

// Queue errors
const EInsufficientBond: u64 = 29;
const EInsufficientCapital: u64 = 30;
const EProposalNotInQueue: u64 = 31;
const EProposalAlreadyActive: u64 = 32;
const ENotProposer: u64 = 33;
const EQueueFull: u64 = 34;
const ETooManyActiveProposals: u64 = 35;
const EInsufficientLiquidity: u64 = 36;
const EProposalNotExpired: u64 = 37;

// Execution errors
const EProposalNotFinalized: u64 = 26;
const EProposalNotResolved: u64 = 5;
const EProposalNotExecutable: u64 = 6;
const EProposalAlreadyExecuted: u64 = 10;
const EExecutionDeadlinePassed: u64 = 13;
const EInvalidWinningOutcome: u64 = 20;
const EInvalidDaoId: u64 = 21;
const EExecutionDeadlineNotSet: u64 = 24;

// === Constants ===

// Proposal states
const STATE_PREMARKET: u8 = 0;
const STATE_REVIEW: u8 = 1; // Market initialized but not trading
const STATE_TRADING: u8 = 2; // Market live and trading
const STATE_FINALIZED: u8 = 3; // Market resolved

// Queue constants
const MAX_QUEUE_SIZE: u64 = 50;
const PROPOSAL_EXPIRY_PERIOD_MS: u64 = 86_400_000; // 24 hours
const EXECUTION_DEADLINE_MS: u64 = 604_800_000; // 7 days

// Proposal limits
const TITLE_MAX_LENGTH: u64 = 512;
const METADATA_MAX_LENGTH: u64 = 1024;
const DETAILS_MAX_LENGTH: u64 = 16384; // 16KB
const MAX_RESULT_LENGTH: u64 = 128;

// === Events ===

public struct ProposalQueued has copy, drop {
    dao_id: ID,
    proposal_id: ID,
    proposer: address,
    bond_amount: u64,
    queue_position: u64,
}

public struct ProposalActivated has copy, drop {
    dao_id: ID,
    proposal_id: ID,
    proposer: address,
    activation_time: u64,
}

public struct ProposalEvicted has copy, drop {
    dao_id: ID,
    proposal_id: ID,
    reason: String,
    evicted_by: address,
}

public struct ProposalExecuted has copy, drop {
    dao_id: ID,
    proposal_id: ID,
    winning_outcome: u64,
    executor: address,
    execution_time: u64,
}

// === Proposal Creation Functions ===

/// Creates a new proposal with proposer-provided liquidity
public entry fun create_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    initial_outcome_messages: vector<String>,
    initial_outcome_details: vector<String>,
    initial_outcome_asset_amounts: vector<u64>,
    initial_outcome_stable_amounts: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (_p_id, _, _) = create_proposal_internal<AssetType, StableType>(
        dao,
        fee_manager,
        payment,
        dao_fee_payment,
        title,
        metadata,
        initial_outcome_messages,
        initial_outcome_details,
        initial_outcome_asset_amounts,
        initial_outcome_stable_amounts,
        false, // uses_dao_liquidity = false
        clock,
        ctx
    );
}

/// Creates a proposal that will be funded by the DAO's own liquidity pool
public entry fun create_proposal_with_dao_liquidity<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    initial_outcome_messages: vector<String>,
    initial_outcome_details: vector<String>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let placeholder_amounts = vector::tabulate!(initial_outcome_messages.length(), |_| 0);

    let (_p_id, _, _) = create_proposal_internal<AssetType, StableType>(
        dao, fee_manager, payment, dao_fee_payment, title, metadata,
        initial_outcome_messages, initial_outcome_details,
        placeholder_amounts, placeholder_amounts, true,
        clock, ctx
    );
}

/// Internal function that returns proposal ID and related IDs for action storage
public(package) fun create_proposal_internal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    mut dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    initial_outcome_messages: vector<String>,
    initial_outcome_details: vector<String>,
    initial_outcome_asset_amounts: vector<u64>,
    initial_outcome_stable_amounts: vector<u64>,
    uses_dao_liquidity: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID, u8) {
    // Validate DAO is in an active state for creating new proposals
    assert!(dao_state::operational_state(dao) == dao_state::state_active(), E_DAO_NOT_ACTIVE);
    
    // Validate outcome parameters
    let outcome_count = initial_outcome_messages.length();
    assert!(outcome_count > 1, EOneOutcome);
    assert!(outcome_count == initial_outcome_details.length(), EInvalidDetailsLength);
    assert!(outcome_count == initial_outcome_asset_amounts.length(), EInvalidDetailsLength);
    assert!(outcome_count == initial_outcome_stable_amounts.length(), EInvalidDetailsLength);
    assert!(outcome_count <= dao_state::max_outcomes(dao), EInvalidOutcomeCount);

    // Process factory fee
    fee::deposit_proposal_creation_payment(fee_manager, payment, outcome_count, clock, ctx);

    // Process DAO fee
    let required_dao_fee = dao_state::proposal_fee_per_outcome(dao) * outcome_count;
    let dao_fee_balance: Balance<StableType>;
    if (required_dao_fee > 0) {
        assert!(dao_state::treasury_id(dao).is_some(), EUnauthorized);
        assert!(dao_fee_payment.value() >= required_dao_fee, EInvalidAmount);
        let fee_coin = dao_fee_payment.split(required_dao_fee, ctx);
        dao_fee_balance = fee_coin.into_balance();
        transfer::public_transfer(dao_fee_payment, ctx.sender());
    } else {
        dao_fee_balance = balance::zero<StableType>();
        transfer::public_transfer(dao_fee_payment, ctx.sender());
    };

    // Validate types
    let asset_type = type_name::get<AssetType>().into_string().to_string();
    let stable_type = type_name::get<StableType>().into_string().to_string();
    assert!(&asset_type == dao_state::asset_type(dao), EInvalidAssetType);
    assert!(&stable_type == dao_state::stable_type(dao), EInvalidStableType);

    // Validate outcome messages
    let reject_string = b"Reject".to_string();
    assert!(&initial_outcome_messages[0] == &reject_string, EInvalidMessages);
    if (outcome_count == 2) {
        let accept_string = b"Accept".to_string();
        assert!(&initial_outcome_messages[1] == &accept_string, EInvalidMessages);
    };
    assert!(
        vectors::check_valid_outcomes(initial_outcome_messages, MAX_RESULT_LENGTH),
        EInvalidOutcomeLengths,
    );

    // Validate title and metadata
    assert!(title.length() <= TITLE_MAX_LENGTH, ETitleTooLong);
    assert!(title.length() > 0, ETitleTooShort);
    assert!(metadata.length() <= METADATA_MAX_LENGTH, EMetadataTooLong);

    // Ensure treasury is configured
    assert!(dao_state::treasury_id(dao).is_some(), EUnauthorized);
    let treasury_address = object::id_to_address(dao_state::treasury_id(dao).borrow());

    // Create the proposal
    let (proposal_id, market_state_id, state) = proposal::create<AssetType, StableType>(
        dao_fee_balance,
        object::id(dao),
        dao_state::review_period_ms(dao),
        dao_state::trading_period_ms(dao),
        dao_state::min_asset_amount(dao),
        dao_state::min_stable_amount(dao),
        title,
        metadata,
        initial_outcome_messages,
        initial_outcome_details,
        initial_outcome_asset_amounts,
        initial_outcome_stable_amounts,
        dao_state::amm_twap_start_delay(dao),
        dao_state::amm_twap_initial_observation(dao),
        dao_state::amm_twap_step_max(dao),
        dao_state::twap_threshold(dao),
        dao_state::amm_total_fee_bps(dao),
        uses_dao_liquidity,
        treasury_address,
        clock,
        ctx,
    );

    // Store proposal info
    let info = dao_state::new_proposal_info(
        ctx.sender(),
        clock.timestamp_ms(),
        state,
        outcome_count,
        title,
        market_state_id,
    );

    let proposals = dao_state::proposals_mut(dao);
    assert!(!proposals.contains(proposal_id), EProposalExists);
    proposals.add(proposal_id, info);
    dao_state::increment_active_proposals(dao);
    dao_state::increment_total_proposals(dao);
    
    (proposal_id, market_state_id, state)
}

/// Adds a new outcome to a proposal during its premarket phase
public entry fun add_proposal_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    dao: &DAO<AssetType, StableType>,
    mut payment: Coin<StableType>,
    message: String,
    detail: String,
    asset_amount: u64,
    stable_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate proposal state and ownership
    assert!(proposal::state(proposal) == STATE_PREMARKET, EInvalidState);
    assert!(proposal::get_dao_id(proposal) == object::id(dao), EUnauthorized);

    // Validate outcome parameters
    let outcome_count = proposal::outcome_count(proposal);
    assert!(outcome_count < dao_state::max_outcomes(dao), EInvalidOutcomeCount);
    assert!(asset_amount >= dao_state::min_asset_amount(dao), EInvalidAmount);
    assert!(stable_amount >= dao_state::min_stable_amount(dao), EInvalidAmount);
    
    // Validate message and detail
    assert!(vectors::validate_outcome_message(&message, MAX_RESULT_LENGTH), EInvalidOutcomeLengths);
    assert!(vectors::validate_outcome_detail(&detail, DETAILS_MAX_LENGTH), EDetailsTooLong);
    
    // Check for duplicate messages
    let outcome_messages = proposal::get_outcome_messages(proposal);
    assert!(!vectors::is_duplicate_message(outcome_messages, &message), EDuplicateMessage);

    // Process fee
    let fee_amount = dao_state::proposal_fee_per_outcome(dao);
    assert!(payment.value() >= fee_amount, EInvalidAmount);
    let fee_coin = payment.split(fee_amount, ctx);
    
    if (dao_state::treasury_id(dao).is_some()) {
        let treasury_address = object::id_to_address(dao_state::treasury_id(dao).borrow());
        transfer::public_transfer(fee_coin, treasury_address);
    } else {
        transfer::public_transfer(fee_coin, ctx.sender());
    };
    transfer::public_transfer(payment, ctx.sender());

    // Add the outcome
    proposal::add_outcome(
        proposal,
        message,
        detail,
        asset_amount,
        stable_amount,
        ctx.sender(),
        clock,
    );
}

/// Allows mutating outcome details during premarket
public entry fun mutate_proposal_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    dao: &DAO<AssetType, StableType>,
    mut payment: Coin<StableType>,
    outcome_idx: u64,
    new_detail: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate proposal state
    assert!(proposal::state(proposal) == STATE_PREMARKET, EInvalidState);
    assert!(outcome_idx < proposal::outcome_count(proposal), EInvalidOutcomeCount);
    assert!(new_detail.length() <= DETAILS_MAX_LENGTH, EDetailsTooLong);
    assert!(new_detail.length() > 0, EDetailsTooShort);

    // Verify mutator is different from creator
    let mutator = ctx.sender();
    let outcome_creators = proposal::get_outcome_creators(proposal);
    let old_creator = *vector::borrow(outcome_creators, outcome_idx);
    assert!(mutator != old_creator, EUnauthorized);

    // Process fee
    let fee_amount = dao_state::proposal_fee_per_outcome(dao);
    assert!(payment.value() >= fee_amount, EInvalidAmount);
    let fee_coin = payment.split(fee_amount, ctx);
    
    if (dao_state::treasury_id(dao).is_some()) {
        let treasury_address = object::id_to_address(dao_state::treasury_id(dao).borrow());
        transfer::public_transfer(fee_coin, treasury_address);
    } else {
        transfer::public_transfer(fee_coin, ctx.sender());
    };
    transfer::public_transfer(payment, ctx.sender());

    // Mutate the detail
    let details_mut = proposal::get_details_mut(proposal);
    let detail_ref = vector::borrow_mut(details_mut, outcome_idx);
    *detail_ref = new_detail;
    
    proposal::set_outcome_creator(proposal, outcome_idx, mutator);

    // Emit event
    proposal::emit_outcome_mutated(
        proposal::get_id(proposal),
        proposal::get_dao_id(proposal),
        outcome_idx,
        old_creator,
        mutator,
        clock.timestamp_ms(),
    );
}

// === Queue Management Functions ===

/// Submit a proposal to the priority queue
public entry fun submit_to_queue<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    queue: &mut ProposalQueue<StableType>,
    fee_manager: &mut FeeManager,
    proposal_fee_manager: &mut ProposalFeeManager,
    payment: Coin<SUI>,
    fee_coin: Coin<SUI>,
    uses_dao_liquidity: bool,
    bond: vector<Coin<StableType>>,
    title: String,
    metadata: String,
    initial_outcome_messages: vector<String>,
    initial_outcome_details: vector<String>,
    initial_outcome_asset_amounts: vector<u64>,
    initial_outcome_stable_amounts: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify queue belongs to this DAO
    assert!(priority_queue::dao_id(queue) == object::id(dao), EUnauthorized);
    
    // Process bond
    let required_bond = get_required_bond_amount(dao);
    let bond_option = if (!bond.is_empty()) {
        let mut merged_bond = vectors::merge_coins(bond, ctx);
        let bond_value = merged_bond.value();
        assert!(bond_value >= required_bond, EInsufficientBond);
        if (bond_value > required_bond) {
            let excess = merged_bond.split(bond_value - required_bond, ctx);
            transfer::public_transfer(excess, ctx.sender());
        };
        option::some(merged_bond)
    } else {
        bond.destroy_empty();
        assert!(!uses_dao_liquidity, EInsufficientBond);
        option::none()
    };

    // Calculate queue fee  
    let queue_fee = calculate_queue_fee(dao);
    assert!(fee_coin.value() >= queue_fee, EInvalidAmount);
    
    // Pay platform fee for proposal creation
    fee::deposit_proposal_creation_payment(
        fee_manager,
        payment,
        initial_outcome_messages.length(),
        clock,
        ctx
    );
    
    // Process queue fee
    proposal_fee_manager::deposit_queue_fee(proposal_fee_manager, fee_coin, clock, ctx);

    // Generate proposal ID
    let proposal_id = object::id_from_address(ctx.fresh_object_address());
    
    // Create proposal data
    let data = priority_queue::new_proposal_data(
        title,
        metadata,
        initial_outcome_messages,
        initial_outcome_details,
        initial_outcome_asset_amounts,
        initial_outcome_stable_amounts,
    );
    
    // Create queued proposal
    let queued_proposal = priority_queue::new_queued_proposal(
        proposal_id,
        object::id(dao),
        queue_fee,
        uses_dao_liquidity,
        ctx.sender(),
        data,
        bond_option,
        clock,
    );
    
    // Check if can create immediately
    if (priority_queue::can_create_immediately(queue, uses_dao_liquidity)) {
        // Would activate immediately here
        // For now just add to queue
        priority_queue::insert(queue, queued_proposal, proposal_fee_manager, clock, ctx);
    } else {
        // Add to queue
        priority_queue::insert(queue, queued_proposal, proposal_fee_manager, clock, ctx);
    };
    
    event::emit(ProposalQueued {
        dao_id: object::id(dao),
        proposal_id,
        proposer: ctx.sender(),
        bond_amount: required_bond,
        queue_position: priority_queue::length(queue),
    });
}

/// Activate next proposal from queue with proposer funding
public entry fun activate_next_proposer_funded_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    queue: &mut ProposalQueue<StableType>,
    fee_manager: &mut FeeManager,
    proposal_fee_manager: &mut ProposalFeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Try to activate next proposal from queue
    let next = priority_queue::try_activate_next(queue);
    assert!(option::is_some(&next), EProposalNotInQueue);
    
    let mut queued_proposal = option::destroy_some(next);
    
    // Verify it's proposer-funded
    assert!(!priority_queue_helpers::uses_dao_liquidity(&queued_proposal), EUnauthorized);
    
    // Verify caller is proposer
    assert!(priority_queue_helpers::get_proposer(&queued_proposal) == ctx.sender(), ENotProposer);
    
    // Extract data
    let proposal_id = priority_queue_helpers::get_proposal_id(&queued_proposal);
    let proposer = priority_queue_helpers::get_proposer(&queued_proposal);
    let mut bond = priority_queue_helpers::get_bond(&mut queued_proposal);
    
    let proposal_data = priority_queue_helpers::get_data(&queued_proposal);
    // Extract proposal details
    let title = *priority_queue_helpers::get_title(proposal_data);
    let metadata = *priority_queue_helpers::get_metadata(proposal_data);
    let outcome_messages = *priority_queue_helpers::get_outcome_messages(proposal_data);
    let outcome_details = *priority_queue_helpers::get_outcome_details(proposal_data);
    let initial_asset_amounts = *priority_queue_helpers::get_initial_asset_amounts(proposal_data);
    let initial_stable_amounts = *priority_queue_helpers::get_initial_stable_amounts(proposal_data);
    
    // Create the actual proposal
    let (created_id, market_state_id, _) = create_proposal_internal(
        dao, fee_manager, 
        coin::zero<SUI>(ctx), // Already paid during queue submission
        coin::zero<StableType>(ctx), // Already paid
        title, metadata,
        outcome_messages, outcome_details,
        initial_asset_amounts, initial_stable_amounts,
        false, // proposer-funded
        clock, ctx
    );
    
    // Give activator reward
    let reward = proposal_fee_manager::take_activator_reward(
        proposal_fee_manager,
        proposal_id,
        ctx
    );
    transfer::public_transfer(reward, ctx.sender());
    
    // Bond should be none for proposer-funded proposals
    bond.destroy_none();
    
    // Destroy the queued proposal
    priority_queue::destroy_proposal(queued_proposal);
    
    event::emit(ProposalActivated {
        dao_id: object::id(dao),
        proposal_id: created_id,
        proposer: ctx.sender(),
        activation_time: clock.timestamp_ms(),
    });
}

/// Activate next proposal from queue with DAO funding
public entry fun activate_next_dao_funded_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    queue: &mut ProposalQueue<StableType>,
    pool: &mut DAOLiquidityPool<AssetType, StableType>,
    fee_manager: &mut FeeManager,
    proposal_fee_manager: &mut ProposalFeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Try to activate next proposal from queue
    let next = priority_queue::try_activate_next(queue);
    assert!(option::is_some(&next), EProposalNotInQueue);
    
    let mut queued_proposal = option::destroy_some(next);
    
    // Verify it uses DAO liquidity
    assert!(priority_queue_helpers::uses_dao_liquidity(&queued_proposal), EUnauthorized);
    
    // Extract data
    let proposal_id = priority_queue_helpers::get_proposal_id(&queued_proposal);
    let proposer = priority_queue_helpers::get_proposer(&queued_proposal);
    let mut bond = priority_queue_helpers::get_bond(&mut queued_proposal);
    
    let proposal_data = priority_queue_helpers::get_data(&queued_proposal);
    // Extract proposal details
    let title = *priority_queue_helpers::get_title(proposal_data);
    let metadata = *priority_queue_helpers::get_metadata(proposal_data);
    let outcome_messages = *priority_queue_helpers::get_outcome_messages(proposal_data);
    let outcome_details = *priority_queue_helpers::get_outcome_details(proposal_data);
    
    // Get minimum liquidity amounts from DAO
    let min_asset = dao_state::min_asset_amount(dao);
    let min_stable = dao_state::min_stable_amount(dao);
    let outcome_count = outcome_messages.length();
    
    // Calculate required liquidity
    let required_asset = min_asset * outcome_count;
    let required_stable = min_stable * outcome_count;
    
    // Check DAO pool has sufficient liquidity
    let (available_asset, available_stable) = dao_liquidity_pool::get_available_liquidity(pool);
    assert!(available_asset >= required_asset, EInsufficientLiquidity);
    assert!(available_stable >= required_stable, EInsufficientLiquidity);
    
    // Create the actual proposal with DAO liquidity flag
    let (created_id, market_state_id, _) = create_proposal_internal(
        dao, fee_manager,
        coin::zero<SUI>(ctx), // Already paid during queue submission
        coin::zero<StableType>(ctx), // Already paid
        title, metadata,
        outcome_messages, outcome_details,
        vector::tabulate!(outcome_count, |_| 0), // DAO will provide liquidity
        vector::tabulate!(outcome_count, |_| 0), // DAO will provide liquidity
        true, // uses_dao_liquidity
        clock, ctx
    );
    
    // Give activator reward  
    let reward = proposal_fee_manager::take_activator_reward(
        proposal_fee_manager,
        proposal_id,
        ctx
    );
    transfer::public_transfer(reward, ctx.sender());
    
    // Return bond if any (DAO-funded proposals should have a bond)
    if (option::is_some(&bond)) {
        let bond_coin = option::destroy_some(bond);
        transfer::public_transfer(bond_coin, proposer);
    } else {
        bond.destroy_none();
    };
    
    // Destroy the queued proposal
    priority_queue::destroy_proposal(queued_proposal);
    
    event::emit(ProposalActivated {
        dao_id: object::id(dao),
        proposal_id: created_id,
        proposer: ctx.sender(),
        activation_time: clock.timestamp_ms(),
    });
}

/// Evict a stale proposal from the queue
public entry fun evict_stale_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    queue: &mut ProposalQueue<StableType>,
    proposal_fee_manager: &mut ProposalFeeManager,
    proposal_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get all proposals to check for staleness
    let proposals = priority_queue::get_all_proposals(queue);
    let mut found = false;
    let mut i = 0;
    let len = proposals.length();
    
    while (i < len && !found) {
        let proposal = &proposals[i];
        if (priority_queue_helpers::get_proposal_id(proposal) == proposal_id) {
            // Check if proposal is expired
            let created_at = priority_queue_helpers::get_timestamp(proposal);
            let is_expired = clock.timestamp_ms() >= created_at + PROPOSAL_EXPIRY_PERIOD_MS;
            assert!(is_expired, EProposalNotExpired);
            found = true;
        };
        i = i + 1;
    };
    
    assert!(found, EProposalNotInQueue);
    
    // Remove the proposal from queue
    let mut evicted = priority_queue::remove_from_queue(queue, proposal_id);
    
    // Slash the proposal fee (goes to protocol revenue)
    proposal_fee_manager::slash_proposal_fee(proposal_fee_manager, proposal_id);
    
    // Return bond to proposer if any
    let mut bond = priority_queue_helpers::get_bond(&mut evicted);
    let proposer = priority_queue_helpers::get_proposer(&evicted);
    if (option::is_some(&bond)) {
        let bond_coin = option::destroy_some(bond);
        transfer::public_transfer(bond_coin, proposer);
    } else {
        bond.destroy_none();
    };
    
    // Destroy the evicted proposal
    priority_queue::destroy_proposal(evicted);
    
    event::emit(ProposalEvicted {
        dao_id: object::id(dao),
        proposal_id,
        reason: b"Expired in queue".to_string(),
        evicted_by: ctx.sender(),
    });
}

/// Update the fee of a queued proposal to increase its priority
public entry fun update_proposal_fee<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    queue: &mut ProposalQueue<StableType>,
    proposal_fee_manager: &mut ProposalFeeManager,
    proposal_id: ID,
    fee_top_up: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify queue belongs to this DAO
    assert!(priority_queue::dao_id(queue) == object::id(dao), EUnauthorized);

    let additional_fee = fee_top_up.value();

    // Update the priority in the queue
    priority_queue::update_proposal_fee(queue, proposal_id, additional_fee, clock, ctx);

    // Add the additional fee to the manager
    proposal_fee_manager::add_to_proposal_fee(
        proposal_fee_manager, proposal_id, fee_top_up, clock
    );
}

// === Execution Functions ===

/// Sign the result of a finalized proposal
public entry fun sign_result_entry<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    proposal_id: ID,
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Validate proposal state
    assert!(proposal::state(proposal) == STATE_FINALIZED, EProposalNotFinalized);
    assert!(proposal::get_id(proposal) == proposal_id, EUnauthorized);
    assert!(proposal::get_dao_id(proposal) == object::id(dao), EInvalidDaoId);
    
    // Get proposal info
    let proposals = dao_state::proposals_mut(dao);
    assert!(proposals.contains(proposal_id), EProposalNotFound);
    let info = &mut proposals[proposal_id];
    
    // Check not already executed
    assert!(!dao_state::proposal_info_executed(info), EProposalAlreadyExecuted);
    
    // Get winning outcome
    let winning_outcome = proposal::get_winning_outcome(proposal);
    assert!(winning_outcome < dao_state::proposal_info_outcome_count(info), EInvalidWinningOutcome);
    
    // Get outcome message
    let outcome_messages = proposal::get_outcome_messages(proposal);
    let result = vector::borrow(outcome_messages, winning_outcome);
    
    // Update proposal info
    dao_state::set_proposal_info_result(info, *result);
    dao_state::set_proposal_info_execution_deadline(info, clock.timestamp_ms() + EXECUTION_DEADLINE_MS);
    
    // Update proposal state
    dao_state::set_proposal_info_state(info, STATE_FINALIZED);
    
    // Decrement active proposals
    dao_state::decrement_active_proposals(dao);
}

/// Funds a PREMARKET proposal, initializes its market, and moves it to the REVIEW state.
public entry fun fund_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(proposal::state(proposal) == STATE_PREMARKET, EInvalidState);
    assert!(proposal::get_dao_id(proposal) == object::id(dao), EUnauthorized);

    // Get parameters from proposal
    let (outcome_count, outcome_messages, asset_amounts, stable_amounts) =
        proposal::get_market_init_params(proposal);

    // Verify liquidity matches required amounts
    let mut total_asset = 0;
    let mut total_stable = 0;
    let mut i = 0;
    while(i < asset_amounts.length()) {
        total_asset = total_asset + asset_amounts[i];
        total_stable = total_stable + stable_amounts[i];
        i = i + 1;
    };
    assert!(asset_coin.value() >= total_asset, EInvalidAmount);
    assert!(stable_coin.value() >= total_stable, EInvalidAmount);

    // Create MarketState, Escrow, and Pools
    let market_state = market_state::new(proposal::get_id(proposal), object::id(dao), outcome_count, *outcome_messages, clock, ctx);
    let market_state_id = object::id(&market_state);

    let mut escrow = coin_escrow::new<AssetType, StableType>(market_state, ctx);
    let escrow_id = object::id(&escrow);

    let (_, amm_pools) = liquidity_initialize::create_outcome_markets(
        &mut escrow,
        outcome_count,
        *asset_amounts,
        *stable_amounts,
        proposal::get_twap_start_delay(proposal),
        proposal::get_twap_initial_observation(proposal),
        proposal::get_twap_step_max(proposal),
        proposal::get_amm_total_fee_bps(proposal),
        asset_coin.into_balance(),
        stable_coin.into_balance(),
        clock,
        ctx
    );

    // Update the proposal object
    proposal::initialize_market_fields(
        proposal,
        market_state_id,
        escrow_id,
        amm_pools,
        clock.timestamp_ms(),
        ctx.sender()
    );

    proposal::emit_market_initialized(
        proposal::get_id(proposal),
        proposal::get_dao_id(proposal),
        market_state_id,
        escrow_id,
        clock.timestamp_ms()
    );

    transfer::public_share_object(escrow);

    // Update DAO proposal info state
    let proposals = dao_state::proposals_mut(dao);
    let info = &mut proposals[proposal::get_id(proposal)];
    dao_state::set_proposal_info_state(info, STATE_REVIEW);
}

/// Check if execution is allowed for a proposal
public fun is_execution_allowed<AssetType, StableType>(
    dao: &DAO<AssetType, StableType>,
    proposal_id: ID,
    clock: &Clock,
): bool {
    let proposals = dao_state::proposals(dao);
    if (!proposals.contains(proposal_id)) return false;
    
    let info = &proposals[proposal_id];
    if (dao_state::proposal_info_executed(info)) return false;
    if (!dao_state::proposal_info_result(info).is_some()) return false;
    
    let deadline = dao_state::proposal_info_execution_deadline(info);
    if (deadline.is_none()) return false;
    
    clock.timestamp_ms() < *deadline.borrow()
}

/// Create execution context for a proposal
public fun create_execution_context<AssetType, StableType>(
    dao: &DAO<AssetType, StableType>,
    proposal_id: ID,
    winning_outcome: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ProposalExecutionContext {
    let proposals = dao_state::proposals(dao);
    assert!(proposals.contains(proposal_id), EProposalNotFound);
    
    let info = &proposals[proposal_id];
    assert!(!dao_state::proposal_info_executed(info), EProposalAlreadyExecuted);
    assert!(dao_state::proposal_info_result(info).is_some(), EProposalNotResolved);
    
    let deadline = dao_state::proposal_info_execution_deadline(info);
    assert!(deadline.is_some(), EExecutionDeadlineNotSet);
    assert!(clock.timestamp_ms() < *deadline.borrow(), EExecutionDeadlinePassed);
    
    execution_context::new(
        proposal_id,
        object::id(dao),
        winning_outcome,
        clock::timestamp_ms(clock),
        ctx
    )
}

/// Mark a proposal as executed
public(package) fun mark_proposal_executed<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    proposal_id: ID,
    clock: &Clock,
) {
    let proposals = dao_state::proposals_mut(dao);
    let info = &mut proposals[proposal_id];
    
    dao_state::set_proposal_info_executed(info, true);
    dao_state::set_proposal_info_execution_time(info, clock.timestamp_ms());
}

// === Helper Functions ===

/// Get the proposal queue for a DAO (creates it if it doesn't exist)
public(package) fun get_or_create_queue<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    ctx: &mut TxContext
): ID {
    if (dao_state::proposal_queue_id(dao).is_none()) {
        // Create new queue
        let queue = priority_queue::new<StableType>(
            object::id(dao),
            dao_state::max_concurrent_proposals(dao) - 1, // Reserve 1 slot for DAO-funded
            dao_state::max_concurrent_proposals(dao),
            ctx
        );
        let queue_id = object::id(&queue);
        dao_state::set_proposal_queue_id(dao, option::some(queue_id));
        transfer::public_share_object(queue);
        queue_id
    } else {
        *dao_state::proposal_queue_id(dao).borrow()
    }
}

/// Calculate current queue fee based on queue size
fun calculate_queue_fee<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 {
    let queue_size = dao_state::queue_size(dao);
    let base_fee = 1_000_000; // 1 SUI base fee
    let escalation = dao_state::fee_escalation_basis_points(dao);
    
    // Fee increases by escalation_basis_points per queued proposal
    let multiplier = 10000 + (queue_size * escalation);
    (base_fee * multiplier) / 10000
}

/// Get required bond amount for queue submission
public fun get_required_bond_amount<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 {
    dao_state::required_bond_amount(dao)
}

/// Calculate eviction fee (constant for now)
fun calculate_eviction_fee(): u64 {
    100_000 // 0.1 SUI
}

// === Getters ===

/// Get proposal info
public fun get_proposal_info<AssetType, StableType>(
    dao: &DAO<AssetType, StableType>,
    proposal_id: ID
): &ProposalInfo {
    let proposals = dao_state::proposals(dao);
    assert!(proposals.contains(proposal_id), EProposalNotFound);
    &proposals[proposal_id]
}

/// Get queue statistics
public fun get_queue_stats<AssetType, StableType>(
    dao: &DAO<AssetType, StableType>
): (u64, u64, u64, bool) {
    (
        dao_state::queue_size(dao),
        calculate_queue_fee(dao),
        get_required_bond_amount(dao),
        dao_state::queue_size(dao) < MAX_QUEUE_SIZE
    )
}

use std::type_name;