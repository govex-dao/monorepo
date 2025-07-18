module futarchy::factory;

use futarchy::dao;
use futarchy::fee;
use std::ascii::String as AsciiString;
use std::string::String as UTF8String;
use std::type_name;
use std::u64;
use sui::clock::Clock;
use sui::coin::Coin;
use sui::event;
use sui::sui::SUI;
use sui::vec_set::{Self, VecSet};

// === Introduction ===
// This is the entry point and Main Factory of the protocol. It define admin capabilities and creates DAOs

// === Errors ===
const EHighTwapThreshold: u64 = 0;
const EPaused: u64 = 1;
const EAlreadyVerified: u64 = 2;
const EBadWitness: u64 = 3;
const EStableTypeNotAllowed: u64 = 4;
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
const MAX_TWAP_START_DELAY: u64 = 86_400_000; // 1 days in ms
const MAX_TWAP_THRESHOLD: u64 = 1_000_000; //equivilant to requiring 10x increase in price to pass

// === Structs ===
/// One-time witness for factory initialization
public struct FACTORY has drop {}

/// Factory is the main entry point for creating DAOs in the Futarchy protocol.
/// It manages admin capabilities, tracks created DAOs, and enforces creation parameters.
public struct Factory has key, store {
    id: UID,
    dao_count: u64,
    paused: bool,
    allowed_stable_types: VecSet<UTF8String>,
}

public struct FactoryOwnerCap has key, store {
    id: UID,
}

public struct ValidatorAdminCap has key, store {
    id: UID,
}

// === Events ===
public struct VerificationRequested has copy, drop {
    dao_id: ID,
    verification_id: ID,
    requester: address,
    attestation_url: UTF8String,
    timestamp: u64,
}

public struct DAOReviewed has copy, drop {
    dao_id: ID,
    verification_id: ID,
    attestation_url: UTF8String,
    verified: bool,
    validator: address,
    timestamp: u64,
    reject_reason: UTF8String,
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

// === Public Functions ===
fun init(witness: FACTORY, ctx: &mut TxContext) {
    // Verify that the witness is valid and one-time only.
    assert!(sui::types::is_one_time_witness(&witness), EBadWitness);

    // Initialize with an empty set for now
    let allowed_stable_types = vec_set::empty<UTF8String>();

    let factory = Factory {
        id: object::new(ctx),
        dao_count: 0,
        paused: false,
        allowed_stable_types,
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

    // Consuming the witness ensures one-time initialization.
    let _ = witness;
}

public entry fun create_dao<AssetType, StableType>(
    factory: &mut Factory,
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>,
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
    description: UTF8String,
    max_outcomes: u64,
    metadata: vector<UTF8String>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Check factory is active
    assert!(!factory.paused, EPaused);

    // Check if StableType is allowed
    let stable_type_str = get_type_string<StableType>();
    assert!(factory.allowed_stable_types.contains(&stable_type_str), EStableTypeNotAllowed);

    fee_manager.deposit_dao_creation_payment(payment, clock, ctx);

    assert!(amm_twap_step_max >= TWAP_MINIMUM_WINDOW_CAP, ELowTwapWindowCap);
    assert!(review_period_ms <= MAX_REVIEW_TIME, ELongReviewTime);
    assert!(trading_period_ms <= MAX_TRADING_TIME, ELongTradingTime);
    assert!(amm_twap_start_delay <= MAX_TWAP_START_DELAY, ELongTwapDelayTime);
    assert!((amm_twap_start_delay + 60_000) < trading_period_ms, EDelayNearTotalTrading); // Must have one full window of trading
    assert!(twap_threshold <= MAX_TWAP_THRESHOLD, EHighTwapThreshold);
    assert!(
        amm_twap_initial_observation <= (u64::max_value!() as u128) * 1_000_000_000_000,
        ETwapInitialTooLarge,
    );

    // Create DAO and AdminCap
    let dao = dao::create<AssetType, StableType>(
        min_asset_amount,
        min_stable_amount,
        dao_name,
        icon_url_string,
        review_period_ms,
        trading_period_ms,
        amm_twap_start_delay,
        amm_twap_step_max,
        amm_twap_initial_observation,
        twap_threshold,
        description,
        max_outcomes,
        metadata,
        clock,
        ctx,
    );

    // Treasury initialization is now optional
    // DAOs can add treasury later if needed

    // Share the DAO
    transfer::public_share_object(dao);

    // Update state
    factory.dao_count = factory.dao_count + 1;
}

// === Admin Functions ===
public entry fun toggle_pause(factory: &mut Factory, _cap: &FactoryOwnerCap) {
    factory.paused = !factory.paused;
}

public entry fun request_verification(
    fee_manager: &mut fee::FeeManager,
    payment: Coin<SUI>,
    dao: &mut dao::DAO,
    attestation_url: UTF8String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(!dao.is_verified(), EAlreadyVerified);

    fee_manager.deposit_verification_payment(payment, clock, ctx);

    // Generate unique verification ID
    let verification_id = object::new(ctx);
    let verification_id_inner = object::uid_to_inner(&verification_id);
    verification_id.delete();

    // Set pending verification state
    dao.set_pending_verification(attestation_url);

    // Emit event
    event::emit(VerificationRequested {
        dao_id: object::id(dao),
        verification_id: verification_id_inner,
        requester: ctx.sender(),
        attestation_url,
        timestamp: clock.timestamp_ms(),
    });
}

public entry fun verify_dao(
    _validator_cap: &ValidatorAdminCap,
    dao: &mut dao::DAO,
    verification_id: ID,
    attestation_url: UTF8String,
    verified: bool,
    reject_reason: UTF8String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Update verification status with optional new attestation URL
    dao.set_verification(attestation_url, verified);

    // Emit verification event
    event::emit(DAOReviewed {
        dao_id: object::id(dao),
        verification_id,
        attestation_url,
        verified,
        validator: ctx.sender(),
        timestamp: clock.timestamp_ms(),
        reject_reason,
    });
}

/// Adds a new stable coin type to the allowed list
public entry fun add_allowed_stable_type<StableType>(
    factory: &mut Factory,
    _owner_cap: &FactoryOwnerCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let type_str = get_type_string<StableType>();
    if (!factory.allowed_stable_types.contains(&type_str)) {
        factory.allowed_stable_types.insert(type_str);

        event::emit(StableCoinTypeAdded {
            type_str,
            admin: ctx.sender(),
            timestamp: clock.timestamp_ms(),
        });
    }
}

public entry fun remove_allowed_stable_type<StableType>(
    factory: &mut Factory,
    _owner_cap: &FactoryOwnerCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let type_str = get_type_string<StableType>();
    if (factory.allowed_stable_types.contains(&type_str)) {
        factory.allowed_stable_types.remove(&type_str);

        event::emit(StableCoinTypeRemoved {
            type_str,
            admin: ctx.sender(),
            timestamp: clock.timestamp_ms(),
        });
    }
}

public entry fun disable_dao_proposals(dao: &mut dao::DAO, _cap: &FactoryOwnerCap) {
    dao.disable_proposals();
}

public entry fun burn_factory_owner_cap(cap: FactoryOwnerCap) {
    let FactoryOwnerCap { id } = cap;
    id.delete();
}

// === Private Functions ===

fun get_type_string<T>(): UTF8String {
    let type_name_obj = type_name::get_with_original_ids<T>();
    let type_str = type_name_obj.into_string().into_bytes();
    type_str.to_string()
}

// === View Functions ===
public fun dao_count(factory: &Factory): u64 {
    factory.dao_count
}

public fun is_paused(factory: &Factory): bool {
    factory.paused
}

public fun is_stable_type_allowed<StableType>(factory: &Factory): bool {
    let type_str = get_type_string<StableType>();
    factory.allowed_stable_types.contains(&type_str)
}

// === Test Functions ===
#[test_only]
public fun create_factory(ctx: &mut TxContext) {
    let factory = Factory {
        id: object::new(ctx),
        dao_count: 0,
        paused: false,
        allowed_stable_types: {
            let mut set = vec_set::empty<UTF8String>();
            let stable_str = get_type_string<futarchy::stable_coin::STABLE_COIN>();
            set.insert(stable_str);
            set
        },
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
public fun check_stable_type_allowed<StableType>(factory: &Factory) {
    let type_str = get_type_string<StableType>();
    // Abort with EStableTypeNotAllowed if not allowed.
    assert!(factory.allowed_stable_types.contains(&type_str), EStableTypeNotAllowed);
}
