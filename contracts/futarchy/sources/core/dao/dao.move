/// Main DAO module - serves as the public interface to DAO functionality
/// Delegates to specialized modules for actual implementation
module futarchy::dao;

// Import the three core modules
use futarchy::dao_state::{Self, DAO, ProposalInfo};
use futarchy::dao_governance::{Self};
use futarchy::dao_management::{Self};
use futarchy::dao_liquidity_pool::{DAOLiquidityPool};
use futarchy::fee::{FeeManager};
use futarchy::proposal_fee_manager::{ProposalFeeManager};
use futarchy::proposal::{Proposal};
use futarchy::coin_escrow::{TokenEscrow};
use futarchy::treasury::{Treasury};
use futarchy::execution_context::{Self, ProposalExecutionContext};
use futarchy::priority_queue::{ProposalQueue};
use std::string::String;
use std::ascii::String as AsciiString;
use sui::clock::Clock;
use sui::coin::{Coin, TreasuryCap};
use sui::sui::SUI;
use sui::url::Url;

// === Creation ===

/// Creates a new DAO
public(package) fun create<AssetType: drop, StableType>(
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
    amm_total_fee_bps: u64,
    description: String,
    max_outcomes: u64,
    treasury_cap: Option<TreasuryCap<AssetType>>,
    clock: &Clock,
    ctx: &mut TxContext,
): DAO<AssetType, StableType> {
    let icon_url = sui::url::new_unsafe(icon_url_string);
    dao_state::create(
        min_asset_amount,
        min_stable_amount,
        dao_name,
        icon_url,
        review_period_ms,
        trading_period_ms,
        amm_twap_start_delay,
        amm_twap_step_max,
        amm_twap_initial_observation,
        twap_threshold,
        amm_total_fee_bps,
        description,
        max_outcomes,
        treasury_cap,
        clock,
        ctx
    )
}

// === Proposal Lifecycle (Governance) ===

/// Submit a proposal to the queue
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
    dao_governance::submit_to_queue(
        dao, queue, fee_manager, proposal_fee_manager, payment, fee_coin,
        uses_dao_liquidity, bond, title, metadata,
        initial_outcome_messages, initial_outcome_details,
        initial_outcome_asset_amounts, initial_outcome_stable_amounts,
        clock, ctx
    )
}

/// Create a proposal directly (no queue)
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
    dao_governance::create_proposal(
        dao, fee_manager, payment, dao_fee_payment,
        title, metadata, initial_outcome_messages, initial_outcome_details,
        initial_outcome_asset_amounts, initial_outcome_stable_amounts,
        clock, ctx
    )
}

/// Create a proposal with DAO liquidity
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
    dao_governance::create_proposal_with_dao_liquidity(
        dao, fee_manager, payment, dao_fee_payment,
        title, metadata, initial_outcome_messages, initial_outcome_details,
        clock, ctx
    )
}

/// Activate next proposer-funded proposal from queue
public entry fun activate_next_proposer_funded_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    queue: &mut ProposalQueue<StableType>,
    fee_manager: &mut FeeManager,
    proposal_fee_manager: &mut ProposalFeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    dao_governance::activate_next_proposer_funded_proposal(
        dao, queue, fee_manager, proposal_fee_manager,
        clock, ctx
    )
}

/// Activate next DAO-funded proposal from queue
public entry fun activate_next_dao_funded_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    queue: &mut ProposalQueue<StableType>,
    pool: &mut DAOLiquidityPool<AssetType, StableType>,
    fee_manager: &mut FeeManager,
    proposal_fee_manager: &mut ProposalFeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    dao_governance::activate_next_dao_funded_proposal(
        dao, queue, pool, fee_manager, proposal_fee_manager, clock, ctx
    )
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
    dao_governance::evict_stale_proposal(
        dao, queue, proposal_fee_manager, proposal_id, clock, ctx
    )
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
    dao_governance::update_proposal_fee(
        dao, queue, proposal_fee_manager, proposal_id,
        fee_top_up, clock, ctx
    )
}

/// Fund a PREMARKET proposal to initialize its market
public entry fun fund_proposal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    proposal: &mut Proposal<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    dao_governance::fund_proposal(
        dao, proposal, asset_coin, stable_coin, clock, ctx
    )
}

/// Add an outcome to a proposal
public entry fun add_proposal_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    dao: &DAO<AssetType, StableType>,
    payment: Coin<StableType>,
    message: String,
    detail: String,
    asset_amount: u64,
    stable_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    dao_governance::add_proposal_outcome(
        proposal, dao, payment, message, detail,
        asset_amount, stable_amount, clock, ctx
    )
}

/// Mutate an outcome detail
public entry fun mutate_proposal_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    dao: &DAO<AssetType, StableType>,
    payment: Coin<StableType>,
    outcome_idx: u64,
    new_detail: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    dao_governance::mutate_proposal_outcome(
        proposal, dao, payment, outcome_idx, new_detail, clock, ctx
    )
}

/// Sign the result of a finalized proposal
public entry fun sign_result_entry<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    proposal_id: ID,
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    dao_governance::sign_result_entry(
        dao, proposal_id, proposal, escrow, clock, ctx
    )
}

// === Package Functions for Proposal System ===

/// Create proposal (internal version that returns IDs)
public(package) fun create_proposal_internal<AssetType, StableType>(
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
    uses_dao_liquidity: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID, u8) {
    dao_governance::create_proposal_internal(
        dao, fee_manager, payment, dao_fee_payment,
        title, metadata, initial_outcome_messages, initial_outcome_details,
        initial_outcome_asset_amounts, initial_outcome_stable_amounts,
        uses_dao_liquidity, clock, ctx
    )
}

/// Check if execution is allowed
public fun is_execution_allowed<AssetType, StableType>(
    dao: &DAO<AssetType, StableType>,
    proposal_id: ID,
    clock: &Clock,
): bool {
    dao_governance::is_execution_allowed(dao, proposal_id, clock)
}

/// Create execution context
public fun create_execution_context<AssetType, StableType>(
    dao: &DAO<AssetType, StableType>,
    proposal_id: ID,
    winning_outcome: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ProposalExecutionContext {
    dao_governance::create_execution_context(dao, proposal_id, winning_outcome, clock, ctx)
}

/// Create proposal execution context (alternate name for compatibility)
public(package) fun create_proposal_execution_context<AssetType, StableType>(
    dao: &DAO<AssetType, StableType>,
    proposal_id: ID,
    winning_outcome: u64,
    ctx: &mut TxContext,
): ProposalExecutionContext {
    execution_context::new(proposal_id, object::id(dao), winning_outcome, 0, ctx)
}

// === Configuration Management ===

/// Update trading parameters
public(package) fun update_trading_params<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    min_asset_amount: u64,
    min_stable_amount: u64,
    review_period_ms: u64,
    trading_period_ms: u64,
) {
    dao_management::update_trading_params(
        dao, min_asset_amount, min_stable_amount, review_period_ms, trading_period_ms
    )
}

/// Update metadata
public(package) fun update_metadata<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    dao_name: AsciiString,
    icon_url_string: AsciiString,
    description: String,
) {
    dao_management::update_metadata(dao, dao_name, icon_url_string, description)
}

/// Update TWAP config
public(package) fun update_twap_config<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    amm_twap_start_delay: u64,
    amm_twap_step_max: u64,
    amm_twap_initial_observation: u128,
    twap_threshold: u64,
) {
    dao_management::update_twap_config(
        dao, amm_twap_start_delay, amm_twap_step_max, 
        amm_twap_initial_observation, twap_threshold
    )
}

/// Update governance parameters
public(package) fun update_governance<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    max_outcomes: u64,
    proposal_fee_per_outcome: u64,
    max_concurrent_proposals: u64,
    required_bond_amount: u64,
) {
    dao_management::update_governance(
        dao, max_outcomes, proposal_fee_per_outcome,
        max_concurrent_proposals, required_bond_amount
    )
}

/// Update metadata entry
public(package) fun update_metadata_entry<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    key: String,
    value: String,
) {
    dao_management::update_metadata_entry(dao, key, value)
}

/// Remove metadata entry
public(package) fun remove_metadata_entry<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    key: String,
) {
    dao_management::remove_metadata_entry(dao, key)
}

/// Set required bond amount (for compatibility)
public(package) fun set_required_bond_amount<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    amount: u64,
) {
    dao_state::set_required_bond_amount(dao, amount)
}

/// Initialize operating agreement
public(package) fun init_operating_agreement_internal<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    initial_lines: vector<String>,
    initial_difficulties: vector<u64>,
    ctx: &mut TxContext,
): ID {
    dao_management::init_operating_agreement_internal(dao, initial_lines, initial_difficulties, ctx)
}

/// Disable proposals
public(package) fun disable_proposals<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
) {
    dao_management::disable_proposals(dao)
}

/// Enable proposals
public(package) fun enable_proposals<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
) {
    dao_management::enable_proposals(dao)
}

// === Liquidity Management ===

/// Initialize liquidity pool
public entry fun init_liquidity_pool<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    initial_asset_coin: Coin<AssetType>,
    initial_stable_coin: Coin<StableType>,
    ctx: &mut TxContext,
) {
    dao_management::init_liquidity_pool(dao, initial_asset_coin, initial_stable_coin, ctx)
}

/// Deposit to liquidity pool
public entry fun deposit_to_liquidity_pool<AssetType, StableType>(
    dao: &DAO<AssetType, StableType>,
    pool: &mut DAOLiquidityPool<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    ctx: &mut TxContext,
) {
    dao_management::deposit_to_liquidity_pool(dao, pool, asset_coin, stable_coin, ctx)
}

// === Treasury Bridge Functions ===

/// Withdraw LP tokens from treasury
public(package) fun withdraw_lp_from_treasury<AssetType, StableType, LPType>(
    dao: &DAO<AssetType, StableType>,
    treasury: &mut Treasury,
    execution_context: &ProposalExecutionContext,
    amount: u64,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<LPType> {
    dao_management::withdraw_lp_from_treasury(
        dao, treasury, execution_context, amount, recipient, clock, ctx
    )
}

/// Withdraw asset from treasury
public(package) fun withdraw_asset_from_treasury<AssetType: drop, StableType>(
    dao: &DAO<AssetType, StableType>,
    treasury: &mut Treasury,
    execution_context: &ProposalExecutionContext,
    amount: u64,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    dao_management::withdraw_asset_from_treasury(
        dao, treasury, execution_context, amount, recipient, clock, ctx
    )
}

/// Withdraw stable from treasury
public(package) fun withdraw_stable_from_treasury<AssetType, StableType: drop>(
    dao: &DAO<AssetType, StableType>,
    treasury: &mut Treasury,
    execution_context: &ProposalExecutionContext,
    amount: u64,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableType> {
    dao_management::withdraw_stable_from_treasury(
        dao, treasury, execution_context, amount, recipient, clock, ctx
    )
}

// === Core Getters ===

/// Get DAO name
public fun get_name<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &AsciiString {
    dao_state::dao_name(dao)
}

/// Get asset type
public fun get_asset_type<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &String {
    dao_state::asset_type(dao)
}

/// Get stable type
public fun get_stable_type<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &String {
    dao_state::stable_type(dao)
}

/// Get types
public fun get_types<AssetType, StableType>(dao: &DAO<AssetType, StableType>): (&String, &String) {
    (dao_state::asset_type(dao), dao_state::stable_type(dao))
}

/// Get minimum amounts
public fun get_min_amounts<AssetType, StableType>(dao: &DAO<AssetType, StableType>): (u64, u64) {
    (dao_state::min_asset_amount(dao), dao_state::min_stable_amount(dao))
}

/// Get stats
public fun get_stats<AssetType, StableType>(dao: &DAO<AssetType, StableType>): (u64, u64, u64) {
    (
        dao_state::active_proposals(dao),
        dao_state::total_proposals(dao),
        dao_state::queue_size(dao)
    )
}

/// Get AMM config
public fun get_amm_config<AssetType, StableType>(dao: &DAO<AssetType, StableType>): (u64, u64, u128) {
    (
        dao_state::amm_twap_start_delay(dao),
        dao_state::amm_twap_step_max(dao),
        dao_state::amm_twap_initial_observation(dao)
    )
}

/// Get treasury ID
public fun get_treasury_id<AssetType, StableType>(dao: &DAO<AssetType, StableType>): &Option<ID> {
    dao_state::treasury_id(dao)
}

/// Check if has treasury
public fun has_treasury<AssetType, StableType>(dao: &DAO<AssetType, StableType>): bool {
    dao_management::has_treasury(dao)
}

/// Check if proposals are enabled
public fun are_proposals_enabled<AssetType, StableType>(dao: &DAO<AssetType, StableType>): bool {
    dao_management::are_proposals_enabled(dao)
}

/// Get max outcomes
public fun get_max_outcomes<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 {
    dao_management::get_max_outcomes(dao)
}

/// Get governance parameters
public fun get_governance_params<AssetType, StableType>(
    dao: &DAO<AssetType, StableType>
): (u64, u64, u64, u64) {
    dao_management::get_governance_params(dao)
}

// === Proposal Info Getters ===

/// Get proposal info
public fun get_proposal_info<AssetType, StableType>(dao: &DAO<AssetType, StableType>, proposal_id: ID): &ProposalInfo {
    dao_governance::get_proposal_info(dao, proposal_id)
}

/// Get result
public fun get_result(info: &ProposalInfo): &Option<String> {
    dao_state::proposal_info_result(info)
}

/// Check if has result
public fun has_result(info: &ProposalInfo): bool {
    dao_state::proposal_info_result(info).is_some()
}

/// Check if executed
public fun is_executed(info: &ProposalInfo): bool {
    dao_state::proposal_info_executed(info)
}

/// Get execution time
public fun get_execution_time(info: &ProposalInfo): &Option<u64> {
    dao_state::proposal_info_execution_time(info)
}

/// Get proposer
public fun get_proposer(info: &ProposalInfo): address {
    dao_state::proposal_info_proposer(info)
}

/// Get created at
public fun get_created_at(info: &ProposalInfo): u64 {
    dao_state::proposal_info_created_at(info)
}

/// Get title
public fun get_title(info: &ProposalInfo): &String {
    dao_state::proposal_info_title(info)
}

// === Queue Getters ===

/// Get queue stats
public fun get_queue_stats<AssetType, StableType>(dao: &DAO<AssetType, StableType>): (u64, u64, u64, bool) {
    dao_governance::get_queue_stats(dao)
}

/// Get required bond amount
public fun get_required_bond_amount<AssetType, StableType>(dao: &DAO<AssetType, StableType>): u64 {
    dao_state::required_bond_amount(dao)
}