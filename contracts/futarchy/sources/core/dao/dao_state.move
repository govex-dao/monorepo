/// Pure state module for DAO data structures
/// Contains only data definitions and basic accessors/mutators
module futarchy::dao_state;

use std::string::String;
use std::ascii::String as AsciiString;
use std::type_name;
use sui::table::{Self, Table};
use sui::url::{Self, Url};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::clock::Clock;
use sui::event;

// === Constants ===
const DAO_STATE_ACTIVE: u8 = 0;
const DAO_STATE_DISSOLVING: u8 = 1;
const DAO_STATE_PAUSED: u8 = 2; // For general purpose pausing

// === Structs ===

/// Core DAO state object
public struct DAO<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    // Type information
    asset_type: String,
    stable_type: String,
    
    // Trading parameters
    min_asset_amount: u64,
    min_stable_amount: u64,
    review_period_ms: u64,
    trading_period_ms: u64,
    
    // AMM configuration
    amm_twap_start_delay: u64,
    amm_twap_step_max: u64,
    amm_twap_initial_observation: u128,
    twap_threshold: u64,
    amm_total_fee_bps: u64,
    
    // Metadata
    dao_name: AsciiString,
    icon_url: Url,
    description: String,
    metadata: Table<String, String>,
    
    // Governance parameters
    max_outcomes: u64,
    proposal_fee_per_outcome: u64,
    operational_state: u8,
    max_concurrent_proposals: u64,
    required_bond_amount: u64,
    
    // State tracking
    proposals: Table<ID, ProposalInfo>,
    active_proposals: u64,
    total_proposals: u64,
    
    // References to other objects
    liquidity_pool_id: Option<ID>,
    treasury_id: Option<ID>,
    treasury_cap: Option<TreasuryCap<AssetType>>,
    operating_agreement_id: Option<ID>,
    
    // Queue management (deprecated - using priority_queue module now)
    queue_size: u64,
    queue_head: Option<ID>,
    queue_tail: Option<ID>,
    fee_escalation_basis_points: u64,
    
    // Proposal queue ID
    proposal_queue_id: Option<ID>,
    
    // Action registry ID for unified action system
    action_registry_id: Option<ID>,
    
    // Verification
    attestation_url: String,
    verification_pending: bool,
    verified: bool,
}

/// Information about a proposal
public struct ProposalInfo has store {
    proposer: address,
    created_at: u64,
    state: u8,
    outcome_count: u64,
    title: String,
    result: Option<String>,
    executed: bool,
    execution_time: Option<u64>,
    market_state_id: ID,
    execution_deadline: Option<u64>,
}

/// Events
public struct DAOCreated has copy, drop {
    dao_id: ID,
    dao_name: AsciiString,
    asset_type: String,
    stable_type: String,
    creator: address,
}

// === Basic Accessors ===

// Type information
public fun asset_type<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &String { &dao.asset_type }
public fun stable_type<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &String { &dao.stable_type }

// Trading parameters
public fun min_asset_amount<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 { dao.min_asset_amount }
public fun min_stable_amount<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 { dao.min_stable_amount }
public fun review_period_ms<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 { dao.review_period_ms }
public fun trading_period_ms<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 { dao.trading_period_ms }

// AMM configuration
public fun amm_twap_start_delay<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 { dao.amm_twap_start_delay }
public fun amm_twap_step_max<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 { dao.amm_twap_step_max }
public fun amm_twap_initial_observation<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u128 { dao.amm_twap_initial_observation }
public fun twap_threshold<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 { dao.twap_threshold }
public fun amm_total_fee_bps<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 { dao.amm_total_fee_bps }

// Metadata
public fun dao_name<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &AsciiString { &dao.dao_name }
public fun icon_url<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &Url { &dao.icon_url }
public fun description<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &String { &dao.description }
public fun metadata<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &Table<String, String> { &dao.metadata }

// Governance parameters
public fun max_outcomes<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 { dao.max_outcomes }
public fun proposal_fee_per_outcome<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 { dao.proposal_fee_per_outcome }
public fun operational_state<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u8 { dao.operational_state }
public fun max_concurrent_proposals<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 { dao.max_concurrent_proposals }
public fun required_bond_amount<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 { dao.required_bond_amount }

// State tracking
public fun proposals<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &Table<ID, ProposalInfo> { &dao.proposals }
public fun active_proposals<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 { dao.active_proposals }
public fun total_proposals<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 { dao.total_proposals }

// References
public fun liquidity_pool_id<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &Option<ID> { &dao.liquidity_pool_id }
public fun treasury_id<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &Option<ID> { &dao.treasury_id }
public fun treasury_cap<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &Option<TreasuryCap<AssetType>> { &dao.treasury_cap }
public fun operating_agreement_id<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &Option<ID> { &dao.operating_agreement_id }

// Queue management
public fun queue_size<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 { dao.queue_size }
public fun queue_head<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &Option<ID> { &dao.queue_head }
public fun queue_tail<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &Option<ID> { &dao.queue_tail }
public fun fee_escalation_basis_points<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 { dao.fee_escalation_basis_points }
public fun proposal_queue_id<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &Option<ID> { &dao.proposal_queue_id }
public fun action_registry_id<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &Option<ID> { &dao.action_registry_id }

// Verification
public fun attestation_url<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &String { &dao.attestation_url }
public fun verification_pending<AssetType, StableType>(dao: &DAO<AssetType, StableType>): bool { dao.verification_pending }
public fun verified<AssetType, StableType>(dao: &DAO<AssetType, StableType>): bool { dao.verified }

// State constants
public fun state_active(): u8 { DAO_STATE_ACTIVE }
public fun state_dissolving(): u8 { DAO_STATE_DISSOLVING }
public fun state_paused(): u8 { DAO_STATE_PAUSED }

// === Package-Level Mutators ===

// Only expose mutators that other modules legitimately need
public(package) fun set_min_asset_amount<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, amount: u64) {
    dao.min_asset_amount = amount;
}

public(package) fun set_min_stable_amount<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, amount: u64) {
    dao.min_stable_amount = amount;
}

public(package) fun set_operational_state<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, new_state: u8) {
    dao.operational_state = new_state;
}

public(package) fun set_liquidity_pool_id<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, id: Option<ID>) {
    dao.liquidity_pool_id = id;
}

public(package) fun set_operating_agreement_id<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, id: Option<ID>) {
    dao.operating_agreement_id = id;
}

public(package) fun set_proposal_queue_id<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, id: Option<ID>) {
    dao.proposal_queue_id = id;
}

public(package) fun set_action_registry_id<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, id: Option<ID>) {
    dao.action_registry_id = id;
}

public(package) fun proposals_mut<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>): &mut Table<ID, ProposalInfo> {
    &mut dao.proposals
}

public(package) fun metadata_mut<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>): &mut Table<String, String> {
    &mut dao.metadata
}

public(package) fun increment_active_proposals<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>) {
    dao.active_proposals = dao.active_proposals + 1;
}

public(package) fun decrement_active_proposals<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>) {
    dao.active_proposals = dao.active_proposals - 1;
}

public(package) fun increment_total_proposals<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>) {
    dao.total_proposals = dao.total_proposals + 1;
}

public(package) fun set_required_bond_amount<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, amount: u64) {
    dao.required_bond_amount = amount;
}

public(package) fun set_review_period_ms<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, period: u64) {
    dao.review_period_ms = period;
}

public(package) fun set_trading_period_ms<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, period: u64) {
    dao.trading_period_ms = period;
}

public(package) fun set_dao_name<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, name: AsciiString) {
    dao.dao_name = name;
}

public(package) fun set_icon_url<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, url: Url) {
    dao.icon_url = url;
}

public(package) fun set_description<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, desc: String) {
    dao.description = desc;
}

public(package) fun set_amm_twap_start_delay<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, delay: u64) {
    dao.amm_twap_start_delay = delay;
}

public(package) fun set_amm_twap_step_max<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, max: u64) {
    dao.amm_twap_step_max = max;
}

public(package) fun set_amm_twap_initial_observation<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, obs: u128) {
    dao.amm_twap_initial_observation = obs;
}

public(package) fun set_twap_threshold<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, threshold: u64) {
    dao.twap_threshold = threshold;
}

public(package) fun set_proposal_creation_enabled<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, enabled: bool) {
    abort 999 // E_NOT_IMPLEMENTED
}

public(package) fun set_amm_total_fee_bps<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, fee_bps: u64) {
    dao.amm_total_fee_bps = fee_bps;
}

public(package) fun set_max_outcomes<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, max: u64) {
    dao.max_outcomes = max;
}

public(package) fun set_proposal_fee_per_outcome<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, fee: u64) {
    dao.proposal_fee_per_outcome = fee;
}

public(package) fun set_max_concurrent_proposals<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, max: u64) {
    dao.max_concurrent_proposals = max;
}

public(package) fun set_attestation_url<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, url: String) {
    dao.attestation_url = url;
}

public(package) fun set_verification_pending<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, pending: bool) {
    dao.verification_pending = pending;
}

public(package) fun set_verified<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, verified: bool) {
    dao.verified = verified;
}

public(package) fun set_queue_head<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, head: Option<ID>) {
    dao.queue_head = head;
}

public(package) fun set_queue_tail<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>, tail: Option<ID>) {
    dao.queue_tail = tail;
}

public(package) fun increment_queue_size<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>) {
    dao.queue_size = dao.queue_size + 1;
}

public(package) fun decrement_queue_size<AssetType, StableType>(dao: &mut DAO<AssetType, StableType>) {
    dao.queue_size = dao.queue_size - 1;
}

public(package) fun set_proposal_info_state(info: &mut ProposalInfo, state: u8) {
    info.state = state;
}

public(package) fun set_proposal_info_result(info: &mut ProposalInfo, result: String) {
    info.result = option::some(result);
}

public(package) fun set_proposal_info_execution_deadline(info: &mut ProposalInfo, deadline: u64) {
    info.execution_deadline = option::some(deadline);
}

public(package) fun set_proposal_info_executed(info: &mut ProposalInfo, executed: bool) {
    info.executed = executed;
}

public(package) fun set_proposal_info_execution_time(info: &mut ProposalInfo, time: u64) {
    info.execution_time = option::some(time);
}

// Safe treasury cap operations - never extract the cap
public(package) fun mint_with_treasury_cap<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    amount: u64,
    ctx: &mut TxContext
): Coin<AssetType> {
    assert!(dao.treasury_cap.is_some(), 0); // ENoTreasuryCap
    let treasury_cap = dao.treasury_cap.borrow_mut();
    coin::mint(treasury_cap, amount, ctx)
}

public(package) fun burn_with_treasury_cap<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    coin_to_burn: Coin<AssetType>
) {
    assert!(dao.treasury_cap.is_some(), 0); // ENoTreasuryCap
    let treasury_cap = dao.treasury_cap.borrow_mut();
    coin::burn(treasury_cap, coin_to_burn);
}

public(package) fun total_supply_with_treasury_cap<AssetType, StableType>(
    dao: &DAO<AssetType, StableType>
): u64 {
    assert!(dao.treasury_cap.is_some(), 0); // ENoTreasuryCap
    let treasury_cap = dao.treasury_cap.borrow();
    coin::total_supply(treasury_cap)
}

// === ProposalInfo Accessors ===

public fun proposal_info_proposer(info: &ProposalInfo): address { info.proposer }
public fun proposal_info_created_at(info: &ProposalInfo): u64 { info.created_at }
public fun proposal_info_state(info: &ProposalInfo): u8 { info.state }
public fun proposal_info_outcome_count(info: &ProposalInfo): u64 { info.outcome_count }
public fun proposal_info_title(info: &ProposalInfo): &String { &info.title }
public fun proposal_info_result(info: &ProposalInfo): &Option<String> { &info.result }
public fun proposal_info_executed(info: &ProposalInfo): bool { info.executed }
public fun proposal_info_execution_time(info: &ProposalInfo): &Option<u64> { &info.execution_time }
public fun proposal_info_market_state_id(info: &ProposalInfo): ID { info.market_state_id }
public fun proposal_info_execution_deadline(info: &ProposalInfo): &Option<u64> { &info.execution_deadline }

// === DAO Creation ===

/// Creates a new DAO with all parameters
public(package) fun create<AssetType: drop, StableType>(
    min_asset_amount: u64,
    min_stable_amount: u64,
    dao_name: AsciiString,
    icon_url: Url,
    review_period_ms: u64,
    trading_period_ms: u64,
    amm_twap_start_delay: u64,
    amm_twap_step_max: u64,
    amm_twap_initial_observation: u128,
    twap_threshold: u64,
    amm_total_fee_bps: u64,
    description: String,
    max_outcomes: u64,
    treasury_cap: Option<TreasuryCap<AssetType>>,
    clock: &Clock,
    ctx: &mut TxContext,
): DAO<AssetType, StableType> {
    let dao = DAO {
        id: object::new(ctx),
        asset_type: type_name::get<AssetType>().into_string().to_string(),
        stable_type: type_name::get<StableType>().into_string().to_string(),
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
        amm_twap_start_delay,
        amm_twap_step_max,
        amm_twap_initial_observation,
        twap_threshold,
        amm_total_fee_bps,
        dao_name,
        icon_url,
        description,
        metadata: table::new(ctx),
        max_outcomes,
        proposal_fee_per_outcome: 0,
        operational_state: DAO_STATE_ACTIVE,
        max_concurrent_proposals: 50,
        required_bond_amount: 100_000_000, // 100 USDC default
        proposals: table::new(ctx),
        active_proposals: 0,
        total_proposals: 0,
        liquidity_pool_id: option::none(),
        treasury_id: option::none(),
        treasury_cap,
        operating_agreement_id: option::none(),
        queue_size: 0,
        queue_head: option::none(),
        queue_tail: option::none(),
        fee_escalation_basis_points: 100, // 1% default
        proposal_queue_id: option::none(),
        action_registry_id: option::none(),
        attestation_url: b"".to_string(),
        verification_pending: false,
        verified: false,
    };

    event::emit(DAOCreated {
        dao_id: object::id(&dao),
        dao_name,
        asset_type: dao.asset_type,
        stable_type: dao.stable_type,
        creator: ctx.sender(),
    });

    dao
}

// === ProposalInfo Creation ===

public(package) fun new_proposal_info(
    proposer: address,
    created_at: u64,
    state: u8,
    outcome_count: u64,
    title: String,
    market_state_id: ID,
): ProposalInfo {
    ProposalInfo {
        proposer,
        created_at,
        state,
        outcome_count,
        title,
        result: option::none(),
        executed: false,
        execution_time: option::none(),
        market_state_id,
        execution_deadline: option::none(),
    }
}