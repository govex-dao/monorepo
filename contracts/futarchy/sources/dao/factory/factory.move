/// Factory for creating futarchy DAOs using account_protocol
/// This is the main entry point for creating DAOs in the Futarchy protocol
module futarchy::factory;

// === Imports ===
use std::{
    string::{String as UTF8String},
    ascii::String as AsciiString,
    type_name::{Self, TypeName},
    option::{Self, Option},
};
use sui::{
    clock::Clock,
    coin::{Self, Coin, TreasuryCap},
    event,
    object::{Self, ID, UID},
    sui::SUI,
    vec_set::{Self, VecSet},
    transfer,
    url,
};
use account_protocol::{
    account::{Self, Account},
};
use account_extensions::extensions::Extensions;
use account_actions::currency;
use futarchy::{
    futarchy_config::{Self, FutarchyConfig, ConfigParams},
    dao_config,
    futarchy_vault_init,
    fee::{Self, FeeManager},
    priority_queue::{Self, ProposalQueue},
    account_spot_pool::{Self, AccountSpotPool},
    version,
    policy_registry,
};

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

// === Constants ===
const TWAP_MINIMUM_WINDOW_CAP: u64 = 1;
const MAX_TRADING_TIME: u64 = 604_800_000; // 7 days in ms
const MAX_REVIEW_TIME: u64 = 604_800_000; // 7 days in ms
const MAX_TWAP_START_DELAY: u64 = 86_400_000; // 1 day in ms
const MAX_TWAP_THRESHOLD: u64 = 1_000_000; // 10x increase required to pass

// === Structs ===

/// One-time witness for factory initialization
public struct FACTORY has drop {}

/// Factory for creating futarchy DAOs
public struct Factory has key, store {
    id: UID,
    dao_count: u64,
    paused: bool,
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
        owner_cap_id: object::id(&owner_cap),
        allowed_stable_types: vec_set::empty<TypeName>(),
    };
    
    let validator_cap = ValidatorAdminCap {
        id: object::new(ctx),
    };
    
    transfer::share_object(factory);
    transfer::public_transfer(owner_cap, ctx.sender());
    transfer::public_transfer(validator_cap, ctx.sender());
}

/// Create a new futarchy DAO with Extensions
public entry fun create_dao<AssetType: drop, StableType>(
    factory: &mut Factory,
    extensions: &Extensions,
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
    twap_threshold: u64,
    amm_total_fee_bps: u64,
    description: UTF8String,
    max_outcomes: u64,
    _agreement_lines: vector<UTF8String>,
    _agreement_difficulties: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    create_dao_internal_with_extensions<AssetType, StableType>(
        factory,
        extensions,
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
        clock,
        ctx,
    );
}

/// Internal function to create a DAO with Extensions and optional TreasuryCap
#[allow(lint(share_owned))]
public(package) fun create_dao_internal_with_extensions<AssetType: drop, StableType>(
    factory: &mut Factory,
    extensions: &Extensions,
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
    twap_threshold: u64,
    amm_total_fee_bps: u64,
    description: UTF8String,
    max_outcomes: u64,
    _agreement_lines: vector<UTF8String>,
    _agreement_difficulties: vector<u64>,
    mut treasury_cap: Option<TreasuryCap<AssetType>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Check factory is active
    assert!(!factory.paused, EPaused);
    
    // Check if StableType is allowed
    let stable_type_name = type_name::get<StableType>();
    assert!(factory.allowed_stable_types.contains(&stable_type_name), EStableTypeNotAllowed);
    
    // Process payment
    fee::deposit_dao_creation_payment(fee_manager, payment, clock, ctx);
    
    // Validate parameters
    assert!(twap_step_max >= TWAP_MINIMUM_WINDOW_CAP, ELowTwapWindowCap);
    assert!(review_period_ms <= MAX_REVIEW_TIME, ELongReviewTime);
    assert!(trading_period_ms <= MAX_TRADING_TIME, ELongTradingTime);
    assert!(twap_start_delay <= MAX_TWAP_START_DELAY, ELongTwapDelayTime);
    assert!((twap_start_delay + 60_000) < trading_period_ms, EDelayNearTotalTrading);
    assert!(twap_threshold <= MAX_TWAP_THRESHOLD, EHighTwapThreshold);
    assert!(
        twap_initial_observation <= (18446744073709551615u128) * 1_000_000_000_000,
        ETwapInitialTooLarge,
    );
    
    // Create config parameters using the new structured approach
    let config_params = futarchy_config::new_config_params_from_values(
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
        twap_start_delay,
        twap_step_max,
        twap_initial_observation,
        twap_threshold,
        amm_total_fee_bps,
        max_outcomes,
        1000000, // proposal_fee_per_outcome (1 token per outcome)
        50, // max_concurrent_proposals
        100_000_000, // required_bond_amount
        2_592_000_000, // proposal_recreation_window_ms (30 days default)
        5, // max_proposal_chain_depth
        100, // fee_escalation_basis_points
        dao_name,
        url::new_unsafe(icon_url_string),
        description,
    );
    
    // --- Phase 1: Create all objects in memory (no sharing) ---

    // Create fee manager for this DAO
    let _dao_fee_manager_id = object::id(fee_manager); // Use factory fee manager for now
    
    // Create the spot pool but do not share it yet.
    let spot_pool = account_spot_pool::new<AssetType, StableType>(
        amm_total_fee_bps,
        ctx
    );
    let spot_pool_id = object::id(&spot_pool);
    
    // Create the futarchy configuration
    let mut config = futarchy_config::new<AssetType, StableType>(
        config_params,
        ctx
    );
    
    // Set additional fields that aren't in the constructor
    futarchy_config::set_proposal_queue_id(&mut config, option::none());
    futarchy_config::set_spot_pool_id(&mut config, spot_pool_id);
    futarchy_config::set_dao_pool_id(&mut config, spot_pool_id);
    
    // Create the account with Extensions registry validation for security
    let mut account = futarchy_config::new_account_with_extensions(extensions, config, ctx);
    
    // Get eviction grace period from config for the queue
    let eviction_grace_period_ms = futarchy_config::eviction_grace_period_ms(account::config(&account));
    
    // Now create the priority queue but do not share it yet.
    let queue = priority_queue::new<StableType>(
        object::id(&account), // dao_id
        30, // max_proposer_funded
        50, // max_concurrent_proposals
        eviction_grace_period_ms,
        ctx
    );
    let priority_queue_id = object::id(&queue);
    
    // --- Phase 2: Configure the objects and link them together ---

    // Note: DAO liquidity pool is not used in the new architecture
    // The spot pool handles all liquidity needs
    
    // Update the config with the actual priority queue ID
    let config_mut = futarchy_config::internal_config_mut(&mut account);
    futarchy_config::set_proposal_queue_id(config_mut, option::some(priority_queue_id));
    
    // Action registry removed - using statically-typed pattern
    
    // Initialize the policy registry
    policy_registry::initialize(&mut account, version::current(), ctx);
    
    // Initialize the vault
    futarchy_vault_init::initialize(&mut account, version::current(), ctx);
    
    // If treasury cap provided, lock it using Move framework's currency module
    if (treasury_cap.is_some()) {
        let cap = treasury_cap.extract();
        // Use Move framework's currency::lock_cap for proper treasury cap storage
        // This ensures atomic borrowing and proper permissions management
        let auth = futarchy_config::authenticate(&account, ctx);
        currency::lock_cap(
            auth,
            &mut account,
            cap,
            option::none() // No max supply limit for now
        );
    };
    // Destroy the empty option
    treasury_cap.destroy_none();
    
    // Get account ID before sharing
    let account_id = object::id_address(&account);
    
    // --- Phase 3: Final Atomic Sharing ---
    // All objects are shared at the end of the function. If any step above failed,
    // the transaction would abort and no objects would be created.
    transfer::public_share_object(account);
    account_spot_pool::share(spot_pool);
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
        timestamp: clock.timestamp_ms(),
    });
}

#[test_only]
/// Internal function to create a DAO for testing without Extensions
fun create_dao_internal_test<AssetType: drop, StableType>(
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
    twap_threshold: u64,
    amm_total_fee_bps: u64,
    description: UTF8String,
    max_outcomes: u64,
    _agreement_lines: vector<UTF8String>,
    _agreement_difficulties: vector<u64>,
    mut treasury_cap: Option<TreasuryCap<AssetType>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Check factory is active
    assert!(!factory.paused, EPaused);
    
    // Check if StableType is allowed
    let stable_type_name = type_name::get<StableType>();
    assert!(factory.allowed_stable_types.contains(&stable_type_name), EStableTypeNotAllowed);
    
    // Process payment
    fee::deposit_dao_creation_payment(fee_manager, payment, clock, ctx);
    
    // Validate parameters
    assert!(twap_step_max >= TWAP_MINIMUM_WINDOW_CAP, ELowTwapWindowCap);
    assert!(review_period_ms <= MAX_REVIEW_TIME, ELongReviewTime);
    assert!(trading_period_ms <= MAX_TRADING_TIME, ELongTradingTime);
    assert!(twap_start_delay <= MAX_TWAP_START_DELAY, ELongTwapDelayTime);
    assert!((twap_start_delay + 60_000) < trading_period_ms, EDelayNearTotalTrading);
    assert!(twap_threshold <= MAX_TWAP_THRESHOLD, EHighTwapThreshold);
    assert!(
        twap_initial_observation <= (18446744073709551615u128) * 1_000_000_000_000,
        ETwapInitialTooLarge,
    );
    
    // Create config parameters using the new structured approach
    let config_params = futarchy_config::new_config_params_from_values(
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
        twap_start_delay,
        twap_step_max,
        twap_initial_observation,
        twap_threshold,
        amm_total_fee_bps,
        max_outcomes,
        1000000, // proposal_fee_per_outcome (1 token per outcome)
        50, // max_concurrent_proposals
        100_000_000, // required_bond_amount
        2_592_000_000, // proposal_recreation_window_ms (30 days default)
        5, // max_proposal_chain_depth
        100, // fee_escalation_basis_points
        dao_name,
        url::new_unsafe(icon_url_string),
        description,
    );
    
    // --- Phase 1: Create all objects in memory (no sharing) ---

    // Create fee manager for this DAO
    let _dao_fee_manager_id = object::id(fee_manager); // Use factory fee manager for now
    
    // Create the spot pool but do not share it yet.
    let spot_pool = account_spot_pool::new<AssetType, StableType>(
        amm_total_fee_bps,
        ctx
    );
    let spot_pool_id = object::id(&spot_pool);
    
    // Create the futarchy configuration
    let mut config = futarchy_config::new<AssetType, StableType>(
        config_params,
        ctx
    );
    
    // Set additional fields that aren't in the constructor
    futarchy_config::set_proposal_queue_id(&mut config, option::none());
    futarchy_config::set_spot_pool_id(&mut config, spot_pool_id);
    futarchy_config::set_dao_pool_id(&mut config, spot_pool_id);
    
    // Create the account using test function
    let mut account = futarchy_config::new_account_test(config, ctx);
    
    // Get eviction grace period from config for the queue
    let eviction_grace_period_ms = futarchy_config::eviction_grace_period_ms(account::config(&account));
    
    // Now create the priority queue but do not share it yet.
    let queue = priority_queue::new<StableType>(
        object::id(&account), // dao_id
        30, // max_proposer_funded
        50, // max_concurrent_proposals
        eviction_grace_period_ms,
        ctx
    );
    let priority_queue_id = object::id(&queue);
    
    // --- Phase 2: Configure the objects and link them together ---

    // Update the config with the actual priority queue ID
    let config_mut = futarchy_config::internal_config_mut_test(&mut account);
    futarchy_config::set_proposal_queue_id(config_mut, option::some(priority_queue_id));
    
    // Action registry removed - using statically-typed pattern
    
    // Initialize the vault (test version uses @account_protocol witness)
    {
        use account_protocol::version_witness;
        futarchy_vault_init::initialize(
            &mut account, 
            version_witness::new_for_testing(@account_protocol), 
            ctx
        );
    };
    
    // If treasury cap provided, lock it using Move framework's currency module
    if (treasury_cap.is_some()) {
        let cap = treasury_cap.extract();
        // Use Move framework's currency::lock_cap for proper treasury cap storage
        // This ensures atomic borrowing and proper permissions management
        let auth = futarchy_config::authenticate(&account, ctx);
        currency::lock_cap(
            auth,
            &mut account,
            cap,
            option::none() // No max supply limit for now
        );
    };
    // Destroy the empty option
    treasury_cap.destroy_none();
    
    // Get account ID before sharing
    let account_id = object::id_address(&account);
    
    // --- Phase 3: Final Atomic Sharing ---
    // All objects are shared at the end of the function. If any step above failed,
    // the transaction would abort and no objects would be created.
    transfer::public_share_object(account);
    account_spot_pool::share(spot_pool);
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
        timestamp: clock.timestamp_ms(),
    });
}

// === Admin Functions ===

/// Toggle factory pause state
public entry fun toggle_pause(factory: &mut Factory, cap: &FactoryOwnerCap) {
    assert!(object::id(cap) == factory.owner_cap_id, EBadWitness);
    factory.paused = !factory.paused;
}

/// Add an allowed stable coin type
public entry fun add_allowed_stable_type<StableType>(
    factory: &mut Factory,
    owner_cap: &FactoryOwnerCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(owner_cap) == factory.owner_cap_id, EBadWitness);
    let type_name_val = type_name::get<StableType>();
    
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
    let type_name_val = type_name::get<StableType>();
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

/// Check if factory is paused
public fun is_paused(factory: &Factory): bool {
    factory.paused
}

/// Check if a stable type is allowed
public fun is_stable_type_allowed<StableType>(factory: &Factory): bool {
    let type_name_val = type_name::get<StableType>();
    factory.allowed_stable_types.contains(&type_name_val)
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
        owner_cap_id: object::id(&owner_cap),
        allowed_stable_types: vec_set::empty<TypeName>(),
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
public entry fun create_dao_test<AssetType: drop, StableType>(
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
    twap_threshold: u64,
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
        clock,
        ctx,
    );
}