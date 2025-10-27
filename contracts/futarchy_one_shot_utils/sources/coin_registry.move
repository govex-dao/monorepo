// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Registry of pre-created "blank" coin types that can be used for conditional tokens
/// Solves the problem that coin types can't be created dynamically in Sui
/// Allows proposal creators to acquire coin pairs without requiring two transactions
module futarchy_one_shot_utils::coin_registry;

use sui::clock::Clock;
use sui::coin::{TreasuryCap, CoinMetadata, Coin};
use sui::dynamic_field;
use sui::event;
use sui::sui::SUI;

// === Errors ===
const ESupplyNotZero: u64 = 0;
const EInsufficientFee: u64 = 1;
const ERegistryNotEmpty: u64 = 2;
const ENameNotEmpty: u64 = 3;
const EDescriptionNotEmpty: u64 = 4;
const ESymbolNotEmpty: u64 = 5;
const EIconUrlNotEmpty: u64 = 6;
const ERegistryFull: u64 = 7;
const EFeeExceedsMaximum: u64 = 8;
const ENoCoinSetsAvailable: u64 = 9;

// === Constants ===
const MAX_COIN_SETS: u64 = 100_000;
/// Maximum fee in SUI MIST (10 SUI = 10_000_000_000 MIST)
/// Prevents malicious actors from setting arbitrarily high fees that would DoS the registry
/// by filling it with economically unusable coin sets
const MAX_FEE: u64 = 10_000_000_000;

// === Structs ===

/// A single coin set ready for use as conditional tokens
/// Contains both TreasuryCap and CoinMetadata for one coin type
public struct CoinSet<phantom T> has store {
    treasury_cap: TreasuryCap<T>,
    metadata: CoinMetadata<T>,
    owner: address, // Who deposited this set and gets paid
    fee: u64, // Fee in SUI to acquire this set
}

/// Global registry storing available coin sets
/// Permissionless - anyone can add coin sets
/// Uses dynamic fields to store different CoinSet<T> types
public struct CoinRegistry has key {
    id: UID,
    // CoinSets stored as dynamic fields with cap_id as key
    // Dynamic fields allow storing different CoinSet<T> types
    total_sets: u64,
}

// === Events ===

public struct CoinSetDeposited has copy, drop {
    registry_id: ID,
    cap_id: ID,
    owner: address,
    fee: u64,
    timestamp: u64,
}

public struct CoinSetTaken has copy, drop {
    registry_id: ID,
    cap_id: ID,
    taker: address,
    fee_paid: u64,
    owner_paid: address,
    timestamp: u64,
}

// === Validation Functions ===

/// Basic validation of a coin set (supply must be zero, types must match)
/// Used by factory and launchpad to ensure cap validity
/// Does NOT enforce empty metadata - use validate_coin_set_for_registry for that
///
/// Checks:
/// 1. Supply must be zero (prevents using already-minted coins)
/// 2. Type parameters of treasury_cap and metadata must match (enforced by generics)
public fun validate_coin_set<T>(
    treasury_cap: &TreasuryCap<T>,
    _metadata: &CoinMetadata<T>,
) {
    // Validate coin meets requirements: supply must be zero
    assert!(treasury_cap.total_supply() == 0, ESupplyNotZero);

    // Type match is enforced by generics - both must be same type T
}

/// Validate a coin set for deposit into registry
/// Enforces stricter requirements: metadata must be empty for "blank" conditional tokens
///
/// Checks:
/// 1. Supply must be zero (prevents using already-minted coins)
/// 2. Metadata must be empty (name, symbol, description, icon)
/// 3. Type parameters of treasury_cap and metadata must match (enforced by generics)
fun validate_coin_set_for_registry<T>(
    treasury_cap: &TreasuryCap<T>,
    metadata: &CoinMetadata<T>,
) {
    // First do basic validation
    validate_coin_set(treasury_cap, metadata);

    // Validate metadata is empty (required for "blank" conditional tokens)
    // These coins should have no preset names/symbols so they can be customized
    assert!(metadata.get_name().is_empty(), ENameNotEmpty);
    assert!(metadata.get_description().is_empty(), EDescriptionNotEmpty);
    assert!(metadata.get_symbol().is_empty(), ESymbolNotEmpty);
    assert!(metadata.get_icon_url().is_none(), EIconUrlNotEmpty);
}

// === Admin Functions ===

/// Create a new coin registry (admin/one-time setup)
public fun create_registry(ctx: &mut TxContext): CoinRegistry {
    CoinRegistry {
        id: object::new(ctx),
        total_sets: 0,
    }
}

/// Share the registry to make it publicly accessible
public entry fun share_registry(registry: CoinRegistry) {
    transfer::share_object(registry);
}

/// Destroy an empty registry
public fun destroy_empty_registry(registry: CoinRegistry) {
    let CoinRegistry { id, total_sets } = registry;
    assert!(total_sets == 0, ERegistryNotEmpty);
    id.delete();
}

// === Deposit Functions ===

/// Deposit a coin set into the registry
/// Validates that the coin meets all requirements for conditional tokens
public fun deposit_coin_set<T>(
    registry: &mut CoinRegistry,
    treasury_cap: TreasuryCap<T>,
    metadata: CoinMetadata<T>,
    fee: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    // Check registry not full
    assert!(registry.total_sets < MAX_COIN_SETS, ERegistryFull);

    // Validate fee is reasonable to prevent DoS attacks
    // Without this check, malicious actors could fill the registry with
    // coin sets demanding arbitrarily high fees (e.g., u64::max = 18.4B SUI),
    // making them economically unusable and permanently occupying registry slots
    assert!(fee <= MAX_FEE, EFeeExceedsMaximum);

    // Validate coin set for registry (supply must be zero, metadata must be empty)
    validate_coin_set_for_registry(&treasury_cap, &metadata);

    let cap_id = object::id(&treasury_cap);
    let owner = ctx.sender();

    // Create coin set
    let coin_set = CoinSet {
        treasury_cap,
        metadata,
        owner,
        fee,
    };

    // Store in registry as dynamic field
    dynamic_field::add(&mut registry.id, cap_id, coin_set);
    registry.total_sets = registry.total_sets + 1;

    // Emit event
    event::emit(CoinSetDeposited {
        registry_id: object::id(registry),
        cap_id,
        owner,
        fee,
        timestamp: clock.timestamp_ms(),
    });
}

/// Deposit a coin set via entry function (transfers ownership)
public entry fun deposit_coin_set_entry<T>(
    registry: &mut CoinRegistry,
    treasury_cap: TreasuryCap<T>,
    metadata: CoinMetadata<T>,
    fee: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    deposit_coin_set(registry, treasury_cap, metadata, fee, clock, ctx);
}

// === Take Functions ===

/// Take a coin set from registry and transfer caps to sender
/// Returns the remaining payment coin for chaining multiple takes in a PTB
/// Call this N times in a PTB for N outcomes
public fun take_coin_set<T>(
    registry: &mut CoinRegistry,
    cap_id: ID,
    mut fee_payment: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<SUI> {
    // Check exists
    assert!(
        dynamic_field::exists_with_type<ID, CoinSet<T>>(&registry.id, cap_id),
        ENoCoinSetsAvailable,
    );

    // Remove from registry
    let coin_set: CoinSet<T> = dynamic_field::remove(&mut registry.id, cap_id);

    // Validate fee
    assert!(fee_payment.value() >= coin_set.fee, EInsufficientFee);

    // Split exact payment
    let payment = fee_payment.split(coin_set.fee, ctx);

    // Pay owner
    transfer::public_transfer(payment, coin_set.owner);

    // Update total count
    registry.total_sets = registry.total_sets - 1;

    // Emit event
    event::emit(CoinSetTaken {
        registry_id: object::id(registry),
        cap_id,
        taker: ctx.sender(),
        fee_paid: coin_set.fee,
        owner_paid: coin_set.owner,
        timestamp: clock.timestamp_ms(),
    });

    // Return caps to sender (they become owned objects)
    let CoinSet { treasury_cap, metadata, owner: _, fee: _ } = coin_set;
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());

    // Return remaining payment for next take
    fee_payment
}

// === View Functions ===

/// Get total number of coin sets in registry
public fun total_sets(registry: &CoinRegistry): u64 {
    registry.total_sets
}

/// Check if a specific coin set is available
public fun has_coin_set(registry: &CoinRegistry, cap_id: ID): bool {
    dynamic_field::exists_(&registry.id, cap_id)
}

/// Get fee for a specific coin set
public fun get_fee<T>(registry: &CoinRegistry, cap_id: ID): u64 {
    let coin_set: &CoinSet<T> = dynamic_field::borrow(&registry.id, cap_id);
    coin_set.fee
}

/// Get owner of a specific coin set
public fun get_owner<T>(registry: &CoinRegistry, cap_id: ID): address {
    let coin_set: &CoinSet<T> = dynamic_field::borrow(&registry.id, cap_id);
    coin_set.owner
}

// === Helper Functions for Proposals ===

/// Validate coin set in registry without removing it
public fun validate_coin_set_in_registry(registry: &CoinRegistry, cap_id: ID): bool {
    dynamic_field::exists_(&registry.id, cap_id)
}
