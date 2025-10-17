// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_markets_core::proposal;

use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use futarchy_markets_primitives::coin_escrow::{Self, TokenEscrow};
use futarchy_markets_core::liquidity_initialize;
use futarchy_markets_primitives::market_state;
use futarchy_one_shot_utils::coin_validation;
use std::ascii::String as AsciiString;
use std::string::{Self, String};
use std::type_name;
use std::option;
use std::type_name::TypeName;
use std::vector;
use sui::balance::{Balance};
use sui::clock::Clock;
use sui::coin::{Coin, TreasuryCap, CoinMetadata};
use sui::event;
use sui::bag::{Self, Bag};
use futarchy_types::init_action_specs::{Self as action_specs, InitActionSpecs};
use futarchy_types::signed::{Self as signed, SignedU128};
use futarchy_core::dao_config::{Self, ConditionalCoinConfig};

// === Introduction ===
// This defines the core proposal logic and details

// === Errors ===

const EInvalidAmount: u64 = 1;
const EInvalidState: u64 = 2;
const EAssetLiquidityTooLow: u64 = 4;
const EStableLiquidityTooLow: u64 = 5;
const EPoolNotFound: u64 = 6;
const EOutcomeOutOfBounds: u64 = 7;
const EInvalidOutcomeVectors: u64 = 8;
const ESpotTwapNotReady: u64 = 9;
const ETooManyOutcomes: u64 = 10;
const EInvalidOutcome: u64 = 11;
const ENotFinalized: u64 = 12;
const ETwapNotSet: u64 = 13;
const ETooManyActions: u64 = 14;
const EInvalidConditionalCoinCount: u64 = 15;
const EConditionalCoinAlreadySet: u64 = 16;
const ENotLiquidityProvider: u64 = 17;

// === Constants ===

const STATE_PREMARKET: u8 = 0; // Proposal exists, outcomes can be added/mutated. No market yet.
const STATE_REVIEW: u8 = 1;    // Market is initialized and locked for review. Not yet trading.
const STATE_TRADING: u8 = 2;   // Market is live and trading.
const STATE_FINALIZED: u8 = 3; // Market has resolved.

// Outcome constants for TWAP calculation
const OUTCOME_ACCEPTED: u64 = 0;
const OUTCOME_REJECTED: u64 = 1;

// === Structs ===

/// Key for storing conditional coin caps in Bag
/// Each outcome has 2 coins: asset-conditional and stable-conditional
public struct ConditionalCoinKey has store, copy, drop {
    outcome_index: u64,
    is_asset: bool,  // true for asset, false for stable
}

/// Configuration for proposal timing and periods
public struct ProposalTiming has store {
    created_at: u64,
    market_initialized_at: Option<u64>,
    review_period_ms: u64,
    trading_period_ms: u64,
    last_twap_update: u64,
    twap_start_delay: u64,
}

/// Configuration for liquidity requirements
public struct LiquidityConfig has store {
    min_asset_liquidity: u64,
    min_stable_liquidity: u64,
    asset_amounts: vector<u64>,
    stable_amounts: vector<u64>,
    uses_dao_liquidity: bool,
}

/// TWAP (Time-Weighted Average Price) configuration
public struct TwapConfig has store {
    twap_prices: vector<u128>,
    twap_initial_observation: u128,
    twap_step_max: u64,
    twap_threshold: SignedU128,
}

/// Outcome-related data
public struct OutcomeData has store {
    outcome_count: u64,
    outcome_messages: vector<String>,
    outcome_creators: vector<address>,
    outcome_creator_fees: vector<u64>,  // Track fees paid by each outcome creator (for refunds)
    intent_specs: vector<Option<InitActionSpecs>>,  // Changed from intent_keys to intent_specs
    actions_per_outcome: vector<u64>,
    winning_outcome: Option<u64>,
}

/// Core proposal object that owns AMM pools
public struct Proposal<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    /// The logical ID of the proposal from the priority queue.
    queued_proposal_id: ID,
    state: u8,
    dao_id: ID,
    proposer: address, // The original proposer.
    liquidity_provider: Option<address>,
    withdraw_only_mode: bool, // When true, return liquidity to provider instead of auto-reinvesting
    /// Track if proposal used admin quota/budget (excludes from creator rewards)
    used_quota: bool,

    // Market-related fields (pools now live in MarketState)
    escrow_id: Option<ID>,
    market_state_id: Option<ID>,

    // Conditional coin capabilities (stored dynamically per outcome)
    conditional_treasury_caps: Bag,  // Stores TreasuryCap<ConditionalCoinType> per outcome
    conditional_metadata: Bag,        // Stores CoinMetadata<ConditionalCoinType> per outcome

    // Proposal content
    title: String,
    details: vector<String>,
    metadata: String,
    
    // Grouped configurations
    timing: ProposalTiming,
    liquidity_config: LiquidityConfig,
    twap_config: TwapConfig,
    outcome_data: OutcomeData,
    
    // Fee-related fields
    amm_total_fee_bps: u64,
    conditional_liquidity_ratio_percent: u64,  // Percentage of spot liquidity to move to conditional markets (1-99%, base 100)
    fee_escrow: Balance<StableType>,
    treasury_address: address,
}

/// A scoped witness proving that a particular (proposal, outcome) had an IntentSpec.
/// Only mintable by the module that has &mut Proposal and consumes the slot.
/// This prevents cross-proposal cancellation attacks.
///
/// After IntentSpec refactor: This witness proves ownership of a proposal outcome slot,
/// used for cleanup and lifecycle management.
public struct CancelWitness has drop {
    proposal: address,
    outcome_index: u64,
}

// Getter functions for CancelWitness
public fun cancel_witness_proposal(witness: &CancelWitness): address {
    witness.proposal
}

public fun cancel_witness_outcome_index(witness: &CancelWitness): u64 {
    witness.outcome_index
}

// === Events ===

public struct ProposalCreated has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    proposer: address,
    outcome_count: u64,
    outcome_messages: vector<String>,
    created_at: u64,
    asset_type: AsciiString,
    stable_type: AsciiString,
    review_period_ms: u64,
    trading_period_ms: u64,
    title: String,
    metadata: String,
}

public struct ProposalMarketInitialized has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    market_state_id: ID,
    escrow_id: ID,
    timestamp: u64,
}

public struct ProposalOutcomeMutated has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    outcome_idx: u64,
    old_creator: address,
    new_creator: address,
    timestamp: u64,
}

public struct ProposalOutcomeAdded has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    new_outcome_idx: u64,
    creator: address,
    timestamp: u64,
}

// Early resolution events moved to early_resolve.move

// === Public Functions ===

/// Creates all on-chain objects for a futarchy market when a proposal is activated from the queue.
/// This is the main entry point for creating a full proposal with market infrastructure.
#[allow(lint(share_owned))]
public fun initialize_market<AssetType, StableType>(
    // Proposal ID (generated when adding to queue)
    proposal_id: ID,
    // Market parameters from DAO
    dao_id: ID,
    review_period_ms: u64,
    trading_period_ms: u64,
    min_asset_liquidity: u64,
    min_stable_liquidity: u64,
    twap_start_delay: u64,
    twap_initial_observation: u128,
    twap_step_max: u64,
    twap_threshold: SignedU128,
    amm_total_fee_bps: u64,
    conditional_liquidity_ratio_percent: u64,  // Percentage of spot liquidity to move (1-99%, base 100)
    max_outcomes: u64, // DAO's configured max outcomes
    treasury_address: address,
    // Proposal specific parameters
    title: String,
    metadata: String,
    initial_outcome_messages: vector<String>,
    initial_outcome_details: vector<String>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    proposer: address, // The original proposer from the queue
    proposer_fee_paid: u64, // Fee paid by proposer (for tracking refunds)
    uses_dao_liquidity: bool,
    used_quota: bool, // Track if proposal used admin budget (from QueuedProposal)
    fee_escrow: Balance<StableType>, // DAO fees if any
    mut intent_spec_for_yes: Option<InitActionSpecs>, // Intent spec for YES outcome
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID, u8) {

    // Create a new proposal UID
    let id = object::new(ctx);
    let actual_proposal_id = object::uid_to_inner(&id);
    let outcome_count = initial_outcome_messages.length();

    // Validate outcome count
    assert!(outcome_count == initial_outcome_details.length(), EInvalidOutcomeVectors);
    assert!(outcome_count <= max_outcomes, ETooManyOutcomes);

    // Liquidity is split evenly among all outcomes
    let total_asset_liquidity = asset_coin.value();
    let total_stable_liquidity = stable_coin.value();
    assert!(total_asset_liquidity > 0 && total_stable_liquidity > 0, EInvalidAmount);
    
    let asset_per_outcome = total_asset_liquidity / outcome_count;
    let stable_per_outcome = total_stable_liquidity / outcome_count;
    
    // Calculate remainders from integer division
    let asset_remainder = total_asset_liquidity % outcome_count;
    let stable_remainder = total_stable_liquidity % outcome_count;
    
    // Distribute liquidity evenly, with remainder going to first outcomes
    let mut initial_asset_amounts = vector::empty<u64>();
    let mut initial_stable_amounts = vector::empty<u64>();
    let mut i = 0;
    while (i < outcome_count) {
        // Add 1 extra token to first 'remainder' outcomes
        let asset_amount = if (i < asset_remainder) { asset_per_outcome + 1 } else { asset_per_outcome };
        let stable_amount = if (i < stable_remainder) { stable_per_outcome + 1 } else { stable_per_outcome };
        
        vector::push_back(&mut initial_asset_amounts, asset_amount);
        vector::push_back(&mut initial_stable_amounts, stable_amount);
        i = i + 1;
    };

    // Validate minimum liquidity requirements for conditional markets
    assert!(asset_per_outcome >= min_asset_liquidity, EAssetLiquidityTooLow);
    assert!(stable_per_outcome >= min_stable_liquidity, EStableLiquidityTooLow);

    // CRITICAL: Pre-validate that spot pool will maintain k >= 1000 after quantum split
    // Defense-in-depth to catch misconfiguration at proposal creation
    // Spot ratio = (100 - conditional_liquidity_ratio_percent) / 100
    // With protocol min = 100,000 and ratio = 99%: spot keeps 1,000 each → k = 1,000,000 ✅
    // NOTE: This assumes single proposal (current model). If multiple proposals allowed in future,
    //       may need to store conditional_liquidity_ratio_percent in AMM as optional field.
    let spot_ratio = 100 - conditional_liquidity_ratio_percent;
    let spot_asset_projected = (min_asset_liquidity as u128) * (spot_ratio as u128) / 100u128;
    let spot_stable_projected = (min_stable_liquidity as u128) * (spot_ratio as u128) / 100u128;
    let projected_spot_k = spot_asset_projected * spot_stable_projected;
    assert!(projected_spot_k >= 1000u128, EAssetLiquidityTooLow); // Reuse error for simplicity

    // Initialize outcome creators to the original proposer
    let outcome_creators = vector::tabulate!(outcome_count, |_| proposer);

    // Create market state
    let market_state = market_state::new(
        actual_proposal_id,  // Use the actual proposal ID, not the parameter
        dao_id, 
        outcome_count, 
        initial_outcome_messages, 
        clock, 
        ctx
    );
    let market_state_id = object::id(&market_state);

    // Create escrow
    let mut escrow = coin_escrow::new<AssetType, StableType>(market_state, ctx);
    let escrow_id = object::id(&escrow);

    // Create AMM pools and initialize liquidity
    let mut asset_balance = asset_coin.into_balance();
    let mut stable_balance = stable_coin.into_balance();
    
    // Quantum liquidity: the same liquidity backs all outcomes conditionally
    // We only need the MAX amount across outcomes since they share the same underlying liquidity
    let mut max_asset = 0u64;
    let mut max_stable = 0u64;
    let mut j = 0;
    while (j < outcome_count) {
        let asset_amt = *initial_asset_amounts.borrow(j);
        let stable_amt = *initial_stable_amounts.borrow(j);
        if (asset_amt > max_asset) { max_asset = asset_amt };
        if (stable_amt > max_stable) { max_stable = stable_amt };
        j = j + 1;
    };
    
    // Extract the exact amount needed for quantum liquidity
    let asset_total = asset_balance.value();
    let stable_total = stable_balance.value();
    
    let asset_for_pool = if (asset_total > max_asset) {
        asset_balance.split(max_asset)
    } else {
        asset_balance.split(asset_total)
    };
    
    let stable_for_pool = if (stable_total > max_stable) {
        stable_balance.split(max_stable)
    } else {
        stable_balance.split(stable_total)
    };
    
    // Return excess to proposer if any
    if (asset_balance.value() > 0) {
        transfer::public_transfer(asset_balance.into_coin(ctx), proposer);
    } else {
        asset_balance.destroy_zero();
    };
    
    if (stable_balance.value() > 0) {
        transfer::public_transfer(stable_balance.into_coin(ctx), proposer);
    } else {
        stable_balance.destroy_zero();
    };
    
    let amm_pools = liquidity_initialize::create_outcome_markets(
        &mut escrow,
        outcome_count,
        initial_asset_amounts,
        initial_stable_amounts,
        twap_start_delay,
        twap_initial_observation,
        twap_step_max,
        amm_total_fee_bps,
        asset_for_pool,
        stable_for_pool,
        clock,
        ctx
    );

    // Move pools to MarketState (architectural fix: pools belong to market, not proposal)
    let market_state = coin_escrow::get_market_state_mut(&mut escrow);
    market_state::set_amm_pools(market_state, amm_pools);

    // Prepare intent_specs and actions_per_outcome
    let mut intent_specs = vector::tabulate!(outcome_count, |_| option::none<InitActionSpecs>());
    let mut actions_per_outcome = vector::tabulate!(outcome_count, |_| 0);

    // Store the intent spec for YES outcome at index 0 if provided
    if (intent_spec_for_yes.is_some()) {
        let spec = intent_spec_for_yes.extract();
        let actions_count = action_specs::action_count(&spec);
        *vector::borrow_mut(&mut intent_specs, 0) = option::some(spec);
        *vector::borrow_mut(&mut actions_per_outcome, 0) = actions_count;
    };

    // Create proposal object
    let proposal = Proposal<AssetType, StableType> {
        id,
        queued_proposal_id: proposal_id,
        state: STATE_REVIEW, // Start in REVIEW state since market is initialized
        dao_id,
        proposer,
        liquidity_provider: option::some(ctx.sender()),
        withdraw_only_mode: false,
        used_quota,
        escrow_id: option::some(escrow_id),
        market_state_id: option::some(market_state_id),
        conditional_treasury_caps: bag::new(ctx),
        conditional_metadata: bag::new(ctx),
        title,
        details: initial_outcome_details,
        metadata,
        timing: ProposalTiming {
            created_at: clock.timestamp_ms(),
            market_initialized_at: option::some(clock.timestamp_ms()),
            review_period_ms,
            trading_period_ms,
            last_twap_update: 0,
            twap_start_delay,
        },
        liquidity_config: LiquidityConfig {
            min_asset_liquidity,
            min_stable_liquidity,
            asset_amounts: initial_asset_amounts,
            stable_amounts: initial_stable_amounts,
            uses_dao_liquidity,
        },
        twap_config: TwapConfig {
            twap_prices: vector::empty(),
            twap_initial_observation,
            twap_step_max,
            twap_threshold,
        },
        outcome_data: OutcomeData {
            outcome_count,
            outcome_messages: initial_outcome_messages,
            outcome_creators,
            outcome_creator_fees: {
                // Track actual fees paid by each outcome creator
                // Outcome 0 (reject): 0 fee
                // Outcome 1+ (proposer's outcomes): proposer_fee_paid divided by (outcome_count - 1)
                let mut fees = vector::empty();
                fees.push_back(0u64); // Outcome 0 (reject) - no fee
                let mut i = 1u64;
                while (i < outcome_count) {
                    fees.push_back(proposer_fee_paid); // Each outcome tracks the proposer's fee
                    i = i + 1;
                };
                fees
            },
            intent_specs,
            actions_per_outcome,
            winning_outcome: option::none(),
        },
        amm_total_fee_bps,
        conditional_liquidity_ratio_percent,
        fee_escrow,
        treasury_address,
    };

    event::emit(ProposalCreated {
        proposal_id: actual_proposal_id,
        dao_id,
        proposer,
        outcome_count,
        outcome_messages: initial_outcome_messages,
        created_at: clock.timestamp_ms(),
        asset_type: type_name::with_defining_ids<AssetType>().into_string(),
        stable_type: type_name::with_defining_ids<StableType>().into_string(),
        review_period_ms,
        trading_period_ms,
        title,
        metadata,
    });

    transfer::public_share_object(proposal);
    transfer::public_share_object(escrow);

    // Return the actual on-chain proposal ID, not the queue ID
    (actual_proposal_id, market_state_id, STATE_REVIEW)
}

// The create function has been removed as it's not used in production.
// All proposals are created through initialize_market which properly handles proposal IDs
// generated from the priority queue.

/// Create a PREMARKET proposal without market/escrow/liquidity.
/// This reserves the proposal "as next" without consuming DAO/proposer liquidity.
#[allow(lint(share_owned))]
public fun new_premarket<AssetType, StableType>(
    // Proposal ID originating from queue
    proposal_id_from_queue: ID,
    dao_id: ID,
    review_period_ms: u64,
    trading_period_ms: u64,
    min_asset_liquidity: u64,
    min_stable_liquidity: u64,
    twap_start_delay: u64,
    twap_initial_observation: u128,
    twap_step_max: u64,
    twap_threshold: SignedU128,
    amm_total_fee_bps: u64,
    conditional_liquidity_ratio_percent: u64,  // Percentage of spot liquidity to move (1-99%, base 100)
    max_outcomes: u64, // DAO's configured max outcomes
    treasury_address: address,
    title: String,
    metadata: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
    proposer: address,
    uses_dao_liquidity: bool,
    used_quota: bool, // Track if proposal used admin budget
    fee_escrow: Balance<StableType>,
    intent_spec_for_yes: Option<InitActionSpecs>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let id = object::new(ctx);
    let actual_proposal_id = object::uid_to_inner(&id);
    let outcome_count = outcome_messages.length();
    
    // Validate outcome count
    assert!(outcome_count <= max_outcomes, ETooManyOutcomes);
    
    let proposal = Proposal<AssetType, StableType> {
        id,
        queued_proposal_id: proposal_id_from_queue,
        state: STATE_PREMARKET,
        dao_id,
        proposer,
        liquidity_provider: option::none(),
        withdraw_only_mode: false,
        used_quota,
        escrow_id: option::none(),
        market_state_id: option::none(),
        conditional_treasury_caps: bag::new(ctx),
        conditional_metadata: bag::new(ctx),
        title,
        details: outcome_details,
        metadata,
        timing: ProposalTiming {
            created_at: clock.timestamp_ms(),
            market_initialized_at: option::none(),
            review_period_ms,
            trading_period_ms,
            last_twap_update: 0,
            twap_start_delay,
        },
        liquidity_config: LiquidityConfig {
            min_asset_liquidity,
            min_stable_liquidity,
            asset_amounts: vector::empty(),
            stable_amounts: vector::empty(),
            uses_dao_liquidity,
        },
        twap_config: TwapConfig {
            twap_prices: vector::empty(),
            twap_initial_observation,
            twap_step_max,
            twap_threshold,
        },
        outcome_data: OutcomeData {
            outcome_count,
            outcome_messages,
            outcome_creators: vector::tabulate!(outcome_count, |_| proposer),
            outcome_creator_fees: vector::tabulate!(outcome_count, |_| 0u64),  // Initialize with 0 fees
            intent_specs: vector::tabulate!(outcome_count, |_| option::none<InitActionSpecs>()),
            actions_per_outcome: vector::tabulate!(outcome_count, |_| 0),
            winning_outcome: option::none(),
        },
        amm_total_fee_bps,
        conditional_liquidity_ratio_percent,
        fee_escrow,
        treasury_address,
    };

    transfer::public_share_object(proposal);
    actual_proposal_id
}

/// Initialize market/escrow/AMMs for a PREMARKET proposal.
/// Consumes provided coins, sets state to REVIEW, and readies the market for the review timer.
#[allow(lint(share_owned, self_transfer))]
/// Step 1: Create escrow with market state (called first in PTB)
/// Returns unshared escrow for cap registration
public fun create_escrow_for_market<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): TokenEscrow<AssetType, StableType> {
    assert!(proposal.state == STATE_PREMARKET, EInvalidState);

    // Create market state
    let ms = market_state::new(
        object::id(proposal),
        proposal.dao_id,
        proposal.outcome_data.outcome_count,
        proposal.outcome_data.outcome_messages,
        clock,
        ctx
    );

    // Create and return escrow (not yet shared)
    coin_escrow::new<AssetType, StableType>(ms, ctx)
}

/// Step 2: Extract conditional coin caps from proposal and register with escrow
/// Must be called once per outcome (PTB calls this N times with different type parameters)
public fun register_outcome_caps_with_escrow<AssetType, StableType, AssetConditionalCoin, StableConditionalCoin>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_index: u64,
) {
    assert!(proposal.state == STATE_PREMARKET, EInvalidState);

    // Extract TreasuryCaps from proposal bags
    let asset_key = ConditionalCoinKey { outcome_index, is_asset: true };
    let stable_key = ConditionalCoinKey { outcome_index, is_asset: false };

    let asset_cap: TreasuryCap<AssetConditionalCoin> =
        bag::remove(&mut proposal.conditional_treasury_caps, asset_key);
    let stable_cap: TreasuryCap<StableConditionalCoin> =
        bag::remove(&mut proposal.conditional_treasury_caps, stable_key);

    // Register with escrow
    coin_escrow::register_conditional_caps(escrow, outcome_index, asset_cap, stable_cap);
}

/// Step 3: Initialize market with pre-configured escrow
/// Called after create_escrow_for_market() and N calls to register_outcome_caps_with_escrow()
#[allow(lint(share_owned, self_transfer))]
public fun initialize_market_with_escrow<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    mut escrow: TokenEscrow<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert!(proposal.state == STATE_PREMARKET, EInvalidState);

    let outcome_count = proposal.outcome_data.outcome_count;

    // Evenly split liquidity across outcomes
    let total_asset_liquidity = asset_coin.value();
    let total_stable_liquidity = stable_coin.value();
    assert!(total_asset_liquidity > 0 && total_stable_liquidity > 0, EInvalidAmount);

    let asset_per = total_asset_liquidity / outcome_count;
    let stable_per = total_stable_liquidity / outcome_count;
    assert!(asset_per >= proposal.liquidity_config.min_asset_liquidity, EAssetLiquidityTooLow);
    assert!(stable_per >= proposal.liquidity_config.min_stable_liquidity, EStableLiquidityTooLow);

    let asset_remainder = total_asset_liquidity % outcome_count;
    let stable_remainder = total_stable_liquidity % outcome_count;

    let mut initial_asset_amounts = vector::empty<u64>();
    let mut initial_stable_amounts = vector::empty<u64>();
    let mut i = 0;
    while (i < outcome_count) {
        let a = if (i < asset_remainder) { asset_per + 1 } else { asset_per };
        let s = if (i < stable_remainder) { stable_per + 1 } else { stable_per };
        vector::push_back(&mut initial_asset_amounts, a);
        vector::push_back(&mut initial_stable_amounts, s);
        i = i + 1;
    };

    let escrow_id = object::id(&escrow);
    let market_state_id = coin_escrow::market_state_id(&escrow);
    
    // Determine quantum liquidity amounts
    let mut asset_balance = asset_coin.into_balance();
    let mut stable_balance = stable_coin.into_balance();
    
    let mut max_asset = 0u64;
    let mut max_stable = 0u64;
    i = 0;
    while (i < outcome_count) {
        let a = *initial_asset_amounts.borrow(i);
        let s = *initial_stable_amounts.borrow(i);
        if (a > max_asset) { max_asset = a };
        if (s > max_stable) { max_stable = s };
        i = i + 1;
    };
    
    let asset_total = asset_balance.value();
    let stable_total = stable_balance.value();
    
    let asset_for_pool = if (asset_total > max_asset) {
        asset_balance.split(max_asset)
    } else {
        asset_balance.split(asset_total)
    };
    
    let stable_for_pool = if (stable_total > max_stable) {
        stable_balance.split(max_stable)
    } else {
        stable_balance.split(stable_total)
    };
    
    // Return any excess to liquidity provider (the activator who supplied coins)
    let sender = ctx.sender();
    if (asset_balance.value() > 0) {
        transfer::public_transfer(asset_balance.into_coin(ctx), sender);
    } else {
        asset_balance.destroy_zero();
    };
    
    if (stable_balance.value() > 0) {
        transfer::public_transfer(stable_balance.into_coin(ctx), sender);
    } else {
        stable_balance.destroy_zero();
    };
    
    // Create outcome markets (TreasuryCaps already registered with escrow)
    let amm_pools = liquidity_initialize::create_outcome_markets(
        &mut escrow,
        proposal.outcome_data.outcome_count,
        initial_asset_amounts,
        initial_stable_amounts,
        proposal.timing.twap_start_delay,
        proposal.twap_config.twap_initial_observation,
        proposal.twap_config.twap_step_max,
        proposal.amm_total_fee_bps,
        asset_for_pool,
        stable_for_pool,
        clock,
        ctx
    );

    // Move pools to MarketState (architectural fix: pools belong to market, not proposal)
    let market_state = coin_escrow::get_market_state_mut(&mut escrow);
    market_state::set_amm_pools(market_state, amm_pools);

    // Update proposal's liquidity amounts
    proposal.liquidity_config.asset_amounts = initial_asset_amounts;
    proposal.liquidity_config.stable_amounts = initial_stable_amounts;

    // Initialize market fields: PREMARKET → REVIEW
    initialize_market_fields(
        proposal,
        market_state_id,
        escrow_id,
        clock.timestamp_ms(),
        sender
    );
    
    transfer::public_share_object(escrow);
    market_state_id
}

/// Internal function: Adds a new outcome during the premarket phase.
/// max_outcomes: The DAO's configured maximum number of outcomes allowed
/// fee_paid: The fee paid by the outcome creator (for potential refund if their outcome wins)
///
/// SECURITY: This is an internal function. Fee payment must be validated before calling.
/// External callers MUST use entry functions that collect actual Coin<SUI> payments.
public fun add_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    message: String,
    detail: String,
    asset_amount: u64,
    stable_amount: u64,
    creator: address,
    fee_paid: u64,
    max_outcomes: u64,
    clock: &Clock,
) {
    // SECURITY: Only allow adding outcomes in PREMARKET state
    assert!(proposal.state == STATE_PREMARKET, EInvalidState);

    // Check that we're not exceeding the maximum number of outcomes
    assert!(proposal.outcome_data.outcome_count < max_outcomes, ETooManyOutcomes);

    proposal.outcome_data.outcome_messages.push_back(message);
    proposal.details.push_back(detail);
    proposal.liquidity_config.asset_amounts.push_back(asset_amount);
    proposal.liquidity_config.stable_amounts.push_back(stable_amount);
    proposal.outcome_data.outcome_creators.push_back(creator);
    proposal.outcome_data.outcome_creator_fees.push_back(fee_paid);  // Track the fee paid

    // Initialize action count for new outcome
    proposal.outcome_data.actions_per_outcome.push_back(0);

    // Initialize IntentSpec slot as empty
    proposal.outcome_data.intent_specs.push_back(option::none());

    let new_idx = proposal.outcome_data.outcome_count;
    proposal.outcome_data.outcome_count = new_idx + 1;

    event::emit(ProposalOutcomeAdded {
        proposal_id: get_id(proposal),
        dao_id: get_dao_id(proposal),
        new_outcome_idx: new_idx,
        creator,
        timestamp: clock.timestamp_ms(),
    });
}

/// SECURE entry function: Adds outcome with actual fee collection
/// This collects the fee payment and stores it in the proposal's fee escrow
/// for later refund if the outcome wins.
public entry fun add_outcome_with_fee<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    fee_payment: Coin<StableType>,
    message: String,
    detail: String,
    asset_amount: u64,
    stable_amount: u64,
    max_outcomes: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    use sui::coin;

    // Get the actual fee paid
    let fee_paid = fee_payment.value();

    // SECURITY: Deposit fee into proposal's escrow (for later refund)
    // This ensures fees are tracked per-proposal, not mixed with protocol revenue
    proposal.fee_escrow.join(fee_payment.into_balance());

    // Add the outcome with validated fee
    add_outcome(
        proposal,
        message,
        detail,
        asset_amount,
        stable_amount,
        ctx.sender(),
        fee_paid,
        max_outcomes,
        clock,
    );
}

/// Initializes the market-related fields of the proposal.
/// Pools are now stored in MarketState, not Proposal
public fun initialize_market_fields<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    market_state_id: ID,
    escrow_id: ID,
    initialized_at: u64,
    liquidity_provider: address,
) {
    assert!(proposal.state == STATE_PREMARKET, EInvalidState);

    // Use option::fill to replace None with Some value
    option::fill(&mut proposal.market_state_id, market_state_id);
    option::fill(&mut proposal.escrow_id, escrow_id);
    // amm_pools removed - now stored in MarketState
    // LP caps no longer needed - using conditional tokens
    option::fill(&mut proposal.timing.market_initialized_at, initialized_at);
    option::fill(&mut proposal.liquidity_provider, liquidity_provider);
    proposal.state = STATE_REVIEW; // Advance state to REVIEW
}

/// Emits the ProposalMarketInitialized event
public fun emit_market_initialized(
    proposal_id: ID,
    dao_id: ID,
    market_state_id: ID,
    escrow_id: ID,
    timestamp: u64,
) {
    event::emit(ProposalMarketInitialized {
        proposal_id,
        dao_id,
        market_state_id,
        escrow_id,
        timestamp,
    });
}

/// Takes the escrowed fee balance out of the proposal, leaving a zero balance behind.
public fun take_fee_escrow<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
): Balance<StableType> {
    let fee_balance = &mut proposal.fee_escrow;
    let amount = fee_balance.value();
    sui::balance::split(fee_balance, amount)
}

/// Get TWAPs from all pools via MarketState
/// Returns a reference to that oracle; aborts if not found.
public fun get_twaps_for_proposal<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    clock: &Clock,
): vector<u128> {
    let market_state = coin_escrow::get_market_state_mut(escrow);
    let pools = market_state::borrow_amm_pools_mut(market_state);
    let mut twaps = vector[];
    let mut i = 0;
    while (i < pools.length()) {
        let pool = &mut pools[i];
        let twap = pool.get_twap(clock);
        twaps.push_back(twap);
        i = i + 1;
    };
    twaps
}

/// Calculate current winner by INSTANT PRICE (fast flip detection)
/// Returns (winner_index, winner_price, spread)
/// Used for flip detection - faster than TWAP
public fun calculate_current_winner_by_price<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
): (u64, u128, u128) {
    let market_state = coin_escrow::get_market_state_mut(escrow);
    let pools = market_state::borrow_amm_pools_mut(market_state);
    let outcome_count = pools.length();

    assert!(outcome_count >= 2, EInvalidOutcome);

    // Get instant prices from all pools
    let mut winner_idx = 0u64;
    let mut winner_price = conditional_amm::get_current_price(&pools[0]);
    let mut second_price = 0u128;

    let mut i = 1u64;
    while (i < outcome_count) {
        let current_price = conditional_amm::get_current_price(&pools[i]);

        if (current_price > winner_price) {
            // New winner
            second_price = winner_price;
            winner_price = current_price;
            winner_idx = i;
        } else if (current_price > second_price) {
            // New second place
            second_price = current_price;
        };

        i = i + 1;
    };

    // Calculate spread (winner - second)
    let spread = if (winner_price > second_price) {
        winner_price - second_price
    } else {
        0u128
    };

    (winner_idx, winner_price, spread)
}

/// Calculate current winner by TWAP (for final resolution - manipulation resistant)
/// Returns (winner_index, winner_twap, spread)
/// Used for final resolution - slower but more secure
public fun calculate_current_winner<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    clock: &Clock,
): (u64, u128, u128) {
    // Get TWAPs from all markets
    let twaps = get_twaps_for_proposal(proposal, escrow, clock);
    let outcome_count = twaps.length();

    assert!(outcome_count >= 2, EInvalidOutcome);  // Need at least 2 outcomes

    // Find highest and second-highest TWAPs
    let mut winner_idx = 0u64;
    let mut winner_twap = *twaps.borrow(0);
    let mut second_twap = 0u128;

    let mut i = 1u64;
    while (i < outcome_count) {
        let current_twap = *twaps.borrow(i);

        if (current_twap > winner_twap) {
            // New winner found
            second_twap = winner_twap;
            winner_twap = current_twap;
            winner_idx = i;
        } else if (current_twap > second_twap) {
            // New second place
            second_twap = current_twap;
        };

        i = i + 1;
    };

    // Calculate spread (winner - second)
    let spread = if (winner_twap > second_twap) {
        winner_twap - second_twap
    } else {
        0u128
    };

    (winner_idx, winner_twap, spread)
}

// Early resolve functions removed to avoid circular dependencies.
// Callers should use early_resolve::update_metrics() and early_resolve::check_eligibility() directly.

// === Private Functions ===

fun get_pool_mut(pools: &mut vector<LiquidityPool>, outcome_idx: u8): &mut LiquidityPool {
    let mut i = 0;
    let len = pools.length();
    while (i < len) {
        let pool = &mut pools[i];
        if (pool.get_outcome_idx() == outcome_idx) {
            return pool
        };
        i = i + 1;
    };
    abort EPoolNotFound
}

// === View Functions ===

public fun is_finalized<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): bool {
    proposal.state == STATE_FINALIZED
}

public fun get_twap_prices<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): &vector<u128> {
    &proposal.twap_config.twap_prices
}

public fun get_last_twap_update<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    proposal.timing.last_twap_update
}

/// Get TWAP for a specific outcome by index
public fun get_twap_by_outcome<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    outcome_index: u64,
): u128 {
    // Add defensive checks
    assert!(proposal.state == STATE_FINALIZED, ENotFinalized);
    let twap_prices = &proposal.twap_config.twap_prices;
    assert!(!twap_prices.is_empty(), ETwapNotSet);
    assert!(outcome_index < twap_prices.length(), EOutcomeOutOfBounds);
    *twap_prices.borrow(outcome_index)
}

/// Get the TWAP of the winning outcome
public fun get_winning_twap<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u128 {
    // Add defensive checks
    assert!(proposal.state == STATE_FINALIZED, ENotFinalized);
    assert!(proposal.outcome_data.winning_outcome.is_some(), EInvalidState);
    assert!(!proposal.twap_config.twap_prices.is_empty(), ETwapNotSet);
    let winning_outcome = *proposal.outcome_data.winning_outcome.borrow();
    get_twap_by_outcome(proposal, winning_outcome)
}

public fun state<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u8 {
    proposal.state
}

/// Check if proposal is currently live (trading active)
public fun is_live<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>
): bool {
    proposal.state == STATE_TRADING
}

public fun get_winning_outcome<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    assert!(proposal.outcome_data.winning_outcome.is_some(), EInvalidState);
    *proposal.outcome_data.winning_outcome.borrow()
}

/// Checks if winning outcome has been set
public fun is_winning_outcome_set<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): bool {
    proposal.outcome_data.winning_outcome.is_some()
}

/// Returns the treasury address where fees for failed proposals are sent.
public fun treasury_address<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): address {
    proposal.treasury_address
}

public fun get_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    proposal.id.to_inner()
}

public fun escrow_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    assert!(proposal.escrow_id.is_some(), EInvalidState);
    *proposal.escrow_id.borrow()
}

public fun market_state_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    assert!(proposal.market_state_id.is_some(), EInvalidState);
    *proposal.market_state_id.borrow()
}

public fun get_market_initialized_at<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u64 {
    assert!(proposal.timing.market_initialized_at.is_some(), EInvalidState);
    *proposal.timing.market_initialized_at.borrow()
}

public fun outcome_count<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u64 {
    proposal.outcome_data.outcome_count
}

/// Alias for outcome_count for better readability
public fun get_num_outcomes<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u64 {
    proposal.outcome_data.outcome_count
}

public fun proposer<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): address {
    proposal.proposer
}

public fun created_at<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u64 {
    proposal.timing.created_at
}

public fun get_details<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): &vector<String> {
    &proposal.details
}

public fun get_metadata<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): &String {
    &proposal.metadata
}

public fun get_amm_pool_ids<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
): vector<ID> {
    let mut ids = vector[];
    let mut i = 0;
    let market_state = coin_escrow::get_market_state(escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let len = pools.length();
    while (i < len) {
        let pool = &pools[i];
        ids.push_back(pool.get_id());
        i = i + 1;
    };
    ids
}

public fun get_pool_mut_by_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u8,
): &mut LiquidityPool {
    assert!((outcome_idx as u64) < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);
    let market_state = coin_escrow::get_market_state_mut(escrow);
    let pools_mut = market_state::borrow_amm_pools_mut(market_state);
    get_pool_mut(pools_mut, outcome_idx)
}

public fun get_pool_by_outcome<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
    outcome_idx: u8,
): &LiquidityPool {
    assert!((outcome_idx as u64) < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);
    let market_state = coin_escrow::get_market_state(escrow);
    let pools = market_state::borrow_amm_pools(market_state);
    let mut i = 0;
    let len = pools.length();
    while (i < len) {
        let pool = &pools[i];
        if (pool.get_outcome_idx() == outcome_idx) {
            return pool
        };
        i = i + 1;
    };
    abort EPoolNotFound
}

// LP caps no longer needed - using conditional tokens for LP

// Pool and LP cap getter no longer needed - using conditional tokens for LP

public fun get_state<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u8 {
    proposal.state
}

public fun get_dao_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    proposal.dao_id
}


public fun proposal_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    proposal.id.to_inner()
}

public fun get_amm_pools<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    escrow: &TokenEscrow<AssetType, StableType>,
): &vector<LiquidityPool> {
    let market_state = coin_escrow::get_market_state(escrow);
    market_state::borrow_amm_pools(market_state)
}

public fun get_amm_pools_mut<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
): &mut vector<LiquidityPool> {
    let market_state = coin_escrow::get_market_state_mut(escrow);
    market_state::borrow_amm_pools_mut(market_state)
}

public fun get_created_at<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u64 {
    proposal.timing.created_at
}

public fun get_review_period_ms<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    proposal.timing.review_period_ms
}

public fun get_trading_period_ms<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    proposal.timing.trading_period_ms
}

public fun get_twap_threshold<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): SignedU128 {
    proposal.twap_config.twap_threshold
}

public fun get_twap_start_delay<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u64 {
    proposal.timing.twap_start_delay
}

public fun get_twap_initial_observation<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u128 {
    proposal.twap_config.twap_initial_observation
}

public fun get_twap_step_max<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u64 {
    proposal.twap_config.twap_step_max
}

public fun uses_dao_liquidity<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): bool {
    proposal.liquidity_config.uses_dao_liquidity
}

public fun get_amm_total_fee_bps<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    proposal.amm_total_fee_bps
}


/// Returns the parameters needed to initialize the market after the premarket phase.
public fun get_market_init_params<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): (u64, &vector<String>, &vector<u64>, &vector<u64>) {
    (
        proposal.outcome_data.outcome_count,
        &proposal.outcome_data.outcome_messages,
        &proposal.liquidity_config.asset_amounts,
        &proposal.liquidity_config.stable_amounts,
    )
}

// === Package Functions ===

/// Advances the proposal state based on elapsed time
/// Transitions from REVIEW to TRADING when review period ends
/// Returns true if state was changed
/// NOTE: spot_pool parameter removed - registration happens in proposal_lifecycle
public fun advance_state<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    let current_time = clock.timestamp_ms();
    // Use market_initialized_at for timing calculations instead of created_at
    // This ensures premarket proposals get proper review/trading periods after initialization
    let base_timestamp = if (proposal.timing.market_initialized_at.is_some()) {
        *proposal.timing.market_initialized_at.borrow()
    } else {
        // Fallback to created_at if market not initialized (shouldn't happen in normal flow)
        proposal.timing.created_at
    };
    
    // Check if we should transition from REVIEW to TRADING
    if (proposal.state == STATE_REVIEW) {
        let review_end = base_timestamp + proposal.timing.review_period_ms;
        if (current_time >= review_end) {
            proposal.state = STATE_TRADING;

            // Start trading in the market state
            let market = coin_escrow::get_market_state_mut(escrow);
            market_state::start_trading(market, proposal.timing.trading_period_ms, clock);

            // Extract market_id and trading_start_time before borrowing pools
            let market_id = market_state::market_id(market);
            let trading_start_time = market_state::get_trading_start(market);

            // Set oracle start time for all pools when trading begins
            let pools = market_state::borrow_amm_pools_mut(market);
            let mut i = 0;
            while (i < pools.length()) {
                let pool = &mut pools[i];
                conditional_amm::set_oracle_start_time(pool, market_id, trading_start_time);
                i = i + 1;
            };

            // NOTE: Quantum split and registration happens in proposal_lifecycle

            return true
        };
    };
    
    // Check if we should transition from TRADING to ended
    if (proposal.state == STATE_TRADING) {
        let trading_end = base_timestamp + proposal.timing.review_period_ms + proposal.timing.trading_period_ms;
        if (current_time >= trading_end) {
            // End trading in the market state
            let market = coin_escrow::get_market_state_mut(escrow);
            if (market_state::is_trading_active(market)) {
                market_state::end_trading(market, clock);
            };
            // Note: Full finalization requires calculating winner and is done separately
            // NOTE: spot pool registration is cleared in proposal_lifecycle
            return true
        };
    };
    
    false
}

public fun set_state<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    new_state: u8,
) {
    proposal.state = new_state;
}

public fun set_twap_prices<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    twap_prices: vector<u128>,
) {
    proposal.twap_config.twap_prices = twap_prices;
}

public fun set_last_twap_update<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    timestamp: u64,
) {
    proposal.timing.last_twap_update = timestamp;
}

public fun set_winning_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome: u64,
) {
    proposal.outcome_data.winning_outcome = option::some(outcome);
}

/// Finalize the proposal with the winning outcome computed on-chain
/// This combines computing the winner from TWAP, setting the winning outcome and updating state atomically
/// @deprecated Use proposal_lifecycle::finalize_proposal_market instead - this version lacks critical intent cleanup
#[test_only]
public fun finalize_proposal<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    clock: &Clock,
) {
    // Ensure we're in a state that can be finalized
    assert!(proposal.state == STATE_TRADING || proposal.state == STATE_REVIEW, EInvalidState);
    
    // If still in trading, end trading first
    if (proposal.state == STATE_TRADING) {
        let market = coin_escrow::get_market_state_mut(escrow);
        if (market_state::is_trading_active(market)) {
            market_state::end_trading(market, clock);
        };
    };
    
    // Critical fix: Compute the winning outcome on-chain from TWAP prices
    // Get TWAP prices from all pools
    let twap_prices = get_twaps_for_proposal(proposal, escrow, clock);

    // For a simple YES/NO proposal, compare the YES TWAP to the threshold
    let winning_outcome = if (twap_prices.length() >= 2) {
        let yes_twap = *twap_prices.borrow(OUTCOME_ACCEPTED);
        let threshold = get_twap_threshold(proposal);
        let yes_signed = signed::from_u128(yes_twap);

        // If YES TWAP exceeds threshold, YES wins
        if (signed::compare(&yes_signed, &threshold) == signed::ordering_greater()) {
            OUTCOME_ACCEPTED
        } else {
            OUTCOME_REJECTED
        }
    } else {
        // For single-outcome or other configs, default to first outcome
        // This should be revisited based on your specific requirements
        0
    };
    
    // Set the winning outcome
    proposal.outcome_data.winning_outcome = option::some(winning_outcome);
    
    // Update state to finalized
    proposal.state = STATE_FINALIZED;
    
    // Finalize the market state
    let market = coin_escrow::get_market_state_mut(escrow);
    market_state::finalize(market, winning_outcome, clock);
}

public fun get_outcome_creators<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): &vector<address> {
    &proposal.outcome_data.outcome_creators
}

/// Get the address of the creator for a specific outcome
public fun get_outcome_creator<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    outcome_index: u64
): address {
    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);
    *vector::borrow(&proposal.outcome_data.outcome_creators, outcome_index)
}

/// Get the fee paid by the creator for a specific outcome
public fun get_outcome_creator_fee<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    outcome_index: u64
): u64 {
    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);
    *vector::borrow(&proposal.outcome_data.outcome_creator_fees, outcome_index)
}

/// Get all outcome creator fees
public fun get_outcome_creator_fees<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>
): &vector<u64> {
    &proposal.outcome_data.outcome_creator_fees
}

/// Get proposal start time for early resolve calculations
/// Returns market_initialized_at if available, otherwise created_at
public(package) fun get_start_time_for_early_resolve<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>
): u64 {
    if (proposal.timing.market_initialized_at.is_some()) {
        *proposal.timing.market_initialized_at.borrow()
    } else {
        proposal.timing.created_at
    }
}

public fun get_liquidity_provider<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): Option<address> {
    proposal.liquidity_provider
}

public fun get_proposer<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): address {
    proposal.proposer
}

/// Check if this proposal used admin quota/budget (excludes from creator rewards)
public fun get_used_quota<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): bool {
    proposal.used_quota
}

/// Check if this proposal's liquidity is in withdraw-only mode
public fun is_withdraw_only<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): bool {
    proposal.withdraw_only_mode
}

/// Set withdraw-only mode - prevents auto-reinvestment in next proposal
/// Only callable by the liquidity provider
public entry fun set_withdraw_only_mode<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    withdraw_only: bool,
    ctx: &TxContext,
) {
    assert!(proposal.liquidity_provider.is_some(), ENotLiquidityProvider);
    let provider = *proposal.liquidity_provider.borrow();
    assert!(tx_context::sender(ctx) == provider, ENotLiquidityProvider);
    proposal.withdraw_only_mode = withdraw_only;
}

public fun get_outcome_messages<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): &vector<String> {
    &proposal.outcome_data.outcome_messages
}

/// Get the intent spec for a specific outcome
public fun get_intent_spec_for_outcome<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    outcome_index: u64
): &Option<InitActionSpecs> {
    vector::borrow(&proposal.outcome_data.intent_specs, outcome_index)
}


/// Take (move out) the intent spec for a specific outcome and clear the slot.
public fun take_intent_spec_for_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_index: u64
): Option<InitActionSpecs> {
    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);
    let slot = vector::borrow_mut(&mut proposal.outcome_data.intent_specs, outcome_index);
    let old_value = *slot;
    *slot = option::none();
    old_value
}

/// Mint a scoped cancel witness by taking (moving) the spec out of the slot.
/// Returns None if no spec was set for that outcome.
/// This witness can only be created once per (proposal, outcome) pair.
public fun make_cancel_witness<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_index: u64
): option::Option<CancelWitness> {
    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);
    let addr = object::uid_to_address(&proposal.id);
    let mut spec_opt = take_intent_spec_for_outcome(proposal, outcome_index);
    if (option::is_some(&spec_opt)) {
        // Reset action count for this outcome now that the spec has been removed
        let action_count_slot =
            vector::borrow_mut(&mut proposal.outcome_data.actions_per_outcome, outcome_index);
        *action_count_slot = 0;
        // Spec exists, create witness
        option::destroy_some(spec_opt);
        option::some(CancelWitness {
            proposal: addr,
            outcome_index,
        })
    } else {
        option::none<CancelWitness>()
    }
}

/// Set the intent spec for a specific outcome and track action count
/// This function:
/// 1. Validates the IntentSpec action count
/// 2. Stores the IntentSpec in the outcome slot
public fun set_intent_spec_for_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_index: u64,
    intent_spec: InitActionSpecs,
    max_actions_per_outcome: u64,
) {
    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);

    let spec_slot = vector::borrow_mut(&mut proposal.outcome_data.intent_specs, outcome_index);
    let action_count = vector::borrow_mut(&mut proposal.outcome_data.actions_per_outcome, outcome_index);

    // Get action count from the spec
    let num_actions = action_specs::action_count(&intent_spec);

    // Check outcome limit only
    assert!(num_actions <= max_actions_per_outcome, ETooManyActions);

    // Set the intent spec and update count
    *spec_slot = option::some(intent_spec);
    *action_count = num_actions;
}


/// Check if an outcome has an intent spec
public fun has_intent_spec<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    outcome_index: u64
): bool {
    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);
    option::is_some(vector::borrow(&proposal.outcome_data.intent_specs, outcome_index))
}

/// Get the number of actions for a specific outcome
public fun get_actions_for_outcome<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    outcome_index: u64
): u64 {
    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);
    *vector::borrow(&proposal.outcome_data.actions_per_outcome, outcome_index)
}

/// Clear the intent spec for an outcome and reset action count
public fun clear_intent_spec_for_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_index: u64,
) {
    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);

    let spec_slot = vector::borrow_mut(&mut proposal.outcome_data.intent_specs, outcome_index);
    let action_count = vector::borrow_mut(&mut proposal.outcome_data.actions_per_outcome, outcome_index);

    if (option::is_some(spec_slot)) {
        // Clear the intent spec
        *spec_slot = option::none();

        // Reset this outcome's action count
        *action_count = 0;
    };
}


/// Emits the ProposalOutcomeMutated event
public fun emit_outcome_mutated(
    proposal_id: ID,
    dao_id: ID,
    outcome_idx: u64,
    old_creator: address,
    new_creator: address,
    timestamp: u64,
) {
    event::emit(ProposalOutcomeMutated {
        proposal_id,
        dao_id,
        outcome_idx,
        old_creator,
        new_creator,
        timestamp,
    });
}

public fun set_outcome_creator<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_idx: u64,
    creator: address,
) {
    assert!(outcome_idx < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);
    let creator_ref = vector::borrow_mut(&mut proposal.outcome_data.outcome_creators, outcome_idx);
    *creator_ref = creator;
}

public fun get_details_mut<AssetType, StableType>(proposal: &mut Proposal<AssetType, StableType>): &mut vector<String> {
    &mut proposal.details
}

// === Test Functions ===

#[test_only]
/// Create a minimal proposal for testing
public fun new_for_testing<AssetType, StableType>(
    dao_id: address,
    proposer: address,
    liquidity_provider: Option<address>,
    title: String,
    metadata: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
    outcome_creators: vector<address>,
    outcome_count: u8,
    review_period_ms: u64,
    trading_period_ms: u64,
    min_asset_liquidity: u64,
    min_stable_liquidity: u64,
    twap_start_delay: u64,
    twap_initial_observation: u128,
    twap_step_max: u64,
    twap_threshold: SignedU128,
    amm_total_fee_bps: u64,
    winning_outcome: Option<u64>,
    fee_escrow: Balance<StableType>,
    treasury_address: address,
    intent_specs: vector<Option<InitActionSpecs>>,
    ctx: &mut TxContext
): Proposal<AssetType, StableType> {
    Proposal {
        id: object::new(ctx),
        dao_id: object::id_from_address(dao_id),
        queued_proposal_id: object::id_from_address(@0x0),
        state: STATE_PREMARKET,
        proposer,
        liquidity_provider,
        withdraw_only_mode: false,
        used_quota: false, // Default to false for testing
        escrow_id: option::none(),
        market_state_id: option::none(),
        conditional_treasury_caps: bag::new(ctx),
        conditional_metadata: bag::new(ctx),
        title,
        details: outcome_details,
        metadata,
        timing: ProposalTiming {
            created_at: 0,
            market_initialized_at: option::none(),
            review_period_ms,
            trading_period_ms,
            last_twap_update: 0,
            twap_start_delay,
        },
        liquidity_config: LiquidityConfig {
            min_asset_liquidity,
            min_stable_liquidity,
            asset_amounts: vector::empty(),
            stable_amounts: vector::empty(),
            uses_dao_liquidity: false,
        },
        twap_config: TwapConfig {
            twap_prices: vector::empty(),
            twap_initial_observation,
            twap_step_max,
            twap_threshold,
        },
        outcome_data: OutcomeData {
            outcome_count: outcome_count as u64,
            outcome_messages,
            outcome_creators,
            outcome_creator_fees: vector::tabulate!(outcome_count as u64, |_| 0u64),  // Initialize with 0 fees
            intent_specs,
            actions_per_outcome: vector::tabulate!(outcome_count as u64, |_| 0),
            winning_outcome,
        },
        amm_total_fee_bps,
        conditional_liquidity_ratio_percent: 50,  // 50% (base 100, not bps!)
        fee_escrow,
        treasury_address,
    }
}

#[test_only]
/// Gets a mutable reference to the token escrow of the proposal
public fun test_get_coin_escrow<AssetType, StableType>(
    escrow: &mut coin_escrow::TokenEscrow<AssetType, StableType>,
): &mut coin_escrow::TokenEscrow<AssetType, StableType> {
    escrow
}

#[test_only]
/// Gets the market state through the token escrow
public fun test_get_market_state<AssetType, StableType>(
    escrow: &coin_escrow::TokenEscrow<AssetType, StableType>,
): &market_state::MarketState {
    escrow.get_market_state()
}


// === Additional View Functions ===

/// Get proposal ID
public fun id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
    object::id(proposal)
}

/// Get proposal address (for testing)
public fun id_address<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): address {
    object::uid_to_address(&proposal.id)
}

// === Conditional Coin Management ===

/// Add a conditional coin treasury cap and metadata to proposal
/// Must be called once per outcome per side (asset/stable)
/// The coin will be validated and its metadata updated according to DAO config
public fun add_conditional_coin<AssetType, StableType, ConditionalCoinType>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_index: u64,
    is_asset: bool,  // true for asset-conditional, false for stable-conditional
    mut treasury_cap: TreasuryCap<ConditionalCoinType>,
    mut metadata: CoinMetadata<ConditionalCoinType>,
    coin_config: &ConditionalCoinConfig,
    asset_type_name: &String,  // Name of AssetType (e.g., "SUI")
    stable_type_name: &String, // Name of StableType (e.g., "USDC")
) {
    assert!(proposal.state == STATE_PREMARKET, EInvalidState);
    assert!(outcome_index < proposal.outcome_data.outcome_count, EOutcomeOutOfBounds);

    // Create key for this conditional coin
    let key = ConditionalCoinKey { outcome_index, is_asset };

    // Check not already set
    assert!(!bag::contains(&proposal.conditional_treasury_caps, key), EConditionalCoinAlreadySet);

    // Validate coin meets requirements
    coin_validation::validate_conditional_coin(&treasury_cap, &metadata);

    // Update metadata with DAO naming pattern: c_<outcome>_<ASSET|STABLE>
    update_conditional_coin_metadata(
        &mut metadata,
        coin_config,
        outcome_index,
        if (is_asset) { asset_type_name } else { stable_type_name },
    );

    // Store in bags
    bag::add(&mut proposal.conditional_treasury_caps, key, treasury_cap);
    bag::add(&mut proposal.conditional_metadata, key, metadata);
}

/// Update conditional coin metadata with DAO naming pattern
/// Pattern: c_<outcome_index>_<ASSET_NAME>
fun update_conditional_coin_metadata<ConditionalCoinType>(
    metadata: &mut CoinMetadata<ConditionalCoinType>,
    coin_config: &ConditionalCoinConfig,
    outcome_index: u64,
    base_coin_name: &String,
) {
    use std::ascii;
    use sui::url;

    // Build name: prefix + outcome_index + _ + base_coin_name
    let mut name_bytes = vector::empty<u8>();

    // Add prefix (e.g., "c_") if configured
    let prefix_opt = dao_config::coin_name_prefix(coin_config);
    if (prefix_opt.is_some()) {
        let prefix = prefix_opt.destroy_some();
        let prefix_bytes = ascii::as_bytes(&prefix);
        let mut i = 0;
        while (i < prefix_bytes.length()) {
            name_bytes.push_back(*prefix_bytes.borrow(i));
            i = i + 1;
        };
    } else {
        prefix_opt.destroy_none();
    };

    // Add outcome index if configured
    if (dao_config::use_outcome_index(coin_config)) {
        // Convert outcome_index to string
        let index_str = u64_to_ascii(outcome_index);
        let index_bytes = ascii::as_bytes(&index_str);
        let mut i = 0;
        while (i < index_bytes.length()) {
            name_bytes.push_back(*index_bytes.borrow(i));
            i = i + 1;
        };
        name_bytes.push_back(95u8); // '_' character
    };

    // Add base coin name
    {
        let base_bytes = string::as_bytes(base_coin_name);
        let mut i = 0;
        while (i < base_bytes.length()) {
            name_bytes.push_back(*base_bytes.borrow(i));
            i = i + 1;
        };
    };

    // Update metadata (need to use coin::update_* functions if available)
    // For now, just validate - actual metadata update requires special capabilities
    // This will be handled when we integrate with coin framework properly
}

/// Helper: Convert u64 to ASCII string
fun u64_to_ascii(mut num: u64): AsciiString {
    use std::ascii;

    if (num == 0) {
        return ascii::string(b"0")
    };

    let mut digits = vector::empty<u8>();
    while (num > 0) {
        let digit = ((num % 10) as u8) + 48; // ASCII '0' = 48
        vector::push_back(&mut digits, digit);
        num = num / 10;
    };

    // Reverse digits
    vector::reverse(&mut digits);
    ascii::string(digits)
}

// === LP Preferences Dynamic Field Management ===

/// Get mutable reference to proposal's UID for dynamic field operations
/// Public to allow other packages (e.g., futarchy_governance) to use dynamic fields
public fun borrow_uid_mut<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>
): &mut UID {
    &mut proposal.id
}

/// Get immutable reference to proposal's UID for dynamic field reads
/// Public to allow other packages (e.g., futarchy_governance) to use dynamic fields
public fun borrow_uid<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>
): &UID {
    &proposal.id
}

#[test_only]
/// Simplified test helper: creates a REAL proposal with sensible defaults
/// Can configure state (FINALIZED), outcome_count, and winning_outcome for testing
public fun create_test_proposal<AssetType, StableType>(
    outcome_count: u8,
    winning_outcome: u64,
    is_finalized: bool,
    ctx: &mut TxContext,
): Proposal<AssetType, StableType> {
    use std::string;

    let outcome_messages = vector::tabulate!(outcome_count as u64, |i| {
        string::utf8(b"Outcome")
    });

    let outcome_details = vector::tabulate!(outcome_count as u64, |i| {
        string::utf8(b"Details")
    });

    let outcome_creators = vector::tabulate!(outcome_count as u64, |_| @0xAAA);

    let intent_specs = vector::tabulate!(outcome_count as u64, |_| option::none());

    let mut proposal = new_for_testing<AssetType, StableType>(
        @0x1,                       // dao_id
        @0x2,                       // proposer
        option::some(@0x3),         // liquidity_provider
        string::utf8(b"Test"),      // title
        string::utf8(b"Metadata"),  // metadata
        outcome_messages,
        outcome_details,
        outcome_creators,
        outcome_count,
        60000,                      // review_period_ms (1 min)
        120000,                     // trading_period_ms (2 min)
        1000,                       // min_asset_liquidity
        1000,                       // min_stable_liquidity
        30000,                      // twap_start_delay
        1000000000000000000u128,    // twap_initial_observation
        10000,                      // twap_step_max
        signed::from_u128(500000000000000000u128),      // twap_threshold
        30,                         // amm_total_fee_bps (0.3%)
        option::some(winning_outcome),
        sui::balance::zero<StableType>(),
        @0x4,                       // treasury_address
        intent_specs,
        ctx
    );

    if (is_finalized) {
        set_state(&mut proposal, STATE_FINALIZED);
    };

    proposal
}

#[test_only]
/// Destroy a proposal for testing - handles cleanup of all internal structures
public fun destroy_for_testing<AssetType, StableType>(proposal: Proposal<AssetType, StableType>) {
    let Proposal {
        id,
        queued_proposal_id: _,
        state: _,
        dao_id: _,
        proposer: _,
        liquidity_provider: _,
        withdraw_only_mode: _,
        used_quota: _,
        escrow_id: _,
        market_state_id: _,
        conditional_treasury_caps,
        conditional_metadata,
        title: _,
        details: _,
        metadata: _,
        timing: ProposalTiming {
            created_at: _,
            market_initialized_at: _,
            review_period_ms: _,
            trading_period_ms: _,
            last_twap_update: _,
            twap_start_delay: _,
        },
        liquidity_config: LiquidityConfig {
            min_asset_liquidity: _,
            min_stable_liquidity: _,
            asset_amounts: _,
            stable_amounts: _,
            uses_dao_liquidity: _,
        },
        twap_config: TwapConfig {
            twap_prices: _,
            twap_initial_observation: _,
            twap_step_max: _,
            twap_threshold: _,
        },
        outcome_data: OutcomeData {
            outcome_count: _,
            outcome_messages: _,
            outcome_creators: _,
            outcome_creator_fees: _,
            intent_specs: _,
            actions_per_outcome: _,
            winning_outcome: _,
        },
        amm_total_fee_bps: _,
        conditional_liquidity_ratio_percent: _,
        fee_escrow,
        treasury_address: _,
    } = proposal;

    // Destroy bags (must be empty for testing)
    bag::destroy_empty(conditional_treasury_caps);
    bag::destroy_empty(conditional_metadata);
    fee_escrow.destroy_zero();

    object::delete(id);
}
