module futarchy::dao;

use futarchy::coin_escrow;
use futarchy::fee;
use futarchy::market_state;
use futarchy::proposal;
use futarchy::vectors;
use futarchy::execution_context::{Self, ProposalExecutionContext};
use std::ascii::String as AsciiString;
use std::option;
use std::string::String;
use std::type_name;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use sui::table::{Self, Table};
use sui::url::{Self, Url};
use sui::balance::{Self, Balance};

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
const ENoneFullWindowTwapDelay: u64 = 20;
const EDaoDescriptionTooLong: u64 = 21;
const EInvalidDetailsLength: u64 = 22;

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

// === Structs ===

public struct DAO has key, store {
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
    next_fee_due_timestamp: u64,
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
): DAO {
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


    assert!((amm_twap_start_delay % 60_000) == 0, ENoneFullWindowTwapDelay);

    assert!(description.length() <= DAO_DESCRIPTION_MAX_LENGTH, EDaoDescriptionTooLong);
    
    // Validate max_outcomes is within reasonable bounds
    assert!(max_outcomes >= MIN_OUTCOMES && max_outcomes <= MAX_OUTCOMES, EInvalidOutcomeCount);

    let dao = DAO {
        id: object::new(ctx),
        asset_type: type_name::get<AssetType>().into_string(),
        stable_type: type_name::get<StableType>().into_string(),
        min_asset_amount,
        min_stable_amount,
        proposals: table::new(ctx),
        active_proposal_count: 0,
        total_proposals: 0,
        creation_time: timestamp,
        amm_twap_start_delay,
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
        next_fee_due_timestamp: timestamp + MONTHLY_FEE_PERIOD_MS,
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

/// Internal function that returns proposal ID and related IDs for action storage
public fun create_proposal_internal<AssetType, StableType>(
    dao: &mut DAO,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>,
    mut dao_fee_payment: Coin<StableType>,
    outcome_count: u64,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    title: String,
    details: vector<String>,
    metadata: String,
    outcome_messages: vector<String>,
    initial_outcome_amounts: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID, u8) {
    assert!(dao.proposal_creation_enabled, EProposalCreationDisabled);
    
    // Handle factory fee (in SUI)
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

    assert!(outcome_count >= MIN_OUTCOMES && outcome_count <= dao.max_outcomes, EInvalidOutcomeCount);
    let asset_amount = asset_coin.value();
    let stable_amount = stable_coin.value();
    assert!(asset_amount >= dao.min_asset_amount, EInvalidAmount);
    assert!(stable_amount >= dao.min_stable_amount, EInvalidAmount);
    assert!(outcome_messages.length() == outcome_count, EInvalidMessages);

    // Assert first outcome is "Reject"
    let reject_string = b"Reject".to_string();
    let first_message = &outcome_messages[0];
    assert!(first_message == &reject_string, EInvalidMessages);

    // For 2-outcome proposals, assert second outcome is "Accept"
    if (outcome_count == 2) {
        let accept_string = b"Accept".to_string();
        let second_message = &outcome_messages[1];
        assert!(second_message == &accept_string, EInvalidMessages);
    };
    assert!(
        vectors::check_valid_outcomes(outcome_messages, MAX_RESULT_LENGTH),
        EInvalidOutcomeLengths,
    );

    assert!(title.length() <= TITLE_MAX_LENGTH, ETitleTooLong);
    assert!(metadata.length() <= METADATA_MAX_LENGTH, EMetadataTooLong);
    assert!(vector::length(&details) == outcome_count, EInvalidDetailsLength);
    
    // Check each detail string length
    let mut i = 0;
    while (i < outcome_count) {
        let detail = &details[i];
        assert!(detail.length() <= DETAILS_MAX_LENGTH, EDetailsTooLong);
        assert!(detail.length() > 0, EDetailsTooShort);
        i = i + 1;
    };

    assert!(title.length() > 0, ETitleTooShort);

    assert!(outcome_count > 1, EOneOutcome);

    let initial_asset = asset_coin.into_balance();
    let initial_stable = stable_coin.into_balance();

    let treasury_address = if (dao.treasury_account_id.is_some()) {
        object::id_to_address(dao.treasury_account_id.borrow())
    } else {
        @0x0
    };

    let (proposal_id, market_state_id, state) = proposal::create<AssetType, StableType>(
        dao_fee_balance,
        dao.id.to_inner(),
        outcome_count,
        initial_asset,
        initial_stable,
        dao.review_period_ms,
        dao.trading_period_ms,
        dao.min_asset_amount,
        dao.min_stable_amount,
        title,
        details,
        metadata,
        outcome_messages,
        dao.amm_twap_start_delay,
        dao.amm_twap_initial_observation,
        dao.amm_twap_step_max,
        initial_outcome_amounts,
        dao.twap_threshold,
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
    dao: &mut DAO,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>,
    mut dao_fee_payment: Coin<StableType>,
    outcome_count: u64,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    title: String,
    details: vector<String>,
    metadata: String,
    outcome_messages: vector<String>,
    initial_outcome_amounts: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Call internal function and discard return values
    let (_proposal_id, _market_state_id, _state) = create_proposal_internal(
        dao,
        fee_manager,
        payment,
        dao_fee_payment,
        outcome_count,
        asset_coin,
        stable_coin,
        title,
        details,
        metadata,
        outcome_messages,
        initial_outcome_amounts,
        clock,
        ctx
    );
}

// === Package Functions ===
public(package) fun sign_result<AssetType, StableType>(
    dao: &mut DAO,
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
    dao: &mut DAO,
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

public(package) fun set_pending_verification(dao: &mut DAO, attestation_url: String) {
    dao.attestation_url = attestation_url;
    dao.verification_pending = true;
}

public(package) fun set_verification(dao: &mut DAO, attestation_url: String, verified: bool) {
    if (verified) {
        dao.attestation_url = attestation_url;
    } else {
        dao.attestation_url = b"".to_string();
    };

    dao.verification_pending = false;
    dao.verified = verified;
}

public fun is_verification_pending(dao: &DAO): bool {
    dao.verification_pending
}

public fun is_verified(dao: &DAO): bool { dao.verified }

public fun get_attestation_url(dao: &DAO): &String { &dao.attestation_url }

// === View Functions ===
public fun get_amm_config(dao: &DAO): (u64, u64, u128) {
    (dao.amm_twap_start_delay, dao.amm_twap_step_max, dao.amm_twap_initial_observation)
}

public fun get_proposal_info(dao: &DAO, proposal_id: ID): &ProposalInfo {
    assert!(dao.proposals.contains(proposal_id), EProposalNotFound);
    &dao.proposals[proposal_id]
}

public fun get_result(info: &ProposalInfo): &Option<String> {
    &info.result
}

public fun has_result(info: &ProposalInfo): bool {
    info.result.is_some()
}

public fun get_stats(dao: &DAO): (u64, u64, u64) {
    (dao.active_proposal_count, dao.total_proposals, dao.creation_time)
}

public fun get_min_amounts(dao: &DAO): (u64, u64) {
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

public fun get_asset_type(dao: &DAO): &AsciiString {
    &dao.asset_type
}

public fun get_stable_type(dao: &DAO): &AsciiString {
    &dao.stable_type
}

public fun get_types(dao: &DAO): (&AsciiString, &AsciiString) {
    (&dao.asset_type, &dao.stable_type)
}

public fun get_name(dao: &DAO): &AsciiString {
    &dao.dao_name
}

public(package) fun disable_proposals(dao: &mut DAO) {
    dao.proposal_creation_enabled = false;
}

public fun are_proposals_enabled(dao: &DAO): bool {
    dao.proposal_creation_enabled
}

public fun get_max_outcomes(dao: &DAO): u64 {
    dao.max_outcomes
}

public fun get_metadata(dao: &DAO): &vector<String> {
    &dao.metadata
}

// === Execution Context Functions ===

/// Creates a ProposalExecutionContext for authorized proposal execution
/// This can only be called by trusted modules that have verified the proposal has passed
public(package) fun create_proposal_execution_context(
    dao: &DAO,
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
public fun get_treasury_id(dao: &DAO): &Option<ID> {
    &dao.treasury_account_id
}

/// Checks if treasury is initialized
public fun has_treasury(dao: &DAO): bool {
    dao.treasury_account_id.is_some()
}

/// Sets the treasury ID (package-only, used by factory)
public(package) fun set_treasury_id(dao: &mut DAO, treasury_id: ID) {
    dao.treasury_account_id = option::some(treasury_id);
}

// === Configuration Update Functions ===

/// Update trading parameters after a config proposal passes
public(package) fun update_trading_params(
    dao: &mut DAO,
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
public(package) fun update_metadata(
    dao: &mut DAO,
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
public(package) fun update_twap_config(
    dao: &mut DAO,
    start_delay: Option<u64>,
    step_max: Option<u64>,
    initial_observation: Option<u128>,
    threshold: Option<u64>,
) {
    // Update TWAP start delay if provided
    if (start_delay.is_some()) {
        let delay = *start_delay.borrow();
        assert!((delay % 60_000) == 0, ENoneFullWindowTwapDelay);
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
public fun get_proposal_fee_per_outcome(dao: &DAO): u64 {
    dao.proposal_fee_per_outcome
}

public fun get_next_fee_due_timestamp(dao: &DAO): u64 {
    dao.next_fee_due_timestamp
}

public(package) fun update_next_fee_due_timestamp(dao: &mut DAO, new_timestamp: u64) {
    dao.next_fee_due_timestamp = new_timestamp;
}

/// Collect monthly platform fee from DAO treasury
public entry fun collect_dao_platform_fee<StableType: drop>(
    dao: &mut DAO,
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
public(package) fun update_governance(
    dao: &mut DAO,
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
public fun test_set_proposal_state(dao: &mut DAO, proposal_id: ID, state: u8) {
    let info = &mut dao.proposals[proposal_id];
    info.state = state;
}

#[test_only]
public fun test_mark_proposal_executed(dao: &mut DAO, proposal_id: ID, winning_outcome: u64) {
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
public fun add_proposal_for_testing(
    dao: &mut DAO,
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
