module futarchy::dao;

use futarchy::coin_escrow;
use futarchy::fee;
use futarchy::proposal_fee_manager;
use futarchy::liquidity_initialize;
use futarchy::liquidity_interact;
use futarchy::market_state;
use futarchy::advance_stage::{Self, FinalizationReceipt};
use futarchy::dao_liquidity_pool::{Self, DAOLiquidityPool};
use futarchy::proposal;
use futarchy::operating_agreement;
use futarchy::vectors;
use futarchy::priority_queue::{Self, ProposalQueue, QueuedProposal, ProposalData};
use futarchy::priority_queue_helpers;
use futarchy::execution_context::{Self, ProposalExecutionContext};
use std::ascii::String as AsciiString;
use std::option;
use std::string::String;
use std::vector;
use std::type_name;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use sui::table::{Self, Table};
use sui::url::{Self, Url};
use sui::balance::{Self, Balance};
use sui::transfer;

// === Introduction ===
// This defines the DAO type

// === Errors ===
const EInvalidAmount: u64 = 0;
const EProposalExists: u64 = 1;
const EUnauthorized: u64 = 2;
const EInvalidOutcomeCount: u64 = 3;
const EProposalNotFound: u64 = 4;
const EInvalidMinAmounts: u64 = 5;
const EAlreadyExecuted: u64 = 6;
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
const EInvalidTwapDelay: u64 = 20;
const EDaoDescriptionTooLong: u64 = 21;
const EInvalidDetailsLength: u64 = 22;
const EInvalidState: u64 = 23;
const EOutcomeOutOfBounds: u64 = 24;
const EDuplicateMessage: u64 = 25;
const EDaoOwnedLiquidityInUse: u64 = 26;
const EMaxConcurrentProposalsReached: u64 = 27;
const EProposalQueuedNotActive: u64 = 28;
const EProposalNotUsesDaoLiquidity: u64 = 29;
const EProposalUsesDaoLiquidity: u64 = 30;
const EInvalidProposalData: u64 = 31;
const EInvalidBond: u64 = 32;
const EStaleProposal: u64 = 33;
const EInvalidReceipt: u64 = 34;
const EInvalidProposalId: u64 = 35;

// === State Constants ===
const STATE_PREMARKET: u8 = 0;
const STATE_REVIEW: u8 = 1;

// === Constants ===
const TITLE_MAX_LENGTH: u64 = 512;
const METADATA_MAX_LENGTH: u64 = 1024;
const DETAILS_MAX_LENGTH: u64 = 16384; // 16KB
const MIN_OUTCOMES: u64 = 2;
const MAX_OUTCOMES: u64 = 3;
const MAX_RESULT_LENGTH: u64 = 128;
const MIN_AMM_SAFE_AMOUNT: u64 = 1000; // under 50 swap will have significant slippage
const DAO_DESCRIPTION_MAX_LENGTH: u64 = 1024;

const MONTHLY_FEE_PERIOD_MS: u64 = 2_592_000_000; // 30 days
const DEFAULT_MAX_CONCURRENT_PROPOSALS: u64 = 10;
const DEFAULT_MAX_PROPOSER_FUNDED_QUEUE: u64 = 50;
const STALE_DURATION_MS: u64 = 2_592_000_000; // 30 days
const DEFAULT_BOND_AMOUNT: u64 = 100_000_000; // 100 StableType tokens as default bond

// === Structs ===

public struct DAO<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    asset_type: AsciiString,
    stable_type: AsciiString,
    min_asset_amount: u64,
    min_stable_amount: u64,
    proposals: Table<ID, ProposalInfo>,
    active_proposal_count: u64,
    total_proposals: u64,
    creation_time: u64,
    amm_twap_start_delay: u64,
    // The queue for upcoming proposals.
    proposal_queue: ProposalQueue<StableType>,
    amm_twap_step_max: u64,
    amm_twap_initial_observation: u128,
    twap_threshold: u64,
    dao_name: AsciiString,
    icon_url: Url,
    review_period_ms: u64,
    trading_period_ms: u64,
    attestation_url: String,
    verification_pending: bool,
    verified: bool,
    proposal_creation_enabled: bool,
    description: String,
    max_outcomes: u64,
    metadata: vector<String>,
    treasury_account_id: Option<ID>,
    proposal_fee_per_outcome: u64,
    operating_agreement_id: Option<ID>,
    // ID of the DAO's own liquidity pool for proposals.
    dao_liquidity_pool_id: Option<ID>,
    next_fee_due_timestamp: u64,
    // Maximum number of concurrent active proposals
    max_concurrent_proposals: u64,
    // Track if DAO liquidity is currently in use
    dao_liquidity_in_use: bool,
    // ID of the proposal fee manager for this DAO
    proposal_fee_manager_id: ID,
    // Required bond amount for DAO-funded proposals (in StableType)
    required_bond_amount: u64,
}

public struct ProposalInfo has store {
    proposer: address,
    created_at: u64,
    state: u8,
    outcome_count: u64,
    title: String,
    result: Option<String>,
    execution_time: Option<u64>,
    executed: bool,
    market_state_id: ID,
}



// === Events ===
public struct DAOCreated has copy, drop {
    dao_id: ID,
    min_asset_amount: u64,
    min_stable_amount: u64,
    timestamp: u64,
    asset_type: AsciiString,
    stable_type: AsciiString,
    dao_name: AsciiString,
    icon_url: Url,
    review_period_ms: u64,
    trading_period_ms: u64,
    amm_twap_start_delay: u64,
    amm_twap_step_max: u64,
    amm_twap_initial_observation: u128,
    twap_threshold: u64,
    description: String,
}

public struct ResultSigned has copy, drop {
    dao_id: ID,
    proposal_id: ID,
    outcome: String,
    description: String,
    winning_outcome: u64,
    timestamp: u64,
}

public struct ProposalCreationPausedDueToUnpaidFees has copy, drop {
    dao_id: ID,
    timestamp: u64,
    fee_due_timestamp: u64,
}

public struct ProposalCreationUnpaused has copy, drop {
    dao_id: ID,
    timestamp: u64,
}

public struct BondSlashed has copy, drop {
    dao_id: ID,
    proposal_id: ID,
    proposer: address,
    amount: u64,
    recipient: address,
    timestamp: u64,
}

public struct ProposalEvicted has copy, drop {
    dao_id: ID,
    proposal_id: ID,
    proposer: address,
    evicted_by: address,
    timestamp: u64,
}

// === Public Functions ===
public(package) fun create<AssetType, StableType>(
    min_asset_amount: u64,
    min_stable_amount: u64,
    dao_name: AsciiString,
    icon_url_string: AsciiString,
    review_period_ms: u64,
    trading_period_ms: u64,
    amm_twap_start_delay: u64,
    amm_twap_step_max: u64,
    amm_twap_initial_observation: u128,
    twap_threshold: u64,
    description: String,
    max_outcomes: u64,
    metadata: vector<String>,
    clock: &Clock,
    ctx: &mut TxContext,
): DAO<AssetType, StableType> {
    assert!(
        min_asset_amount > MIN_AMM_SAFE_AMOUNT && min_stable_amount > MIN_AMM_SAFE_AMOUNT,
        EInvalidMinAmounts,
    );
    // checks that both types are for coins, but still allows regulated coins
    let _test_coin_asset = coin::zero<AssetType>(ctx);
    let _test_coin_stable = coin::zero<StableType>(ctx);
    _test_coin_asset.destroy_zero();
    _test_coin_stable.destroy_zero();

    let icon_url = url::new_unsafe(icon_url_string);

    let timestamp = clock.timestamp_ms();


    assert!((amm_twap_start_delay % 60_000) == 0, EInvalidTwapDelay);

    assert!(description.length() <= DAO_DESCRIPTION_MAX_LENGTH, EDaoDescriptionTooLong);
    
    // Validate max_outcomes is within reasonable bounds
    assert!(max_outcomes >= MIN_OUTCOMES && max_outcomes <= MAX_OUTCOMES, EInvalidOutcomeCount);

    let dao_id = object::new(ctx);
    
    // Create the proposal fee manager for this DAO
    let pfm = proposal_fee_manager::new(ctx);
    let pfm_id = object::id(&pfm);
    transfer::public_share_object(pfm);
    
    let dao_id_inner = dao_id.to_inner();
    let dao = DAO {
        id: dao_id,
        asset_type: type_name::get<AssetType>().into_string(),
        stable_type: type_name::get<StableType>().into_string(),
        min_asset_amount,
        min_stable_amount,
        proposals: table::new(ctx),
        active_proposal_count: 0,
        total_proposals: 0,
        creation_time: timestamp,
        amm_twap_start_delay,
        // Initialize the priority queue with a max size for proposer-funded proposals.
        proposal_queue: priority_queue::new<StableType>(dao_id_inner, DEFAULT_MAX_PROPOSER_FUNDED_QUEUE, DEFAULT_MAX_CONCURRENT_PROPOSALS, ctx),
        amm_twap_step_max,
        amm_twap_initial_observation,
        twap_threshold,
        dao_name: dao_name,
        icon_url,
        review_period_ms,
        trading_period_ms,
        attestation_url: b"".to_string(),
        verification_pending: false,
        verified: false,
        proposal_creation_enabled: true,
        description: description,
        max_outcomes: max_outcomes,
        metadata: metadata,
        treasury_account_id: option::none(),
        proposal_fee_per_outcome: 0,
        operating_agreement_id: option::none(),
        dao_liquidity_pool_id: option::none(),
        next_fee_due_timestamp: timestamp + MONTHLY_FEE_PERIOD_MS,
        max_concurrent_proposals: DEFAULT_MAX_CONCURRENT_PROPOSALS,
        dao_liquidity_in_use: false,
        proposal_fee_manager_id: pfm_id,
        required_bond_amount: DEFAULT_BOND_AMOUNT,
    };

    event::emit(DAOCreated {
        dao_id: dao.id.to_inner(),
        min_asset_amount,
        min_stable_amount,
        timestamp,
        asset_type: type_name::get<AssetType>().into_string(),
        stable_type: type_name::get<StableType>().into_string(),
        dao_name: dao_name,
        icon_url: icon_url,
        review_period_ms,
        trading_period_ms,
        amm_twap_start_delay,
        amm_twap_step_max,
        amm_twap_initial_observation,
        twap_threshold,
        description,
    });

    // Return the DAO
    dao
}

/// Internal function to initialize the Operating Agreement for the DAO. 
/// Can only be called by authorized proposal execution.
/// Returns the ID of the created OperatingAgreement.
public(package) fun init_operating_agreement_internal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    initial_lines: vector<String>,
    initial_difficulties: vector<u64>,
    ctx: &mut TxContext,
): ID {
    // Ensure an agreement hasn't already been initialized.
    assert!(dao.operating_agreement_id.is_none(), EUnauthorized);

    let agreement = operating_agreement::new(
        object::id(dao),
        initial_lines,
        initial_difficulties,
        ctx,
    );
    let agreement_id = object::id(&agreement);
    dao.operating_agreement_id = option::some(agreement_id);
    transfer::public_share_object(agreement);
    
    agreement_id
}

/// Entry point for users to submit a new proposal to the DAO's priority queue.
public entry fun submit_to_queue<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut fee::FeeManager,
    proposal_fee_manager: &mut proposal_fee_manager::ProposalFeeManager,
    payment: Coin<SUI>,
    fee_coin: Coin<SUI>, // Separate coin for proposal submission fee
    uses_dao_liquidity: bool,
    mut bond: vector<Coin<StableType>>, // Pass as vector, empty if not using DAO liquidity
    title: String,
    metadata: String,
    initial_outcome_messages: vector<String>,
    initial_outcome_details: vector<String>,
    initial_outcome_asset_amounts: vector<u64>,
    initial_outcome_stable_amounts: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(dao.proposal_creation_enabled, EProposalCreationDisabled);
    
    // Validate bond requirement for DAO-funded proposals
    let bond_opt = if (uses_dao_liquidity) {
        assert!(bond.length() == 1, EInvalidBond);
        let bond_coin = bond.pop_back();
        // Validate bond amount meets requirement
        assert!(bond_coin.value() >= dao.required_bond_amount, EInvalidBond);
        option::some(bond_coin)
    } else {
        assert!(bond.is_empty(), EInvalidBond);
        option::none()
    };
    
    // Perform cheap validation upfront
    assert!(title.length() > 0 && title.length() <= TITLE_MAX_LENGTH, ETitleTooLong);
    assert!(metadata.length() <= METADATA_MAX_LENGTH, EMetadataTooLong);
    
    let outcome_count = initial_outcome_messages.length();
    assert!(outcome_count >= MIN_OUTCOMES && outcome_count <= MAX_OUTCOMES, EInvalidOutcomeCount);
    assert!(initial_outcome_details.length() == outcome_count, EInvalidDetailsLength);
    assert!(initial_outcome_asset_amounts.length() == outcome_count, EInvalidDetailsLength);
    assert!(initial_outcome_stable_amounts.length() == outcome_count, EInvalidDetailsLength);
    
    // Validate first outcome is "Reject"
    let reject_string = b"Reject".to_string();
    assert!(&initial_outcome_messages[0] == &reject_string, EInvalidMessages);
    
    // For 2-outcome proposals, assert second outcome is "Accept"
    if (outcome_count == 2) {
        let accept_string = b"Accept".to_string();
        assert!(&initial_outcome_messages[1] == &accept_string, EInvalidMessages);
    };
    
    // Handle platform fee (in SUI) - paid to the fee manager
    fee::deposit_proposal_creation_payment(fee_manager, payment, outcome_count, clock, ctx);
    
    // Generate a unique proposal ID for the queue
    let uid = object::new(ctx);
    let proposal_id = uid.to_inner();
    
    // Store the submission fee in the proposal fee manager
    proposal_fee_manager::deposit_proposal_fee(proposal_fee_manager, proposal_id, fee_coin);
    
    // Check if proposal can be created immediately
    if (priority_queue::can_create_immediately(&dao.proposal_queue, uses_dao_liquidity)) {
        // If using DAO liquidity and slot is available, create directly
        if (uses_dao_liquidity) {
            dao.dao_liquidity_in_use = true;
            // Don't increment the active count here, it will be done when creating the proposal
        };
        
        // Create the proposal directly without queuing
        // For immediate creation, we need to pass the initial amounts as well
        // Create proposal directly using the proposal module
        // Payment has already been handled by fee_manager
        let fee_balance = if (uses_dao_liquidity) {
            let bond = bond_opt.destroy_some();
            bond.into_balance()
        } else {
            bond_opt.destroy_none();
            balance::zero<StableType>()
        };
        
        let (created_proposal_id, market_state_id, state) = proposal::create<AssetType, StableType>(
            fee_balance, object::id(dao), dao.review_period_ms, dao.trading_period_ms,
            dao.min_asset_amount, dao.min_stable_amount,
            title, metadata, initial_outcome_messages, initial_outcome_details,
            initial_outcome_asset_amounts, initial_outcome_stable_amounts,
            dao.amm_twap_start_delay, dao.amm_twap_initial_observation,
            dao.amm_twap_step_max, dao.twap_threshold,
            uses_dao_liquidity, if (dao.treasury_account_id.is_some()) {
                object::id_to_address(dao.treasury_account_id.borrow())
            } else {
                // For now, use the DAO creator as fallback treasury
                // In production, should require treasury before allowing fee-based proposals
                ctx.sender()
            }, clock, ctx
        );
        
        // Update proposal count
        dao.active_proposal_count = dao.active_proposal_count + 1;
        dao.total_proposals = dao.total_proposals + 1;
        
        // Store proposal in DAO
        dao.proposals.add(created_proposal_id, ProposalInfo {
            proposer: ctx.sender(),
            created_at: clock.timestamp_ms(),
            state,
            outcome_count: initial_outcome_messages.length(),
            title,
            result: option::none(),
            execution_time: option::none(),
            executed: false,
            market_state_id
        });
        
        // Return the submission fee since the proposal was created immediately
        // The fee is returned to incentivize immediate creation
        if (proposal_fee_manager::has_proposal_fee(proposal_fee_manager, proposal_id)) {
            let reward = proposal_fee_manager::take_activator_reward(proposal_fee_manager, proposal_id, ctx);
            transfer::public_transfer(reward, ctx.sender());
        };
    } else {
        // Create typed proposal data
        let proposal_data = priority_queue::new_proposal_data(
            title, 
            metadata, 
            initial_outcome_messages, 
            initial_outcome_details,
            initial_outcome_asset_amounts, 
            initial_outcome_stable_amounts
        );
        
        // Get the submission fee amount from the coin we stored
        let fee_amount = proposal_fee_manager::get_proposal_fee(proposal_fee_manager, proposal_id);
        let queued_proposal = priority_queue::new_queued_proposal<StableType>(
            proposal_id,
            object::id(dao),
            fee_amount,
            uses_dao_liquidity,
            ctx.sender(),
            proposal_data,
            bond_opt,
            clock,
        );
        
        priority_queue::insert(&mut dao.proposal_queue, queued_proposal);
    };
    
    // Ensure bond vector is empty
    bond.destroy_empty();
    
    // Clean up uid
    uid.delete();
}

/// Permissionless crank function to activate the highest-priority proposal from the queue.
/// This version is for proposals where the liquidity is provided by the caller.
public entry fun activate_next_proposer_funded_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut fee::FeeManager,
    proposal_fee_manager: &mut proposal_fee_manager::ProposalFeeManager,
    // Liquidity for the market must be provided by the activator.
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Try to activate next proposal
    let mut queued_proposal_opt = priority_queue::try_activate_next(&mut dao.proposal_queue);
    assert!(queued_proposal_opt.is_some(), EProposalQueuedNotActive);
    
    let mut queued_proposal = queued_proposal_opt.extract();
    queued_proposal_opt.destroy_none();
    
    // A DAO-funded proposal cannot be activated by this function.
    assert!(!priority_queue_helpers::uses_dao_liquidity(&queued_proposal), EProposalUsesDaoLiquidity);
    
    // Get proposal data
    let data = priority_queue_helpers::get_data(&queued_proposal);
    let title = *priority_queue_helpers::get_title(data);
    let metadata = *priority_queue_helpers::get_metadata(data);
    let messages = *priority_queue_helpers::get_outcome_messages(data);
    let details = *priority_queue_helpers::get_outcome_details(data);
    let asset_amounts = *priority_queue_helpers::get_initial_asset_amounts(data);
    let stable_amounts = *priority_queue_helpers::get_initial_stable_amounts(data);
    
    // Pay activator reward from proposal fee manager
    let proposal_id = priority_queue_helpers::get_proposal_id(&queued_proposal);
    let reward = proposal_fee_manager::take_activator_reward(proposal_fee_manager, proposal_id, ctx);
    transfer::public_transfer(reward, ctx.sender());
    
    // Extract proposal info before destroying
    let proposal_id = priority_queue_helpers::get_proposal_id(&queued_proposal);
    let proposer = priority_queue_helpers::get_proposer(&queued_proposal);
    
    // Destroy the queued proposal
    priority_queue::destroy_proposal(queued_proposal);
    
    // Initialize the market with provided liquidity
    initialize_market_and_provide_liquidity_for_queued<AssetType, StableType>(
        dao,
        proposal_id,
        proposer,
        title,
        metadata,
        messages,
        details,
        asset_coin,
        stable_coin,
        clock,
        ctx
    );
}

/// Activate the next DAO-funded proposal from the queue
public entry fun activate_next_dao_funded_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    pool: &mut DAOLiquidityPool<AssetType, StableType>,
    fee_manager: &mut fee::FeeManager,
    proposal_fee_manager: &mut proposal_fee_manager::ProposalFeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Ensure DAO liquidity is not already in use
    assert!(!dao.dao_liquidity_in_use, EDaoOwnedLiquidityInUse);
    
    // Try to activate next proposal
    let mut queued_proposal_opt = priority_queue::try_activate_next(&mut dao.proposal_queue);
    assert!(queued_proposal_opt.is_some(), EProposalQueuedNotActive);
    
    let mut queued_proposal = queued_proposal_opt.extract();
    queued_proposal_opt.destroy_none();
    
    // Must be a DAO-funded proposal
    assert!(priority_queue_helpers::uses_dao_liquidity(&queued_proposal), EProposalNotUsesDaoLiquidity);
    
    // Return the bond to the original proposer
    let mut bond = priority_queue_helpers::get_bond(&mut queued_proposal);
    assert!(bond.is_some(), EInvalidBond);
    transfer::public_transfer(bond.extract(), priority_queue_helpers::get_proposer(&queued_proposal));
    bond.destroy_none();
    
    // Mark DAO liquidity as in use
    dao.dao_liquidity_in_use = true;
    
    // Get proposal data
    let data = priority_queue_helpers::get_data(&queued_proposal);
    let title = *priority_queue_helpers::get_title(data);
    let metadata = *priority_queue_helpers::get_metadata(data);
    let messages = *priority_queue_helpers::get_outcome_messages(data);
    let details = *priority_queue_helpers::get_outcome_details(data);
    
    // Pay activator reward from proposal fee manager
    let proposal_id = priority_queue_helpers::get_proposal_id(&queued_proposal);
    let reward = proposal_fee_manager::take_activator_reward(proposal_fee_manager, proposal_id, ctx);
    transfer::public_transfer(reward, ctx.sender());
    
    // Get liquidity from DAO pool
    let asset_amount = dao_liquidity_pool::asset_balance(pool);
    let stable_amount = dao_liquidity_pool::stable_balance(pool);
    let asset_balance = dao_liquidity_pool::withdraw_all_asset_balance(pool);
    let stable_balance = dao_liquidity_pool::withdraw_all_stable_balance(pool);
    let asset_coin = asset_balance.into_coin(ctx);
    let stable_coin = stable_balance.into_coin(ctx);
    
    // Extract proposal info before destroying
    let proposal_id = priority_queue_helpers::get_proposal_id(&queued_proposal);
    let proposer = priority_queue_helpers::get_proposer(&queued_proposal);
    
    // Destroy the queued proposal
    priority_queue::destroy_proposal(queued_proposal);
    
    // Initialize the market with DAO liquidity
    initialize_market_and_provide_liquidity_for_queued<AssetType, StableType>(
        dao,
        proposal_id,
        proposer,
        title,
        metadata,
        messages,
        details,
        asset_coin,
        stable_coin,
        clock,
        ctx
    );
}

// Helper function to initialize market for queued proposals
fun initialize_market_and_provide_liquidity_for_queued<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    proposal_id: ID,
    proposer: address,
    title: String,
    metadata: String,
    messages: vector<String>,
    details: vector<String>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let dao_id = object::id(dao);
    let outcome_count = messages.length();
    let asset_amounts = vector::tabulate!(outcome_count, |_| asset_coin.value() / outcome_count);
    let stable_amounts = vector::tabulate!(outcome_count, |_| stable_coin.value() / outcome_count);
    
    // Get DAO parameters
    let (
        _dao_id, review_period_ms, trading_period_ms, min_asset_liquidity, min_stable_liquidity,
        twap_start_delay, twap_initial_observation, twap_step_max, twap_threshold,
        treasury_address
    ) = get_market_params(dao);
    
    // Use the new initialize_market function that creates everything at once
    let (actual_proposal_id, market_state_id, state) = proposal::initialize_market<AssetType, StableType>(
        dao_id,
        review_period_ms,
        trading_period_ms,
        min_asset_liquidity,
        min_stable_liquidity,
        twap_start_delay,
        twap_initial_observation,
        twap_step_max,
        twap_threshold,
        treasury_address,
        title,
        metadata,
        messages,
        details,
        asset_coin,
        stable_coin,
        proposer,
        false, // uses_dao_liquidity = false for user-funded
        balance::zero<StableType>(), // No fee escrow for user-funded proposals
        clock,
        ctx
    );
    
    // The proposal ID from the queue should match the created proposal
    assert!(actual_proposal_id == proposal_id, EInvalidProposalId);
}


/// Initializes the DAO's owned liquidity pool. Can only be called once.
public entry fun init_liquidity_pool<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    ctx: &mut TxContext
) {
    assert!(dao.dao_liquidity_pool_id.is_none(), EUnauthorized);
    let pool = dao_liquidity_pool::new<AssetType, StableType>(
        object::id(dao),
        ctx
    );
    let pool_id = object::id(&pool);
    dao.dao_liquidity_pool_id = option::some(pool_id);
    transfer::public_share_object(pool);
}

/// Deposits funds into the DAO's liquidity pool. Can be called by anyone.
public entry fun deposit_to_liquidity_pool<AssetType, StableType>(
    pool: &mut DAOLiquidityPool<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>
) {
    dao_liquidity_pool::deposit_asset(pool, asset_coin);
    dao_liquidity_pool::deposit_stable(pool, stable_coin);
}

/// Withdraws funds from the DAO's liquidity pool. Requires DAO authorization via an executed proposal.
public(package) fun withdraw_from_liquidity_pool<AssetType, StableType>(
    pool: &mut DAOLiquidityPool<AssetType, StableType>,
    asset_amount: u64,
    stable_amount: u64,
    _ctx: &mut TxContext // Auth would be handled by an action registry
): (Coin<AssetType>, Coin<StableType>) {
    let asset_coin = dao_liquidity_pool::withdraw_asset(pool, asset_amount, _ctx);
    let stable_coin = dao_liquidity_pool::withdraw_stable(pool, stable_amount, _ctx);
    (asset_coin, stable_coin)
}

/// Join asset balance to the DAO liquidity pool
public(package) fun join_asset_balance<AssetType, StableType>(
    pool: &mut DAOLiquidityPool<AssetType, StableType>,
    balance: Balance<AssetType>
) {
    dao_liquidity_pool::join_asset_balance(pool, balance);
}

/// Join stable balance to the DAO liquidity pool
public(package) fun join_stable_balance<AssetType, StableType>(
    pool: &mut DAOLiquidityPool<AssetType, StableType>,
    balance: Balance<StableType>
) {
    dao_liquidity_pool::join_stable_balance(pool, balance);
}


/// Create a proposal that will be funded by the DAO's own liquidity pool.
/// This version does not require the proposer to set liquidity amounts, as it will
/// use the full balance of the DAO's pool.
public entry fun create_proposal_with_dao_liquidity<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    initial_outcome_messages: vector<String>,
    initial_outcome_details: vector<String>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // For this proposal type, the asset and stable amounts are implicitly defined
    // by the DAO's liquidity pool and are not set by the proposer.
    // The proposal creation function will handle setting these to a placeholder (e.g., 0)
    // and the `initialize_market_with_dao_liquidity` will use the real values.
    let placeholder_amounts = vector::tabulate!(initial_outcome_messages.length(), |_| 0);

    let (_p_id, _, _) = create_proposal_internal<AssetType, StableType>(
        dao, fee_manager, payment, dao_fee_payment, title, metadata,
        initial_outcome_messages, initial_outcome_details,
        placeholder_amounts, placeholder_amounts, true, // uses_dao_liquidity = true
        clock, ctx
    );
}


/// Internal function that returns proposal ID and related IDs for action storage
public fun create_proposal_internal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut fee::FeeManager,
    // Note: No large liquidity deposit here anymore.
    payment: Coin<SUI>,
    mut dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String,
    // Initial outcomes are now passed as a tuple of vectors.
    initial_outcome_messages: vector<String>,
    initial_outcome_details: vector<String>,
    initial_outcome_asset_amounts: vector<u64>,
    initial_outcome_stable_amounts: vector<u64>,
    uses_dao_liquidity: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID, u8) {
    assert!(dao.proposal_creation_enabled, EProposalCreationDisabled);
    
    // Handle factory fee (in SUI)
    let outcome_count = initial_outcome_messages.length();
    assert!(outcome_count > 1, EOneOutcome);
    assert!(outcome_count == initial_outcome_details.length(), EInvalidDetailsLength);
    assert!(outcome_count == initial_outcome_asset_amounts.length(), EInvalidDetailsLength);
    assert!(outcome_count == initial_outcome_stable_amounts.length(), EInvalidDetailsLength);

    fee::deposit_proposal_creation_payment(fee_manager, payment, outcome_count, clock, ctx);

    // Handle DAO-level fee (in StableType)
    let required_dao_fee = dao.proposal_fee_per_outcome * outcome_count;
    let dao_fee_balance: Balance<StableType>;
    if (required_dao_fee > 0) {
        assert!(dao.has_treasury(), EUnauthorized); // Must have a treasury to collect fees
        assert!(dao_fee_payment.value() >= required_dao_fee, EInvalidAmount);
        // Take only the required amount for escrow and return the rest to the sender
        let fee_coin = dao_fee_payment.split(required_dao_fee, ctx);
        dao_fee_balance = fee_coin.into_balance();
        // Return the remainder to sender
        transfer::public_transfer(dao_fee_payment, ctx.sender());
    } else {
        // If no fee, return the entire coin to the sender
        dao_fee_balance = balance::zero<StableType>();
        transfer::public_transfer(dao_fee_payment, ctx.sender());
    };

    let asset_type = type_name::get<AssetType>().into_string();
    let stable_type = type_name::get<StableType>().into_string();

    assert!(&asset_type == &dao.asset_type, EInvalidAssetType);
    assert!(&stable_type == &dao.stable_type, EInvalidStableType);

    assert!(outcome_count <= dao.max_outcomes, EInvalidOutcomeCount);
    
    // Validate first outcome is "Reject"
    let reject_string = b"Reject".to_string();
    assert!(&initial_outcome_messages[0] == &reject_string, EInvalidMessages);
    
    // For 2-outcome proposals, assert second outcome is "Accept"
    if (outcome_count == 2) {
        let accept_string = b"Accept".to_string();
        assert!(&initial_outcome_messages[1] == &accept_string, EInvalidMessages);
    };
    assert!(
        vectors::check_valid_outcomes(initial_outcome_messages, MAX_RESULT_LENGTH),
        EInvalidOutcomeLengths,
    );

    assert!(title.length() <= TITLE_MAX_LENGTH, ETitleTooLong);
    assert!(title.length() > 0, ETitleTooShort);
    assert!(metadata.length() <= METADATA_MAX_LENGTH, EMetadataTooLong);

    let treasury_address = if (dao.treasury_account_id.is_some()) {
        object::id_to_address(dao.treasury_account_id.borrow())
    } else {
        // Use proposer as fallback treasury to avoid burning funds
        ctx.sender()
    };

    // Lightweight proposal creation, no market or escrow yet.
    let (proposal_id, market_state_id, state) = proposal::create<AssetType, StableType>(
        dao_fee_balance,
        dao.id.to_inner(),
        dao.review_period_ms,
        dao.trading_period_ms,
        dao.min_asset_amount,
        dao.min_stable_amount,
        title,
        metadata,
        initial_outcome_messages,
        initial_outcome_details,
        initial_outcome_asset_amounts,
        initial_outcome_stable_amounts,
        dao.amm_twap_start_delay,
        dao.amm_twap_initial_observation,
        dao.amm_twap_step_max,
        dao.twap_threshold,
        uses_dao_liquidity,
        treasury_address,
        clock,
        ctx,
    );

    let info = ProposalInfo {
        proposer: ctx.sender(),
        created_at: clock.timestamp_ms(),
        state,
        outcome_count,
        title: title,
        result: option::none(),
        execution_time: option::none(),
        executed: false,
        market_state_id,
    };

    assert!(!dao.proposals.contains(proposal_id), EProposalExists);
    dao.proposals.add(proposal_id, info);
    dao.active_proposal_count = dao.active_proposal_count + 1;
    dao.total_proposals = dao.total_proposals + 1;
    
    // Return proposal_id, market_state_id, and state
    (proposal_id, market_state_id, state)
}

public entry fun create_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut fee::FeeManager,
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
    // Call internal function and discard return values
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

/// Adds a new outcome to a proposal during its premarket phase.
public entry fun add_proposal_outcome<AssetType, StableType>(
    proposal: &mut proposal::Proposal<AssetType, StableType>,
    dao: &DAO<AssetType, StableType>,
    mut payment: Coin<StableType>, // Fee payment
    message: String,
    detail: String,
    asset_amount: u64,
    stable_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // 1. Proposal must be in the premarket period.
    assert!(proposal::state(proposal) == STATE_PREMARKET, EInvalidState);
    assert!(proposal::get_dao_id(proposal) == object::id(dao), EUnauthorized);

    // 2. Validate new outcome parameters.
    let outcome_count = proposal::outcome_count(proposal);
    assert!(outcome_count < dao.max_outcomes, EInvalidOutcomeCount);
    assert!(asset_amount >= dao.min_asset_amount, EInvalidAmount);
    assert!(stable_amount >= dao.min_stable_amount, EInvalidAmount);
    
    // 3. Validate message and detail lengths
    assert!(vectors::validate_outcome_message(&message, MAX_RESULT_LENGTH), EInvalidOutcomeLengths);
    assert!(vectors::validate_outcome_detail(&detail, DETAILS_MAX_LENGTH), EDetailsTooLong);
    
    // 4. Check for duplicate messages
    let outcome_messages = proposal::get_outcome_messages(proposal);
    assert!(!vectors::is_duplicate_message(outcome_messages, &message), EDuplicateMessage);

    // 5. Verify and process the mutation fee using the existing proposal fee parameter.
    let fee_amount = dao.proposal_fee_per_outcome;
    assert!(payment.value() >= fee_amount, EInvalidAmount);
    let fee_coin = payment.split(fee_amount, ctx);
    transfer::public_transfer(fee_coin, proposal::get_proposer(proposal)); // Transfer fee to original proposer
    transfer::public_transfer(payment, ctx.sender()); // Return any excess

    // 6. Add the outcome to the proposal object.
    proposal::add_outcome(
        proposal,
        message,
        detail,
        asset_amount,
        stable_amount,
        ctx.sender(),
        clock,
    );

    // No event here, proposal creation event covers initial, this is collaborative.
}

/// Allows a user to mutate the text content of a specific proposal outcome during the premarket period.
/// This makes them the "creator" of that outcome, eligible for the proposal fee rebate if it wins.
public entry fun mutate_proposal_outcome<AssetType, StableType>(
    proposal: &mut proposal::Proposal<AssetType, StableType>,
    dao: &DAO<AssetType, StableType>, // Added for fee access
    mut payment: Coin<StableType>, // Fee payment
    outcome_idx: u64,
    new_detail: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // 1. Proposal must be in the premarket period to be mutated.
    assert!(proposal::state(proposal) == STATE_PREMARKET, EInvalidState);
    assert!(outcome_idx < proposal::outcome_count(proposal), EInvalidOutcomeCount);
    assert!(new_detail.length() <= DETAILS_MAX_LENGTH, EDetailsTooLong);
    assert!(new_detail.length() > 0, EDetailsTooShort);

    // 2. The mutator must be different from the current creator of this outcome.
    let mutator = ctx.sender();
    let outcome_creators = proposal::get_outcome_creators(proposal);
    let old_creator = *vector::borrow(outcome_creators, outcome_idx);
    assert!(mutator != old_creator, EUnauthorized);

    // 3. Verify and process the mutation fee using the existing proposal fee parameter.
    let fee_amount = dao.proposal_fee_per_outcome;
    assert!(payment.value() >= fee_amount, EInvalidAmount);
    let fee_coin = payment.split(fee_amount, ctx);
    transfer::public_transfer(fee_coin, proposal::get_proposer(proposal)); // Transfer fee to original proposer
    transfer::public_transfer(payment, ctx.sender()); // Return any excess

    // 4. Mutate the detail and update the creator for that outcome.
    let details_mut = proposal::get_details_mut(proposal);
    let detail_ref = vector::borrow_mut(details_mut, outcome_idx);
    *detail_ref = new_detail;
    
    proposal::set_outcome_creator(proposal, outcome_idx, mutator);

    // 5. Emit an event to record the mutation.
    proposal::emit_outcome_mutated(
        proposal::get_id(proposal),
        proposal::get_dao_id(proposal),
        outcome_idx,
        old_creator,
        mutator,
        clock.timestamp_ms(),
    );
}

/// Called by the original proposer to provide liquidity and initialize the market.
/// This moves the proposal from PREMARKET to REVIEW state.
public entry fun initialize_market_and_provide_liquidity<AssetType, StableType>(
    proposal: &mut proposal::Proposal<AssetType, StableType>,
    dao: &DAO<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // 1. Must be in premarket state and called by the original proposer.
    assert!(proposal::state(proposal) == STATE_PREMARKET, EInvalidState);
    assert!(proposal::proposer(proposal) == ctx.sender(), EUnauthorized);

    let dao_id = object::id(dao);
    assert!(proposal::get_dao_id(proposal) == dao_id, EUnauthorized);

    // 2. Create the market infrastructure.
    let (
        outcome_count,
        outcome_messages,
        asset_amounts,
        stable_amounts
    ) = proposal::get_market_init_params(proposal);

    // 3. Calculate total required liquidity to validate coin amounts
    let mut total_asset_required = 0u64;
    let mut total_stable_required = 0u64;
    let mut i = 0;
    while (i < outcome_count) {
        total_asset_required = total_asset_required + asset_amounts[i];
        total_stable_required = total_stable_required + stable_amounts[i];
        i = i + 1;
    };
    
    // Validate that provided coins match current total requirements
    assert!(asset_coin.value() >= total_asset_required, EInvalidAmount);
    assert!(stable_coin.value() >= total_stable_required, EInvalidAmount);

    // Create MarketState.
    let market_state = market_state::new(
        proposal::get_id(proposal),
        dao_id,
        outcome_count,
        *outcome_messages,
        clock,
        ctx,
    );
    let market_state_id = object::id(&market_state);

    // Create TokenEscrow.
    let mut escrow = coin_escrow::new<AssetType, StableType>(market_state, ctx);
    let escrow_id = object::id(&escrow);

    // 4. Create AMMs and deposit liquidity into escrow.
    let (_supply_ids, amm_pools) = liquidity_initialize::create_outcome_markets(
        &mut escrow,
        outcome_count,
        *asset_amounts,
        *stable_amounts,
        proposal::get_twap_start_delay(proposal),
        proposal::get_twap_initial_observation(proposal),
        proposal::get_twap_step_max(proposal),
        asset_coin.into_balance(),
        stable_coin.into_balance(),
        clock,
        ctx,
    );

    // 5. Finalize the proposal's market fields and advance its state.
    proposal::initialize_market_fields(
        proposal,
        market_state_id,
        escrow_id,
        amm_pools,
        clock.timestamp_ms(),
        ctx.sender(), // Set the liquidity provider
    );

    // Share the newly created objects.
    transfer::public_share_object(escrow);

    // Emit an event indicating the market is now live for review.
    proposal::emit_market_initialized(
        proposal::get_id(proposal),
        dao_id,
        market_state_id,
        escrow_id,
        clock.timestamp_ms(),
    );
}

/// Initialize the market for a proposal using the DAO's liquidity pool.
public entry fun initialize_market_with_dao_liquidity<AssetType, StableType>(
    proposal: &mut proposal::Proposal<AssetType, StableType>,
    dao: &DAO<AssetType, StableType>,
    dao_pool: &mut DAOLiquidityPool<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // 1. Must be in premarket state, called by original proposer, and flagged for DAO liquidity.
    assert!(proposal::state(proposal) == STATE_PREMARKET, EInvalidState);
    assert!(proposal::proposer(proposal) == ctx.sender(), EUnauthorized);
    assert!(proposal::uses_dao_liquidity(proposal), EUnauthorized);
    let dao_id = object::id(dao);
    assert!(proposal::get_dao_id(proposal) == dao_id, EUnauthorized);
    assert!(dao_liquidity_pool::dao_id(dao_pool) == dao_id, EUnauthorized);

    // 2. Determine liquidity amounts from the pool's balance. Price is implicitly 50/50.
    let asset_balance = dao_liquidity_pool::asset_balance(dao_pool);
    let stable_balance = dao_liquidity_pool::stable_balance(dao_pool);
    assert!(asset_balance > 0 && stable_balance > 0, EInvalidAmount);
    let (outcome_count, outcome_messages, _, _) = proposal::get_market_init_params(proposal);
    let outcome_asset_amounts = vector::tabulate!(outcome_count, |_| asset_balance);
    let outcome_stable_amounts = vector::tabulate!(outcome_count, |_| stable_balance);

    // 3. Create MarketState and Escrow.
    let market_state = market_state::new(
        proposal::get_id(proposal), dao_id, outcome_count, *outcome_messages, clock, ctx
    );
    let market_state_id = object::id(&market_state);
    let mut escrow = coin_escrow::new<AssetType, StableType>(market_state, ctx);
    let escrow_id = object::id(&escrow);

    // 4. Withdraw the ENTIRE liquidity from DAO pool and initialize markets.
    // We use withdraw_all helpers to ensure the pool is completely drained.
    let asset_liquidity = dao_liquidity_pool::withdraw_all_asset_balance(dao_pool);
    let stable_liquidity = dao_liquidity_pool::withdraw_all_stable_balance(dao_pool);

    let (_supply_ids, amm_pools) = liquidity_initialize::create_outcome_markets(
        &mut escrow, outcome_count, outcome_asset_amounts, outcome_stable_amounts,
        proposal::get_twap_start_delay(proposal),
        proposal::get_twap_initial_observation(proposal),
        proposal::get_twap_step_max(proposal),
        asset_liquidity, stable_liquidity, clock, ctx
    );

    // 5. Finalize the proposal's market fields, setting the DAO as the LP.
    proposal::initialize_market_fields(
        proposal, market_state_id, escrow_id, amm_pools,
        clock.timestamp_ms(), object::id_address(dao)
    );

    // 6. Share escrow object.
    transfer::public_share_object(escrow);

    proposal::emit_market_initialized(
        proposal::get_id(proposal), dao_id, market_state_id, escrow_id, clock.timestamp_ms()
    );
}

/// Marks a proposal as completed and updates the DAO's active proposal count.
/// This must be called when a proposal is finalized to free up the slot.
public(package) fun mark_proposal_completed<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    proposal_id: ID,
    proposal: &proposal::Proposal<AssetType, StableType>,
) {
    // Update the proposal state in the DAO
    let info = &mut dao.proposals[proposal_id];
    info.state = proposal::state(proposal);
    
    // Decrement active proposal count
    assert!(dao.active_proposal_count > 0, EInvalidState);
    dao.active_proposal_count = dao.active_proposal_count - 1;
    
    // Update queue state
    priority_queue::mark_proposal_completed(&mut dao.proposal_queue, proposal::uses_dao_liquidity(proposal));
    
    // If this was a DAO-funded proposal, mark the slot as available
    if (proposal::uses_dao_liquidity(proposal)) {
        dao.dao_liquidity_in_use = false;
    };
}

/// Redeems liquidity for a proposer-funded proposal and marks it as complete.
/// Consumes the FinalizationReceipt to ensure atomicity.
public entry fun redeem_proposer_liquidity<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    proposal: &mut proposal::Proposal<AssetType, StableType>,
    escrow: &mut coin_escrow::TokenEscrow<AssetType, StableType>,
    receipt: FinalizationReceipt,
    ctx: &mut TxContext,
) {
    let (proposal_id, liquidity_provider, uses_dao_liquidity) = advance_stage::consume_finalization_receipt(receipt);
    
    assert!(proposal_id == proposal::get_id(proposal), EInvalidReceipt);
    assert!(!uses_dao_liquidity, EProposalUsesDaoLiquidity);

    liquidity_interact::empty_amm_and_return_to_provider(proposal, escrow, ctx);

    // This call is now guaranteed to happen after liquidity is returned.
    mark_proposal_completed(dao, proposal::get_id(proposal), proposal);
}

/// Redeems liquidity for a DAO-funded proposal and marks it as complete.
public entry fun redeem_dao_liquidity<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    dao_pool: &mut DAOLiquidityPool<AssetType, StableType>,
    proposal: &mut proposal::Proposal<AssetType, StableType>,
    escrow: &mut coin_escrow::TokenEscrow<AssetType, StableType>,
    receipt: FinalizationReceipt,
    ctx: &mut TxContext,
) {
    let (proposal_id, liquidity_provider, uses_dao_liquidity) = advance_stage::consume_finalization_receipt(receipt);
    
    assert!(proposal_id == proposal::get_id(proposal), EInvalidReceipt);
    assert!(uses_dao_liquidity, EProposalNotUsesDaoLiquidity);

    liquidity_interact::empty_amm_and_return_to_dao_pool(proposal, escrow, dao_pool, ctx);
    
    mark_proposal_completed(dao, proposal::get_id(proposal), proposal);
}

/// Permissionless function to evict a stale proposal from the queue.
public entry fun evict_stale_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut fee::FeeManager,
    proposal_fee_manager: &mut proposal_fee_manager::ProposalFeeManager,
    proposal_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // First verify the proposal is not already active
    assert!(!dao.proposals.contains(proposal_id), EProposalExists);
    
    let queue = &mut dao.proposal_queue;
    
    // Remove the stale proposal from the queue
    let mut proposal = priority_queue::remove_from_queue(queue, proposal_id);
    let proposer = priority_queue::get_proposer(&proposal);
    let evicted_by = ctx.sender();
    let timestamp = clock.timestamp_ms();
    
    // Check if proposal is stale (30 days old)
    assert!(timestamp > priority_queue::get_timestamp(&proposal) + STALE_DURATION_MS, EStaleProposal);
    
    // Emit proposal evicted event
    event::emit(ProposalEvicted {
        dao_id: dao.id.to_inner(),
        proposal_id,
        proposer,
        evicted_by,
        timestamp,
    });

    if (priority_queue::uses_dao_liquidity(&proposal)) {
        // Extract and slash the bond to the treasury
        let mut bond_opt = priority_queue::extract_bond(&mut proposal);
        if (bond_opt.is_some()) {
            let bond = bond_opt.extract();
            let bond_amount = bond.value();
            let recipient = if (dao.treasury_account_id.is_some()) {
                let treasury_address = object::id_to_address(dao.treasury_account_id.borrow());
                transfer::public_transfer(bond, treasury_address);
                treasury_address
            } else {
                // If no treasury, return bond to the proposer instead of burning
                let proposer_address = proposer;
                transfer::public_transfer(bond, proposer_address);
                proposer_address
            };
            
            // Emit bond slashed event
            event::emit(BondSlashed {
                dao_id: dao.id.to_inner(),
                proposal_id,
                proposer,
                amount: bond_amount,
                recipient,
                timestamp,
            });
        };
        bond_opt.destroy_none();
    };

    // Destroy the proposal (it has no drop ability)
    priority_queue::destroy_proposal(proposal);

    // The submission fee is always slashed to the protocol.
    proposal_fee_manager::slash_proposal_fee(proposal_fee_manager, proposal_id);
}

// === Package Functions ===
public(package) fun sign_result<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    proposal_id: ID,
    proposal: &proposal::Proposal<AssetType, StableType>,
    market_state: &market_state::MarketState,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert!(dao.proposals.contains(proposal_id), EProposalNotFound);

    let info = &mut dao.proposals[proposal_id];
    assert!(!info.executed, EAlreadyExecuted);

    assert!(object::id(market_state) == info.market_state_id, EUnauthorized);
    assert!(market_state.market_id() == proposal_id, EUnauthorized);
    assert!(market_state.dao_id() == dao.id.to_inner(), EUnauthorized);

    market_state.assert_market_finalized();

    let winning_outcome = market_state.get_winning_outcome();
    let message = market_state.get_outcome_message(winning_outcome);
    
    // Get the description for the winning outcome from the proposal
    let details = proposal::get_details(proposal);
    // If winning outcome is 0 (Reject), emit empty description since reject actions are 
    // contextual and advisory only, not binding
    let description = if (winning_outcome == 0) {
        b"".to_string()
    } else {
        details[winning_outcome]
    };

    info.result.fill(message);
    info.executed = true;
    info.execution_time = option::some(clock.timestamp_ms());

    // Safely reduce active_proposal_count
    if (dao.active_proposal_count > 0) {
        dao.active_proposal_count = dao.active_proposal_count - 1;
    };

    event::emit(ResultSigned {
        dao_id: dao.id.to_inner(),
        proposal_id,
        outcome: message,
        description: description,
        winning_outcome: winning_outcome,
        timestamp: clock.timestamp_ms(),
    });

    // IMPORTANT: Treasury action execution is intentionally separated from proposal resolution
    // This ensures:
    // 1. Type safety - each coin type can be executed separately
    // 2. Atomicity - proposal resolution succeeds even if treasury actions fail
    // 3. Flexibility - treasury actions can be retried if needed
    // 
    // To execute treasury actions after proposal resolution:
    // - For SUI actions: call treasury_actions::execute_actions_entry_sui
    // - For other coins: call treasury_actions::execute_actions_entry<CoinType>
    // - For all actions: call treasury_actions::execute_all_actions_auto
    //
    // The ActionRegistry tracks treasury execution status independently
}

public entry fun sign_result_entry<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    proposal_id: ID,
    proposal: &proposal::Proposal<AssetType, StableType>,
    escrow: &mut coin_escrow::TokenEscrow<AssetType, StableType>, // Use fully qualified path
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let escrow_market_state_id = escrow.get_market_state_id();
    let info = dao.get_proposal_info(proposal_id);
    assert!(escrow_market_state_id == info.market_state_id, EUnauthorized);

    let market_state = escrow.get_market_state_mut();
    sign_result(
        dao,
        proposal_id,
        proposal,
        market_state,
        clock,
        ctx,
    );
}

public(package) fun set_pending_verification<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, attestation_url: String) {
    dao.attestation_url = attestation_url;
    dao.verification_pending = true;
}

public(package) fun set_verification<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, attestation_url: String, verified: bool) {
    if (verified) {
        dao.attestation_url = attestation_url;
    } else {
        dao.attestation_url = b"".to_string();
    };

    dao.verification_pending = false;
    dao.verified = verified;
}

public fun is_verification_pending<AssetType, StableType>(dao: &DAO<AssetType, StableType>): bool {
    dao.verification_pending
}

public fun is_verified<AssetType, StableType>(dao: &DAO<AssetType, StableType>): bool { dao.verified }

public fun get_attestation_url<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &String { &dao.attestation_url }

// === View Functions ===
public fun get_amm_config<AssetType, StableType>(dao: &DAO<AssetType, StableType>): (u64, u64, u128) {
    (dao.amm_twap_start_delay, dao.amm_twap_step_max, dao.amm_twap_initial_observation)
}

public fun get_proposal_info<AssetType, StableType>(dao: &DAO<AssetType, StableType>, proposal_id: ID): &ProposalInfo {
    assert!(dao.proposals.contains(proposal_id), EProposalNotFound);
    &dao.proposals[proposal_id]
}

public fun get_result(info: &ProposalInfo): &Option<String> {
    &info.result
}

public fun has_result(info: &ProposalInfo): bool {
    info.result.is_some()
}

public fun get_stats<AssetType, StableType>(dao: &DAO<AssetType, StableType>): (u64, u64, u64) {
    (dao.active_proposal_count, dao.total_proposals, dao.creation_time)
}

public fun get_min_amounts<AssetType, StableType>(dao: &DAO<AssetType, StableType>): (u64, u64) {
    (dao.min_asset_amount, dao.min_stable_amount)
}

public fun is_executed(info: &ProposalInfo): bool {
    info.executed
}

public fun get_execution_time(info: &ProposalInfo): Option<u64> {
    info.execution_time
}

public fun get_proposer(info: &ProposalInfo): address {
    info.proposer
}

public fun get_created_at(info: &ProposalInfo): u64 {
    info.created_at
}

public fun get_title(info: &ProposalInfo): &String {
    &info.title
}

public fun get_asset_type<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &AsciiString {
    &dao.asset_type
}

public fun get_stable_type<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &AsciiString {
    &dao.stable_type
}

public fun get_types<AssetType, StableType>(dao: &DAO<AssetType, StableType>): (&AsciiString, &AsciiString) {
    (&dao.asset_type, &dao.stable_type)
}

public fun get_name<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &AsciiString {
    &dao.dao_name
}

public(package) fun disable_proposals<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>) {
    dao.proposal_creation_enabled = false;
}

public fun are_proposals_enabled<AssetType, StableType>(dao: &DAO<AssetType, StableType>): bool {
    dao.proposal_creation_enabled
}

/// Get market parameters for proposal creation
public fun get_market_params<AssetType, StableType>(dao: &DAO<AssetType, StableType>): (ID, u64, u64, u64, u64, u64, u128, u64, u64, address) {
    (
        object::id(dao),
        dao.review_period_ms,
        dao.trading_period_ms,
        dao.min_asset_amount,
        dao.min_stable_amount,
        dao.amm_twap_start_delay,
        dao.amm_twap_initial_observation,
        dao.amm_twap_step_max,
        dao.twap_threshold,
        if (dao.treasury_account_id.is_some()) {
            object::id_to_address(dao.treasury_account_id.borrow())
        } else {
            // Return a valid address instead of @0x0 to prevent fund loss
            // This should be the DAO's address as a fallback
            object::id_to_address(&dao.id.to_inner())
        }
    )
}

public fun get_max_outcomes<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 {
    dao.max_outcomes
}

/// Update the maximum number of concurrent proposals allowed
public(package) fun set_max_concurrent_proposals<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, max_concurrent: u64) {
    dao.max_concurrent_proposals = max_concurrent;
}

/// Update the maximum number of proposer-funded proposals in queue
public(package) fun set_max_proposer_funded_queue<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, max_queue: u64) {
    // This would require updating the priority queue's max capacity
    // For now, we'll store it in DAO for future use
    // In a real implementation, we'd need to update the queue structure
}

/// Get queue statistics
public fun get_queue_stats<AssetType, StableType>(dao: &DAO<AssetType, StableType>): (u64, u64, u64, bool) {
    priority_queue::get_stats(&dao.proposal_queue)
}

/// Update the required bond amount for DAO-funded proposals
/// This should only be called through DAO governance
public(package) fun set_required_bond_amount<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>, 
    new_bond_amount: u64
) {
    dao.required_bond_amount = new_bond_amount;
}

/// Get the current required bond amount
public fun get_required_bond_amount<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 {
    dao.required_bond_amount
}

public fun get_metadata<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &vector<String> {
    &dao.metadata
}

/// Returns the operating agreement ID if initialized
public fun get_operating_agreement_id<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &Option<ID> {
    &dao.operating_agreement_id
}

/// Checks if an operating agreement is initialized
public fun has_operating_agreement<AssetType, StableType>(dao: &DAO<AssetType, StableType>): bool {
    dao.operating_agreement_id.is_some()
}

// === Execution Context Functions ===

/// Creates a ProposalExecutionContext for authorized proposal execution
/// This can only be called by trusted modules that have verified the proposal has passed
public(package) fun create_proposal_execution_context<AssetType, StableType>(
    dao: &DAO<AssetType, StableType>,
    proposal_id: ID,
    winning_outcome: u64,
): ProposalExecutionContext {
    execution_context::new(
        proposal_id,
        winning_outcome,
        object::id(dao)
    )
}


// === Treasury Functions ===

/// Returns the treasury account ID if initialized
public fun get_treasury_id<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &Option<ID> {
    &dao.treasury_account_id
}

/// Checks if treasury is initialized
public fun has_treasury<AssetType, StableType>(dao: &DAO<AssetType, StableType>): bool {
    dao.treasury_account_id.is_some()
}

/// Sets the treasury ID (package-only, used by factory)
public(package) fun set_treasury_id<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, treasury_id: ID) {
    dao.treasury_account_id = option::some(treasury_id);
}

// === Configuration Update Functions ===

/// Update trading parameters after a config proposal passes
public(package) fun update_trading_params<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    min_asset_amount: Option<u64>,
    min_stable_amount: Option<u64>,
    review_period_ms: Option<u64>,
    trading_period_ms: Option<u64>,
) {
    // Update min asset amount if provided
    if (min_asset_amount.is_some()) {
        let new_amount = *min_asset_amount.borrow();
        assert!(new_amount > MIN_AMM_SAFE_AMOUNT, EInvalidMinAmounts);
        dao.min_asset_amount = new_amount;
    };
    
    // Update min stable amount if provided
    if (min_stable_amount.is_some()) {
        let new_amount = *min_stable_amount.borrow();
        assert!(new_amount > MIN_AMM_SAFE_AMOUNT, EInvalidMinAmounts);
        dao.min_stable_amount = new_amount;
    };
    
    // Update review period if provided
    if (review_period_ms.is_some()) {
        dao.review_period_ms = *review_period_ms.borrow();
    };
    
    // Update trading period if provided
    if (trading_period_ms.is_some()) {
        dao.trading_period_ms = *trading_period_ms.borrow();
    };
}

/// Update DAO metadata after a config proposal passes
public(package) fun update_metadata<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    dao_name: Option<AsciiString>,
    icon_url: Option<Url>,
    description: Option<String>,
) {
    // Update name if provided
    if (dao_name.is_some()) {
        dao.dao_name = *dao_name.borrow();
    };
    
    // Update icon URL if provided
    if (icon_url.is_some()) {
        dao.icon_url = *icon_url.borrow();
    };
    
    // Update description if provided
    if (description.is_some()) {
        let new_desc = *description.borrow();
        assert!(new_desc.length() <= DAO_DESCRIPTION_MAX_LENGTH, EDaoDescriptionTooLong);
        dao.description = new_desc;
    };
}

/// Update TWAP configuration after a config proposal passes
public(package) fun update_twap_config<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    start_delay: Option<u64>,
    step_max: Option<u64>,
    initial_observation: Option<u128>,
    threshold: Option<u64>,
) {
    // Update TWAP start delay if provided
    if (start_delay.is_some()) {
        let delay = *start_delay.borrow();
        assert!((delay % 60_000) == 0, EInvalidTwapDelay);
        dao.amm_twap_start_delay = delay;
    };
    
    // Update TWAP step max if provided
    if (step_max.is_some()) {
        dao.amm_twap_step_max = *step_max.borrow();
    };
    
    // Update TWAP initial observation if provided
    if (initial_observation.is_some()) {
        dao.amm_twap_initial_observation = *initial_observation.borrow();
    };
    
    // Update TWAP threshold if provided
    if (threshold.is_some()) {
        dao.twap_threshold = *threshold.borrow();
    };
}

/// Get the proposal fee per outcome
public fun get_proposal_fee_per_outcome<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 {
    dao.proposal_fee_per_outcome
}

public fun get_next_fee_due_timestamp<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 {
    dao.next_fee_due_timestamp
}

public(package) fun update_next_fee_due_timestamp<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, new_timestamp: u64) {
    dao.next_fee_due_timestamp = new_timestamp;
}

/// Collect monthly platform fee from DAO treasury
public entry fun collect_dao_platform_fee<AssetType, StableType: drop>(
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut fee::FeeManager,
    treasury: &mut futarchy::treasury::Treasury,
    admin_cap: &fee::FeeAdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Call the fee module function, passing DAO info
    let (new_timestamp, collection_successful) = fee::collect_dao_recurring_fee<StableType>(
        fee_manager,
        treasury,
        admin_cap,
        object::id(dao),
        &dao.stable_type,
        dao.next_fee_due_timestamp,
        clock,
        ctx,
    );
    
    if (collection_successful) {
        // Update the DAO's next fee due timestamp
        dao.next_fee_due_timestamp = new_timestamp;
        
        // Unpause proposal creation if it was paused
        if (!dao.proposal_creation_enabled) {
            dao.proposal_creation_enabled = true;
            event::emit(ProposalCreationUnpaused {
                dao_id: object::id(dao),
                timestamp: clock.timestamp_ms(),
            });
        }
    } else {
        // Pause proposal creation due to insufficient funds
        if (dao.proposal_creation_enabled) {
            dao.proposal_creation_enabled = false;
            event::emit(ProposalCreationPausedDueToUnpaidFees {
                dao_id: object::id(dao),
                timestamp: clock.timestamp_ms(),
                fee_due_timestamp: dao.next_fee_due_timestamp,
            });
        }
    }
}

/// Update governance settings after a config proposal passes
public(package) fun update_governance<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    proposal_creation_enabled: Option<bool>,
    max_outcomes: Option<u64>,
    proposal_fee_per_outcome: Option<u64>,
) {
    // Update proposal creation enabled flag if provided
    if (proposal_creation_enabled.is_some()) {
        dao.proposal_creation_enabled = *proposal_creation_enabled.borrow();
    };
    
    // Update max outcomes if provided
    if (max_outcomes.is_some()) {
        let max = *max_outcomes.borrow();
        assert!(max >= MIN_OUTCOMES && max <= MAX_OUTCOMES, EInvalidOutcomeCount);
        dao.max_outcomes = max;
    };
    
    // Update proposal fee per outcome if provided
    if (proposal_fee_per_outcome.is_some()) {
        dao.proposal_fee_per_outcome = *proposal_fee_per_outcome.borrow();
    };
}



// === Test Functions ===
#[test_only]
public fun test_set_proposal_state<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, proposal_id: ID, state: u8) {
    let info = &mut dao.proposals[proposal_id];
    info.state = state;
}

#[test_only]
public fun test_mark_proposal_executed<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, proposal_id: ID, winning_outcome: u64) {
    let info = &mut dao.proposals[proposal_id];
    info.state = 2; // RESOLVED
    info.result = option::some(if (winning_outcome == 0) { 
        b"Reject".to_string() 
    } else { 
        b"Accept".to_string() 
    });
    info.executed = true;
    
    // Safely reduce active_proposal_count
    if (dao.active_proposal_count > 0) {
        dao.active_proposal_count = dao.active_proposal_count - 1;
    };
}

#[test_only]
public fun add_proposal_for_testing<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    proposal_id: ID,
    outcome_count: u64,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
) {
    let info = ProposalInfo {
        proposer: ctx.sender(),
        created_at: clock.timestamp_ms(),
        state: 2, // RESOLVED
        outcome_count,
        title: b"Test Proposal".to_string(),
        result: option::some(b"1".to_string()), // Default to outcome 1
        execution_time: option::some(clock.timestamp_ms() + 3600000), // 1 hour from now
        executed: false,
        market_state_id: object::id_from_address(@0x0), // dummy market state
    };
    
    assert!(!dao.proposals.contains(proposal_id), EProposalExists);
    dao.proposals.add(proposal_id, info);
    dao.active_proposal_count = dao.active_proposal_count + 1;
    dao.total_proposals = dao.total_proposals + 1;
}
