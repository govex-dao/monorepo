module futarchy_lifecycle::launchpad;

use std::ascii;
use std::string::{String};
use std::type_name::{Self, TypeName};
use std::option::{Self as option, Option};
use std::vector;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::clock::{Clock};
use sui::event;
use sui::dynamic_field as df;
use sui::object::{Self, UID, ID};
use sui::tx_context::TxContext;
use sui::table;
use futarchy_lifecycle::factory;
use futarchy_types::action_specs;
use futarchy_actions::init_actions;
use account_protocol::account::{Self, Account};
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_core::priority_queue::ProposalQueue;
use futarchy_markets::{fee, account_spot_pool::{Self, AccountSpotPool}};
use futarchy_one_shot_utils::math;
use account_extensions::extensions::Extensions;

// === Witnesses ===
public struct LaunchpadWitness has drop {}

// === Errors ===
const ERaiseStillActive: u64 = 0;
const ERaiseNotActive: u64 = 1;
const EDeadlineNotReached: u64 = 2;
const EMinRaiseNotMet: u64 = 3;
const EMinRaiseAlreadyMet: u64 = 4;
const ENotAContributor: u64 = 6;
const EInvalidStateForAction: u64 = 7;
const EWrongTotalSupply: u64 = 9;
const EReentrancy: u64 = 10;
const EArithmeticOverflow: u64 = 11;
const ENotUSDC: u64 = 12;
const EZeroContribution: u64 = 13;
const EStableTypeNotAllowed: u64 = 14;
const ENotTheCreator: u64 = 15;
const EInvalidActionData: u64 = 16;
const ESettlementNotStarted: u64 = 101;
const ESettlementInProgress: u64 = 102;
const ESettlementAlreadyDone: u64 = 103;
const ENotEligibleForTokens: u64 = 104;
const ECapChangeAfterDeadline: u64 = 105;
const ECapHeapInvariant: u64 = 106;
const ESettlementAlreadyStarted: u64 = 107;
const EInvalidSettlementState: u64 = 108;
const ETooManyUniqueCaps: u64 = 109;
const ETooManyInitActions: u64 = 110;
const EDaoNotPreCreated: u64 = 111;
const EDaoAlreadyPreCreated: u64 = 112;
const EIntentsAlreadyLocked: u64 = 113;
const EResourcesNotFound: u64 = 114;
const EInitActionsFailed: u64 = 115;

// === Constants ===
/// The duration for every raise is fixed. 14 days in milliseconds.
const LAUNCHPAD_DURATION_MS: u64 = 1_209_600_000;
/// A fixed period after a successful raise for contributors to claim tokens
/// before the creator can sweep any remaining dust. 14 days in milliseconds.
const CLAIM_PERIOD_DURATION_MS: u64 = 1_209_600_000;

const STATE_FUNDING: u8 = 0;
const STATE_SUCCESSFUL: u8 = 1;
const STATE_FAILED: u8 = 2;

const DEFAULT_AMM_TOTAL_FEE_BPS: u64 = 30; // 0.3% default AMM fee
const MAX_UNIQUE_CAPS: u64 = 1000; // Maximum number of unique cap values to prevent unbounded heap

// === Safety Limits ===
const MAX_INIT_ACTIONS: u64 = 20; // Maximum number of init actions to prevent gas exhaustion
const MAX_GAS_PER_ACTION: u64 = 1_000_000; // Estimated max gas per action

// === Structs ===

/// A one-time witness for module initialization
public struct LAUNCHPAD has drop {}

// === IMPORTANT: Stable Coin Integration ===
// This module supports any stable coin that has been allowed by the factory.
// The creator of a raise sets the minimum raise amount for that specific launchpad.
// 
// Common stable coins and their addresses:
// - USDC Mainnet: 0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC
// - USDC Testnet: 0xa1ec7fc00a6f40db9693ad1415d0c193ad3906494428cf252621037bd7117e29::usdc::USDC
// 
// To add a new stable coin type that can be used in launchpads, use factory::add_allowed_stable_type.

// === Scalability Design ===
// This launchpad uses dynamic fields instead of tables for contributor storage.
// Benefits:
// - No hard limits on number of contributors (can handle 100,000+ easily)
// - Each contributor's data is stored separately, improving gas efficiency
// - Supports large raises ($10M+) with many small contributors
// - Only the accessed contributor data is loaded during operations

/// Key type for storing contributor data as dynamic fields
/// This approach allows unlimited contributors without table size constraints
public struct ContributorKey has copy, drop, store {
    contributor: address,
}

/// Key types for storing unshared DAO components
public struct DaoAccountKey has copy, drop, store {}
public struct DaoQueueKey has copy, drop, store {}
public struct DaoPoolKey has copy, drop, store {}

/// Key for tracking pending intent specs (removed - using dao_params instead)
// public struct PendingIntentsKey has copy, drop, store {}

/// Per-contributor record with amount and cap
public struct Contribution has store, drop, copy {
    amount: u64,
    max_total: u64, // cap; u64::MAX means "no cap"
}

/// Key type for storing refunds separately from contributions
public struct RefundKey has copy, drop, store {
    contributor: address,
}

/// Record for tracking refunds due to hard cap
public struct RefundRecord has store, drop {
    amount: u64,
}

/// Cap-bin dynamic fields for aggregating contributions by cap
public struct ThresholdKey has copy, drop, store { 
    cap: u64 
}

public struct ThresholdBin has store, drop {
    total: u64,  // sum of amounts for this cap
    count: u64,  // number of contributors with this cap
}

/// Settlement crank state for processing caps
public struct CapSettlement has key, store {
    id: UID,
    raise_id: ID,
    heap: vector<u64>,   // max-heap of caps
    size: u64,           // heap size
    running_sum: u64,    // C_k as we walk from high cap to low
    final_total: u64,    // T* once found
    done: bool,
}

/// Main object for a DAO fundraising launchpad.
/// RaiseToken is the governance token being sold.
/// StableCoin is the currency used for contributions (must be allowed by factory).
public struct Raise<phantom RaiseToken, phantom StableCoin> has key, store {
    id: UID,
    creator: address,
    state: u8,
    total_raised: u64,
    min_raise_amount: u64,
    max_raise_amount: Option<u64>, // The new creator-defined hard cap
    deadline_ms: u64,
    /// Balance of the token being sold to contributors.
    raise_token_vault: Balance<RaiseToken>,
    /// Amount of tokens being sold.
    tokens_for_sale_amount: u64,
    /// Vault for the stable coins contributed by users.
    stable_coin_vault: Balance<StableCoin>,
    /// Number of unique contributors (contributions stored as dynamic fields)
    contributor_count: u64,
    description: String,
    // All parameters required to create the DAO are stored here.
    dao_params: DAOParameters,
    /// TreasuryCap stored until DAO creation
    treasury_cap: Option<TreasuryCap<RaiseToken>>,
    /// Reentrancy guard flag
    claiming: bool,
    /// Cap-aware accounting
    thresholds: vector<u64>,       // unique caps we've seen
    settlement_done: bool,
    settlement_in_progress: bool,  // Track if settlement has started
    final_total_eligible: u64,     // T* after enforcing caps
    final_raise_amount: u64,       // The final amount after applying the hard cap
    /// Pre-created DAO ID (if DAO was created before raise)
    dao_id: Option<ID>,
    /// Whether init actions can still be added
    intents_locked: bool,
}

/// Stores all parameters needed for DAO creation to keep the Raise object clean.
public struct DAOParameters has store, drop, copy {
    dao_name: ascii::String,
    dao_description: String,
    icon_url_string: ascii::String,
    review_period_ms: u64,
    trading_period_ms: u64,
    amm_twap_start_delay: u64,
    amm_twap_step_max: u64,
    amm_twap_initial_observation: u128,
    twap_threshold: u64,
    max_outcomes: u64,
    agreement_lines: vector<String>,
    agreement_difficulties: vector<u64>,
    // Founder reward parameters
    founder_reward_params: Option<FounderRewardParams>,
    // Whether init actions must all succeed (if false, raise fails on init failure)
    init_actions_must_succeed: bool,
    // Staged init action specifications
    init_action_specs: Option<action_specs::InitActionSpecs>,
}

/// Parameters for founder rewards based on price performance
public struct FounderRewardParams has store, drop, copy {
    /// Address to receive founder rewards
    founder_address: address,
    /// Percentage of tokens reserved for founder (in basis points, max 2000 = 20%)
    founder_allocation_bps: u64,
    /// Minimum price ratio to unlock rewards (scaled by 1e9, e.g., 2e9 = 2x)
    min_price_ratio: u64,
    /// Time after which rewards can be claimed (milliseconds from DAO creation)
    unlock_delay_ms: u64,
    /// Whether rewards vest linearly based on price performance
    linear_vesting: bool,
    /// Maximum price ratio for full vesting (if linear_vesting)
    max_price_ratio: u64,
}

// === Events ===

public struct InitActionsStaged has copy, drop {
    raise_id: ID,
    action_count: u64,
}

public struct InitActionsFailed has copy, drop {
    raise_id: ID,
    action_count: u64,
    timestamp: u64,
}

public struct FailedRaiseCleanup has copy, drop {
    raise_id: ID,
    dao_id: ID,
    timestamp: u64,
}

public struct RaiseCreated has copy, drop {
    raise_id: ID,
    creator: address,
    raise_token_type: String,
    stable_coin_type: String,
    min_raise_amount: u64,
    tokens_for_sale: u64,
    deadline_ms: u64,
    description: String,
}

public struct ContributionAdded has copy, drop {
    raise_id: ID,
    contributor: address,
    amount: u64,
    new_total_raised: u64,
}

public struct ContributionAddedCapped has copy, drop {
    raise_id: ID,
    contributor: address,
    amount: u64,
    cap: u64,                // max_total specified
    new_naive_total: u64,    // naive running sum (pre-cap settlement)
}

public struct SettlementStarted has copy, drop {
    raise_id: ID,
    caps_count: u64,
}

public struct SettlementStep has copy, drop {
    raise_id: ID,
    processed_cap: u64,
    added_amount: u64,
    running_sum: u64,
    next_cap: u64,
}

public struct SettlementFinalized has copy, drop {
    raise_id: ID,
    final_total: u64,
}

public struct RaiseSuccessful has copy, drop {
    raise_id: ID,
    total_raised: u64,
}

public struct RaiseFailed has copy, drop {
    raise_id: ID,
    total_raised: u64,
    min_raise_amount: u64,
}

public struct TokensClaimed has copy, drop {
    raise_id: ID,
    contributor: address,
    contribution_amount: u64,
    tokens_claimed: u64,
}

public struct RefundClaimed has copy, drop {
    raise_id: ID,
    contributor: address,
    refund_amount: u64,
}

public struct FounderRewardsConfigured has copy, drop {
    raise_id: ID,
    founder_address: address,
    allocation_bps: u64,
    tiers: u64,
}

// === Init ===

fun init(_witness: LAUNCHPAD, _ctx: &mut TxContext) {
    // No initialization needed for simplified version
}

// === Public Functions ===

/// Pre-create a DAO for a raise but keep it unshared
/// This allows adding init intents before the raise starts
public fun pre_create_dao_for_raise<RaiseToken: drop, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    factory: &mut factory::Factory,
    extensions: &Extensions,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<sui::sui::SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Only creator can pre-create DAO
    assert!(ctx.sender() == raise.creator, ENotTheCreator);
    // Can only pre-create before raise starts
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);
    // Can't pre-create if already created
    assert!(raise.dao_id.is_none(), EInvalidStateForAction);
    
    // Extract the TreasuryCap
    let treasury_cap = if (raise.treasury_cap.is_some()) {
        option::some(raise.treasury_cap.extract())
    } else {
        option::none()
    };
    
    let params = &raise.dao_params;
    
    // Create DAO WITHOUT sharing it yet
    let (account, queue, spot_pool) = factory::create_dao_unshared<RaiseToken, StableCoin>(
        factory,
        extensions,
        fee_manager,
        payment,
        1, // min_asset_amount
        1, // min_stable_amount
        params.dao_name,
        params.icon_url_string,
        params.review_period_ms,
        params.trading_period_ms,
        params.amm_twap_start_delay,
        params.amm_twap_step_max,
        params.amm_twap_initial_observation,
        params.twap_threshold,
        DEFAULT_AMM_TOTAL_FEE_BPS,
        params.dao_description,
        params.max_outcomes,
        treasury_cap,
        clock,
        ctx
    );
    
    // Store DAO ID
    raise.dao_id = option::some(object::id(&account));
    
    // Store unshared components in dynamic fields
    df::add(&mut raise.id, DaoAccountKey {}, account);
    df::add(&mut raise.id, DaoQueueKey {}, queue);
    df::add(&mut raise.id, DaoPoolKey {}, spot_pool);
    
    // Init action specs are now stored in dao_params.init_action_specs
}

/// Add init actions to the pre-created DAO
/// Must be called before the raise is locked
public entry fun add_init_actions_to_dao<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    action_types: vector<type_name::TypeName>,
    action_data: vector<vector<u8>>,
    ctx: &mut TxContext,
) {
    // Only creator can add actions
    assert!(ctx.sender() == raise.creator, ENotTheCreator);
    // Can't add actions after locked
    assert!(!raise.intents_locked, EIntentsAlreadyLocked);
    // DAO must be pre-created
    assert!(raise.dao_id.is_some(), EDaoNotPreCreated);
    // Vectors must have same length
    assert!(vector::length(&action_types) == vector::length(&action_data), EInvalidActionData);

    // Get or create init specs
    let mut specs = if (raise.dao_params.init_action_specs.is_some()) {
        *raise.dao_params.init_action_specs.borrow()
    } else {
        action_specs::new_init_specs()
    };

    // Check we haven't exceeded max actions limit
    let new_action_count = vector::length(&action_types);
    let current_count = action_specs::action_count(&specs);
    assert!(current_count + new_action_count <= MAX_INIT_ACTIONS, ETooManyInitActions);

    // Add new actions
    let mut i = 0;
    while (i < new_action_count) {
        action_specs::add_action(
            &mut specs,
            *vector::borrow(&action_types, i),
            *vector::borrow(&action_data, i)
        );
        i = i + 1;
    };

    // Update dao params
    raise.dao_params.init_action_specs = option::some(specs);
}

/// Lock intents - no more can be added after this
public entry fun lock_intents_and_start_raise<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    ctx: &mut TxContext,
) {
    // Only creator can lock intents
    assert!(ctx.sender() == raise.creator, ENotTheCreator);
    // Can only lock once
    assert!(!raise.intents_locked, EInvalidStateForAction);
    
    raise.intents_locked = true;
    // Raise can now begin accepting contributions
}

/// Create a raise that sells tokens with optional founder rewards.
/// `StableCoin` must be an allowed type in the factory.
public entry fun create_raise_with_founder_rewards<RaiseToken: drop, StableCoin: drop>(
    factory: &factory::Factory,
    treasury_cap: TreasuryCap<RaiseToken>,
    tokens_for_raise: Coin<RaiseToken>,
    min_raise_amount: u64,
    max_raise_amount: Option<u64>, // Add the new parameter
    description: String,
    // DAOParameters passed as individual fields for entry function compatibility
    dao_name: ascii::String,
    dao_description: String,
    icon_url_string: ascii::String,
    review_period_ms: u64,
    trading_period_ms: u64,
    amm_twap_start_delay: u64,
    amm_twap_step_max: u64,
    amm_twap_initial_observation: u128,
    twap_threshold: u64,
    max_outcomes: u64,
    agreement_lines: vector<String>,
    agreement_difficulties: vector<u64>,
    // Founder reward parameters
    with_founder_rewards: bool,
    founder_address: address,
    founder_allocation_bps: u64,
    min_price_ratio: u64,
    unlock_delay_ms: u64,
    linear_vesting: bool,
    max_price_ratio: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate founder reward parameters if enabled
    let founder_params = if (with_founder_rewards) {
        assert!(founder_allocation_bps <= 2000, EInvalidStateForAction); // Max 20%
        assert!(min_price_ratio >= 1_000_000_000, EInvalidStateForAction); // At least 1x
        assert!(max_price_ratio >= min_price_ratio, EInvalidStateForAction);
        
        option::some(FounderRewardParams {
            founder_address,
            founder_allocation_bps,
            min_price_ratio,
            unlock_delay_ms,
            linear_vesting,
            max_price_ratio,
        })
    } else {
        option::none()
    };
    
    // Calculate actual tokens for sale (excluding founder allocation)
    let total_supply = treasury_cap.total_supply();
    let tokens_for_sale_amount = if (with_founder_rewards) {
        // Reserve founder allocation
        let founder_reserve = total_supply * founder_allocation_bps / 10000;
        assert!(tokens_for_raise.value() == total_supply - founder_reserve, EWrongTotalSupply);
        tokens_for_raise.value()
    } else {
        // Full supply for sale
        assert!(tokens_for_raise.value() == total_supply, EWrongTotalSupply);
        tokens_for_raise.value()
    };

    // Check that StableCoin is allowed
    assert!(factory::is_stable_type_allowed<StableCoin>(factory), EStableTypeNotAllowed);

    // Validate the new parameter
    if (option::is_some(&max_raise_amount)) {
        assert!(*option::borrow(&max_raise_amount) >= min_raise_amount, EInvalidStateForAction);
    };
    
    let dao_params = DAOParameters {
        dao_name, dao_description, icon_url_string, review_period_ms, trading_period_ms,
        amm_twap_start_delay, amm_twap_step_max, amm_twap_initial_observation,
        twap_threshold, max_outcomes, agreement_lines, agreement_difficulties,
        founder_reward_params: founder_params,
        init_actions_must_succeed: true,
        init_action_specs: option::none(),
    };
    
    init_raise_with_founder<RaiseToken, StableCoin>(
        treasury_cap, tokens_for_raise, min_raise_amount, max_raise_amount, description, dao_params, clock, ctx
    );
}

/// Create a raise that sells 100% of the token supply (backward compatibility).
public entry fun create_raise<RaiseToken: drop, StableCoin: drop>(
    factory: &factory::Factory,
    treasury_cap: TreasuryCap<RaiseToken>,
    tokens_for_raise: Coin<RaiseToken>,
    min_raise_amount: u64,
    max_raise_amount: Option<u64>, // Add the new parameter
    description: String,
    dao_name: ascii::String,
    dao_description: String,
    icon_url_string: ascii::String,
    review_period_ms: u64,
    trading_period_ms: u64,
    amm_twap_start_delay: u64,
    amm_twap_step_max: u64,
    amm_twap_initial_observation: u128,
    twap_threshold: u64,
    max_outcomes: u64,
    agreement_lines: vector<String>,
    agreement_difficulties: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // CRITICAL: Ensure we're selling 100% of the total supply
    assert!(tokens_for_raise.value() == treasury_cap.total_supply(), EWrongTotalSupply);

    // Check that StableCoin is allowed
    assert!(factory::is_stable_type_allowed<StableCoin>(factory), EStableTypeNotAllowed);

    // Validate the new parameter
    if (option::is_some(&max_raise_amount)) {
        assert!(*option::borrow(&max_raise_amount) >= min_raise_amount, EInvalidStateForAction);
    };
    
    let dao_params = DAOParameters {
        dao_name, dao_description, icon_url_string, review_period_ms, trading_period_ms,
        amm_twap_start_delay, amm_twap_step_max, amm_twap_initial_observation,
        twap_threshold, max_outcomes, agreement_lines, agreement_difficulties,
        founder_reward_params: option::none(),
        init_actions_must_succeed: true,
        init_action_specs: option::none(),
    };
    
    init_raise<RaiseToken, StableCoin>(
        treasury_cap, tokens_for_raise, min_raise_amount, max_raise_amount, description, dao_params, clock, ctx
    );
}

/// Contribute with a cap: max final total raise you accept.
/// cap = u64::max_value() means "no cap".
public entry fun contribute_with_cap<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    contribution: Coin<StableCoin>,
    cap: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(raise.state == STATE_FUNDING, ERaiseNotActive);
    assert!(clock.timestamp_ms() < raise.deadline_ms, ERaiseStillActive);

    let contributor = ctx.sender();
    let amount = contribution.value();
    assert!(amount > 0, EZeroContribution);
    
    // SECURITY: Cap must be reasonable (at least the contribution amount)
    assert!(cap >= amount, EInvalidStateForAction);

    // Deposit coins into vault + naive total accounting
    raise.stable_coin_vault.join(contribution.into_balance());
    assert!(raise.total_raised <= std::u64::max_value!() - amount, EArithmeticOverflow);
    raise.total_raised = raise.total_raised + amount;

    // Contributor DF: (amount, max_total)
    let key = ContributorKey { contributor };

    if (df::exists_(&raise.id, key)) {
        let rec: &mut Contribution = df::borrow_mut(&mut raise.id, key);
        // SECURITY: For existing contributors, cap must match or use update_cap
        assert!(rec.max_total == cap, ECapChangeAfterDeadline);
        assert!(rec.amount <= std::u64::max_value!() - amount, EArithmeticOverflow);
        rec.amount = rec.amount + amount;
        
        // SECURITY: Updated total cap must still be reasonable
        assert!(rec.max_total >= rec.amount, EInvalidStateForAction);
    } else {
        df::add(&mut raise.id, key, Contribution { amount, max_total: cap });
        raise.contributor_count = raise.contributor_count + 1;

        // Ensure a cap-bin exists and index it if first time seen
        let tkey = ThresholdKey { cap };
        if (!df::exists_(&raise.id, tkey)) {
            // Check we haven't exceeded maximum unique caps
            assert!(vector::length(&raise.thresholds) < MAX_UNIQUE_CAPS, ETooManyUniqueCaps);
            df::add(&mut raise.id, tkey, ThresholdBin { total: 0, count: 0 });
            vector::push_back(&mut raise.thresholds, cap);
        };
    };

    // Update the cap-bin aggregate
    {
        let bin: &mut ThresholdBin = df::borrow_mut(&mut raise.id, ThresholdKey { cap });
        assert!(bin.total <= std::u64::max_value!() - amount, EArithmeticOverflow);
        bin.total = bin.total + amount;
        bin.count = bin.count + 1;
    };

    event::emit(ContributionAddedCapped {
        raise_id: object::id(raise),
        contributor,
        amount,
        cap,
        new_naive_total: raise.total_raised,
    });
}

/// Backward compatibility: no-cap contribution just forwards with cap = MAX
public entry fun contribute<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    contribution: Coin<StableCoin>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    contribute_with_cap<RaiseToken, StableCoin>(
        raise, contribution, std::u64::max_value!(), clock, ctx
    )
}

/// Optional: explicit cap update before deadline (moves contributor's amount across bins)
public entry fun update_cap<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    new_cap: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(clock.timestamp_ms() < raise.deadline_ms, ECapChangeAfterDeadline);
    // SECURITY: Cannot update caps after settlement started
    assert!(!raise.settlement_in_progress && !raise.settlement_done, ESettlementAlreadyStarted);
    
    let who = ctx.sender();
    let key = ContributorKey { contributor: who };
    assert!(df::exists_(&raise.id, key), ENotAContributor);

    // Get the existing contribution
    let rec: &Contribution = df::borrow(&raise.id, key);
    let old_cap = rec.max_total;
    let amount = rec.amount;
    
    if (old_cap == new_cap) return;
    
    // SECURITY: New cap must be at least the contribution amount
    assert!(new_cap >= amount, EInvalidStateForAction);

    // create bin for new cap if needed
    let new_tk = ThresholdKey { cap: new_cap };
    if (!df::exists_(&raise.id, new_tk)) {
        // Check we haven't exceeded maximum unique caps
        assert!(vector::length(&raise.thresholds) < MAX_UNIQUE_CAPS, ETooManyUniqueCaps);
        df::add(&mut raise.id, new_tk, ThresholdBin { total: 0, count: 0 });
        vector::push_back(&mut raise.thresholds, new_cap);
    };

    // move amount across bins
    {
        let old_bin: &mut ThresholdBin = df::borrow_mut(&mut raise.id, ThresholdKey { cap: old_cap });
        assert!(old_bin.total >= amount, EArithmeticOverflow);
        old_bin.total = old_bin.total - amount;
        assert!(old_bin.count > 0, EArithmeticOverflow);
        old_bin.count = old_bin.count - 1;
    };
    {
        let new_bin: &mut ThresholdBin = df::borrow_mut(&mut raise.id, new_tk);
        assert!(new_bin.total <= std::u64::max_value!() - amount, EArithmeticOverflow);
        new_bin.total = new_bin.total + amount;
        new_bin.count = new_bin.count + 1;
    };

    // Update the contributor's record
    let rec_mut: &mut Contribution = df::borrow_mut(&mut raise.id, key);
    rec_mut.max_total = new_cap;
}

// === Max-heap helpers over vector<u64> ===
fun parent(i: u64): u64 { if (i == 0) 0 else (i - 1) / 2 }
fun left(i: u64): u64 { 2 * i + 1 }
fun right(i: u64): u64 { 2 * i + 2 }

fun heapify_down(v: &mut vector<u64>, mut i: u64, size: u64) {
    loop {
        let l = left(i);
        let r = right(i);
        let mut largest = i;

        if (l < size && *vector::borrow(v, l) > *vector::borrow(v, largest)) {
            largest = l;
        };
        if (r < size && *vector::borrow(v, r) > *vector::borrow(v, largest)) {
            largest = r;
        };
        if (largest == i) break;
        vector::swap(v, i, largest);
        i = largest;
    }
}

fun build_max_heap(v: &mut vector<u64>) {
    let sz = vector::length(v);
    let mut i = if (sz == 0) { 0 } else { (sz - 1) / 2 };
    loop {
        heapify_down(v, i, sz);
        if (i == 0) break;
        i = i - 1;
    };
}

fun heap_peek(v: &vector<u64>, size: u64): u64 {
    if (size == 0) 0 else *vector::borrow(v, 0)
}

fun heap_pop(v: &mut vector<u64>, size_ref: &mut u64): u64 {
    assert!(*size_ref > 0, ECapHeapInvariant);
    let last = *size_ref - 1;
    let top = *vector::borrow(v, 0);
    if (last != 0) {
        vector::swap(v, 0, last);
    };
    let _ = vector::pop_back(v);
    *size_ref = last;
    if (last > 0) {
        heapify_down(v, 0, last);
    };
    top
}

/// Start settlement: snapshot caps into a heap
public fun begin_settlement<RT, SC>(
    raise: &mut Raise<RT, SC>,
    clock: &Clock,
    ctx: &mut TxContext,
): CapSettlement {
    assert!(clock.timestamp_ms() >= raise.deadline_ms, EDeadlineNotReached);
    assert!(!raise.settlement_done && !raise.settlement_in_progress, ESettlementAlreadyDone);
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);
    
    // SECURITY: Mark that settlement has started to prevent bin/cap manipulation
    raise.settlement_in_progress = true;

    // Copy caps vector into heap
    let mut heap = raise.thresholds; // copy
    build_max_heap(&mut heap);
    let size = vector::length(&heap);

    let s = CapSettlement {
        id: object::new(ctx),
        raise_id: object::id(raise),
        heap,
        size,
        running_sum: 0,
        final_total: 0,
        done: false,
    };

    event::emit(SettlementStarted { raise_id: object::id(raise), caps_count: size });
    s
}

/// Crank up to `steps` caps. Once done is true, final_total is T*.
public entry fun crank_settlement<RT, SC>(
    raise: &mut Raise<RT, SC>,
    s: &mut CapSettlement,
    steps: u64,
) {
    assert!(object::id(raise) == s.raise_id, EInvalidStateForAction);
    assert!(!s.done, ESettlementInProgress);
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);
    assert!(raise.settlement_in_progress, EInvalidSettlementState);
    
    // SECURITY: Limit steps to prevent DOS
    let actual_steps = if (steps > 100) { 100 } else { steps };

    let mut i = 0;
    while (i < actual_steps && s.size > 0 && !s.done) {
        // Pop the highest cap
        let cap = heap_pop(&mut s.heap, &mut s.size);

        // Pull bin total; remove bin to avoid double counting
        let bin: ThresholdBin = df::remove(&mut raise.id, ThresholdKey { cap });
        let added = bin.total;

        // Update running sum
        assert!(s.running_sum <= std::u64::max_value!() - added, EArithmeticOverflow);
        s.running_sum = s.running_sum + added;

        // Peek next cap (0 if none)
        let next_cap = heap_peek(&s.heap, s.size);

        // Check fixed-point window: M_{k+1} < C_k <= M_k
        if (s.running_sum > next_cap && s.running_sum <= cap) {
            s.final_total = s.running_sum;
            s.done = true;
        };

        event::emit(SettlementStep {
            raise_id: s.raise_id,
            processed_cap: cap,
            added_amount: added,
            running_sum: s.running_sum,
            next_cap,
        });

        i = i + 1;
    };

    // If heap exhausted but not done, no fixed point > 0 exists -> T* = 0
    if (s.size == 0 && !s.done) {
        s.final_total = 0;
        s.done = true;
    };
}

/// Finalize: record T* and lock settlement
public fun finalize_settlement<RT, SC>(
    raise: &mut Raise<RT, SC>,
    s: CapSettlement,
) {
    assert!(object::id(raise) == s.raise_id, EInvalidStateForAction);
    assert!(s.done, ESettlementNotStarted);
    assert!(!raise.settlement_done, ESettlementAlreadyDone);
    assert!(raise.settlement_in_progress, EInvalidSettlementState);
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);
    
    // SECURITY: Validate final total is reasonable
    assert!(s.final_total <= raise.total_raised, EInvalidSettlementState);

    raise.final_total_eligible = s.final_total;
    raise.settlement_done = true;
    raise.settlement_in_progress = false; // Settlement completed

    event::emit(SettlementFinalized { raise_id: object::id(raise), final_total: s.final_total });

    // Destroy the crank object
    let CapSettlement { id, raise_id: _, heap: _, size: _, running_sum: _, final_total: _, done: _ } = s;
    object::delete(id);
}

/// Entry function to start settlement and share the settlement object
public entry fun start_settlement<RT, SC>(
    raise: &mut Raise<RT, SC>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let settlement = begin_settlement(raise, clock, ctx);
    transfer::public_share_object(settlement);
}

/// Entry function to finalize settlement
public entry fun complete_settlement<RT, SC>(
    raise: &mut Raise<RT, SC>,
    s: CapSettlement,
) {
    finalize_settlement(raise, s);
}

/// Activates pre-created DAO and executes pending intents
/// If init actions fail and init_actions_must_succeed is true, the raise fails
/// This ensures atomic execution - either all init actions succeed or the raise fails
public entry fun claim_success_and_activate_dao<RaiseToken: drop, StableCoin: drop>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    factory: &mut factory::Factory,
    extensions: &Extensions,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<sui::sui::SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);
    assert!(clock.timestamp_ms() >= raise.deadline_ms, EDeadlineNotReached);
    assert!(raise.settlement_done, ESettlementNotStarted);

    // Use T* from the settlement algorithm
    let consensual_total = raise.final_total_eligible;
    assert!(consensual_total >= raise.min_raise_amount, EMinRaiseNotMet);
    assert!(consensual_total > 0, EMinRaiseNotMet);

    // --- THE CRUCIAL HYBRID LOGIC ---
    // The final raise is the lesser of the market consensus and the creator's hard cap.
    let final_total = if (option::is_some(&raise.max_raise_amount)) {
        math::min(consensual_total, *option::borrow(&raise.max_raise_amount))
    } else {
        consensual_total
    };

    // Store this final capped amount for claims and refunds
    raise.final_raise_amount = final_total;

    // SECURITY: Verify invariants
    assert!(raise.final_raise_amount <= raise.final_total_eligible, EInvalidSettlementState);
    assert!(raise.final_raise_amount <= raise.stable_coin_vault.value(), EInvalidSettlementState);

    // Check if DAO was pre-created
    if (raise.dao_id.is_some()) {
        // Extract the unshared DAO components
        let mut account: Account<FutarchyConfig> = df::remove(&mut raise.id, DaoAccountKey {});
        let mut queue: ProposalQueue<StableCoin> = df::remove(&mut raise.id, DaoQueueKey {});
        let mut spot_pool: AccountSpotPool<RaiseToken, StableCoin> = df::remove(&mut raise.id, DaoPoolKey {});

        // Check if there are staged init actions
        if (raise.dao_params.init_action_specs.is_some()) {
            let specs = *raise.dao_params.init_action_specs.borrow();

            // ATOMIC EXECUTION: Execute all init actions as a batch
            // If ANY action fails, this function will abort and the entire transaction reverts
            // This means:
            // 1. The raise remains in STATE_FUNDING (not marked successful)
            // 2. The DAO components remain unshared
            // 3. Contributors can claim refunds after deadline
            // 4. The launchpad automatically takes the fail path
            //
            // This is enforced by Move's transaction atomicity - no partial state changes
            init_actions::execute_init_intent_with_resources<RaiseToken, StableCoin>(
                &mut account,
                specs,
                &mut queue,
                &mut spot_pool,
                clock,
                ctx
            );
        };

        // Mark successful only if we reach here (init actions succeeded)
        raise.state = STATE_SUCCESSFUL;

        // Share all objects now that everything succeeded
        transfer::public_share_object(account);
        transfer::public_share_object(queue);
        account_spot_pool::share(spot_pool);
    } else {
        // DAO must be pre-created - remove backward compatibility
        abort EDaoNotPreCreated
    };
    
    // Transfer the final, capped amount to the creator
    let raised_funds = coin::from_balance(raise.stable_coin_vault.split(raise.final_raise_amount), ctx);
    transfer::public_transfer(raised_funds, raise.creator);

    event::emit(RaiseSuccessful {
        raise_id: object::id(raise),
        total_raised: raise.final_raise_amount,
    });
}

/// Creates DAO atomically with staged init actions (backward compatibility)
/// Executes all init actions that were staged via stage_init_actions()
/// If ANY init action fails, entire DAO creation reverts and raise remains refundable
/// 
/// ## Two-Phase Process:
/// 1. Before deadline: Creator calls stage_init_actions() to set up init actions
/// 2. After deadline: Anyone calls this to create DAO with staged actions
/// 
/// Uses hot potato pattern - DAO components exist unshared until init succeeds
public entry fun claim_success_and_create_dao_with_init<RaiseToken: drop, StableCoin: drop>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    factory: &mut factory::Factory,
    extensions: &Extensions,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<sui::sui::SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);
    assert!(clock.timestamp_ms() >= raise.deadline_ms, EDeadlineNotReached);
    assert!(raise.settlement_done, ESettlementNotStarted);

    // Use T* from the settlement algorithm
    let consensual_total = raise.final_total_eligible;

    assert!(consensual_total >= raise.min_raise_amount, EMinRaiseNotMet);
    assert!(consensual_total > 0, EMinRaiseNotMet);

    // SECURITY: Final total cannot exceed total raised
    assert!(consensual_total <= raise.total_raised, EInvalidSettlementState);

    // --- THE CRUCIAL HYBRID LOGIC ---
    // The final raise is the lesser of the market consensus and the creator's hard cap.
    let final_total = if (option::is_some(&raise.max_raise_amount)) {
        math::min(consensual_total, *option::borrow(&raise.max_raise_amount))
    } else {
        consensual_total
    };

    // Store this final capped amount for claims and refunds
    raise.final_raise_amount = final_total;

    // SECURITY: Verify invariants
    assert!(raise.final_raise_amount <= raise.final_total_eligible, EInvalidSettlementState);
    assert!(raise.final_raise_amount <= raise.stable_coin_vault.value(), EInvalidSettlementState);

    // Extract the TreasuryCap if available
    let treasury_cap = if (raise.treasury_cap.is_some()) {
        option::some(raise.treasury_cap.extract())
    } else {
        option::none()
    };

    let params = &raise.dao_params;
    
    // Create DAO WITHOUT sharing it yet - need to execute init actions first
    let (mut account, mut queue, mut spot_pool) = factory::create_dao_unshared<RaiseToken, StableCoin>(
        factory,
        extensions,
        fee_manager,
        payment,
        1, // min_asset_amount
        1, // min_stable_amount
        params.dao_name,
        params.icon_url_string,
        params.review_period_ms,
        params.trading_period_ms,
        params.amm_twap_start_delay,
        params.amm_twap_step_max,
        params.amm_twap_initial_observation,
        params.twap_threshold,
        DEFAULT_AMM_TOTAL_FEE_BPS,
        params.dao_description,
        params.max_outcomes,
        treasury_cap,
        clock,
        ctx
    );
    
    // Execute staged init actions if any
    if (params.init_action_specs.is_some()) {
        let specs = *params.init_action_specs.borrow();
        
        // Execute with hot potato resources - any failure aborts entire transaction
        init_actions::execute_init_intent_with_resources<RaiseToken, StableCoin>(
            &mut account,
            specs,
            &mut queue,
            &mut spot_pool,
            clock,
            ctx
        );
    };
    
    // Handle founder rewards as commitment action
    if (params.founder_reward_params.is_some()) {
        let founder_params = params.founder_reward_params.borrow();
        
        // Founder rewards are handled as commitment actions
        // These create price-locked tokens that unlock at price targets
        // Implementation depends on commitment module availability
        
        event::emit(FounderRewardsConfigured {
            raise_id: object::id(raise),
            founder_address: founder_params.founder_address,
            allocation_bps: founder_params.founder_allocation_bps,
            tiers: if (founder_params.linear_vesting) { 5u64 } else { 1u64 },
        });
    };
    
    // Only mark successful AFTER init actions succeed
    raise.state = STATE_SUCCESSFUL;
    
    // Share all objects now that everything succeeded
    transfer::public_share_object(account);
    transfer::public_share_object(queue);
    account_spot_pool::share(spot_pool);

    // Transfer the final, capped amount to the creator
    let raised_funds = coin::from_balance(raise.stable_coin_vault.split(raise.final_raise_amount), ctx);
    transfer::public_transfer(raised_funds, raise.creator);

    event::emit(RaiseSuccessful {
        raise_id: object::id(raise),
        total_raised: raise.final_raise_amount,
    });
}

/// Stage init actions for execution during DAO creation
/// Completely generic - accepts ANY action types as BCS-serialized data
/// Must be called by creator before raise ends
public entry fun stage_init_actions<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    action_types: vector<TypeName>,     // Types of actions
    action_data: vector<vector<u8>>,    // BCS-serialized action data
    ctx: &mut TxContext,
) {
    use futarchy_actions::action_specs;
    
    // Only creator can stage actions
    assert!(ctx.sender() == raise.creator, ENotTheCreator);
    // Can only stage before funding ends
    assert!(raise.state == STATE_FUNDING, EInvalidStateForAction);
    // Vectors must have same length
    assert!(vector::length(&action_types) == vector::length(&action_data), EInvalidActionData);
    
    // Build the specs - completely generic
    let mut specs = action_specs::new_init_specs();
    
    let mut i = 0;
    let len = vector::length(&action_types);
    while (i < len) {
        action_specs::add_action(
            &mut specs,
            *vector::borrow(&action_types, i),
            *vector::borrow(&action_data, i)
        );
        i = i + 1;
    };
    
    // Store specs in Raise's DAO parameters
    raise.dao_params.init_action_specs = option::some(specs);
    
    event::emit(InitActionsStaged {
        raise_id: object::id(raise),
        action_count: len,
    });
}


/// If successful, contributors can call this to claim their share of the governance tokens.
public entry fun claim_tokens<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    ctx: &mut TxContext,
) {
    assert!(raise.state == STATE_SUCCESSFUL, EInvalidStateForAction);
    assert!(raise.settlement_done, ESettlementNotStarted);

    assert!(!raise.claiming, EReentrancy);
    raise.claiming = true;

    let who = ctx.sender();
    let key = ContributorKey { contributor: who };
    assert!(df::exists_(&raise.id, key), ENotAContributor);

    // SECURITY: Remove and get contribution record to prevent double-claim
    let rec: Contribution = df::remove(&mut raise.id, key);
    
    // SECURITY: Verify contribution integrity
    assert!(rec.amount > 0, EInvalidStateForAction);
    assert!(rec.max_total >= rec.amount, EInvalidStateForAction);

    // Step 1: Eligibility check is still against the CONSENSUS total (T*)
    // This respects the outcome of the settlement phase.
    let consensual_total = raise.final_total_eligible;
    if (!(rec.max_total >= consensual_total)) {
        // This user was filtered out by the market. They get a 100% refund.
        // We put their full contribution back so they can claim it.
        df::add(&mut raise.id, key, rec);
        raise.claiming = false;
        abort ENotEligibleForTokens
    };

    // Step 2: Pro-rata calculation for ELIGIBLE users
    // Calculate the user's share of the consensual total
    let accepted_amount = math::mul_div_to_64(
        rec.amount,
        raise.final_raise_amount, // Use the final, possibly capped amount
        consensual_total          // But scale it relative to the larger consensus pool
    );

    let tokens_to_claim = math::mul_div_to_64(
        accepted_amount,
        raise.tokens_for_sale_amount,
        raise.final_raise_amount
    );

    let tokens = coin::from_balance(raise.raise_token_vault.split(tokens_to_claim), ctx);
    transfer::public_transfer(tokens, who);

    event::emit(TokensClaimed {
        raise_id: object::id(raise),
        contributor: who,
        contribution_amount: accepted_amount,
        tokens_claimed: tokens_to_claim,
    });

    // Step 3: Handle any refund due
    let refund_due = rec.amount - accepted_amount;
    if (refund_due > 0) {
        // Use a separate RefundKey to prevent double-claiming
        let refund_key = RefundKey { contributor: who };
        // Only add if no existing refund (safety check)
        if (!df::exists_(&raise.id, refund_key)) {
            df::add(&mut raise.id, refund_key, RefundRecord { amount: refund_due });
        } else {
            // If refund already exists, add to it
            let existing: &mut RefundRecord = df::borrow_mut(&mut raise.id, refund_key);
            existing.amount = existing.amount + refund_due;
        };
    };

    raise.claiming = false;
}

/// Cleanup resources for a failed raise
/// This properly handles pre-created DAO components that couldn't be shared
/// Objects with UID need special handling - they can't just be dropped
public entry fun cleanup_failed_raise<RaiseToken: drop, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Only callable after deadline
    assert!(clock.timestamp_ms() >= raise.deadline_ms, EDeadlineNotReached);
    
    // Only for failed raises
    if (raise.settlement_done) {
        assert!(raise.final_total_eligible < raise.min_raise_amount, EMinRaiseAlreadyMet);
    } else {
        assert!(raise.total_raised < raise.min_raise_amount, EMinRaiseAlreadyMet);
    };
    
    // Mark as failed if not already
    if (raise.state != STATE_FAILED) {
        raise.state = STATE_FAILED;
    };
    
    // Clean up pre-created DAO if it exists
    if (raise.dao_id.is_some()) {
        // Note: When init actions fail, the transaction reverts atomically
        // so these unshared components won't exist in dynamic fields.
        // This cleanup is only needed if DAO was pre-created but raise failed
        // for other reasons (e.g., didn't meet min raise amount)

        // Properly handle objects with UID - they need to be shared or transferred
        if (df::exists_(&raise.id, DaoAccountKey {})) {
            let account: Account<FutarchyConfig> = df::remove(&mut raise.id, DaoAccountKey {});
            // Share the account so it can be cleaned up later by admin
            // This is safe because the raise failed and DAO won't be used
            transfer::public_share_object(account);
        };

        if (df::exists_(&raise.id, DaoQueueKey {})) {
            let queue: ProposalQueue<StableCoin> = df::remove(&mut raise.id, DaoQueueKey {});
            // Share the queue for cleanup
            transfer::public_share_object(queue);
        };

        if (df::exists_(&raise.id, DaoPoolKey {})) {
            let pool: AccountSpotPool<RaiseToken, StableCoin> = df::remove(&mut raise.id, DaoPoolKey {});
            // Use the module's share function for proper handling
            account_spot_pool::share(pool);
        };

        // Clean up init action specs if they exist
        if (raise.dao_params.init_action_specs.is_some()) {
            raise.dao_params.init_action_specs = option::none();
        }

        // Clear DAO ID
        raise.dao_id = option::none();

        // Emit event for tracking cleanup
        event::emit(FailedRaiseCleanup {
            raise_id: object::id(raise),
            dao_id: *raise.dao_id.borrow(),
            timestamp: clock.timestamp_ms(),
        });
    };
}

/// Refund for eligible contributors who were partially refunded due to hard cap
public entry fun claim_hard_cap_refund<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    ctx: &mut TxContext,
) {
    assert!(raise.state == STATE_SUCCESSFUL, EInvalidStateForAction);
    assert!(raise.settlement_done, ESettlementNotStarted);

    let who = ctx.sender();
    let refund_key = RefundKey { contributor: who };

    // Check if user has a refund due to hard cap
    assert!(df::exists_(&raise.id, refund_key), ENotAContributor);

    // Remove and get refund record
    let refund_rec: RefundRecord = df::remove(&mut raise.id, refund_key);

    // Create refund coin
    let refund_coin = coin::from_balance(raise.stable_coin_vault.split(refund_rec.amount), ctx);
    transfer::public_transfer(refund_coin, who);

    event::emit(RefundClaimed {
        raise_id: object::id(raise),
        contributor: who,
        amount: refund_rec.amount,
    });
}

/// Refund for contributors whose cap excluded them (after successful raise).
public entry fun claim_refund_ineligible<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    ctx: &mut TxContext,
) {
    assert!(raise.settlement_done, ESettlementNotStarted);
    assert!(raise.state == STATE_SUCCESSFUL, EInvalidStateForAction);

    let who = ctx.sender();
    let key = ContributorKey { contributor: who };
    assert!(df::exists_(&raise.id, key), ENotAContributor);

    let rec: Contribution = df::remove(&mut raise.id, key);
    
    // SECURITY: Verify contribution integrity
    assert!(rec.amount > 0, EInvalidStateForAction);
    assert!(rec.max_total >= rec.amount, EInvalidStateForAction);

    // Only for contributors who were excluded by their cap
    if (rec.max_total >= raise.final_total_eligible) {
        // They should claim tokens, not refund
        // Reinsert their record to avoid bricking them
        df::add(&mut raise.id, key, rec);
        abort EInvalidStateForAction
    };

    let refund_coin = coin::from_balance(raise.stable_coin_vault.split(rec.amount), ctx);
    transfer::public_transfer(refund_coin, who);

    event::emit(RefundClaimed {
        raise_id: object::id(raise),
        contributor: who,
        refund_amount: rec.amount,
    });
}

/// If failed, contributors can call this to get a refund.
public entry fun claim_refund<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(clock.timestamp_ms() >= raise.deadline_ms, EDeadlineNotReached);
    
    // For failed raises, check if settlement is done to determine if it failed
    if (raise.settlement_done) {
        // Settlement done, check if final total met minimum
        if (raise.final_total_eligible >= raise.min_raise_amount) {
            // Successful raise - use claim_refund_ineligible instead
            abort EInvalidStateForAction
        };
    } else {
        // No settlement done, check naive total
        assert!(raise.total_raised < raise.min_raise_amount, EMinRaiseAlreadyMet);
    };

    if (raise.state == STATE_FUNDING) {
        raise.state = STATE_FAILED;
        event::emit(RaiseFailed {
            raise_id: object::id(raise),
            total_raised: raise.total_raised,
            min_raise_amount: raise.min_raise_amount,
        });
    };

    assert!(raise.state == STATE_FAILED, EInvalidStateForAction);
    let contributor = ctx.sender();
    let contributor_key = ContributorKey { contributor };
    
    // Check contributor exists
    assert!(df::exists_(&raise.id, contributor_key), ENotAContributor);
    
    // Remove and get contribution record
    let rec: Contribution = df::remove(&mut raise.id, contributor_key);
    let refund_coin = coin::from_balance(raise.stable_coin_vault.split(rec.amount), ctx);
    transfer::public_transfer(refund_coin, contributor);

    event::emit(RefundClaimed {
        raise_id: object::id(raise),
        contributor,
        refund_amount: rec.amount,
    });
}

/// After a successful raise and a claim period, the creator can sweep any remaining
/// "dust" tokens that were left over from rounding during the distribution.
public entry fun sweep_dust<RaiseToken, StableCoin>(
    raise: &mut Raise<RaiseToken, StableCoin>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(raise.state == STATE_SUCCESSFUL, EInvalidStateForAction);
    assert!(ctx.sender() == raise.creator, ENotTheCreator);

    // Ensure the claim period has passed. The claim period starts after the raise deadline.
    assert!(
        clock.timestamp_ms() >= raise.deadline_ms + CLAIM_PERIOD_DURATION_MS,
        EDeadlineNotReached // Reusing error, implies "claim deadline not reached"
    );

    let remaining_balance = raise.raise_token_vault.value();
    if (remaining_balance > 0) {
        let dust_tokens = coin::from_balance(raise.raise_token_vault.split(remaining_balance), ctx);
        transfer::public_transfer(dust_tokens, raise.creator);
    };
}

/// Internal function to initialize a raise with founder rewards.
fun init_raise_with_founder<RaiseToken: drop, StableCoin: drop>(
    treasury_cap: TreasuryCap<RaiseToken>,
    tokens_for_raise: Coin<RaiseToken>,
    min_raise_amount: u64,
    max_raise_amount: Option<u64>,
    description: String,
    dao_params: DAOParameters,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let tokens_for_sale = tokens_for_raise.value();
    let raise = Raise<RaiseToken, StableCoin> {
        id: object::new(ctx),
        creator: ctx.sender(),
        state: STATE_FUNDING,
        total_raised: 0,
        min_raise_amount,
        max_raise_amount,
        deadline_ms: clock.timestamp_ms() + LAUNCHPAD_DURATION_MS,
        raise_token_vault: tokens_for_raise.into_balance(),
        tokens_for_sale_amount: tokens_for_sale,
        stable_coin_vault: balance::zero(),
        contributor_count: 0,
        description,
        dao_params,
        treasury_cap: option::some(treasury_cap),
        claiming: false,
        thresholds: vector::empty<u64>(),
        settlement_done: false,
        settlement_in_progress: false,
        final_total_eligible: 0,
        final_raise_amount: 0,
        dao_id: option::none(),
        intents_locked: false,
    };

    event::emit(RaiseCreated {
        raise_id: object::id(&raise),
        creator: raise.creator,
        raise_token_type: type_name::with_defining_ids<RaiseToken>().into_string().to_string(),
        stable_coin_type: type_name::with_defining_ids<StableCoin>().into_string().to_string(),
        min_raise_amount,
        tokens_for_sale,
        deadline_ms: raise.deadline_ms,
        description: raise.description,
    });

    transfer::public_share_object(raise);
}

/// Internal function to initialize a raise (backward compatibility).
fun init_raise<RaiseToken: drop, StableCoin: drop>(
    treasury_cap: TreasuryCap<RaiseToken>,
    tokens_for_raise: Coin<RaiseToken>,
    min_raise_amount: u64,
    max_raise_amount: Option<u64>,
    description: String,
    dao_params: DAOParameters,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let tokens_for_sale = tokens_for_raise.value();
    let raise = Raise<RaiseToken, StableCoin> {
        id: object::new(ctx),
        creator: ctx.sender(),
        state: STATE_FUNDING,
        total_raised: 0,
        min_raise_amount,
        max_raise_amount,
        deadline_ms: clock.timestamp_ms() + LAUNCHPAD_DURATION_MS,
        raise_token_vault: tokens_for_raise.into_balance(),
        tokens_for_sale_amount: tokens_for_sale,
        stable_coin_vault: balance::zero(),
        contributor_count: 0,
        description,
        dao_params,
        treasury_cap: option::some(treasury_cap),
        claiming: false,
        thresholds: vector::empty<u64>(),
        settlement_done: false,
        settlement_in_progress: false,
        final_total_eligible: 0,
        final_raise_amount: 0,
        dao_id: option::none(),
        intents_locked: false,
    };

    event::emit(RaiseCreated {
        raise_id: object::id(&raise),
        creator: raise.creator,
        raise_token_type: type_name::with_defining_ids<RaiseToken>().into_string().to_string(),
        stable_coin_type: type_name::with_defining_ids<StableCoin>().into_string().to_string(),
        min_raise_amount,
        tokens_for_sale,
        deadline_ms: raise.deadline_ms,
        description: raise.description,
    });

    transfer::public_share_object(raise);
}

// === View Functions ===

public fun total_raised<RT, SC>(r: &Raise<RT, SC>): u64 { r.total_raised }
public fun state<RT, SC>(r: &Raise<RT, SC>): u8 { r.state }
public fun deadline<RT, SC>(r: &Raise<RT, SC>): u64 { r.deadline_ms }
public fun description<RT, SC>(r: &Raise<RT, SC>): &String { &r.description }
public fun contribution_of<RT, SC>(r: &Raise<RT, SC>, addr: address): u64 {
    let key = ContributorKey { contributor: addr };
    if (df::exists_(&r.id, key)) {
        let contribution: &Contribution = df::borrow(&r.id, key);
        contribution.amount
    } else {
        0
    }
}

public fun final_total_eligible<RT, SC>(r: &Raise<RT, SC>): u64 { r.final_total_eligible }
public fun settlement_done<RT, SC>(r: &Raise<RT, SC>): bool { r.settlement_done }
public fun settlement_in_progress<RT, SC>(r: &Raise<RT, SC>): bool { r.settlement_in_progress }
public fun contributor_count<RT, SC>(r: &Raise<RT, SC>): u64 { r.contributor_count }