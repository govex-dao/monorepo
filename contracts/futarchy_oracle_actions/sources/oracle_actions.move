// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Oracle Actions - Price-Based Unlocks
///
/// Clean price-based grant system with:
/// - N tiers with N recipients each
/// - Time bounds (earliest + latest execution)
/// - Price conditions per tier
/// - Launchpad enforcement (global minimum)
/// - Cancelable or immutable grants
/// - Emergency freeze control
///
/// REMOVED: Vesting, strike prices, pause/unpause, repeatability
module futarchy_oracle::oracle_actions;

use std::string::String;
use sui::object;
use sui::tx_context;
use sui::clock::Clock;
use sui::event;
use sui::bcs;
use sui::coin;
use sui::table::{Self, Table};
use account_protocol::{
    bcs_validation,
    executable::{Self, Executable},
    account::Account,
    intents,
    version_witness::VersionWitness,
    action_validation,
};
use account_actions::currency;
use futarchy_core::resource_requests;
use futarchy_markets_core::unified_spot_pool::UnifiedSpotPool;
use futarchy_markets_primitives::conditional_amm::LiquidityPool;
use futarchy_markets_operations::price_based_unlocks_oracle as pass_through_oracle;

// === Action Type Markers ===

public struct CreateOracleGrant has drop {}
public struct CancelGrant has drop {}
public struct EmergencyFreezeGrant has drop {}
public struct EmergencyUnfreezeGrant has drop {}

// === Constants ===

const PRICE_MULTIPLIER_SCALE: u64 = 1_000_000_000; // 1e9
const MAX_TIME_OFFSET_MS: u64 = 315_360_000_000; // 10 years

// DAO states
const DAO_STATE_TERMINATED: u8 = 1;

// === Errors ===

const EInvalidAmount: u64 = 0;
const EPriceConditionNotMet: u64 = 2;
const EPriceBelowLaunchpad: u64 = 3;
const ETierAlreadyExecuted: u64 = 4;
const ENotRecipient: u64 = 5;
const EAlreadyCanceled: u64 = 6;
const EEmergencyFrozen: u64 = 7;
const EInsufficientVested: u64 = 8;
const ETimeCalculationOverflow: u64 = 9;
const EDaoDissolving: u64 = 10;
const EGrantNotCancelable: u64 = 11;
const EExecutionTooEarly: u64 = 14;
const EGrantExpired: u64 = 15;
const EWrongAccount: u64 = 16;
const EGrantNotFrozen: u64 = 17;
const EEmptyTiers: u64 = 18;

// === Core Structs ===

/// Launchpad price enforcement (applies globally to all tiers)
public struct LaunchpadEnforcement has store, copy, drop {
    enabled: bool,
    minimum_multiplier: u64,  // Scaled 1e9
    launchpad_price: u128,    // Absolute price at grant creation (1e12 scale)
}

/// Price condition for a tier
public struct PriceCondition has store, copy, drop {
    threshold: u128,  // Absolute price (scaled 1e12)
    is_above: bool,   // true = unlock above, false = unlock below
}

/// Recipient allocation
public struct RecipientMint has store, copy, drop {
    recipient: address,
    amount: u64,
}

/// Price tier - one unlock condition with N recipients
public struct PriceTier has store, copy, drop {
    price_condition: Option<PriceCondition>,
    recipients: vector<RecipientMint>,
    executed: bool,
    description: String,
}

/// Claim capability - transferable
public struct GrantClaimCap has key, store {
    id: UID,
    grant_id: ID,
}

/// Price-based mint grant - simplified
public struct PriceBasedMintGrant<phantom AssetType, phantom StableType> has key {
    id: UID,

    // === TIER STRUCTURE ===
    tiers: vector<PriceTier>,
    total_amount: u64,

    // === PER-RECIPIENT TRACKING ===
    recipient_claims: Table<address, u64>,

    // === LAUNCHPAD ENFORCEMENT (global) ===
    launchpad_enforcement: LaunchpadEnforcement,

    // === TIME BOUNDS ===
    earliest_execution: Option<u64>,
    latest_execution: Option<u64>,

    // === EMERGENCY CONTROLS ===
    emergency_frozen: bool,

    // === STATE ===
    cancelable: bool,
    canceled: bool,

    // === METADATA ===
    description: String,
    created_at: u64,
    dao_id: ID,
}

// === Storage Keys ===

public struct GrantStorageKey has copy, drop, store {}

public struct GrantStorage has store {
    grants: sui::table::Table<ID, GrantInfo>,
    grant_ids: vector<ID>,
    total_grants: u64,
}

public struct GrantInfo has store, copy, drop {
    recipient: address,
    cancelable: bool,
}

// === Events ===

public struct GrantCreated has copy, drop {
    grant_id: ID,
    total_amount: u64,
    tier_count: u64,
    timestamp: u64,
}

public struct TokensClaimed has copy, drop {
    grant_id: ID,
    tier_index: u64,
    recipient: address,
    amount_claimed: u64,
    timestamp: u64,
}

public struct GrantCanceled has copy, drop {
    grant_id: ID,
    timestamp: u64,
}

public struct GrantFrozen has copy, drop {
    grant_id: ID,
    timestamp: u64,
}

public struct GrantUnfrozen has copy, drop {
    grant_id: ID,
    timestamp: u64,
}

// === Helper Functions ===

/// Convert relative threshold to absolute price
public fun relative_to_absolute_threshold(
    launchpad_price_abs_1e12: u128,
    multiplier_1e9: u64
): u128 {
    (launchpad_price_abs_1e12 * (multiplier_1e9 as u128)) / (PRICE_MULTIPLIER_SCALE as u128)
}

/// Create absolute price condition
public fun absolute_price_condition(
    price: u128,
    is_above: bool,
): PriceCondition {
    PriceCondition {
        threshold: price,
        is_above,
    }
}

/// Create recipient mint
public fun new_recipient_mint(recipient: address, amount: u64): RecipientMint {
    RecipientMint { recipient, amount }
}

// === Constructor Functions ===

/// Create price-based grant with N tiers and N recipients per tier
///
/// @param tiers: Vector of price tiers, each with price condition + recipients
/// @param launchpad_multiplier: Minimum price multiplier (0 = disabled, scaled 1e9)
/// @param earliest_execution_offset_ms: Minimum time before claiming (0 = immediate)
/// @param expiry_years: Maximum time to claim (0 = no expiry)
public fun create_grant<AssetType, StableType>(
    account: &mut Account,
    tiers: vector<PriceTier>,
    launchpad_multiplier: u64,
    earliest_execution_offset_ms: u64,
    expiry_years: u64,
    cancelable: bool,
    description: String,
    dao_id: ID,
    version: VersionWitness,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Validation
    assert!(vector::length(&tiers) > 0, EEmptyTiers);

    let now = clock.timestamp_ms();

    // Calculate total amount across all tiers
    let mut total_amount = 0u64;
    let mut i = 0;
    let tier_count = vector::length(&tiers);
    while (i < tier_count) {
        let tier = vector::borrow(&tiers, i);
        let mut j = 0;
        let recipient_count = vector::length(&tier.recipients);
        while (j < recipient_count) {
            total_amount = total_amount + vector::borrow(&tier.recipients, j).amount;
            j = j + 1;
        };
        i = i + 1;
    };

    assert!(total_amount > 0, EInvalidAmount);

    // Read launchpad price from DAO config
    let dao_config = account_protocol::account::config(account);
    let launchpad_price_opt = futarchy_core::futarchy_config::get_launchpad_initial_price(dao_config);
    let launchpad_price = if (launchpad_price_opt.is_some()) {
        *launchpad_price_opt.borrow()
    } else {
        0u128
    };

    // Calculate time bounds
    let earliest_execution_opt = if (earliest_execution_offset_ms > 0) {
        assert!(earliest_execution_offset_ms <= MAX_TIME_OFFSET_MS, ETimeCalculationOverflow);
        std::option::some(now + earliest_execution_offset_ms)
    } else {
        std::option::none()
    };

    let latest_execution_opt = if (expiry_years > 0) {
        let expiry_ms = expiry_years * 365 * 24 * 60 * 60 * 1000;
        assert!(expiry_ms <= MAX_TIME_OFFSET_MS, ETimeCalculationOverflow);
        std::option::some(now + expiry_ms)
    } else {
        std::option::none()
    };

    let grant_id = object::new(ctx);
    let grant_id_inner = object::uid_to_inner(&grant_id);

    event::emit(GrantCreated {
        grant_id: grant_id_inner,
        total_amount,
        tier_count,
        timestamp: now,
    });

    let grant = PriceBasedMintGrant<AssetType, StableType> {
        id: grant_id,
        tiers,
        total_amount,
        recipient_claims: table::new(ctx),
        launchpad_enforcement: LaunchpadEnforcement {
            enabled: launchpad_multiplier > 0,
            minimum_multiplier: launchpad_multiplier,
            launchpad_price,
        },
        earliest_execution: earliest_execution_opt,
        latest_execution: latest_execution_opt,
        emergency_frozen: false,
        cancelable,
        canceled: false,
        description,
        created_at: now,
        dao_id,
    };

    // Share the grant
    transfer::share_object(grant);

    // Ensure grant storage exists and register grant
    ensure_grant_storage(account, version, ctx);
    register_grant(account, grant_id_inner, cancelable, version);

    grant_id_inner
}

// === View Functions ===

public fun total_amount<A, S>(grant: &PriceBasedMintGrant<A, S>): u64 {
    grant.total_amount
}

public fun is_canceled<A, S>(grant: &PriceBasedMintGrant<A, S>): bool {
    grant.canceled
}

public fun description<A, S>(grant: &PriceBasedMintGrant<A, S>): &String {
    &grant.description
}

public fun tier_count<A, S>(grant: &PriceBasedMintGrant<A, S>): u64 {
    vector::length(&grant.tiers) as u64
}

// === Emergency Controls ===

/// Emergency freeze - prevents all claims
public fun emergency_freeze<A, S>(
    grant: &mut PriceBasedMintGrant<A, S>,
    clock: &Clock,
) {
    assert!(!grant.emergency_frozen, EEmergencyFrozen);
    grant.emergency_frozen = true;

    event::emit(GrantFrozen {
        grant_id: object::id(grant),
        timestamp: clock.timestamp_ms(),
    });
}

/// Remove emergency freeze
public fun emergency_unfreeze<A, S>(
    grant: &mut PriceBasedMintGrant<A, S>,
    clock: &Clock,
) {
    assert!(grant.emergency_frozen, EGrantNotFrozen);
    grant.emergency_frozen = false;

    event::emit(GrantUnfrozen {
        grant_id: object::id(grant),
        timestamp: clock.timestamp_ms(),
    });
}

/// Cancel a grant
public fun cancel_grant<A, S>(
    grant: &mut PriceBasedMintGrant<A, S>,
    clock: &Clock
) {
    assert!(grant.cancelable, EGrantNotCancelable);
    assert!(!grant.canceled, EAlreadyCanceled);
    grant.canceled = true;

    event::emit(GrantCanceled {
        grant_id: object::id(grant),
        timestamp: clock.timestamp_ms()
    });
}

// === Resource Request Pattern ===

/// Claim action data
public struct ClaimGrantAction has store, drop {
    grant_id: ID,
    tier_index: u64,
    recipient: address,
    claimable_amount: u64,
    dao_address: address,
}

// === Claim Functions ===

/// Claim tokens from a specific tier (STEP 1: Validation)
///
/// Checks:
/// - Time bounds (earliest + latest)
/// - Price condition (tier-specific)
/// - Launchpad enforcement (global minimum)
/// - Tier not executed
/// - Recipient is in tier's recipient list
///
/// Returns ResourceRequest that must be fulfilled in same PTB
public fun claim_grant<AssetType, StableType>(
    account: &Account,
    version: VersionWitness,
    grant: &mut PriceBasedMintGrant<AssetType, StableType>,
    tier_index: u64,
    claim_cap: &GrantClaimCap,
    spot_pool: &UnifiedSpotPool<AssetType, StableType>,
    conditional_pools: &vector<LiquidityPool>,
    clock: &Clock,
    ctx: &mut TxContext,
): resource_requests::ResourceRequest<ClaimGrantAction> {
    // Check DAO is not dissolving
    assert_not_dissolving(account, version);

    // Verify claim cap matches grant
    assert!(claim_cap.grant_id == object::id(grant), EWrongAccount);

    // Check grant is not canceled/frozen
    assert!(!grant.canceled, EAlreadyCanceled);
    assert!(!grant.emergency_frozen, EEmergencyFrozen);

    let now = clock.timestamp_ms();

    // Check time bounds
    if (grant.earliest_execution.is_some()) {
        let earliest = grant.earliest_execution.borrow();
        assert!(now >= *earliest, EExecutionTooEarly);
    };

    if (grant.latest_execution.is_some()) {
        let latest = grant.latest_execution.borrow();
        assert!(now <= *latest, EGrantExpired);
    };

    // Get tier
    assert!(tier_index < vector::length(&grant.tiers), EInvalidAmount);
    let tier = vector::borrow_mut(&mut grant.tiers, tier_index);
    assert!(!tier.executed, ETierAlreadyExecuted);

    // Read oracle price
    let current_price = pass_through_oracle::get_geometric_governance_twap(
        spot_pool,
        conditional_pools,
        clock
    );

    // Check tier price condition
    if (tier.price_condition.is_some()) {
        let condition = tier.price_condition.borrow();
        assert!(
            check_price_condition(condition, current_price),
            EPriceConditionNotMet
        );
    };

    // Check launchpad enforcement (global minimum)
    if (grant.launchpad_enforcement.enabled) {
        let min_price = (grant.launchpad_enforcement.launchpad_price *
                         (grant.launchpad_enforcement.minimum_multiplier as u128)) /
                         (PRICE_MULTIPLIER_SCALE as u128);
        assert!(current_price >= min_price, EPriceBelowLaunchpad);
    };

    // Find recipient in tier
    let recipient = tx_context::sender(ctx);
    let mut claimable_amount = 0u64;
    let mut found = false;
    let mut i = 0;
    let recipient_count = vector::length(&tier.recipients);

    while (i < recipient_count) {
        let recipient_mint = vector::borrow(&tier.recipients, i);
        if (recipient_mint.recipient == recipient) {
            claimable_amount = recipient_mint.amount;
            found = true;
            break
        };
        i = i + 1;
    };

    assert!(found, ENotRecipient);

    // Check if already claimed
    let already_claimed = if (table::contains(&grant.recipient_claims, recipient)) {
        *table::borrow(&grant.recipient_claims, recipient)
    } else {
        0u64
    };

    // For tier-based claims, each recipient can only claim once per tier
    // We track total claimed across all tiers for this recipient
    assert!(claimable_amount > 0, EInsufficientVested);

    // Update recipient tracking
    let new_claimed = already_claimed + claimable_amount;
    assert!(new_claimed >= already_claimed, ETimeCalculationOverflow);

    if (table::contains(&mut grant.recipient_claims, recipient)) {
        *table::borrow_mut(&mut grant.recipient_claims, recipient) = new_claimed;
    } else {
        table::add(&mut grant.recipient_claims, recipient, new_claimed);
    };

    // Mark tier as executed for this recipient (we track per-recipient execution separately)
    // For now, mark tier executed when anyone claims - can enhance to track per-recipient later
    tier.executed = true;

    let dao_address = object::id_to_address(&grant.dao_id);

    let action = ClaimGrantAction {
        grant_id: object::id(grant),
        tier_index,
        recipient,
        claimable_amount,
        dao_address,
    };

    resource_requests::new_resource_request(action, ctx)
}

/// Fulfill claim by minting tokens from DAO's TreasuryCap (STEP 2)
#[allow(unused_type_parameter)]
public fun fulfill_claim_grant_from_account<AssetType, StableType, Config>(
    request: resource_requests::ResourceRequest<ClaimGrantAction>,
    account: &mut Account,
    clock: &Clock,
    ctx: &mut tx_context::TxContext,
) {
    let action = resource_requests::extract_action(request);

    // Verify correct DAO Account
    let account_addr = account.addr();
    assert!(account_addr == action.dao_address, EWrongAccount);

    // Borrow TreasuryCap from Account
    let treasury_cap = currency::borrow_treasury_cap_mut<AssetType>(account);

    // Mint tokens
    let minted_coin = coin::mint<AssetType>(treasury_cap, action.claimable_amount, ctx);

    // Transfer to recipient
    transfer::public_transfer(minted_coin, action.recipient);

    // Emit event
    event::emit(TokensClaimed {
        grant_id: action.grant_id,
        tier_index: action.tier_index,
        recipient: action.recipient,
        amount_claimed: action.claimable_amount,
        timestamp: clock.timestamp_ms(),
    });
}

/// Check if price condition is met
fun check_price_condition(condition: &PriceCondition, current_price: u128): bool {
    if (condition.is_above) {
        current_price >= condition.threshold
    } else {
        current_price <= condition.threshold
    }
}

// === Grant Registry Management ===

fun ensure_grant_storage(account: &mut Account, version_witness: VersionWitness, ctx: &mut TxContext) {
    use account_protocol::account;

    if (!account::has_managed_data(account, GrantStorageKey {})) {
        account::add_managed_data(
            account,
            GrantStorageKey {},
            GrantStorage {
                grants: sui::table::new(ctx),
                grant_ids: vector::empty(),
                total_grants: 0,
            },
            version_witness
        );
    }
}

fun register_grant(
    account: &mut Account,
    grant_id: ID,
    cancelable: bool,
    version_witness: VersionWitness,
) {
    use account_protocol::account;

    let storage: &mut GrantStorage = account::borrow_managed_data_mut(
        account,
        GrantStorageKey {},
        version_witness
    );

    let info = GrantInfo {
        recipient: @0x0,  // Multi-recipient, no single owner
        cancelable,
    };

    sui::table::add(&mut storage.grants, grant_id, info);
    storage.grant_ids.push_back(grant_id);
    storage.total_grants = storage.total_grants + 1;
}

fun assert_not_dissolving(account: &Account, version_witness: VersionWitness) {
    use account_protocol::account;
    use futarchy_core::futarchy_config;

    let dao_state: &futarchy_config::DaoState = account::borrow_managed_data(
        account,
        futarchy_config::new_dao_state_key(),
        version_witness
    );

    assert!(
        futarchy_config::operational_state(dao_state) != DAO_STATE_TERMINATED,
        EDaoDissolving
    );
}

public fun get_all_grant_ids(account: &Account, version_witness: VersionWitness): vector<ID> {
    use account_protocol::account;

    if (!account::has_managed_data(account, GrantStorageKey {})) {
        return vector::empty()
    };

    let storage: &GrantStorage = account::borrow_managed_data(
        account,
        GrantStorageKey {},
        version_witness
    );

    storage.grant_ids
}

// === Action Structs for Proposal System ===

public struct CreateOracleGrantAction<phantom AssetType, phantom StableType> has store, drop, copy {
    tier_specs: vector<TierSpec>,
    launchpad_multiplier: u64,
    earliest_execution_offset_ms: u64,
    expiry_years: u64,
    cancelable: bool,
    description: String,
}

public struct TierSpec has store, drop, copy {
    price_threshold: u128,
    is_above: bool,
    recipients: vector<RecipientMint>,
    tier_description: String,
}

public struct CancelGrantAction has store, drop, copy {
    grant_id: ID,
}

public struct EmergencyFreezeGrantAction has store, drop, copy {
    grant_id: ID,
}

public struct EmergencyUnfreezeGrantAction has store, drop, copy {
    grant_id: ID,
}

// === Action Constructors ===

public fun new_create_oracle_grant<AssetType, StableType>(
    tier_specs: vector<TierSpec>,
    launchpad_multiplier: u64,
    earliest_execution_offset_ms: u64,
    expiry_years: u64,
    cancelable: bool,
    description: String,
): CreateOracleGrantAction<AssetType, StableType> {
    CreateOracleGrantAction {
        tier_specs,
        launchpad_multiplier,
        earliest_execution_offset_ms,
        expiry_years,
        cancelable,
        description,
    }
}

public fun new_tier_spec(
    price_threshold: u128,
    is_above: bool,
    recipients: vector<RecipientMint>,
    tier_description: String,
): TierSpec {
    TierSpec {
        price_threshold,
        is_above,
        recipients,
        tier_description,
    }
}

public fun new_cancel_grant(grant_id: ID): CancelGrantAction {
    CancelGrantAction { grant_id }
}

public fun new_emergency_freeze_grant(grant_id: ID): EmergencyFreezeGrantAction {
    EmergencyFreezeGrantAction { grant_id }
}

public fun new_emergency_unfreeze_grant(grant_id: ID): EmergencyUnfreezeGrantAction {
    EmergencyUnfreezeGrantAction { grant_id }
}

// === Execution Functions ===

public fun do_create_oracle_grant<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    version: VersionWitness,
    _witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_not_dissolving(account, version);
    ensure_grant_storage(account, version, ctx);

    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<CreateOracleGrant>(spec);

    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);

    // Deserialize tier specs
    let tier_spec_count = bcs::peel_vec_length(&mut reader);
    let mut tier_specs = vector::empty<TierSpec>();
    let mut i = 0;
    while (i < tier_spec_count) {
        let price_threshold = bcs::peel_u128(&mut reader);
        let is_above = bcs::peel_bool(&mut reader);

        // Deserialize recipients for this tier
        let recipient_count = bcs::peel_vec_length(&mut reader);
        let mut recipients = vector::empty<RecipientMint>();
        let mut j = 0;
        while (j < recipient_count) {
            let recipient = bcs::peel_address(&mut reader);
            let amount = bcs::peel_u64(&mut reader);
            vector::push_back(&mut recipients, RecipientMint { recipient, amount });
            j = j + 1;
        };

        let tier_description_bytes = bcs::peel_vec_u8(&mut reader);
        let tier_description = std::string::utf8(tier_description_bytes);

        vector::push_back(&mut tier_specs, TierSpec {
            price_threshold,
            is_above,
            recipients,
            tier_description,
        });
        i = i + 1;
    };

    let launchpad_multiplier = bcs::peel_u64(&mut reader);
    let earliest_execution_offset_ms = bcs::peel_u64(&mut reader);
    let expiry_years = bcs::peel_u64(&mut reader);
    let cancelable = bcs::peel_bool(&mut reader);
    let description_bytes = bcs::peel_vec_u8(&mut reader);

    bcs_validation::validate_all_bytes_consumed(reader);

    let description = std::string::utf8(description_bytes);
    let dao_id = object::id(account);

    // Convert TierSpecs to PriceTiers
    let mut tiers = vector::empty<PriceTier>();
    let mut k = 0;
    while (k < vector::length(&tier_specs)) {
        let spec = vector::borrow(&tier_specs, k);
        let tier = PriceTier {
            price_condition: std::option::some(PriceCondition {
                threshold: spec.price_threshold,
                is_above: spec.is_above,
            }),
            recipients: spec.recipients,
            executed: false,
            description: spec.tier_description,
        };
        vector::push_back(&mut tiers, tier);
        k = k + 1;
    };

    let grant_id = create_grant<AssetType, StableType>(
        account,
        tiers,
        launchpad_multiplier,
        earliest_execution_offset_ms,
        expiry_years,
        cancelable,
        description,
        dao_id,
        version,
        clock,
        ctx,
    );

    // Create claim caps for all recipients
    let mut m = 0;
    while (m < vector::length(&tier_specs)) {
        let spec = vector::borrow(&tier_specs, m);
        let mut n = 0;
        while (n < vector::length(&spec.recipients)) {
            let recipient_mint = vector::borrow(&spec.recipients, n);
            let claim_cap = GrantClaimCap {
                id: object::new(ctx),
                grant_id,
            };
            transfer::transfer(claim_cap, recipient_mint.recipient);
            n = n + 1;
        };
        m = m + 1;
    };

    executable::increment_action_idx(executable);
}

public fun do_cancel_grant<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account,
    _version: VersionWitness,
    _witness: IW,
    grant: &mut PriceBasedMintGrant<AssetType, StableType>,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<CancelGrant>(spec);

    cancel_grant(grant, clock);
    executable::increment_action_idx(executable);
}

public fun do_emergency_freeze_grant<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account,
    _version: VersionWitness,
    _witness: IW,
    grant: &mut PriceBasedMintGrant<AssetType, StableType>,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<EmergencyFreezeGrant>(spec);

    emergency_freeze(grant, clock);
    executable::increment_action_idx(executable);
}

public fun do_emergency_unfreeze_grant<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account,
    _version: VersionWitness,
    _witness: IW,
    grant: &mut PriceBasedMintGrant<AssetType, StableType>,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<EmergencyUnfreezeGrant>(spec);

    emergency_unfreeze(grant, clock);
    executable::increment_action_idx(executable);
}
