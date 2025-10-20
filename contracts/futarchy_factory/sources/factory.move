// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Factory for creating futarchy DAOs using account_protocol
/// This is the main entry point for creating DAOs in the Futarchy protocol
module futarchy_factory::factory;

use account_actions::{currency, vault};
use account_extensions::extensions::Extensions;
use account_protocol::account::{Self, Account};
use futarchy_core::dao_config::{
    Self,
    DaoConfig,
    TradingParams,
    TwapConfig,
    GovernanceConfig,
    MetadataConfig,
    SecurityConfig
};
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_core::priority_queue::{Self, ProposalQueue};
use futarchy_core::version;
use futarchy_markets_core::fee::{Self, FeeManager};
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_factory::init_actions;
use futarchy_types::init_action_specs::InitActionSpecs;
use futarchy_types::signed::{Self as signed, SignedU128};
use std::ascii::String as AsciiString;
use std::option::Option;
use std::string::String as UTF8String;
use std::type_name::{Self, TypeName};
use std::vector;
use sui::clock::Clock;
use sui::coin::{Self, Coin, TreasuryCap};
use sui::event;
use sui::object::{Self, ID, UID};
use sui::sui::SUI;
use sui::transfer;
use sui::tx_context::TxContext;
use sui::url;
use sui::vec_set::{Self, VecSet};

// === Errors ===
const EPaused: u64 = 1;
const EStableTypeNotAllowed: u64 = 2;
const EBadWitness: u64 = 3;
const EHighTwapThreshold: u64 = 4;
const ELowTwapWindowCap: u64 = 5;
const ELongTradingTime: u64 = 6;
const ELongReviewTime: u64 = 7;
const ELongTwapDelayTime: u64 = 8;
const ETwapInitialTooLarge: u64 = 9;
const EDelayNearTotalTrading: u64 = 10;
const EInvalidStateForAction: u64 = 11;
const EPermanentlyDisabled: u64 = 12;
const EAlreadyDisabled: u64 = 13;

// === Constants ===
const TWAP_MINIMUM_WINDOW_CAP: u64 = 1;
const MAX_TRADING_TIME: u64 = 604_800_000; // 7 days in ms
const MAX_REVIEW_TIME: u64 = 604_800_000; // 7 days in ms
const MAX_TWAP_START_DELAY: u64 = 86_400_000; // 1 day in ms
const MAX_TWAP_THRESHOLD: u64 = 1_000_000; // 10x increase required to pass
const DEFAULT_MAX_PROPOSER_FUNDED: u64 = 30; // Default max proposals that can be funded by a single proposer

// === Structs ===

/// One-time witness for factory initialization
public struct FACTORY has drop {}

/// Factory for creating futarchy DAOs
public struct Factory has key, store {
    id: UID,
    dao_count: u64,
    paused: bool,
    permanently_disabled: bool,
    owner_cap_id: ID,
    allowed_stable_types: VecSet<TypeName>,
}

/// Admin capability for factory operations
public struct FactoryOwnerCap has key, store {
    id: UID,
}

/// Validator capability for DAO verification
public struct ValidatorAdminCap has key, store {
    id: UID,
}

// === Events ===

public struct DAOCreated has copy, drop {
    account_id: address,
    dao_name: AsciiString,
    asset_type: UTF8String,
    stable_type: UTF8String,
    creator: address,
    affiliate_id: UTF8String,
    timestamp: u64,
}

public struct StableCoinTypeAdded has copy, drop {
    type_str: UTF8String,
    admin: address,
    timestamp: u64,
}

public struct StableCoinTypeRemoved has copy, drop {
    type_str: UTF8String,
    admin: address,
    timestamp: u64,
}

public struct FactoryPermanentlyDisabled has copy, drop {
    admin: address,
    dao_count_at_shutdown: u64,
    timestamp: u64,
}

// === Internal Helper Functions ===
// Note: Action registry removed - using statically-typed pattern like move-framework

// Test helpers removed - no longer needed without action registry

// === Public Functions ===

fun init(witness: FACTORY, ctx: &mut TxContext) {
    assert!(sui::types::is_one_time_witness(&witness), EBadWitness);

    let owner_cap = FactoryOwnerCap {
        id: object::new(ctx),
    };

    let factory = Factory {
        id: object::new(ctx),
        dao_count: 0,
        paused: false,
        permanently_disabled: false,
        owner_cap_id: object::id(&owner_cap),
        allowed_stable_types: vec_set::empty(),
    };

    let validator_cap = ValidatorAdminCap {
        id: object::new(ctx),
    };

    transfer::share_object(factory);
    transfer::public_transfer(owner_cap, ctx.sender());
    transfer::public_transfer(validator_cap, ctx.sender());
}

/// Create a new futarchy DAO with Extensions
///
/// optimistic_intent_challenge_enabled:
///   - none(): Use default (true - 10-day challenge period)
///   - some(true): Enable 10-day challenge period for MODE_COUNCIL_ONLY actions
///   - some(false): Disable challenge period (instant execution for MODE_COUNCIL_ONLY actions)
public fun create_dao<AssetType: drop, StableType: drop>(
    factory: &mut Factory,
    extensions: &Extensions,
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    affiliate_id: UTF8String, // Partner identifier (UUID from subclient, empty string if none)
    min_asset_amount: u64,
    min_stable_amount: u64,
    dao_name: AsciiString,
    icon_url_string: AsciiString,
    review_period_ms: u64,
    trading_period_ms: u64,
    twap_start_delay: u64,
    twap_step_max: u64,
    twap_initial_observation: u128,
    twap_threshold: SignedU128,
    amm_total_fee_bps: u64,
    description: UTF8String,
    max_outcomes: u64,
    _agreement_lines: vector<UTF8String>,
    _agreement_difficulties: vector<u64>,
    optimistic_intent_challenge_enabled: Option<bool>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    create_dao_internal_with_extensions<AssetType, StableType>(
        factory,
        extensions,
        fee_manager,
        payment,
        affiliate_id,
        min_asset_amount,
        min_stable_amount,
        dao_name,
        icon_url_string,
        review_period_ms,
        trading_period_ms,
        twap_start_delay,
        twap_step_max,
        twap_initial_observation,
        twap_threshold,
        amm_total_fee_bps,
        description,
        max_outcomes,
        _agreement_lines,
        _agreement_difficulties,
        optimistic_intent_challenge_enabled,
        option::none(),
        vector::empty<InitActionSpecs>(),
        clock,
        ctx,
    );
}

/// Create a DAO and atomically execute a batch of init intents before sharing.
public fun create_dao_with_init_specs<AssetType: drop, StableType: drop>(
    factory: &mut Factory,
    extensions: &Extensions,
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    affiliate_id: UTF8String,
    min_asset_amount: u64,
    min_stable_amount: u64,
    dao_name: AsciiString,
    icon_url_string: AsciiString,
    review_period_ms: u64,
    trading_period_ms: u64,
    twap_start_delay: u64,
    twap_step_max: u64,
    twap_initial_observation: u128,
    twap_threshold: SignedU128,
    amm_total_fee_bps: u64,
    description: UTF8String,
    max_outcomes: u64,
    _agreement_lines: vector<UTF8String>,
    _agreement_difficulties: vector<u64>,
    optimistic_intent_challenge_enabled: Option<bool>,
    treasury_cap: Option<TreasuryCap<AssetType>>,
    init_specs: vector<InitActionSpecs>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    create_dao_internal_with_extensions<AssetType, StableType>(
        factory,
        extensions,
        fee_manager,
        payment,
        affiliate_id,
        min_asset_amount,
        min_stable_amount,
        dao_name,
        icon_url_string,
        review_period_ms,
        trading_period_ms,
        twap_start_delay,
        twap_step_max,
        twap_initial_observation,
        twap_threshold,
        amm_total_fee_bps,
        description,
        max_outcomes,
        _agreement_lines,
        _agreement_difficulties,
        optimistic_intent_challenge_enabled,
        treasury_cap,
        init_specs,
        clock,
        ctx,
    );
}

/// Internal function to create a DAO with Extensions and optional TreasuryCap
///
/// optimistic_intent_challenge_enabled:
///   - none(): Use default (true - 10-day challenge period)
///   - some(enabled): Apply custom setting atomically during creation
#[allow(lint(share_owned))]
public(package) fun create_dao_internal_with_extensions<AssetType: drop, StableType: drop>(
    factory: &mut Factory,
    extensions: &Extensions,
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    affiliate_id: UTF8String,
    min_asset_amount: u64,
    min_stable_amount: u64,
    dao_name: AsciiString,
    icon_url_string: AsciiString,
    review_period_ms: u64,
    trading_period_ms: u64,
    twap_start_delay: u64,
    twap_step_max: u64,
    twap_initial_observation: u128,
    twap_threshold: SignedU128,
    amm_total_fee_bps: u64,
    description: UTF8String,
    max_outcomes: u64,
    _agreement_lines: vector<UTF8String>,
    _agreement_difficulties: vector<u64>,
    optimistic_intent_challenge_enabled: Option<bool>,
    mut treasury_cap: Option<TreasuryCap<AssetType>>,
    init_specs: vector<InitActionSpecs>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Check factory is not permanently disabled
    assert!(!factory.permanently_disabled, EPermanentlyDisabled);

    // Check factory is active
    assert!(!factory.paused, EPaused);

    // Check if StableType is allowed
    let stable_type_name = type_name::with_defining_ids<StableType>();
    assert!(factory.allowed_stable_types.contains(&stable_type_name), EStableTypeNotAllowed);

    // Process payment
    fee::deposit_dao_creation_payment(fee_manager, payment, clock, ctx);

    // DoS protection: limit affiliate_id length (UUID is 36 chars, leave room for custom IDs)
    assert!(affiliate_id.length() <= 64, EInvalidStateForAction);

    // Validate parameters
    assert!(twap_step_max >= TWAP_MINIMUM_WINDOW_CAP, ELowTwapWindowCap);
    assert!(review_period_ms <= MAX_REVIEW_TIME, ELongReviewTime);
    assert!(trading_period_ms <= MAX_TRADING_TIME, ELongTradingTime);
    assert!(twap_start_delay <= MAX_TWAP_START_DELAY, ELongTwapDelayTime);
    assert!((twap_start_delay + 60_000) < trading_period_ms, EDelayNearTotalTrading);
    assert!(signed::magnitude(&twap_threshold) <= (MAX_TWAP_THRESHOLD as u128), EHighTwapThreshold);
    assert!(
        twap_initial_observation <= (18446744073709551615u128) * 1_000_000_000_000,
        ETwapInitialTooLarge,
    );

    // Create config parameters using the structured approach
    let trading_params = dao_config::new_trading_params(
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
        amm_total_fee_bps, // conditional AMM fee
        amm_total_fee_bps, // spot AMM fee (same as conditional)
        0, // market_op_review_period_ms (0 = immediate, allows atomic market init)
        1000, // max_amm_swap_percent_bps (10% max swap per proposal)
        80, // conditional_liquidity_ratio_percent (80%, base 100 - enforced 1-99% range)
    );

    let twap_config = dao_config::new_twap_config(
        twap_start_delay,
        twap_step_max,
        twap_initial_observation,
        twap_threshold,
    );

    let governance_config = dao_config::new_governance_config(
        max_outcomes,
        20, // max_actions_per_outcome (protocol limit)
        1000000, // proposal_fee_per_outcome (1 token per outcome)
        100_000_000, // required_bond_amount
        100, // fee_escalation_basis_points
        true, // proposal_creation_enabled
        true, // accept_new_proposals
        10, // max_intents_per_outcome
        604_800_000, // eviction_grace_period_ms (7 days)
        31_536_000_000, // proposal_intent_expiry_ms (365 days)
        true, // enable_premarket_reservation_lock (default: true for MEV protection)
    );

    let metadata_config = dao_config::new_metadata_config(
        dao_name,
        url::new_unsafe(icon_url_string),
        description,
    );

    let security_config = dao_config::new_security_config(
        false, // deadman_enabled
        2_592_000_000, // recovery_liveness_ms (30 days)
        false, // require_deadman_council
    );

    let dao_config = dao_config::new_dao_config(
        trading_params,
        twap_config,
        governance_config,
        metadata_config,
        security_config,
        dao_config::default_storage_config(),
        dao_config::default_conditional_coin_config(),
        dao_config::default_quota_config(),
        dao_config::default_sponsorship_config(),
    );

    // Create slash distribution with default values
    let slash_distribution = futarchy_config::new_slash_distribution(
        2000, // slasher_reward_bps (20%)
        3000, // dao_treasury_bps (30%)
        2000, // protocol_bps (20%)
        3000, // burn_bps (30%)
    );

    // --- Phase 1: Create all objects in memory (no sharing) ---

    // Create fee manager for this DAO
    let _dao_fee_manager_id = object::id(fee_manager); // Use factory fee manager for now

    // Create the unified spot pool with aggregator support enabled
    // This provides TWAP oracle, registry, and full aggregator features
    let spot_pool = unified_spot_pool::new_with_aggregator<AssetType, StableType>(
        amm_total_fee_bps, // Factory uses same fee for both conditional and spot
        8000, // oracle_conditional_threshold_bps (80% threshold from trading params)
        clock,
        ctx,
    );
    let spot_pool_id = object::id(&spot_pool);

    // Create the futarchy configuration with safe default
    let mut config = futarchy_config::new<AssetType, StableType>(
        dao_config,
        slash_distribution,
    );

    // Apply builder pattern if custom challenge setting provided
    if (optimistic_intent_challenge_enabled.is_some()) {
        config =
            futarchy_config::with_optimistic_intent_challenge_enabled(
                config,
                *optimistic_intent_challenge_enabled.borrow(),
            );
    };

    // Create the account with Extensions registry validation for security
    let mut account = futarchy_config::new_with_extensions(extensions, config, ctx);

    // Get queue parameters from governance config
    let account_config = account::config<FutarchyConfig>(&account);
    let dao_config = futarchy_config::dao_config(account_config);
    let governance = dao_config::governance_config(dao_config);
    let eviction_grace_period_ms = dao_config::eviction_grace_period_ms(governance);

    // Now create the priority queue but do not share it yet.
    let queue = priority_queue::new<StableType>(
        object::id(&account), // dao_id
        DEFAULT_MAX_PROPOSER_FUNDED,
        eviction_grace_period_ms,
        ctx,
    );
    let priority_queue_id = object::id(&queue);

    // --- Phase 2: Configure the objects and link them together ---

    // Note: DAO liquidity pool is not used in the new architecture
    // The spot pool handles all liquidity needs

    // Update the config with the actual priority queue ID
    futarchy_config::set_proposal_queue_id(&mut account, option::some(priority_queue_id));

    // Action registry removed - using statically-typed pattern

    // Initialize the default treasury vault using base vault module
    let auth = account::new_auth(
        &account,
        version::current(),
        futarchy_config::authenticate(&account, ctx),
    );
    vault::open(auth, &mut account, std::string::utf8(b"treasury"), ctx);

    // Pre-approve common coin types for permissionless deposits
    // This enables anyone to send SUI, AssetType, or StableType to the DAO
    // (enables revenue/donations without governance proposals)
    let auth = account::new_auth(
        &account,
        version::current(),
        futarchy_config::authenticate(&account, ctx),
    );
    vault::approve_coin_type<FutarchyConfig, SUI>(auth, &mut account, std::string::utf8(b"treasury"));

    let auth = account::new_auth(
        &account,
        version::current(),
        futarchy_config::authenticate(&account, ctx),
    );
    vault::approve_coin_type<FutarchyConfig, AssetType>(auth, &mut account, std::string::utf8(b"treasury"));

    let auth = account::new_auth(
        &account,
        version::current(),
        futarchy_config::authenticate(&account, ctx),
    );
    vault::approve_coin_type<FutarchyConfig, StableType>(auth, &mut account, std::string::utf8(b"treasury"));

    // If treasury cap provided, lock it using Move framework's currency module
    if (treasury_cap.is_some()) {
        let cap = treasury_cap.extract();
        // Use Move framework's currency::lock_cap for proper treasury cap storage
        // This ensures atomic borrowing and proper permissions management
        let auth = account::new_auth(
            &account,
            version::current(),
            futarchy_config::authenticate(&account, ctx),
        );
        currency::lock_cap(
            auth,
            &mut account,
            cap,
            option::none(), // No max supply limit for now
        );
    };
    // Destroy the empty option
    treasury_cap.destroy_none();

    let account_object_id = object::id(&account);
    let specs_len = vector::length(&init_specs);
    let mut idx = 0;
    while (idx < specs_len) {
        init_actions::stage_init_intent(
            &mut account,
            &account_object_id,
            idx,
            vector::borrow(&init_specs, idx),
            clock,
            ctx,
        );
        idx = idx + 1;
    };

    // Note: Init intents are now executed via PTB after DAO creation
    // The frontend reads the staged specs and constructs a deterministic PTB

    // Get account ID before sharing
    let account_id = object::id_address(&account);

    // --- Phase 3: Final Atomic Sharing ---
    // All objects are shared at the end of the function. If any step above failed,
    // the transaction would abort and no objects would be created.
    transfer::public_share_object(account);
    unified_spot_pool::share(spot_pool);
    transfer::public_share_object(queue);

    // --- Phase 4: Update Factory State and Emit Event ---

    // Update factory state
    factory.dao_count = factory.dao_count + 1;

    // Emit event
    event::emit(DAOCreated {
        account_id,
        dao_name,
        asset_type: get_type_string<AssetType>(),
        stable_type: get_type_string<StableType>(),
        creator: ctx.sender(),
        affiliate_id,
        timestamp: clock.timestamp_ms(),
    });
}

#[test_only]
/// Internal function to create a DAO for testing without Extensions
fun create_dao_internal_test<AssetType: drop, StableType: drop>(
    factory: &mut Factory,
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    min_asset_amount: u64,
    min_stable_amount: u64,
    dao_name: AsciiString,
    icon_url_string: AsciiString,
    review_period_ms: u64,
    trading_period_ms: u64,
    twap_start_delay: u64,
    twap_step_max: u64,
    twap_initial_observation: u128,
    twap_threshold: SignedU128,
    amm_total_fee_bps: u64,
    description: UTF8String,
    max_outcomes: u64,
    _agreement_lines: vector<UTF8String>,
    _agreement_difficulties: vector<u64>,
    mut treasury_cap: Option<TreasuryCap<AssetType>>,
    init_specs: vector<InitActionSpecs>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Check factory is not permanently disabled
    assert!(!factory.permanently_disabled, EPermanentlyDisabled);

    // Check factory is active
    assert!(!factory.paused, EPaused);

    // Check if StableType is allowed
    let stable_type_name = type_name::with_defining_ids<StableType>();
    assert!(factory.allowed_stable_types.contains(&stable_type_name), EStableTypeNotAllowed);

    // Process payment
    fee::deposit_dao_creation_payment(fee_manager, payment, clock, ctx);

    let affiliate_id = b"".to_string();

    // Validate parameters
    assert!(twap_step_max >= TWAP_MINIMUM_WINDOW_CAP, ELowTwapWindowCap);
    assert!(review_period_ms <= MAX_REVIEW_TIME, ELongReviewTime);
    assert!(trading_period_ms <= MAX_TRADING_TIME, ELongTradingTime);
    assert!(twap_start_delay <= MAX_TWAP_START_DELAY, ELongTwapDelayTime);
    assert!((twap_start_delay + 60_000) < trading_period_ms, EDelayNearTotalTrading);
    assert!(signed::magnitude(&twap_threshold) <= (MAX_TWAP_THRESHOLD as u128), EHighTwapThreshold);
    assert!(
        twap_initial_observation <= (18446744073709551615u128) * 1_000_000_000_000,
        ETwapInitialTooLarge,
    );

    // Create config parameters using the structured approach
    let trading_params = dao_config::new_trading_params(
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
        amm_total_fee_bps, // conditional AMM fee
        amm_total_fee_bps, // spot AMM fee (same as conditional)
        0, // market_op_review_period_ms (0 = immediate, allows atomic market init)
        1000, // max_amm_swap_percent_bps (10% max swap per proposal)
        80, // conditional_liquidity_ratio_percent (80%, base 100 - enforced 1-99% range)
    );

    let twap_config = dao_config::new_twap_config(
        twap_start_delay,
        twap_step_max,
        twap_initial_observation,
        twap_threshold,
    );

    let governance_config = dao_config::new_governance_config(
        max_outcomes,
        20, // max_actions_per_outcome (protocol limit)
        1000000, // proposal_fee_per_outcome (1 token per outcome)
        100_000_000, // required_bond_amount
        100, // fee_escalation_basis_points
        true, // proposal_creation_enabled
        true, // accept_new_proposals
        10, // max_intents_per_outcome
        604_800_000, // eviction_grace_period_ms (7 days)
        31_536_000_000, // proposal_intent_expiry_ms (365 days)
        true, // enable_premarket_reservation_lock (default: true for MEV protection)
    );

    let metadata_config = dao_config::new_metadata_config(
        dao_name,
        url::new_unsafe(icon_url_string),
        description,
    );

    let security_config = dao_config::new_security_config(
        false, // deadman_enabled
        2_592_000_000, // recovery_liveness_ms (30 days)
        false, // require_deadman_council
    );

    let dao_config = dao_config::new_dao_config(
        trading_params,
        twap_config,
        governance_config,
        metadata_config,
        security_config,
        dao_config::default_storage_config(),
        dao_config::default_conditional_coin_config(),
        dao_config::default_quota_config(),
        dao_config::default_sponsorship_config(),
    );

    // Create slash distribution with default values
    let slash_distribution = futarchy_config::new_slash_distribution(
        2000, // slasher_reward_bps (20%)
        3000, // dao_treasury_bps (30%)
        2000, // protocol_bps (20%)
        3000, // burn_bps (30%)
    );

    // --- Phase 1: Create all objects in memory (no sharing) ---

    // Create fee manager for this DAO
    let _dao_fee_manager_id = object::id(fee_manager); // Use factory fee manager for now

    // Create the unified spot pool with aggregator support enabled
    let spot_pool = unified_spot_pool::new_with_aggregator<AssetType, StableType>(
        amm_total_fee_bps, // Factory uses same fee for both conditional and spot
        8000, // oracle_conditional_threshold_bps (80% threshold)
        clock,
        ctx,
    );
    let spot_pool_id = object::id(&spot_pool);

    // Create the futarchy configuration (uses safe default: challenge enabled = true)
    let config = futarchy_config::new<AssetType, StableType>(
        dao_config,
        slash_distribution,
    );

    // Create the account using test function
    let mut account = futarchy_config::new_account_test(config, ctx);

    // Get queue parameters from governance config
    let account_config = account::config<FutarchyConfig>(&account);
    let dao_config = futarchy_config::dao_config(account_config);
    let governance = dao_config::governance_config(dao_config);
    let eviction_grace_period_ms = dao_config::eviction_grace_period_ms(governance);

    // Now create the priority queue but do not share it yet.
    let queue = priority_queue::new<StableType>(
        object::id(&account), // dao_id
        DEFAULT_MAX_PROPOSER_FUNDED,
        eviction_grace_period_ms,
        ctx,
    );
    let priority_queue_id = object::id(&queue);

    // --- Phase 2: Configure the objects and link them together ---

    // Update the config with the actual priority queue ID
    futarchy_config::set_proposal_queue_id(&mut account, option::some(priority_queue_id));

    // Action registry removed - using statically-typed pattern

    // Initialize the default treasury vault (test version)
    {
        use account_protocol::version_witness;
        let test_version = version_witness::new_for_testing(@account_protocol);
        let auth = account::new_auth(
            &account,
            test_version,
            futarchy_config::authenticate(&account, ctx),
        );
        vault::open(auth, &mut account, std::string::utf8(b"treasury"), ctx);

        // Pre-approve common coin types for permissionless deposits
        let auth = account::new_auth(
            &account,
            test_version,
            futarchy_config::authenticate(&account, ctx),
        );
        vault::approve_coin_type<FutarchyConfig, SUI>(auth, &mut account, std::string::utf8(b"treasury"));

        let auth = account::new_auth(
            &account,
            test_version,
            futarchy_config::authenticate(&account, ctx),
        );
        vault::approve_coin_type<FutarchyConfig, AssetType>(auth, &mut account, std::string::utf8(b"treasury"));

        let auth = account::new_auth(
            &account,
            test_version,
            futarchy_config::authenticate(&account, ctx),
        );
        vault::approve_coin_type<FutarchyConfig, StableType>(auth, &mut account, std::string::utf8(b"treasury"));
    };

    // If treasury cap provided, lock it using Move framework's currency module
    if (treasury_cap.is_some()) {
        let cap = treasury_cap.extract();
        // Use Move framework's currency::lock_cap for proper treasury cap storage
        // This ensures atomic borrowing and proper permissions management
        let auth = account::new_auth(
            &account,
            version::current(),
            futarchy_config::authenticate(&account, ctx),
        );
        currency::lock_cap(
            auth,
            &mut account,
            cap,
            option::none(), // No max supply limit for now
        );
    };
    // Destroy the empty option
    treasury_cap.destroy_none();

    let account_object_id = object::id(&account);
    let specs_len = vector::length(&init_specs);
    let mut idx = 0;
    while (idx < specs_len) {
        init_actions::stage_init_intent(
            &mut account,
            &account_object_id,
            idx,
            vector::borrow(&init_specs, idx),
            clock,
            ctx,
        );
        idx = idx + 1;
    };

    // Note: Init intents are now executed via PTB after DAO creation
    // The frontend reads the staged specs and constructs a deterministic PTB

    // Get account ID before sharing
    let account_id = object::id_address(&account);

    // --- Phase 3: Final Atomic Sharing ---
    // All objects are shared at the end of the function. If any step above failed,
    // the transaction would abort and no objects would be created.
    transfer::public_share_object(account);
    unified_spot_pool::share(spot_pool);
    transfer::public_share_object(queue);

    // --- Phase 4: Update Factory State and Emit Event ---

    // Update factory state
    factory.dao_count = factory.dao_count + 1;

    // Emit event
    event::emit(DAOCreated {
        account_id,
        dao_name,
        asset_type: get_type_string<AssetType>(),
        stable_type: get_type_string<StableType>(),
        creator: ctx.sender(),
        affiliate_id,
        timestamp: clock.timestamp_ms(),
    });
}

// === Init Actions Support ===

// Removed InitWitness - it belongs in init_actions module
// Removed create_dao_for_init - not needed, use create_dao_unshared

/// Create DAO and return it without sharing (for init actions)
///
/// ## Minimal API - All config set via init actions
/// This function only handles what's truly required for DAO creation.
/// Everything else (metadata, trading params, TWAP, etc.) should be set via init actions.
///
/// ## Hot Potato Pattern:
/// Returns (Account, ProposalQueue, UnifiedSpotPool) as unshared objects
/// These can be passed as `&mut` to init actions before being shared
///
/// ## Usage:
/// 1. Call this to create unshared DAO components with defaults
/// 2. Execute init actions to configure metadata, trading params, etc.
/// 3. Share the objects only after init succeeds
///
/// This ensures atomicity - if init fails, nothing is shared
/// Create a DAO with unshared objects (for PTB composition)
///
/// optimistic_intent_challenge_enabled:
///   - none(): Use default (true - 10-day challenge period)
///   - some(enabled): Apply custom setting atomically during creation
public fun create_dao_unshared<AssetType: drop + store, StableType: drop + store>(
    factory: &mut Factory,
    extensions: &Extensions,
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    optimistic_intent_challenge_enabled: Option<bool>,
    mut treasury_cap: Option<TreasuryCap<AssetType>>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Account<FutarchyConfig>, ProposalQueue<StableType>, UnifiedSpotPool<AssetType, StableType>) {
    // Check factory is not permanently disabled
    assert!(!factory.permanently_disabled, EPermanentlyDisabled);

    // Check factory is active
    assert!(!factory.paused, EPaused);

    // Check if StableType is allowed
    let stable_type_name = type_name::with_defining_ids<StableType>();
    assert!(factory.allowed_stable_types.contains(&stable_type_name), EStableTypeNotAllowed);

    // Process payment
    fee::deposit_dao_creation_payment(fee_manager, payment, clock, ctx);

    // Use all default configs - init actions will set real values
    let trading_params = dao_config::default_trading_params();
    let twap_config = dao_config::default_twap_config();
    let governance_config = dao_config::default_governance_config();

    // Minimal metadata - init actions will update
    let metadata_config = dao_config::new_metadata_config(
        b"DAO".to_ascii_string(), // Default name (init actions will override)
        url::new_unsafe_from_bytes(b""), // Empty icon (init actions will override)
        b"".to_string(), // Empty description (init actions will override)
    );

    let security_config = dao_config::default_security_config();

    let dao_config = dao_config::new_dao_config(
        trading_params,
        twap_config,
        governance_config,
        metadata_config,
        security_config,
        dao_config::default_storage_config(),
        dao_config::default_conditional_coin_config(),
        dao_config::default_quota_config(),
        dao_config::default_sponsorship_config(),
    );

    // Create slash distribution with default values
    let slash_distribution = futarchy_config::new_slash_distribution(
        2000, // slasher_reward_bps (20%)
        3000, // dao_treasury_bps (30%)
        2000, // protocol_bps (20%)
        3000, // burn_bps (30%)
    );

    // Create the futarchy config with safe default
    let mut config = futarchy_config::new<AssetType, StableType>(
        dao_config,
        slash_distribution,
    );

    // Apply builder pattern if custom challenge setting provided
    if (optimistic_intent_challenge_enabled.is_some()) {
        config =
            futarchy_config::with_optimistic_intent_challenge_enabled(
                config,
                *optimistic_intent_challenge_enabled.borrow(),
            );
    };

    // Create account with config
    let mut account = futarchy_config::new_with_extensions(extensions, config, ctx);

    // Create unified spot pool with aggregator support enabled
    let spot_pool = unified_spot_pool::new_with_aggregator<AssetType, StableType>(
        30, // 0.3% default fee (init actions can configure via governance)
        8000, // oracle_conditional_threshold_bps (80% threshold)
        clock,
        ctx,
    );

    // Get eviction grace period from config for the queue
    let eviction_grace_period_ms = dao_config::eviction_grace_period_ms(
        dao_config::governance_config(&dao_config),
    );

    // Create queue with defaults
    let queue = priority_queue::new<StableType>(
        object::id(&account), // dao_id
        30, // max_proposer_funded (init actions can update)
        eviction_grace_period_ms,
        ctx,
    );

    // Setup treasury cap if provided
    if (treasury_cap.is_some()) {
        let cap = treasury_cap.extract();
        let auth = account::new_auth(
            &account,
            version::current(),
            futarchy_config::authenticate(&account, ctx),
        );
        currency::lock_cap(
            auth,
            &mut account,
            cap,
            option::none(), // max_supply
        );
    };
    // Destroy the empty option
    treasury_cap.destroy_none();

    // Update factory state
    factory.dao_count = factory.dao_count + 1;

    // Emit event with default metadata (init actions will update)
    let account_id = object::id_address(&account);
    event::emit(DAOCreated {
        account_id,
        dao_name: b"DAO".to_ascii_string(),
        asset_type: get_type_string<AssetType>(),
        stable_type: get_type_string<StableType>(),
        creator: ctx.sender(),
        affiliate_id: b"".to_string(), // Unshared DAO creation uses empty string (set via init actions)
        timestamp: clock.timestamp_ms(),
    });

    (account, queue, spot_pool)
}

/// Share all DAO components after initialization is complete
/// This is called at the end of the PTB after all init actions
public fun finalize_and_share_dao<AssetType, StableType>(
    account: Account<FutarchyConfig>,
    queue: ProposalQueue<StableType>,
    spot_pool: UnifiedSpotPool<AssetType, StableType>,
) {
    // Each module provides its own share function
    account::share_account(account);
    priority_queue::share_queue(queue);
    unified_spot_pool::share(spot_pool);
}

// === Admin Functions ===

/// Toggle factory pause state (reversible)
public entry fun toggle_pause(factory: &mut Factory, cap: &FactoryOwnerCap) {
    assert!(object::id(cap) == factory.owner_cap_id, EBadWitness);
    factory.paused = !factory.paused;
}

/// Permanently disable the factory - THIS CANNOT BE REVERSED
/// Once called, no new DAOs can ever be created from this factory
/// Existing DAOs are unaffected and continue to operate normally
public entry fun disable_permanently(
    factory: &mut Factory,
    cap: &FactoryOwnerCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(cap) == factory.owner_cap_id, EBadWitness);

    // Idempotency check: prevent duplicate disable and event emission
    assert!(!factory.permanently_disabled, EAlreadyDisabled);

    factory.permanently_disabled = true;

    event::emit(FactoryPermanentlyDisabled {
        admin: ctx.sender(),
        dao_count_at_shutdown: factory.dao_count,
        timestamp: clock.timestamp_ms(),
    });
}

/// Add an allowed stable coin type
public entry fun add_allowed_stable_type<StableType>(
    factory: &mut Factory,
    owner_cap: &FactoryOwnerCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(owner_cap) == factory.owner_cap_id, EBadWitness);
    let type_name_val = type_name::with_defining_ids<StableType>();

    if (!factory.allowed_stable_types.contains(&type_name_val)) {
        factory.allowed_stable_types.insert(type_name_val);

        event::emit(StableCoinTypeAdded {
            type_str: get_type_string<StableType>(),
            admin: ctx.sender(),
            timestamp: clock.timestamp_ms(),
        });
    }
}

/// Remove an allowed stable coin type
public entry fun remove_allowed_stable_type<StableType>(
    factory: &mut Factory,
    owner_cap: &FactoryOwnerCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(owner_cap) == factory.owner_cap_id, EBadWitness);
    let type_name_val = type_name::with_defining_ids<StableType>();
    if (factory.allowed_stable_types.contains(&type_name_val)) {
        factory.allowed_stable_types.remove(&type_name_val);

        event::emit(StableCoinTypeRemoved {
            type_str: get_type_string<StableType>(),
            admin: ctx.sender(),
            timestamp: clock.timestamp_ms(),
        });
    }
}

/// Burn the factory owner cap
public entry fun burn_factory_owner_cap(factory: &Factory, cap: FactoryOwnerCap) {
    // It is good practice to check ownership one last time before burning,
    // even though only the owner can call this.
    assert!(object::id(&cap) == factory.owner_cap_id, EBadWitness);
    let FactoryOwnerCap { id } = cap;
    id.delete();
}

// === View Functions ===

/// Get DAO count
public fun dao_count(factory: &Factory): u64 {
    factory.dao_count
}

/// Check if factory is paused (reversible)
public fun is_paused(factory: &Factory): bool {
    factory.paused
}

/// Check if factory is permanently disabled (irreversible)
public fun is_permanently_disabled(factory: &Factory): bool {
    factory.permanently_disabled
}

/// Check if a stable type is allowed
public fun is_stable_type_allowed<StableType>(factory: &Factory): bool {
    let type_name_val = type_name::with_defining_ids<StableType>();
    factory.allowed_stable_types.contains(&type_name_val)
}

/// Get the permanently disabled error code (for external modules)
public fun permanently_disabled_error(): u64 {
    EPermanentlyDisabled
}

// === Private Functions ===

fun get_type_string<T>(): UTF8String {
    let type_name_obj = type_name::get_with_original_ids<T>();
    let type_str = type_name_obj.into_string().into_bytes();
    type_str.to_string()
}

// === Test Functions ===

#[test_only]
public fun create_factory(ctx: &mut TxContext) {
    let owner_cap = FactoryOwnerCap {
        id: object::new(ctx),
    };

    let factory = Factory {
        id: object::new(ctx),
        dao_count: 0,
        paused: false,
        permanently_disabled: false,
        owner_cap_id: object::id(&owner_cap),
        allowed_stable_types: vec_set::empty(),
    };

    let validator_cap = ValidatorAdminCap {
        id: object::new(ctx),
    };

    transfer::share_object(factory);
    transfer::public_transfer(owner_cap, ctx.sender());
    transfer::public_transfer(validator_cap, ctx.sender());
}

#[test_only]
/// Create a DAO for testing without Extensions
public entry fun create_dao_test<AssetType: drop, StableType: drop>(
    factory: &mut Factory,
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    min_asset_amount: u64,
    min_stable_amount: u64,
    dao_name: AsciiString,
    icon_url_string: AsciiString,
    review_period_ms: u64,
    trading_period_ms: u64,
    twap_start_delay: u64,
   twap_step_max: u64,
   twap_initial_observation: u128,
    twap_threshold_magnitude: u128,
    twap_threshold_negative: bool,
    amm_total_fee_bps: u64,
    description: UTF8String,
    max_outcomes: u64,
    _agreement_lines: vector<UTF8String>,
    _agreement_difficulties: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // For testing, we bypass the Extensions requirement
    // by directly calling the test internal function
    let twap_threshold = signed::new(twap_threshold_magnitude, twap_threshold_negative);
    create_dao_internal_test<AssetType, StableType>(
        factory,
        fee_manager,
        payment,
        min_asset_amount,
        min_stable_amount,
        dao_name,
        icon_url_string,
        review_period_ms,
        trading_period_ms,
        twap_start_delay,
        twap_step_max,
        twap_initial_observation,
        twap_threshold,
        amm_total_fee_bps,
        description,
        max_outcomes,
        _agreement_lines,
        _agreement_difficulties,
        option::none(),
        vector::empty(),
        clock,
        ctx,
    );
}
