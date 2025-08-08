/// Factory for creating futarchy DAOs using account_protocol
/// This is the main entry point for creating DAOs in the Futarchy protocol
module futarchy::factory;

// === Imports ===
use std::{
    string::{String as UTF8String},
    ascii::String as AsciiString,
    type_name,
    option::{Self, Option},
};
use sui::{
    clock::Clock,
    coin::{Self, Coin, TreasuryCap},
    event,
    object::{Self, ID, UID},
    sui::SUI,
    vec_set::{Self, VecSet},
    table::{Self, Table},
    transfer,
    url,
};
use account_protocol::{
    account::{Self, Account},
};
use account_extensions::extensions::Extensions;
use futarchy::{
    futarchy_config::{Self, FutarchyConfig, ConfigParams},
    futarchy_vault_init,
    fee::{Self, FeeManager},
    priority_queue::{Self, ProposalQueue},
    account_spot_pool::{Self, AccountSpotPool},
    action_registry,
    version,
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
    allowed_stable_types: VecSet<UTF8String>,
    min_raise_amounts: Table<UTF8String, u64>,
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
    min_raise_amount: u64,
}

public struct StableCoinTypeRemoved has copy, drop {
    type_str: UTF8String,
    admin: address,
    timestamp: u64,
}

// === Internal Helper Functions ===

/// Register all native futarchy actions in the ActionRegistry
fun register_native_actions(
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext,
) {
    use futarchy::{
        config_actions,
        advanced_config_actions,
        dissolution_actions,
        operating_agreement_actions,
        registry_actions,
        futarchy_vault,
    };
    
    // Register config actions
    action_registry::register_native_action<config_actions::SetProposalsEnabledAction>(
        account,
        b"config_actions".to_string(),
        b"do_set_proposals_enabled".to_string(),
        ctx
    );
    
    action_registry::register_native_action<config_actions::UpdateNameAction>(
        account,
        b"config_actions".to_string(),
        b"do_update_name".to_string(),
        ctx
    );
    
    // Register advanced config actions
    action_registry::register_native_action<advanced_config_actions::TradingParamsUpdateAction>(
        account,
        b"advanced_config_actions".to_string(),
        b"do_update_trading_params".to_string(),
        ctx
    );
    
    action_registry::register_native_action<advanced_config_actions::MetadataUpdateAction>(
        account,
        b"advanced_config_actions".to_string(),
        b"do_update_metadata".to_string(),
        ctx
    );
    
    action_registry::register_native_action<advanced_config_actions::TwapConfigUpdateAction>(
        account,
        b"advanced_config_actions".to_string(),
        b"do_update_twap_config".to_string(),
        ctx
    );
    
    action_registry::register_native_action<advanced_config_actions::GovernanceUpdateAction>(
        account,
        b"advanced_config_actions".to_string(),
        b"do_update_governance".to_string(),
        ctx
    );
    
    action_registry::register_native_action<advanced_config_actions::SlashDistributionUpdateAction>(
        account,
        b"advanced_config_actions".to_string(),
        b"do_update_slash_distribution".to_string(),
        ctx
    );
    
    // Register dissolution actions
    action_registry::register_native_action<dissolution_actions::InitiateDissolutionAction>(
        account,
        b"dissolution_actions".to_string(),
        b"do_initiate_dissolution".to_string(),
        ctx
    );
    
    action_registry::register_native_action<dissolution_actions::CancelDissolutionAction>(
        account,
        b"dissolution_actions".to_string(),
        b"do_cancel_dissolution".to_string(),
        ctx
    );
    
    action_registry::register_native_action<dissolution_actions::FinalizeDissolutionAction>(
        account,
        b"dissolution_actions".to_string(),
        b"do_finalize_dissolution".to_string(),
        ctx
    );
    
    // Register operating agreement actions
    action_registry::register_native_action<operating_agreement_actions::OperatingAgreementAction>(
        account,
        b"operating_agreement_actions".to_string(),
        b"do_execute_operating_agreement".to_string(),
        ctx
    );
    
    action_registry::register_native_action<operating_agreement_actions::UpdateLineAction>(
        account,
        b"operating_agreement_actions".to_string(),
        b"do_update_line".to_string(),
        ctx
    );
    
    action_registry::register_native_action<operating_agreement_actions::InsertLineAfterAction>(
        account,
        b"operating_agreement_actions".to_string(),
        b"do_insert_line_after".to_string(),
        ctx
    );
    
    action_registry::register_native_action<operating_agreement_actions::RemoveLineAction>(
        account,
        b"operating_agreement_actions".to_string(),
        b"do_remove_line".to_string(),
        ctx
    );
    
    // Note: Vault actions with generic coin types cannot be pre-registered
    // They need specific coin types and are registered on demand
    // Example: AddCoinTypeAction<SUI>, RemoveCoinTypeAction<USDC>
    // These are handled dynamically when needed
    
    // Register registry management actions  
    action_registry::register_native_action<registry_actions::RegisterActionAction>(
        account,
        b"registry_actions".to_string(),
        b"do_register_action".to_string(),
        ctx
    );
    
    action_registry::register_native_action<registry_actions::SetActionStatusAction>(
        account,
        b"registry_actions".to_string(),
        b"do_set_action_status".to_string(),
        ctx
    );
    
    action_registry::register_native_action<registry_actions::DeregisterActionAction>(
        account,
        b"registry_actions".to_string(),
        b"do_deregister_action".to_string(),
        ctx
    );
}

/// Test version of register_native_actions
#[test_only]
fun register_native_actions_for_testing(
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext,
) {
    use futarchy::{
        config_actions,
        advanced_config_actions,
        dissolution_actions,
        operating_agreement_actions,
        registry_actions,
    };
    
    // Register config actions
    action_registry::register_native_action_for_testing<config_actions::SetProposalsEnabledAction>(
        account,
        b"config_actions".to_string(),
        b"do_set_proposals_enabled".to_string(),
        ctx
    );
    
    action_registry::register_native_action_for_testing<config_actions::UpdateNameAction>(
        account,
        b"config_actions".to_string(),
        b"do_update_name".to_string(),
        ctx
    );
    
    // Register some essential actions for testing
    action_registry::register_native_action_for_testing<advanced_config_actions::TradingParamsUpdateAction>(
        account,
        b"advanced_config_actions".to_string(),
        b"do_update_trading_params".to_string(),
        ctx
    );
}

// === Public Functions ===

fun init(witness: FACTORY, ctx: &mut TxContext) {
    assert!(sui::types::is_one_time_witness(&witness), EBadWitness);
    
    let factory = Factory {
        id: object::new(ctx),
        dao_count: 0,
        paused: false,
        allowed_stable_types: vec_set::empty<UTF8String>(),
        min_raise_amounts: table::new(ctx),
    };
    
    let owner_cap = FactoryOwnerCap {
        id: object::new(ctx),
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
    let stable_type_str = get_type_string<StableType>();
    assert!(factory.allowed_stable_types.contains(&stable_type_str), EStableTypeNotAllowed);
    
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
    
    // Create a temporary priority queue ID (will create the actual queue later)
    let temp_queue_id = object::id_from_address(@0x0);
    
    // Create fee manager for this DAO
    let _dao_fee_manager_id = object::id(fee_manager); // Use factory fee manager for now
    
    // Create the spot pool
    let spot_pool = account_spot_pool::new<AssetType, StableType>(
        amm_total_fee_bps,
        ctx
    );
    let spot_pool_id = object::id(&spot_pool);
    account_spot_pool::share(spot_pool);
    
    // Create a temporary DAO pool ID (will create the actual pool later)
    let temp_dao_pool_id = object::id_from_address(@0x0);
    
    // Create the futarchy configuration
    let mut config = futarchy_config::new<AssetType, StableType>(
        config_params,
        ctx
    );
    
    // Set additional fields that aren't in the constructor
    futarchy_config::set_proposal_queue_id(&mut config, option::some(temp_queue_id));
    futarchy_config::set_spot_pool_id(&mut config, spot_pool_id);
    futarchy_config::set_dao_pool_id(&mut config, temp_dao_pool_id);
    
    // Create the account with unverified_allowed to bypass deps validation
    let mut account = futarchy_config::new_account_unverified(extensions, config, ctx);
    
    // Now create the priority queue with the actual DAO ID
    let priority_queue_id = {
        let queue = priority_queue::new<StableType>(
            object::id(&account), // dao_id
            30, // max_proposer_funded
            50, // max_concurrent_proposals
            ctx
        );
        let id = object::id(&queue);
        transfer::public_share_object(queue);
        id
    };
    
    // Note: DAO liquidity pool is not used in the new architecture
    // The spot pool handles all liquidity needs
    
    // Update the config with the actual priority queue ID
    let config_mut = futarchy_config::internal_config_mut(&mut account);
    futarchy_config::set_proposal_queue_id(config_mut, option::some(priority_queue_id));
    
    // Initialize the ActionRegistry for extensible actions
    action_registry::init_registry(
        &mut account,
        false, // Don't require publisher verification by default
        ctx
    );
    
    // Register native futarchy actions
    register_native_actions(&mut account, ctx);
    
    // Initialize the vault
    futarchy_vault_init::initialize(&mut account, version::current(), ctx);
    
    // If treasury cap provided, store it
    if (treasury_cap.is_some()) {
        let cap = treasury_cap.extract();
        // Store treasury cap as managed asset
        account::add_managed_asset(
            &mut account,
            b"treasury_cap".to_string(),
            cap,
            version::current()
        );
    };
    // Destroy the empty option
    treasury_cap.destroy_none();
    
    // Get account ID before sharing
    let account_id = object::id_address(&account);
    
    // Share the account
    transfer::public_share_object(account);
    
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
    let stable_type_str = get_type_string<StableType>();
    assert!(factory.allowed_stable_types.contains(&stable_type_str), EStableTypeNotAllowed);
    
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
    
    // Create a temporary priority queue ID (will create the actual queue later)
    let temp_queue_id = object::id_from_address(@0x0);
    
    // Create fee manager for this DAO
    let _dao_fee_manager_id = object::id(fee_manager); // Use factory fee manager for now
    
    // Create the spot pool
    let spot_pool = account_spot_pool::new<AssetType, StableType>(
        amm_total_fee_bps,
        ctx
    );
    let spot_pool_id = object::id(&spot_pool);
    account_spot_pool::share(spot_pool);
    
    // Create a temporary DAO pool ID (will create the actual pool later)
    let temp_dao_pool_id = object::id_from_address(@0x0);
    
    // Create the futarchy configuration
    let mut config = futarchy_config::new<AssetType, StableType>(
        config_params,
        ctx
    );
    
    // Set additional fields that aren't in the constructor
    futarchy_config::set_proposal_queue_id(&mut config, option::some(temp_queue_id));
    futarchy_config::set_spot_pool_id(&mut config, spot_pool_id);
    futarchy_config::set_dao_pool_id(&mut config, temp_dao_pool_id);
    
    // Create the account using test function
    let mut account = futarchy_config::new_account_test(config, ctx);
    
    // Now create the priority queue with the actual DAO ID
    let priority_queue_id = {
        let queue = priority_queue::new<StableType>(
            object::id(&account), // dao_id
            30, // max_proposer_funded
            50, // max_concurrent_proposals
            ctx
        );
        let id = object::id(&queue);
        transfer::public_share_object(queue);
        id
    };
    
    // Update the config with the actual priority queue ID
    let config_mut = futarchy_config::internal_config_mut_test(&mut account);
    futarchy_config::set_proposal_queue_id(config_mut, option::some(priority_queue_id));
    
    // Initialize the ActionRegistry for testing
    action_registry::init_registry_for_testing(
        &mut account,
        false,
        ctx
    );
    
    // Register native actions for testing
    register_native_actions_for_testing(&mut account, ctx);
    
    // Initialize the vault (test version uses @account_protocol witness)
    {
        use account_protocol::version_witness;
        futarchy_vault_init::initialize(
            &mut account, 
            version_witness::new_for_testing(@account_protocol), 
            ctx
        );
    };
    
    // If treasury cap provided, store it
    if (treasury_cap.is_some()) {
        let cap = treasury_cap.extract();
        // Store treasury cap as managed asset
        account::add_managed_asset(
            &mut account,
            b"treasury_cap".to_string(),
            cap,
            account_protocol::version_witness::new_for_testing(@account_protocol)
        );
    };
    // Destroy the empty option
    treasury_cap.destroy_none();
    
    // Get account ID before sharing
    let account_id = object::id_address(&account);
    
    // Share the account
    transfer::public_share_object(account);
    
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
public entry fun toggle_pause(factory: &mut Factory, _cap: &FactoryOwnerCap) {
    factory.paused = !factory.paused;
}

/// Add an allowed stable coin type
public entry fun add_allowed_stable_type<StableType>(
    factory: &mut Factory,
    _owner_cap: &FactoryOwnerCap,
    min_raise_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let type_str = get_type_string<StableType>();
    assert!(min_raise_amount > 0, 0);
    
    if (!factory.allowed_stable_types.contains(&type_str)) {
        factory.allowed_stable_types.insert(type_str);
        factory.min_raise_amounts.add(type_str, min_raise_amount);
        
        event::emit(StableCoinTypeAdded {
            type_str,
            admin: ctx.sender(),
            timestamp: clock.timestamp_ms(),
            min_raise_amount,
        });
    }
}

/// Remove an allowed stable coin type
public entry fun remove_allowed_stable_type<StableType>(
    factory: &mut Factory,
    _owner_cap: &FactoryOwnerCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let type_str = get_type_string<StableType>();
    if (factory.allowed_stable_types.contains(&type_str)) {
        factory.allowed_stable_types.remove(&type_str);
        if (factory.min_raise_amounts.contains(type_str)) {
            factory.min_raise_amounts.remove(type_str);
        };
        
        event::emit(StableCoinTypeRemoved {
            type_str,
            admin: ctx.sender(),
            timestamp: clock.timestamp_ms(),
        });
    }
}

/// Update minimum raise amount for a stable type
public entry fun update_min_raise_amount<StableType>(
    factory: &mut Factory,
    _owner_cap: &FactoryOwnerCap,
    new_min_raise_amount: u64,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    let type_str = get_type_string<StableType>();
    assert!(factory.allowed_stable_types.contains(&type_str), EStableTypeNotAllowed);
    assert!(new_min_raise_amount > 0, 0);
    
    let current_amount = factory.min_raise_amounts.borrow_mut(type_str);
    *current_amount = new_min_raise_amount;
}

/// Burn the factory owner cap
public entry fun burn_factory_owner_cap(cap: FactoryOwnerCap) {
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
    let type_str = get_type_string<StableType>();
    factory.allowed_stable_types.contains(&type_str)
}

/// Get minimum raise amount for a stable type
public fun get_min_raise_amount<StableType>(factory: &Factory): u64 {
    let type_str = get_type_string<StableType>();
    assert!(factory.allowed_stable_types.contains(&type_str), EStableTypeNotAllowed);
    *factory.min_raise_amounts.borrow(type_str)
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
    let factory = Factory {
        id: object::new(ctx),
        dao_count: 0,
        paused: false,
        allowed_stable_types: vec_set::empty<UTF8String>(),
        min_raise_amounts: table::new(ctx),
    };
    
    let owner_cap = FactoryOwnerCap {
        id: object::new(ctx),
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