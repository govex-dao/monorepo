/// Oracle Actions - Price-Based Minting and Grants
///
/// Complete oracle grant system with action structs, execution functions, and grant management.
///
/// Unified system combining:
/// - Employee Options: Vesting with strike prices and launchpad multipliers
/// - Vesting Grants: Simple vesting without strike prices
/// - Milestone Rewards: Multi-tier price-based minting
/// - Conditional Mints: Repeatable price-triggered minting
///
/// Features:
/// - Launchpad price enforcement: Only mint/exercise above configurable multiple of launchpad price
/// - Pause/Resume: Temporary suspension of grants
/// - Emergency Freeze: Admin emergency stop
/// - Cancellation: Return unvested tokens to treasury
///
/// PRICE MULTIPLIERS:
/// - Scaled by 1e9 for precision (e.g., 3_500_000_000 = 3.5x launchpad price)
module futarchy_oracle::oracle_actions;

use std::string::String;
use std::option::Option;
use std::vector;
use sui::object::{Self, ID, UID};
use sui::tx_context::TxContext;
use sui::clock::Clock;
use sui::event;
use sui::transfer;
use sui::bcs;
use account_protocol::{
    bcs_validation,
    executable::{Self, Executable},
    account::Account,
    intents,
    version_witness::VersionWitness,
};
use account_actions::stream_utils;
use futarchy_core::{
    action_validation,
    action_types,
    futarchy_config::FutarchyConfig,
};

// === Constants ===

const PRICE_MULTIPLIER_SCALE: u64 = 1_000_000_000; // 1e9
const MAX_VESTING_DURATION_MS: u64 = 315_360_000_000; // 10 years

// DAO operational states (for dissolution check)
const DAO_STATE_DISSOLVING: u8 = 1;

// === Storage Keys ===

/// Key for accessing grant registry in Account managed data
public struct GrantStorageKey has copy, drop, store {}

/// Registry of all grants created by this DAO
/// Stored in Account managed data for dissolution cleanup
public struct GrantStorage has store {
    grants: sui::table::Table<ID, GrantInfo>,
    grant_ids: vector<ID>,  // Track IDs for iteration during dissolution
    total_grants: u64,
}

/// Minimal grant info stored in registry
public struct GrantInfo has store, copy, drop {
    recipient: address,
    cancelable: bool,
    grant_type: u8,  // 0=employee_option, 1=vesting_grant, 2=tiered, 3=conditional
}

// === Errors ===

const EInvalidAmount: u64 = 0;
const EInvalidDuration: u64 = 1;
const EPriceConditionNotMet: u64 = 2;
const EPriceBelowLaunchpad: u64 = 3;
const ENotVestedYet: u64 = 4;
const ETierAlreadyExecuted: u64 = 5;
const ENotRecipient: u64 = 6;
const EAlreadyCanceled: u64 = 7;
const ERepeatCooldownNotMet: u64 = 8;
const EMaxExecutionsReached: u64 = 9;
const EGrantPaused: u64 = 10;
const EGrantNotPaused: u64 = 11;
const EEmergencyFrozen: u64 = 12;
const EWrongGrantId: u64 = 13;
const EInsufficientVested: u64 = 14;
const ETimeCalculationOverflow: u64 = 15;
const EDaoDissolving: u64 = 16;
const EGrantNotCancelable: u64 = 17;
const EEmptyRecipients: u64 = 18;
const ERecipientAmountMismatch: u64 = 19;
const EInvalidVestingMode: u64 = 20;
const EInvalidStrikeMode: u64 = 21;
const EInvalidGrantAmount: u64 = 22;
const EExecutionTooEarly: u64 = 23;

// === Core Structs ===

/// Vesting configuration
public struct VestingConfig has store, copy, drop {
    start_time: u64,
    cliff_duration: u64,
    total_duration: u64,
}

/// Price condition (used by both single-recipient and tiers)
public struct PriceCondition has store, copy, drop {
    // Mode: 0 = launchpad-relative, 1 = absolute
    mode: u8,
    // If mode == 0: launchpad multiplier (scaled 1e9)
    // If mode == 1: absolute price (scaled 1e12)
    value: u128,
    is_above: bool,
}

/// Launchpad price enforcement
public struct LaunchpadEnforcement has store, copy, drop {
    enabled: bool,
    minimum_multiplier: u64,  // Scaled 1e9
}

/// Repeatability configuration
public struct RepeatConfig has store, copy, drop {
    cooldown_ms: u64,
    max_executions: u64,      // 0 = unlimited
    execution_count: u64,
    last_execution: Option<u64>,
}

/// Recipient allocation for tiers
public struct RecipientMint has store, copy, drop {
    recipient: address,
    amount: u64,
}

/// Price tier - supports vesting and strike price per tier
public struct PriceTier has store, copy, drop {
    price_condition: Option<PriceCondition>,  // Unlock condition (None = no unlock requirement)
    recipients: vector<RecipientMint>,
    vesting: Option<VestingConfig>,           // Per-tier vesting schedule
    strike_price: Option<u64>,                // Per-tier strike price
    executed: bool,
    description: String,
}

/// Claim capability - can be transferred/sold
public struct GrantClaimCap has key, store {
    id: UID,
    grant_id: ID,
}

/// Unified grant - everything is tier-based (1 tier = simple grant, N tiers = complex)
public struct PriceBasedMintGrant<phantom AssetType, phantom StableType> has key {
    id: UID,

    // === TIER STRUCTURE ===
    // All grants use tiers (even "simple" grants have 1 tier)
    // Each tier contains: price_condition, recipients, vesting, strike_price
    tiers: vector<PriceTier>,

    // === TOTAL TRACKING ===
    total_amount: u64,        // Sum of all tier amounts
    claimed_amount: u64,      // Total claimed across all tiers

    // === LAUNCHPAD ENFORCEMENT (applies to ALL claims across all tiers) ===
    launchpad_enforcement: LaunchpadEnforcement,

    // === REPEATABILITY (applies to whole grant) ===
    repeat_config: Option<RepeatConfig>,

    // === TIME BOUNDS (applies to whole grant) ===
    earliest_execution: Option<u64>,
    latest_execution: Option<u64>,

    // === EMERGENCY CONTROLS ===
    paused: bool,
    paused_until: Option<u64>,  // None = indefinite, Some(ts) = pause until timestamp
    paused_at: Option<u64>,
    paused_duration: u64,       // Accumulated pause time
    emergency_frozen: bool,     // If true, even unpause won't work

    // === STATE ===
    cancelable: bool,
    canceled: bool,

    // === METADATA ===
    description: String,
    created_at: u64,
    dao_id: ID,
}

// === Events ===

public struct GrantCreated has copy, drop {
    grant_id: ID,
    recipient: Option<address>,
    total_amount: u64,
    has_strike_price: bool,
    has_vesting: bool,
    has_tiers: bool,
    timestamp: u64,
}

public struct TokensClaimed has copy, drop {
    grant_id: ID,
    recipient: address,
    amount_claimed: u64,
    timestamp: u64,
}

public struct TierExecuted has copy, drop {
    grant_id: ID,
    tier_index: u64,
    price_at_execution: u128,
    total_minted: u64,
    timestamp: u64,
}

public struct GrantCanceled has copy, drop {
    grant_id: ID,
    unvested_amount: u64,
    timestamp: u64,
}

public struct GrantPaused has copy, drop {
    grant_id: ID,
    paused_until: Option<u64>,  // None = indefinite
    timestamp: u64,
}

public struct GrantUnpaused has copy, drop {
    grant_id: ID,
    pause_duration: u64,
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

/// Create launchpad-relative price condition
public fun relative_price_condition(
    multiplier: u64,     // Scaled 1e9
    is_above: bool,
): PriceCondition {
    PriceCondition {
        mode: 0,
        value: (multiplier as u128),
        is_above,
    }
}

/// Create absolute price condition
public fun absolute_price_condition(
    price: u128,         // Scaled 1e12
    is_above: bool,
): PriceCondition {
    PriceCondition {
        mode: 1,
        value: price,
        is_above,
    }
}

/// Create repeat configuration
public fun repeat_config(
    cooldown_ms: u64,
    max_executions: u64,
): RepeatConfig {
    RepeatConfig {
        cooldown_ms,
        max_executions,
        execution_count: 0,
        last_execution: std::option::none(),
    }
}

// === Constructor Functions ===

/// Create employee stock option (simple grant = 1 tier with vesting + strike)
public fun create_employee_option<AssetType, StableType>(
    recipient: address,
    total_amount: u64,
    strike_price: u64,
    cliff_months: u64,
    total_vesting_years: u64,
    launchpad_multiplier: u64,  // Scaled 1e9
    expiry_years: u64,
    dao_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Validation
    assert!(total_amount > 0, EInvalidAmount);
    assert!(total_vesting_years > 0, EInvalidDuration);
    assert!(cliff_months <= total_vesting_years * 12, EInvalidDuration);
    assert!(expiry_years > 0, EInvalidDuration);

    let now = clock.timestamp_ms();

    // Safe time calculations
    let cliff_ms = cliff_months * 30 * 24 * 60 * 60 * 1000;
    assert!(cliff_ms <= MAX_VESTING_DURATION_MS, ETimeCalculationOverflow);

    let total_vesting_ms = total_vesting_years * 365 * 24 * 60 * 60 * 1000;
    assert!(total_vesting_ms <= MAX_VESTING_DURATION_MS, ETimeCalculationOverflow);

    let expiry_ms = expiry_years * 365 * 24 * 60 * 60 * 1000;
    assert!(expiry_ms <= MAX_VESTING_DURATION_MS, ETimeCalculationOverflow);

    let grant_id = object::new(ctx);

    event::emit(GrantCreated {
        grant_id: object::uid_to_inner(&grant_id),
        recipient: std::option::some(recipient),
        total_amount,
        has_strike_price: true,
        has_vesting: true,
        has_tiers: false,
        timestamp: now,
    });

    // Build single tier with vesting and strike
    let tier = PriceTier {
        price_condition: std::option::some(relative_price_condition(launchpad_multiplier, true)),
        recipients: vector[RecipientMint { recipient, amount: total_amount }],
        vesting: std::option::some(VestingConfig {
            start_time: now,
            cliff_duration: cliff_ms,
            total_duration: total_vesting_ms,
        }),
        strike_price: std::option::some(strike_price),
        executed: false,
        description: std::string::utf8(b"Employee Stock Option"),
    };

    let grant = PriceBasedMintGrant<AssetType, StableType> {
        id: grant_id,
        tiers: vector[tier],
        total_amount,
        claimed_amount: 0,
        launchpad_enforcement: LaunchpadEnforcement {
            enabled: true,
            minimum_multiplier: launchpad_multiplier,
        },
        repeat_config: std::option::none(),
        earliest_execution: std::option::some(now),
        latest_execution: std::option::some(now + expiry_ms),
        paused: false,
        paused_until: std::option::none(),
        paused_at: std::option::none(),
        paused_duration: 0,
        emergency_frozen: false,
        cancelable: true,
        canceled: false,
        description: std::string::utf8(b"Employee Stock Option"),
        created_at: now,
        dao_id,
    };

    // Create and transfer claim capability
    let grant_id_inner = object::uid_to_inner(&grant.id);
    let claim_cap = GrantClaimCap {
        id: object::new(ctx),
        grant_id: grant_id_inner,
    };
    transfer::transfer(claim_cap, recipient);

    // Share the grant
    transfer::share_object(grant);

    grant_id_inner
}

/// Create vesting grant (no strike) - simple grant = 1 tier with vesting only
public fun create_vesting_grant<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>,
    recipient: address,
    total_amount: u64,
    cliff_months: u64,
    total_vesting_years: u64,
    dao_id: ID,
    version: VersionWitness,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Validation
    assert!(total_amount > 0, EInvalidAmount);
    assert!(total_vesting_years > 0, EInvalidDuration);
    assert!(cliff_months <= total_vesting_years * 12, EInvalidDuration);

    let now = clock.timestamp_ms();

    // Safe time calculations
    let cliff_ms = cliff_months * 30 * 24 * 60 * 60 * 1000;
    assert!(cliff_ms <= MAX_VESTING_DURATION_MS, ETimeCalculationOverflow);

    let total_vesting_ms = total_vesting_years * 365 * 24 * 60 * 60 * 1000;
    assert!(total_vesting_ms <= MAX_VESTING_DURATION_MS, ETimeCalculationOverflow);

    let grant_id = object::new(ctx);

    event::emit(GrantCreated {
        grant_id: object::uid_to_inner(&grant_id),
        recipient: std::option::some(recipient),
        total_amount,
        has_strike_price: false,
        has_vesting: true,
        has_tiers: false,
        timestamp: now,
    });

    // Build single tier with vesting, no strike
    let tier = PriceTier {
        price_condition: std::option::none(),  // No unlock condition
        recipients: vector[RecipientMint { recipient, amount: total_amount }],
        vesting: std::option::some(VestingConfig {
            start_time: now,
            cliff_duration: cliff_ms,
            total_duration: total_vesting_ms,
        }),
        strike_price: std::option::none(),  // Free grant
        executed: false,
        description: std::string::utf8(b"Vesting Grant"),
    };

    let grant = PriceBasedMintGrant<AssetType, StableType> {
        id: grant_id,
        tiers: vector[tier],
        total_amount,
        claimed_amount: 0,
        launchpad_enforcement: LaunchpadEnforcement {
            enabled: false,
            minimum_multiplier: 0,
        },
        repeat_config: std::option::none(),
        earliest_execution: std::option::some(now),
        latest_execution: std::option::some(now + total_vesting_ms),
        paused: false,
        paused_until: std::option::none(),
        paused_at: std::option::none(),
        paused_duration: 0,
        emergency_frozen: false,
        cancelable: true,
        canceled: false,
        description: std::string::utf8(b"Vesting Grant"),
        created_at: now,
        dao_id,
    };

    let grant_id_inner = object::uid_to_inner(&grant.id);

    // Create and transfer claim capability
    let claim_cap = GrantClaimCap {
        id: object::new(ctx),
        grant_id: grant_id_inner,
    };
    transfer::transfer(claim_cap, recipient);

    // Share the grant
    transfer::share_object(grant);

    // Ensure grant storage exists and register grant in DAO registry
    ensure_grant_storage(account, version, ctx);
    register_grant(account, grant_id_inner, recipient, true, 1, version);

    grant_id_inner
}

/// Create milestone rewards
public fun create_milestone_rewards<AssetType, StableType>(
    tier_multipliers: vector<u64>,      // Scaled 1e9
    tier_recipients: vector<vector<RecipientMint>>,
    tier_descriptions: vector<String>,
    earliest_execution: u64,
    latest_execution: u64,
    dao_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let now = clock.timestamp_ms();

    // Validation
    let tier_count = vector::length(&tier_multipliers);
    assert!(tier_count > 0, EInvalidAmount);
    assert!(tier_count == vector::length(&tier_recipients), EInvalidAmount);
    assert!(tier_count == vector::length(&tier_descriptions), EInvalidAmount);
    assert!(earliest_execution < latest_execution, EInvalidDuration);

    // Build tiers - each tier has price condition, no vesting, no strike
    let mut tiers = vector::empty();
    let mut i = 0;
    let tier_count = vector::length(&tier_multipliers);
    let mut total_amount = 0u64;

    while (i < tier_count) {
        let recipients_for_tier = *vector::borrow(&tier_recipients, i);

        // Calculate tier total
        let mut j = 0;
        let recipient_count = vector::length(&recipients_for_tier);
        while (j < recipient_count) {
            total_amount = total_amount + vector::borrow(&recipients_for_tier, j).amount;
            j = j + 1;
        };

        let tier = PriceTier {
            price_condition: std::option::some(relative_price_condition(
                *vector::borrow(&tier_multipliers, i),
                true
            )),
            recipients: recipients_for_tier,
            vesting: std::option::none(),      // No vesting for milestone rewards
            strike_price: std::option::none(), // Free minting
            executed: false,
            description: *vector::borrow(&tier_descriptions, i),
        };
        vector::push_back(&mut tiers, tier);
        i = i + 1;
    };

    let grant_id = object::new(ctx);

    event::emit(GrantCreated {
        grant_id: object::uid_to_inner(&grant_id),
        recipient: std::option::none(),
        total_amount,
        has_strike_price: false,
        has_vesting: false,
        has_tiers: true,
        timestamp: now,
    });

    let grant = PriceBasedMintGrant<AssetType, StableType> {
        id: grant_id,
        tiers,
        total_amount,
        claimed_amount: 0,
        launchpad_enforcement: LaunchpadEnforcement {
            enabled: false,
            minimum_multiplier: 0,
        },
        repeat_config: std::option::none(),
        earliest_execution: std::option::some(earliest_execution),
        latest_execution: std::option::some(latest_execution),
        paused: false,
        paused_until: std::option::none(),
        paused_at: std::option::none(),
        paused_duration: 0,
        emergency_frozen: false,
        cancelable: false,
        canceled: false,
        description: std::string::utf8(b"Milestone Rewards"),
        created_at: now,
        dao_id,
    };

    // Milestone rewards are shared (no individual claim cap - anyone can execute tiers)
    transfer::share_object(grant)
}

/// Create conditional mint (repeatable) - simple grant = 1 tier with absolute price condition and repeat config
public fun create_conditional_mint<AssetType, StableType>(
    recipient: address,
    mint_amount: u64,
    price_threshold: u128,
    is_above_threshold: bool,
    cooldown_ms: u64,
    max_executions: u64,
    dao_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validation
    assert!(mint_amount > 0, EInvalidAmount);

    let now = clock.timestamp_ms();
    let grant_id = object::new(ctx);

    event::emit(GrantCreated {
        grant_id: object::uid_to_inner(&grant_id),
        recipient: std::option::some(recipient),
        total_amount: mint_amount,
        has_strike_price: false,
        has_vesting: false,
        has_tiers: false,
        timestamp: now,
    });

    // Build single tier with absolute price condition, no vesting, no strike
    let tier = PriceTier {
        price_condition: std::option::some(absolute_price_condition(price_threshold, is_above_threshold)),
        recipients: vector[RecipientMint { recipient, amount: mint_amount }],
        vesting: std::option::none(),
        strike_price: std::option::none(),
        executed: false,
        description: std::string::utf8(b"Conditional Mint"),
    };

    let grant = PriceBasedMintGrant<AssetType, StableType> {
        id: grant_id,
        tiers: vector[tier],
        total_amount: mint_amount,
        claimed_amount: 0,
        launchpad_enforcement: LaunchpadEnforcement {
            enabled: false,
            minimum_multiplier: 0,
        },
        repeat_config: std::option::some(repeat_config(cooldown_ms, max_executions)),
        earliest_execution: std::option::none(),
        latest_execution: std::option::none(),
        paused: false,
        paused_until: std::option::none(),
        paused_at: std::option::none(),
        paused_duration: 0,
        emergency_frozen: false,
        cancelable: false,
        canceled: false,
        description: std::string::utf8(b"Conditional Mint"),
        created_at: now,
        dao_id,
    };

    // Create and transfer claim capability
    let claim_cap = GrantClaimCap {
        id: object::new(ctx),
        grant_id: object::uid_to_inner(&grant.id),
    };
    transfer::transfer(claim_cap, recipient);

    // Share the grant
    transfer::share_object(grant)
}

// === View Functions ===

public fun total_amount<A, S>(grant: &PriceBasedMintGrant<A, S>): u64 {
    grant.total_amount
}

public fun claimed_amount<A, S>(grant: &PriceBasedMintGrant<A, S>): u64 {
    grant.claimed_amount
}

public fun vested_amount<A, S>(grant: &PriceBasedMintGrant<A, S>): u64 {
    // Since grants are now tier-based, vested amount is calculated per tier
    // This is a simplified accessor - real vesting calculation happens in claimable_now
    0 // TODO: Calculate total vested across all tiers
}

public fun is_canceled<A, S>(grant: &PriceBasedMintGrant<A, S>): bool {
    grant.canceled
}

public fun description<A, S>(grant: &PriceBasedMintGrant<A, S>): &String {
    &grant.description
}

// === Preview Functions ===

/// Calculate currently claimable amount (vested but not yet claimed)
/// For simple grants (1 tier), reads from tier[0].vesting
public fun claimable_now<A, S>(
    grant: &PriceBasedMintGrant<A, S>,
    clock: &Clock,
): u64 {
    if (grant.canceled || grant.paused || grant.emergency_frozen) {
        return 0
    };

    // Check execution time bounds
    let current_time = clock.timestamp_ms();

    // Check earliest execution time
    if (grant.earliest_execution.is_some()) {
        let earliest = grant.earliest_execution.borrow();
        if (current_time < *earliest) {
            return 0  // Too early to claim
        };
    };

    // Check latest execution time (expiry)
    if (grant.latest_execution.is_some()) {
        let latest = grant.latest_execution.borrow();
        if (current_time > *latest) {
            return 0  // Grant has expired
        };
    };

    // Read vesting from first tier (simple grants have 1 tier)
    if (grant.tiers.length() == 0) return 0;
    let tier = vector::borrow(&grant.tiers, 0);

    if (tier.vesting.is_none()) {
        // No vesting - all or nothing based on price condition
        if (grant.claimed_amount == 0) { grant.total_amount } else { 0 }
    } else {
        let config = tier.vesting.borrow();
        let current_time = clock.timestamp_ms();

        // Convert cliff_duration to Option<u64> for cliff_time
        let cliff_time_opt = if (config.cliff_duration > 0) {
            std::option::some(config.start_time + config.cliff_duration)
        } else {
            std::option::none()
        };

        // Use shared vesting math from stream_utils
        stream_utils::calculate_claimable(
            grant.total_amount,
            grant.claimed_amount,
            config.start_time,
            config.start_time + config.total_duration,
            current_time,
            grant.paused_duration,
            &cliff_time_opt,
        )
    }
}

/// Get next vesting time (when more tokens become available)
public fun next_vest_time<A, S>(
    grant: &PriceBasedMintGrant<A, S>,
    clock: &Clock,
): Option<u64> {
    // Read vesting from first tier
    if (grant.tiers.length() == 0 || grant.canceled) {
        return std::option::none()
    };
    let tier = vector::borrow(&grant.tiers, 0);

    if (tier.vesting.is_none()) {
        return std::option::none()
    };

    let config = tier.vesting.borrow();
    let current_time = clock.timestamp_ms();

    let cliff_time_opt = if (config.cliff_duration > 0) {
        std::option::some(config.start_time + config.cliff_duration)
    } else {
        std::option::none()
    };

    // Use shared vesting math from stream_utils
    stream_utils::next_vesting_time(
        config.start_time,
        config.start_time + config.total_duration,
        &cliff_time_opt,
        &grant.latest_execution,
        current_time,
    )
}

// === Emergency Controls ===

/// Pause grant for a specific duration (in milliseconds)
/// Pass 0 for pause_duration_ms to pause indefinitely
public fun pause_grant<A, S>(
    grant: &mut PriceBasedMintGrant<A, S>,
    pause_duration_ms: u64,
    clock: &Clock,
) {
    assert!(!grant.paused, EGrantPaused);
    assert!(!grant.emergency_frozen, EEmergencyFrozen);

    let current_time = clock.timestamp_ms();
    grant.paused = true;
    grant.paused_at = std::option::some(current_time);

    // Use shared pause calculation from stream_utils
    grant.paused_until = stream_utils::calculate_pause_until(current_time, pause_duration_ms);

    event::emit(GrantPaused {
        grant_id: object::id(grant),
        paused_until: grant.paused_until,
        timestamp: current_time,
    });
}

/// Unpause grant (can only be called if not frozen)
public fun unpause_grant<A, S>(
    grant: &mut PriceBasedMintGrant<A, S>,
    clock: &Clock,
) {
    assert!(grant.paused, EGrantNotPaused);
    assert!(!grant.emergency_frozen, EEmergencyFrozen);

    let current_time = clock.timestamp_ms();

    // Calculate accumulated pause duration using shared utility
    if (grant.paused_at.is_some()) {
        let pause_start = *grant.paused_at.borrow();
        let this_pause_duration = stream_utils::calculate_pause_duration(pause_start, current_time);
        let new_total_pause = grant.paused_duration + this_pause_duration;

        // Overflow protection
        assert!(new_total_pause >= grant.paused_duration, ETimeCalculationOverflow);

        grant.paused_duration = new_total_pause;
    };

    grant.paused = false;
    grant.paused_at = std::option::none();
    grant.paused_until = std::option::none();

    event::emit(GrantUnpaused {
        grant_id: object::id(grant),
        pause_duration: grant.paused_duration,
        timestamp: current_time,
    });
}

/// Check if pause has expired and auto-unpause if needed
public fun check_and_unpause<A, S>(
    grant: &mut PriceBasedMintGrant<A, S>,
    clock: &Clock,
) {
    if (!grant.paused) {
        return
    };

    // If indefinite pause (paused_until = None), do nothing
    if (grant.paused_until.is_none()) {
        return
    };

    let pause_until = *grant.paused_until.borrow();
    let current_time = clock.timestamp_ms();

    if (current_time >= pause_until) {
        unpause_grant(grant, clock);
    };
}

/// Emergency freeze - prevents all claims and unpause
/// Only DAO governance can freeze/unfreeze
public fun emergency_freeze<A, S>(
    grant: &mut PriceBasedMintGrant<A, S>,
    clock: &Clock,
) {
    assert!(!grant.emergency_frozen, EEmergencyFrozen);

    grant.emergency_frozen = true;
    if (!grant.paused) {
        grant.paused = true;
        grant.paused_at = std::option::some(clock.timestamp_ms());
        grant.paused_until = std::option::none(); // Indefinite
    };

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
    assert!(grant.emergency_frozen, EGrantNotPaused);

    grant.emergency_frozen = false;

    event::emit(GrantUnfrozen {
        grant_id: object::id(grant),
        timestamp: clock.timestamp_ms(),
    });

    // Note: Does NOT auto-unpause - DAO must explicitly unpause after unfreezing
}

// === Grant Registry Management ===

/// Initialize grant storage in Account (call once during DAO setup)
fun ensure_grant_storage(account: &mut Account<FutarchyConfig>, version_witness: VersionWitness, ctx: &mut TxContext) {
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

/// Register a grant in the DAO's registry
fun register_grant(
    account: &mut Account<FutarchyConfig>,
    grant_id: ID,
    recipient: address,
    cancelable: bool,
    grant_type: u8,
    version_witness: VersionWitness,
) {
    use account_protocol::account;

    let storage: &mut GrantStorage = account::borrow_managed_data_mut(
        account,
        GrantStorageKey {},
        version_witness
    );

    let info = GrantInfo {
        recipient,
        cancelable,
        grant_type,
    };

    sui::table::add(&mut storage.grants, grant_id, info);
    storage.grant_ids.push_back(grant_id);
    storage.total_grants = storage.total_grants + 1;
}

/// Check if DAO is dissolving and block new grants
/// Check if DAO is in dissolving state (blocks new grants)
fun assert_not_dissolving(account: &Account<FutarchyConfig>, version_witness: VersionWitness) {
    use account_protocol::account;
    use futarchy_core::futarchy_config;

    let dao_state: &futarchy_config::DaoState = account::borrow_managed_data(
        account,
        futarchy_config::new_dao_state_key(),
        version_witness
    );

    assert!(
        futarchy_config::operational_state(dao_state) != DAO_STATE_DISSOLVING,
        EDaoDissolving
    );
}

/// Get all grant IDs (for dissolution)
public fun get_all_grant_ids(account: &Account<FutarchyConfig>, version_witness: VersionWitness): vector<ID> {
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

/// Cancel all cancelable grants during dissolution
/// Note: Grants are shared objects owned by recipients, so we can't actually cancel them here.
/// The EDaoDissolving check in claim functions prevents claiming during dissolution.
/// This function exists for compatibility but is effectively a no-op.
public fun cancel_all_grants_for_dissolution(
    _account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
) {
    // No-op: Grants are prevented from claiming via EDaoDissolving check in claim functions
    // Shared grant objects can't be modified here since they're owned by recipients
}

// ====================================================================
// === ACTION STRUCTS FOR PROPOSAL SYSTEM =========================
// ====================================================================

// === Constants for modes ===
const VESTING_MODE_NONE: u8 = 0;
const VESTING_MODE_GRANT_LEVEL: u8 = 1;  // All tiers share same vesting
const VESTING_MODE_TIER_LEVEL: u8 = 2;   // Each tier has own vesting

const STRIKE_MODE_FREE: u8 = 0;          // Free grant (no payment required)
const STRIKE_MODE_GRANT_LEVEL: u8 = 1;   // All tiers share same strike price
const STRIKE_MODE_TIER_LEVEL: u8 = 2;    // Each tier has own strike price

/// Unified oracle grant action - replaces all 4 previous grant types
/// Supports: Employee Options, Vesting Grants, Conditional Mints (each with multiple recipients)
/// One action creates one grant per recipient (cleaner than N actions for N recipients)
public struct CreateOracleGrantAction<phantom AssetType, phantom StableType> has store, drop, copy {
    // === RECIPIENTS (supports 1 to N recipients in a single action) ===
    recipients: vector<address>,  // List of grant recipients
    amounts: vector<u64>,         // Amount per recipient (parallel to recipients)

    // === VESTING (grant-level, applies to all recipients) ===
    vesting_mode: u8,  // 0 = none, 1 = grant-level vesting
    vesting_cliff_months: u64,
    vesting_duration_years: u64,

    // === STRIKE PRICE (grant-level, applies to all recipients) ===
    strike_mode: u8,  // 0 = free, 1 = grant-level strike
    strike_price: u64,

    // === LAUNCHPAD ENFORCEMENT (optional, applies to all recipients) ===
    launchpad_multiplier: u64,  // 0 = disabled, >0 = enforce minimum (scaled 1e9)

    // === REPEATABILITY (optional, for conditional mints) ===
    cooldown_ms: u64,       // 0 = no repeat
    max_executions: u64,    // 0 = unlimited (only used if cooldown_ms > 0)

    // === TIME BOUNDS ===
    earliest_execution_offset_ms: u64,  // 0 = immediate
    expiry_years: u64,                  // 0 = no expiry

    // === PRICE CONDITION (for conditional mints) ===
    price_condition_mode: u8,   // 0 = none, 1 = launchpad-relative, 2 = absolute
    price_threshold: u128,      // Threshold value (meaning depends on mode)
    price_is_above: bool,       // true = trigger above threshold, false = trigger below

    // === CANCELABILITY ===
    cancelable: bool,

    // === METADATA ===
    description: String,
}

/// Action to cancel a grant
public struct CancelGrantAction has store, drop, copy {
    grant_id: ID,
}

/// Action to pause a grant
public struct PauseGrantAction has store, drop, copy {
    grant_id: ID,
    pause_duration_ms: u64,
}

/// Action to unpause a grant
public struct UnpauseGrantAction has store, drop, copy {
    grant_id: ID,
}

/// Action to emergency freeze a grant
public struct EmergencyFreezeGrantAction has store, drop, copy {
    grant_id: ID,
}

/// Action to emergency unfreeze a grant
public struct EmergencyUnfreezeGrantAction has store, drop, copy {
    grant_id: ID,
}

// ====================================================================
// === HELPER CONSTRUCTORS ============================================
// ====================================================================

/// Create a RecipientMint for tier-based rewards
public fun new_recipient_mint(recipient: address, amount: u64): RecipientMint {
    RecipientMint { recipient, amount }
}

// ====================================================================
// === ACTION CONSTRUCTOR FUNCTIONS ===================================
// ====================================================================

/// Create unified oracle grant action (supports multiple recipients)
public fun new_create_oracle_grant<AssetType, StableType>(
    recipients: vector<address>,
    amounts: vector<u64>,
    vesting_mode: u8,
    vesting_cliff_months: u64,
    vesting_duration_years: u64,
    strike_mode: u8,
    strike_price: u64,
    launchpad_multiplier: u64,
    cooldown_ms: u64,
    max_executions: u64,
    earliest_execution_offset_ms: u64,
    expiry_years: u64,
    price_condition_mode: u8,
    price_threshold: u128,
    price_is_above: bool,
    cancelable: bool,
    description: String,
): CreateOracleGrantAction<AssetType, StableType> {
    CreateOracleGrantAction {
        recipients,
        amounts,
        vesting_mode,
        vesting_cliff_months,
        vesting_duration_years,
        strike_mode,
        strike_price,
        launchpad_multiplier,
        cooldown_ms,
        max_executions,
        earliest_execution_offset_ms,
        expiry_years,
        price_condition_mode,
        price_threshold,
        price_is_above,
        cancelable,
        description,
    }
}

public fun new_cancel_grant(grant_id: ID): CancelGrantAction {
    CancelGrantAction { grant_id }
}

public fun new_pause_grant(grant_id: ID, pause_duration_ms: u64): PauseGrantAction {
    PauseGrantAction { grant_id, pause_duration_ms }
}

public fun new_unpause_grant(grant_id: ID): UnpauseGrantAction {
    UnpauseGrantAction { grant_id }
}

public fun new_emergency_freeze_grant(grant_id: ID): EmergencyFreezeGrantAction {
    EmergencyFreezeGrantAction { grant_id }
}

public fun new_emergency_unfreeze_grant(grant_id: ID): EmergencyUnfreezeGrantAction {
    EmergencyUnfreezeGrantAction { grant_id }
}

// ====================================================================
// === EXECUTION FUNCTIONS (do_*) FOR PROPOSAL SYSTEM ===============
// ====================================================================

/// Execute unified oracle grant creation action
/// Creates ONE grant object with multiple recipients (true multi-recipient)
/// Supports: employee options, vesting grants, conditional mints
public fun do_create_oracle_grant<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    _witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Check if DAO is dissolving (block new grants)
    assert_not_dissolving(account, _version);

    // Ensure grant storage exists
    ensure_grant_storage(account, _version, ctx);

    // Get spec and validate type
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::CreateOracleGrant>(spec);

    // Deserialize the action with vector fields
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);

    let recipients = bcs::peel_vec_address(&mut reader);
    let amounts = bcs::peel_vec_u64(&mut reader);
    let vesting_mode = bcs::peel_u8(&mut reader);
    let vesting_cliff_months = bcs::peel_u64(&mut reader);
    let vesting_duration_years = bcs::peel_u64(&mut reader);
    let strike_mode = bcs::peel_u8(&mut reader);
    let strike_price = bcs::peel_u64(&mut reader);
    let launchpad_multiplier = bcs::peel_u64(&mut reader);
    let cooldown_ms = bcs::peel_u64(&mut reader);
    let max_executions = bcs::peel_u64(&mut reader);
    let earliest_execution_offset_ms = bcs::peel_u64(&mut reader);
    let expiry_years = bcs::peel_u64(&mut reader);
    let price_condition_mode = bcs::peel_u8(&mut reader);
    let price_threshold = bcs::peel_u128(&mut reader);
    let price_is_above = bcs::peel_bool(&mut reader);
    let cancelable = bcs::peel_bool(&mut reader);
    let description_bytes = bcs::peel_vec_u8(&mut reader);

    bcs_validation::validate_all_bytes_consumed(reader);

    // Validate inputs with specific error codes
    let recipient_count = vector::length(&recipients);
    assert!(recipient_count > 0, EEmptyRecipients);
    assert!(recipient_count == vector::length(&amounts), ERecipientAmountMismatch);
    assert!(vesting_mode <= VESTING_MODE_GRANT_LEVEL, EInvalidVestingMode);
    assert!(strike_mode <= STRIKE_MODE_GRANT_LEVEL, EInvalidStrikeMode);

    let description = std::string::utf8(description_bytes);
    let dao_id = object::id(account);
    let now = clock.timestamp_ms();

    // Build RecipientMint vector and calculate total
    let mut recipient_mints = vector::empty();
    let mut total_amount = 0u64;
    let mut i = 0;
    while (i < recipient_count) {
        let amount = *vector::borrow(&amounts, i);
        assert!(amount > 0, EInvalidGrantAmount);
        total_amount = total_amount + amount;

        vector::push_back(&mut recipient_mints, RecipientMint {
            recipient: *vector::borrow(&recipients, i),
            amount,
        });
        i = i + 1;
    };

    // Build vesting config if needed
    let vesting_config = if (vesting_mode == VESTING_MODE_GRANT_LEVEL) {
        assert!(vesting_duration_years > 0, EInvalidDuration);
        assert!(vesting_cliff_months <= vesting_duration_years * 12, EInvalidDuration);

        let cliff_ms = vesting_cliff_months * 30 * 24 * 60 * 60 * 1000;
        let total_vesting_ms = vesting_duration_years * 365 * 24 * 60 * 60 * 1000;
        assert!(cliff_ms <= MAX_VESTING_DURATION_MS, ETimeCalculationOverflow);
        assert!(total_vesting_ms <= MAX_VESTING_DURATION_MS, ETimeCalculationOverflow);

        std::option::some(VestingConfig {
            start_time: now,
            cliff_duration: cliff_ms,
            total_duration: total_vesting_ms,
        })
    } else {
        std::option::none()
    };

    // Build strike price option
    let strike_price_opt = if (strike_mode == STRIKE_MODE_GRANT_LEVEL) {
        std::option::some(strike_price)
    } else {
        std::option::none()
    };

    // Build price condition option (for conditional mints)
    let price_condition_opt = if (price_condition_mode > 0) {
        std::option::some(PriceCondition {
            mode: price_condition_mode - 1,  // Convert 1-based to 0-based (1=launchpad, 2=absolute -> 0,1)
            value: price_threshold,
            is_above: price_is_above,
        })
    } else {
        std::option::none()
    };

    // Build tier (single tier with multiple recipients)
    let tier = PriceTier {
        price_condition: price_condition_opt,
        recipients: recipient_mints,
        vesting: vesting_config,
        strike_price: strike_price_opt,
        executed: false,
        description,
    };

    // Build repeat config if needed
    let repeat_config_opt = if (cooldown_ms > 0) {
        std::option::some(RepeatConfig {
            cooldown_ms,
            max_executions,
            execution_count: 0,
            last_execution: std::option::none(),
        })
    } else {
        std::option::none()
    };

    // Calculate time bounds
    let earliest_execution_opt = if (earliest_execution_offset_ms > 0) {
        std::option::some(now + earliest_execution_offset_ms)
    } else {
        std::option::none()
    };

    let latest_execution_opt = if (expiry_years > 0) {
        let expiry_ms = expiry_years * 365 * 24 * 60 * 60 * 1000;
        std::option::some(now + expiry_ms)
    } else {
        std::option::none()
    };

    // Create the grant object (ONE object for ALL recipients)
    let grant_id = object::new(ctx);
    let grant_id_inner = object::uid_to_inner(&grant_id);

    event::emit(GrantCreated {
        grant_id: grant_id_inner,
        recipient: std::option::none(),  // Multi-recipient
        total_amount,
        has_strike_price: strike_price_opt.is_some(),
        has_vesting: vesting_config.is_some(),
        has_tiers: false,  // Simple grant
        timestamp: now,
    });

    let grant = PriceBasedMintGrant<AssetType, StableType> {
        id: grant_id,
        tiers: vector[tier],
        total_amount,
        claimed_amount: 0,
        launchpad_enforcement: LaunchpadEnforcement {
            enabled: launchpad_multiplier > 0,
            minimum_multiplier: launchpad_multiplier,
        },
        repeat_config: repeat_config_opt,
        earliest_execution: earliest_execution_opt,
        latest_execution: latest_execution_opt,
        paused: false,
        paused_until: std::option::none(),
        paused_at: std::option::none(),
        paused_duration: 0,
        emergency_frozen: false,
        cancelable,
        canceled: false,
        description,
        created_at: now,
        dao_id,
    };

    // Transfer claim capabilities to each recipient
    let mut j = 0;
    while (j < recipient_count) {
        let recipient = *vector::borrow(&recipients, j);
        let claim_cap = GrantClaimCap {
            id: object::new(ctx),
            grant_id: grant_id_inner,
        };
        transfer::transfer(claim_cap, recipient);
        j = j + 1;
    };

    // Share the grant (ONE object for all recipients)
    transfer::share_object(grant);

    // Register grant ONCE in DAO registry
    // Note: We register with first recipient for legacy compatibility
    let first_recipient = *vector::borrow(&recipients, 0);
    register_grant(account, grant_id_inner, first_recipient, cancelable, 0, _version);

    executable::increment_action_idx(executable);
}

/// Execute pause grant action
public fun do_pause_grant<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    _witness: IW,
    grant: &mut PriceBasedMintGrant<AssetType, StableType>,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::PauseGrant>(spec);

    // Deserialize
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    let _grant_id = object::id_from_bytes(bcs::peel_vec_u8(&mut reader));
    let pause_duration_ms = bcs::peel_u64(&mut reader);

    bcs_validation::validate_all_bytes_consumed(reader);

    // Pause the grant
    pause_grant(grant, pause_duration_ms, clock);

    executable::increment_action_idx(executable);
}

/// Execute unpause grant action
public fun do_unpause_grant<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    _witness: IW,
    grant: &mut PriceBasedMintGrant<AssetType, StableType>,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::UnpauseGrant>(spec);

    // Deserialize
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    let _grant_id = object::id_from_bytes(bcs::peel_vec_u8(&mut reader));

    bcs_validation::validate_all_bytes_consumed(reader);

    // Unpause the grant
    unpause_grant(grant, clock);

    executable::increment_action_idx(executable);
}

/// Execute emergency freeze grant action
public fun do_emergency_freeze_grant<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    _witness: IW,
    grant: &mut PriceBasedMintGrant<AssetType, StableType>,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::EmergencyFreezeGrant>(spec);

    // Deserialize
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    let _grant_id = object::id_from_bytes(bcs::peel_vec_u8(&mut reader));

    bcs_validation::validate_all_bytes_consumed(reader);

    // Emergency freeze the grant
    emergency_freeze(grant, clock);

    executable::increment_action_idx(executable);
}

/// Execute emergency unfreeze grant action
public fun do_emergency_unfreeze_grant<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    _witness: IW,
    grant: &mut PriceBasedMintGrant<AssetType, StableType>,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Get spec and validate type
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::EmergencyUnfreezeGrant>(spec);

    // Deserialize
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    let _grant_id = object::id_from_bytes(bcs::peel_vec_u8(&mut reader));

    bcs_validation::validate_all_bytes_consumed(reader);

    // Emergency unfreeze the grant
    emergency_unfreeze(grant, clock);

    executable::increment_action_idx(executable);
}
