module futarchy::dao;

use futarchy::coin_escrow;
use futarchy::fee;
use futarchy::market_state;
use futarchy::proposal;
use futarchy::vectors;
use std::ascii::{Self, String as AsciiString};
use std::string::{Self, String};
use std::type_name;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use sui::table::{Self, Table};
use sui::url::{Self, Url};

// === Introduction ===
// This defines the DAO type

// === Errors ===

const EINVALID_AMOUNT: u64 = 0;
const EPROPOSAL_EXISTS: u64 = 1;
const EUNAUTHORIZED: u64 = 2;
const EINVALID_OUTCOME_COUNT: u64 = 3;
const EPROPOSAL_NOT_FOUND: u64 = 4;
const EINVALID_MIN_AMOUNTS: u64 = 5;
const EALREADY_EXECUTED: u64 = 6;
const EINVALID_MESSAGES: u64 = 7;
const EINVALID_ASSET_TYPE: u64 = 8;
const EINVALID_STABLE_TYPE: u64 = 9;
const E_DECIMALS_TOO_LARGE: u64 = 10;
const EPROPOSAL_CREATION_DISABLED: u64 = 11;
const EINVALID_OUTCOME_LENGTHS: u64 = 12;
const EINVALID_DECIMALS_DIFF: u64 = 13;
const EMETADATA_TOO_LONG: u64 = 14;
const EDETAILS_TOO_LONG: u64 = 15;
const ETITLE_TOO_SHORT: u64 = 16;
const ETITLE_TOO_LONG: u64 = 17;
const EDETAILS_TOO_SHORT: u64 = 18;
const EONE_OUTCOME: u64 = 19;
const E_NONE_FULL_WINDOW_TWAP_DELAY: u64 = 20;
const E_DAO_DESCRIPTION_TOO_LONG: u64 = 21;

// === Constants ===
const TITLE_MAX_LENGTH: u64 = 512;
const METADATA_MAX_LENGTH: u64 = 1024;
const DETAILS_MAX_LENGTH: u64 = 16384; // 16KB
const MIN_OUTCOMES: u64 = 2;
const MAX_OUTCOMES: u64 = 3;
const MAX_RESULT_LENGTH: u64 = 1024;
const MIN_AMM_SAFE_AMOUNT: u64 = 1000; // under 50 swap will have significant slippage
const MAX_DECIMALS: u8 = 21; // Common max for most token pairs
const DAO_DESCRIPTION_MAX_LENGTH: u64 = 1024;

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
    asset_decimals: u8,
    stable_decimals: u8,
    asset_name: String,
    stable_name: String,
    asset_icon_url: AsciiString,
    stable_icon_url: AsciiString,
    asset_symbol: AsciiString,
    stable_symbol: AsciiString,
    review_period_ms: u64,
    trading_period_ms: u64,
    attestation_url: String,
    verification_pending: bool,
    verified: bool,
    proposal_creation_enabled: bool,
    description: String,
}

public struct ProposalInfo has store {
    proposer: address,
    created_at: u64,
    state: u8,
    outcome_count: u64,
    description: String,
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
    asset_decimals: u8,
    stable_decimals: u8,
    asset_name: String,
    stable_name: String,
    asset_icon_url: AsciiString,
    stable_icon_url: AsciiString,
    asset_symbol: AsciiString,
    stable_symbol: AsciiString,
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
    winning_outcome: u64,
    timestamp: u64,
}

// === Creation Functions ===
public(package) fun create<AssetType, StableType>(
    min_asset_amount: u64,
    min_stable_amount: u64,
    dao_name: AsciiString,
    icon_url_string: AsciiString,
    review_period_ms: u64,
    trading_period_ms: u64,
    asset_decimals: u8,
    stable_decimals: u8,
    asset_name: String,
    stable_name: String,
    asset_icon_url: AsciiString,
    stable_icon_url: AsciiString,
    asset_symbol: AsciiString,
    stable_symbol: AsciiString,
    amm_twap_start_delay: u64,
    amm_twap_step_max: u64,
    amm_twap_initial_observation: u128,
    twap_threshold: u64,
    description: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(
        min_asset_amount > MIN_AMM_SAFE_AMOUNT && min_stable_amount > MIN_AMM_SAFE_AMOUNT,
        EINVALID_MIN_AMOUNTS,
    );
    // checks that both types are for coins, but still allows regulated coins
    let _test_coin_asset = coin::zero<AssetType>(ctx);
    let _test_coin_stable = coin::zero<StableType>(ctx);
    coin::destroy_zero(_test_coin_asset);
    coin::destroy_zero(_test_coin_stable);

    let icon_url = if (ascii::is_empty(&icon_url_string)) {
        url::new_unsafe(asset_icon_url)
    } else {
        url::new_unsafe(icon_url_string)
    };

    let timestamp = clock::timestamp_ms(clock);

    // there is a limit where a large coin decimals gap this might affect TWAP and AMM calculations so let's cap at 9 for now
    assert!(if (stable_decimals >= asset_decimals) {
        (stable_decimals - asset_decimals) <= 9
    } else {
        (asset_decimals - stable_decimals) <= 9
    }, EINVALID_DECIMALS_DIFF);

    assert!(stable_decimals <= MAX_DECIMALS, E_DECIMALS_TOO_LARGE);
    assert!(asset_decimals <= MAX_DECIMALS, E_DECIMALS_TOO_LARGE);

    assert!((amm_twap_start_delay % 60_000) == 0, E_NONE_FULL_WINDOW_TWAP_DELAY);

    assert!(description.length() <= DAO_DESCRIPTION_MAX_LENGTH, E_DAO_DESCRIPTION_TOO_LONG);

    let dao = DAO {
        id: object::new(ctx),
        asset_type: type_name::into_string(type_name::get<AssetType>()),
        stable_type: type_name::into_string(type_name::get<StableType>()),
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
        asset_decimals,
        stable_decimals,
        asset_name,
        stable_name,
        asset_icon_url,
        stable_icon_url,
        asset_symbol,
        stable_symbol,
        review_period_ms,
        trading_period_ms,
        attestation_url: string::utf8(b""),
        verification_pending: false,
        verified: false,
        proposal_creation_enabled: true,
        description: description,
    };

    event::emit(DAOCreated {
        dao_id: object::uid_to_inner(&dao.id),
        min_asset_amount,
        min_stable_amount,
        timestamp,
        asset_type: type_name::into_string(type_name::get<AssetType>()),
        stable_type: type_name::into_string(type_name::get<StableType>()),
        dao_name: dao_name,
        icon_url: icon_url,
        asset_decimals,
        stable_decimals,
        asset_name,
        stable_name,
        asset_icon_url,
        stable_icon_url,
        asset_symbol,
        stable_symbol,
        review_period_ms,
        trading_period_ms,
        amm_twap_start_delay,
        amm_twap_step_max,
        amm_twap_initial_observation,
        twap_threshold,
        description,
    });

    // Transfer objects
    transfer::public_share_object(dao)
}

// ======== Proposal Functions ========
public entry fun create_proposal<AssetType, StableType>(
    dao: &mut DAO,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>, // New fee payment parameter
    outcome_count: u64,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    title: String,
    details: String,
    metadata: String,
    outcome_messages: vector<String>,
    initial_outcome_amounts: Option<vector<u64>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(dao.proposal_creation_enabled, EPROPOSAL_CREATION_DISABLED);
    fee::deposit_proposal_creation_payment(fee_manager, payment, clock, ctx);

    let asset_type = type_name::into_string(type_name::get<AssetType>());
    let stable_type = type_name::into_string(type_name::get<StableType>());

    assert!(&asset_type == &dao.asset_type, EINVALID_ASSET_TYPE);
    assert!(&stable_type == &dao.stable_type, EINVALID_STABLE_TYPE);

    assert!(outcome_count >= MIN_OUTCOMES && outcome_count <= MAX_OUTCOMES, EINVALID_OUTCOME_COUNT);
    let asset_amount = coin::value(&asset_coin);
    let stable_amount = coin::value(&stable_coin);
    assert!(asset_amount >= dao.min_asset_amount, EINVALID_AMOUNT);
    assert!(stable_amount >= dao.min_stable_amount, EINVALID_AMOUNT);
    assert!(vector::length(&outcome_messages) == outcome_count, EINVALID_MESSAGES);

    // Assert first outcome is "Reject"
    let reject_string = string::utf8(b"Reject");
    let first_message = vector::borrow(&outcome_messages, 0);
    assert!(first_message == &reject_string, EINVALID_MESSAGES);

    // For 2-outcome proposals, assert second outcome is "Accept"
    if (outcome_count == 2) {
        let accept_string = string::utf8(b"Accept");
        let second_message = vector::borrow(&outcome_messages, 1);
        assert!(second_message == &accept_string, EINVALID_MESSAGES);
    };
    assert!(
        vectors::check_valid_outcomes(outcome_messages, MAX_RESULT_LENGTH),
        EINVALID_OUTCOME_LENGTHS,
    );

    assert!(title.length() <= TITLE_MAX_LENGTH, ETITLE_TOO_LONG);
    assert!(metadata.length() <= METADATA_MAX_LENGTH, EMETADATA_TOO_LONG);
    assert!(details.length() <= DETAILS_MAX_LENGTH, EDETAILS_TOO_LONG);

    assert!(title.length() > 0, ETITLE_TOO_SHORT);
    assert!(details.length() > 0, EDETAILS_TOO_SHORT);

    // Existing validations
    assert!(outcome_count > 1, EONE_OUTCOME);

    let initial_asset = coin::into_balance(asset_coin);
    let initial_stable = coin::into_balance(stable_coin);

    let (proposal_id, market_state_id, state) = proposal::create<AssetType, StableType>(
        object::uid_to_inner(&dao.id),
        outcome_count,
        initial_asset,
        initial_stable,
        dao.review_period_ms,
        dao.trading_period_ms,
        dao.min_asset_amount,
        dao.min_stable_amount,
        title, // Changed from description
        details, // Added new field
        metadata,
        outcome_messages,
        dao.amm_twap_start_delay,
        dao.amm_twap_initial_observation,
        dao.amm_twap_step_max,
        initial_outcome_amounts,
        dao.twap_threshold,
        clock,
        ctx,
    );

    let info = ProposalInfo {
        proposer: tx_context::sender(ctx),
        created_at: clock::timestamp_ms(clock),
        state,
        outcome_count,
        description: title, // Changed to use title instead of description
        result: option::none(),
        execution_time: option::none(),
        executed: false,
        market_state_id,
    };

    assert!(!table::contains(&dao.proposals, proposal_id), EPROPOSAL_EXISTS);
    table::add(&mut dao.proposals, proposal_id, info);
    dao.active_proposal_count = dao.active_proposal_count + 1;
    dao.total_proposals = dao.total_proposals + 1;
}

// ======== Result Signing ========
public(package) fun sign_result(
    dao: &mut DAO,
    proposal_id: ID,
    market_state: &market_state::MarketState,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert!(table::contains(&dao.proposals, proposal_id), EPROPOSAL_NOT_FOUND);

    let info = table::borrow_mut(&mut dao.proposals, proposal_id);
    assert!(!info.executed, EALREADY_EXECUTED);

    assert!(object::id(market_state) == info.market_state_id, EUNAUTHORIZED);
    assert!(market_state::market_id(market_state) == proposal_id, EUNAUTHORIZED);
    assert!(market_state::dao_id(market_state) == object::uid_to_inner(&dao.id), EUNAUTHORIZED);

    market_state::assert_market_finalized(market_state);

    let winning_outcome = market_state::get_winning_outcome(market_state);
    let message = market_state::get_outcome_message(market_state, winning_outcome);

    option::fill(&mut info.result, message);
    info.executed = true;
    info.execution_time = option::some(clock::timestamp_ms(clock));

    // Safely reduce active_proposal_count
    if (dao.active_proposal_count > 0) {
        dao.active_proposal_count = dao.active_proposal_count - 1;
    };

    event::emit(ResultSigned {
        dao_id: object::uid_to_inner(&dao.id),
        proposal_id,
        outcome: message,
        winning_outcome: winning_outcome,
        timestamp: clock::timestamp_ms(clock),
    });
}

public entry fun sign_result_entry<AssetType, StableType>(
    dao: &mut DAO,
    proposal_id: ID,
    escrow: &mut coin_escrow::TokenEscrow<AssetType, StableType>, // Use fully qualified path
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let escrow_market_state_id = coin_escrow::get_market_state_id(escrow);
    let info = get_proposal_info(dao, proposal_id);
    assert!(escrow_market_state_id == info.market_state_id, EUNAUTHORIZED);

    let market_state = coin_escrow::get_market_state_mut(escrow);
    sign_result(
        dao,
        proposal_id,
        market_state,
        clock,
        ctx,
    );
}

// ======== Admin Functions ========
public(package) fun set_pending_verification(dao: &mut DAO, attestation_url: String) {
    dao.attestation_url = attestation_url;
    dao.verification_pending = true;
}

public(package) fun set_verification(dao: &mut DAO, attestation_url: String, verified: bool) {
    if (verified) {
        dao.attestation_url = attestation_url;
    } else {
        dao.attestation_url = string::utf8(b""); // Empty string in Move
    };

    dao.verification_pending = false;
    dao.verified = verified;
}

public fun is_verification_pending(dao: &DAO): bool {
    dao.verification_pending
}

public fun is_verified(dao: &DAO): bool { dao.verified }

public fun get_attestation_url(dao: &DAO): &String { &dao.attestation_url }

// === Getters ===
public fun get_amm_config(dao: &DAO): (u64, u64, u128) {
    (dao.amm_twap_start_delay, dao.amm_twap_step_max, dao.amm_twap_initial_observation)
}

public fun get_proposal_info(dao: &DAO, proposal_id: ID): &ProposalInfo {
    assert!(table::contains(&dao.proposals, proposal_id), EPROPOSAL_NOT_FOUND);
    table::borrow(&dao.proposals, proposal_id)
}

public fun get_result(info: &ProposalInfo): &Option<String> {
    &info.result
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

public fun get_description(info: &ProposalInfo): &String {
    &info.description
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

// === Test Functions ===
#[test_only]
// Test helper function to set proposal state directly
public fun test_set_proposal_state(dao: &mut DAO, proposal_id: ID, state: u8) {
    let info = table::borrow_mut(&mut dao.proposals, proposal_id);
    info.state = state;
}
