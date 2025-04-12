module futarchy::factory;

use futarchy::dao;
use futarchy::fee;
use std::ascii::{Self, String as AsciiString};
use std::string::{Self, String as UTF8String};
use std::type_name;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin, CoinMetadata};
use sui::event;
use sui::sui::SUI;
use sui::transfer::{public_share_object, public_transfer};
use sui::url;
use sui::vec_set::{Self, VecSet};

// === Introduction ===
// This is the entry point and Main Factory of the protocol. It define admin capabilities and creates DAOs

// === Errors ===
const EHIGH_TWAP_THRESHOLD: u64 = 0;
const EPAUSED: u64 = 1;
const EALREADY_VERIFIED: u64 = 2;
const EBAD_WITNESS: u64 = 3;
const ESTABLE_TYPE_NOT_ALLOWED: u64 = 4;
const TWAP_TWAP_WINDOW_CAP: u64 = 5;
const ELONG_TRADING_TIME: u64 = 6;
const ELONG_REVIEW_TIME: u64 = 7;
const ELONG_TWAP_DELAY_TIME: u64 = 8;

// === Constants ===
const TWAP_MINIMUM_WINDOW_CAP: u64 = 1; // Equals 0.01%
const MAX_TRADING_TIME: u64 = 604_800_000;
const MAX_REVIEW_TIME: u64 = 604_800_000;
const MAX_TWAP_START_DELAY: u64 = 86_400_000;
const MAX_TWAP_THRESHOLD: u64 = 1_000_000; //equivilant to requiring 10x increase in price to pass

// === Structs ===
public struct FACTORY has drop {}

public struct Factory has key, store {
    id: UID,
    dao_count: u64,
    paused: bool,
    allowed_stable_types: VecSet<UTF8String>,
}

public struct FactoryOwnerCap has key, store {
    id: UID,
}

// New validator admin capability
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

// ======== Constructor ========
fun init(witness: FACTORY, ctx: &mut TxContext) {
    // Verify that the witness is valid and one-time only.
    assert!(sui::types::is_one_time_witness(&witness), EBAD_WITNESS);

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

    public_share_object(factory);
    public_transfer(owner_cap, ctx.sender());
    public_transfer(validator_cap, ctx.sender());

    // Consuming the witness ensures one-time initialization.
    let _ = witness;
}

// ======== Core Functions ========
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
    asset_metadata: &CoinMetadata<AssetType>,
    stable_metadata: &CoinMetadata<StableType>,
    amm_twap_start_delay: u64,
    amm_twap_step_max: u64,
    amm_twap_initial_observation: u128,
    twap_threshold: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Check factory is active
    assert!(!factory.paused, EPAUSED);

    // Check if StableType is allowed
    let stable_type_str = get_type_string<StableType>();
    assert!(
        vec_set::contains(&factory.allowed_stable_types, &stable_type_str),
        ESTABLE_TYPE_NOT_ALLOWED,
    );

    fee::deposit_verification_payment(fee_manager, payment, clock, ctx);

    let asset_decimals = coin::get_decimals(asset_metadata);
    let stable_decimals = coin::get_decimals(stable_metadata);
    let asset_name = coin::get_name(asset_metadata);
    let stable_name = coin::get_name(stable_metadata);

    // 1) Retrieve icon Option<URL> for the asset
    let maybe_asset_icon = coin::get_icon_url(asset_metadata);

    // 2) Use a single `if/else` expression that returns an AsciiString
    let asset_icon_url = if (std::option::is_none(&maybe_asset_icon)) {
        ascii::string(vector[])
    } else {
        let url_ref = std::option::borrow(&maybe_asset_icon);
        url::inner_url(url_ref)
    };

    // Same pattern for stable icon
    let maybe_stable_icon = coin::get_icon_url(stable_metadata);
    let stable_icon_url = if (std::option::is_none(&maybe_stable_icon)) {
        ascii::string(vector[])
    } else {
        let url_ref = std::option::borrow(&maybe_stable_icon);
        url::inner_url(url_ref)
    };

    let asset_symbol = coin::get_symbol(asset_metadata);
    let stable_symbol = coin::get_symbol(stable_metadata);

    assert!(amm_twap_step_max >= TWAP_MINIMUM_WINDOW_CAP, TWAP_TWAP_WINDOW_CAP);
    assert!(review_period_ms <= MAX_REVIEW_TIME, ELONG_REVIEW_TIME);
    assert!(trading_period_ms <= MAX_TRADING_TIME, ELONG_TRADING_TIME);
    assert!(amm_twap_start_delay <= MAX_TWAP_START_DELAY, ELONG_TWAP_DELAY_TIME);
    assert!(twap_threshold <= MAX_TWAP_THRESHOLD, EHIGH_TWAP_THRESHOLD);

    // Create DAO and AdminCap
    dao::create<AssetType, StableType>(
        min_asset_amount,
        min_stable_amount,
        dao_name,
        icon_url_string,
        review_period_ms,
        trading_period_ms,
        asset_decimals,
        stable_decimals,
        asset_name,
        stable_name,
        asset_icon_url,
        stable_icon_url,
        asset_symbol,
        stable_symbol,
        amm_twap_start_delay,
        amm_twap_step_max,
        amm_twap_initial_observation,
        twap_threshold,
        clock,
        ctx,
    );

    // Update state
    factory.dao_count = factory.dao_count + 1;
}

// ======== Admin Functions ========

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
    assert!(!dao::is_verified(dao), EALREADY_VERIFIED);

    fee::deposit_dao_creation_payment(fee_manager, payment, clock, ctx);

    // Generate unique verification ID
    let verification_id = object::new(ctx);
    let verification_id_inner = object::uid_to_inner(&verification_id);
    object::delete(verification_id);

    // Set pending verification state
    dao::set_pending_verification(dao, attestation_url);

    // Emit event
    event::emit(VerificationRequested {
        dao_id: object::id(dao),
        verification_id: verification_id_inner,
        requester: ctx.sender(),
        attestation_url,
        timestamp: clock.timestamp_ms(),
    });
}

// Pass option::none() to keep the existing attestation URL
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
    dao::set_verification(dao, attestation_url, verified);

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

// ======== Stable Coin Type Management ========
public entry fun add_allowed_stable_type<StableType>(
    factory: &mut Factory,
    _owner_cap: &FactoryOwnerCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let type_str = get_type_string<StableType>();
    if (!vec_set::contains(&factory.allowed_stable_types, &type_str)) {
        vec_set::insert(&mut factory.allowed_stable_types, type_str);

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
    if (vec_set::contains(&factory.allowed_stable_types, &type_str)) {
        vec_set::remove(&mut factory.allowed_stable_types, &type_str);

        event::emit(StableCoinTypeRemoved {
            type_str,
            admin: ctx.sender(),
            timestamp: clock.timestamp_ms(),
        });
    }
}

public entry fun disable_dao_proposals(dao: &mut dao::DAO, _cap: &FactoryOwnerCap) {
    dao::disable_proposals(dao);
}

public entry fun burn_factory_owner_cap(cap: FactoryOwnerCap) {
    let FactoryOwnerCap { id } = cap;
    object::delete(id);
}

// ======== Helper Functions ========
/// Convert a type to a string representation
fun get_type_string<T>(): UTF8String {
    let type_name_obj = type_name::get_with_original_ids<T>();
    let type_str = type_name_obj.into_string().into_bytes();
    string::utf8(type_str)
}

// ======== View Functions ========
public fun dao_count(factory: &Factory): u64 {
    factory.dao_count
}

public fun is_paused(factory: &Factory): bool {
    factory.paused
}

public fun is_stable_type_allowed<StableType>(factory: &Factory): bool {
    let type_str = get_type_string<StableType>();
    vec_set::contains(&factory.allowed_stable_types, &type_str)
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
            vec_set::insert(&mut set, stable_str);
            set
        },
    };

    let owner_cap = FactoryOwnerCap {
        id: object::new(ctx),
    };

    let validator_cap = ValidatorAdminCap {
        id: object::new(ctx),
    };

    public_share_object(factory);
    public_transfer(owner_cap, ctx.sender());
    public_transfer(validator_cap, ctx.sender());
}

#[test_only]
public fun check_stable_type_allowed<StableType>(factory: &Factory) {
    let type_str = get_type_string<StableType>();
    // Abort with ESTABLE_TYPE_NOT_ALLOWED if not allowed.
    assert!(vec_set::contains(&factory.allowed_stable_types, &type_str), ESTABLE_TYPE_NOT_ALLOWED);
}
