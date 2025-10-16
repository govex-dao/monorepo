/// NFT-based liquidity position tracking for Futarchy AMMs
/// Allows other protocols to discover and compose with LP positions
module futarchy_markets_operations::position_nft;

use std::ascii;
use std::option::{Self, Option};
use std::string::{Self, String};
use std::type_name::{Self, TypeName};
use sui::clock::{Self, Clock};
use sui::display::{Self, Display};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::package::{Self, Publisher};
use sui::transfer;
use sui::tx_context::{Self, TxContext};
use sui::vec_map::{Self, VecMap};

// === Errors ===
const EZeroAmount: u64 = 0;
const EPositionMismatch: u64 = 1;
const EInsufficientLiquidity: u64 = 2;
const ENotOwner: u64 = 3;

// === Display Constants ===
/// Default protocol image (used if no PositionImageConfig exists)
const DEFAULT_POSITION_NFT_IMAGE: vector<u8> = b"https://futarchy.app/images/lp-position-nft.png";

// === Structs ===

/// Mutable configuration for LP position NFT images
/// Allows protocol to update image URL via governance without redeployment
public struct PositionImageConfig has key {
    id: UID,
    /// Image URL for all LP position NFTs
    image_url: String,
}

/// One-time witness for creating PositionImageConfig
public struct POSITION_NFT has drop {}

/// NFT receipt for spot AMM liquidity position
/// Tradeable, composable with other DeFi protocols
public struct SpotLPPosition<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    /// The spot pool this position is for
    pool_id: ID,
    /// Amount of LP shares this position represents
    lp_amount: u64,
    /// Display metadata
    name: String,
    description: String,
    image_url: String,
    /// Pool metadata for other protocols to read
    coin_type_asset: TypeName,
    coin_type_stable: TypeName,
    fee_bps: u64,
    /// Timestamps
    position_created_ms: u64,
    last_updated_ms: u64,
    /// Extensible metadata for future features (e.g., LP bonuses, loyalty tiers)
    metadata: VecMap<String, String>,
}

/// NFT receipt for conditional market liquidity position
/// Tracks LP position in a specific outcome's AMM
public struct ConditionalLPPosition<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    /// The conditional pool this position is for
    pool_id: ID,
    /// The market (proposal) this belongs to
    market_id: ID,
    /// Which outcome (0, 1, 2, etc.)
    outcome_index: u8,
    /// Amount of LP shares
    lp_amount: u64,
    /// Display metadata
    name: String,
    description: String,
    image_url: String,
    /// Pool metadata
    coin_type_asset: TypeName,
    coin_type_stable: TypeName,
    fee_bps: u64,
    /// Proposal tracking
    proposal_id: ID,
    /// Updated when proposal finalizes
    is_winning_outcome: bool,
    /// Timestamps
    position_created_ms: u64,
    last_updated_ms: u64,
    /// Extensible metadata for future features (e.g., LP bonuses, loyalty tiers)
    metadata: VecMap<String, String>,
}

// === Events ===

public struct SpotPositionMinted has copy, drop {
    position_id: ID,
    pool_id: ID,
    owner: address,
    lp_amount: u64,
    timestamp_ms: u64,
}

public struct SpotPositionBurned has copy, drop {
    position_id: ID,
    pool_id: ID,
    owner: address,
    lp_amount: u64,
    timestamp_ms: u64,
}

public struct ConditionalPositionMinted has copy, drop {
    position_id: ID,
    pool_id: ID,
    market_id: ID,
    outcome_index: u8,
    owner: address,
    lp_amount: u64,
    timestamp_ms: u64,
}

public struct ConditionalPositionBurned has copy, drop {
    position_id: ID,
    pool_id: ID,
    market_id: ID,
    outcome_index: u8,
    owner: address,
    lp_amount: u64,
    timestamp_ms: u64,
}

// === Module Initialization ===

/// Initialize module - creates shared PositionImageConfig and publisher
fun init(otw: POSITION_NFT, ctx: &mut TxContext) {
    // Create shared image config with default image
    let config = PositionImageConfig {
        id: object::new(ctx),
        image_url: string::utf8(DEFAULT_POSITION_NFT_IMAGE),
    };
    transfer::share_object(config);

    // Create and transfer publisher for Display setup
    let publisher = package::claim(otw, ctx);
    transfer::public_transfer(publisher, ctx.sender());
}

// === Image Configuration Functions ===

/// Update the image URL for all future LP position NFTs
/// Package-private so it can only be called through governance actions
public(package) fun update_position_image(config: &mut PositionImageConfig, new_url: String) {
    config.image_url = new_url;
}

/// Get the current image URL from config
public fun get_image_url(config: &PositionImageConfig): String {
    config.image_url
}

// === Metadata Management Functions ===

/// Set a metadata key-value pair on a spot position
public fun set_spot_metadata<AssetType, StableType>(
    position: &mut SpotLPPosition<AssetType, StableType>,
    key: String,
    value: String,
) {
    if (vec_map::contains(&position.metadata, &key)) {
        let (_, _) = vec_map::remove(&mut position.metadata, &key);
    };
    vec_map::insert(&mut position.metadata, key, value);
}

/// Get a metadata value from a spot position
public fun get_spot_metadata<AssetType, StableType>(
    position: &SpotLPPosition<AssetType, StableType>,
    key: &String,
): Option<String> {
    if (vec_map::contains(&position.metadata, key)) {
        option::some(*vec_map::get(&position.metadata, key))
    } else {
        option::none()
    }
}

/// Set a metadata key-value pair on a conditional position
public fun set_conditional_metadata<AssetType, StableType>(
    position: &mut ConditionalLPPosition<AssetType, StableType>,
    key: String,
    value: String,
) {
    if (vec_map::contains(&position.metadata, &key)) {
        let (_, _) = vec_map::remove(&mut position.metadata, &key);
    };
    vec_map::insert(&mut position.metadata, key, value);
}

/// Get a metadata value from a conditional position
public fun get_conditional_metadata<AssetType, StableType>(
    position: &ConditionalLPPosition<AssetType, StableType>,
    key: &String,
): Option<String> {
    if (vec_map::contains(&position.metadata, key)) {
        option::some(*vec_map::get(&position.metadata, key))
    } else {
        option::none()
    }
}

// === Spot Position Functions ===

/// Mint a new spot LP position NFT
/// Called when user adds liquidity to spot pool
public fun mint_spot_position<AssetType, StableType>(
    pool_id: ID,
    lp_amount: u64,
    fee_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): SpotLPPosition<AssetType, StableType> {
    assert!(lp_amount > 0, EZeroAmount);

    let position_id = object::new(ctx);
    let timestamp = clock.timestamp_ms();

    // Build display strings
    let asset_type = type_name::get<AssetType>();
    let stable_type = type_name::get<StableType>();

    let name = string::utf8(b"Futarchy Spot LP Position");
    let description = format_spot_description(&asset_type, &stable_type, lp_amount);
    let image_url = string::utf8(DEFAULT_POSITION_NFT_IMAGE);

    event::emit(SpotPositionMinted {
        position_id: object::uid_to_inner(&position_id),
        pool_id,
        owner: ctx.sender(),
        lp_amount,
        timestamp_ms: timestamp,
    });

    SpotLPPosition {
        id: position_id,
        pool_id,
        lp_amount,
        name,
        description,
        image_url,
        coin_type_asset: asset_type,
        coin_type_stable: stable_type,
        fee_bps,
        position_created_ms: timestamp,
        last_updated_ms: timestamp,
        metadata: vec_map::empty(), // Initialize empty metadata
    }
}

/// Increase liquidity in existing spot position
/// Called when user adds more liquidity to same pool
public fun increase_spot_position<AssetType, StableType>(
    position: &mut SpotLPPosition<AssetType, StableType>,
    pool_id: ID,
    additional_lp: u64,
    clock: &Clock,
) {
    assert!(position.pool_id == pool_id, EPositionMismatch);
    assert!(additional_lp > 0, EZeroAmount);

    position.lp_amount = position.lp_amount + additional_lp;
    position.last_updated_ms = clock.timestamp_ms();

    // Update description with new amount
    position.description =
        format_spot_description(
            &position.coin_type_asset,
            &position.coin_type_stable,
            position.lp_amount,
        );
}

/// Decrease liquidity in spot position
/// Returns remaining LP amount (0 if position should be burned)
public fun decrease_spot_position<AssetType, StableType>(
    position: &mut SpotLPPosition<AssetType, StableType>,
    pool_id: ID,
    lp_to_remove: u64,
    clock: &Clock,
): u64 {
    assert!(position.pool_id == pool_id, EPositionMismatch);
    assert!(lp_to_remove > 0, EZeroAmount);
    assert!(position.lp_amount >= lp_to_remove, EInsufficientLiquidity);

    position.lp_amount = position.lp_amount - lp_to_remove;
    position.last_updated_ms = clock.timestamp_ms();

    if (position.lp_amount > 0) {
        // Update description with new amount
        position.description =
            format_spot_description(
                &position.coin_type_asset,
                &position.coin_type_stable,
                position.lp_amount,
            );
    };

    position.lp_amount
}

/// Burn spot position NFT
/// Called when user removes all liquidity
public fun burn_spot_position<AssetType, StableType>(
    position: SpotLPPosition<AssetType, StableType>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let SpotLPPosition {
        id,
        pool_id,
        lp_amount,
        name: _,
        description: _,
        image_url: _,
        coin_type_asset: _,
        coin_type_stable: _,
        fee_bps: _,
        position_created_ms: _,
        last_updated_ms: _,
        metadata: _, // Metadata is dropped when position burns
    } = position;

    event::emit(SpotPositionBurned {
        position_id: object::uid_to_inner(&id),
        pool_id,
        owner: ctx.sender(),
        lp_amount,
        timestamp_ms: clock.timestamp_ms(),
    });

    object::delete(id);
}

// === Conditional Position Functions ===

/// Mint a new conditional LP position NFT
/// Called when user adds liquidity to a conditional market
public fun mint_conditional_position<AssetType, StableType>(
    pool_id: ID,
    market_id: ID,
    proposal_id: ID,
    outcome_index: u8,
    lp_amount: u64,
    fee_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ConditionalLPPosition<AssetType, StableType> {
    assert!(lp_amount > 0, EZeroAmount);

    let position_id = object::new(ctx);
    let timestamp = clock.timestamp_ms();

    // Build display strings
    let asset_type = type_name::get<AssetType>();
    let stable_type = type_name::get<StableType>();

    let name = format_conditional_name(outcome_index);
    let description = format_conditional_description(
        &asset_type,
        &stable_type,
        outcome_index,
        lp_amount,
        proposal_id,
    );
    let image_url = string::utf8(DEFAULT_POSITION_NFT_IMAGE);

    event::emit(ConditionalPositionMinted {
        position_id: object::uid_to_inner(&position_id),
        pool_id,
        market_id,
        outcome_index,
        owner: ctx.sender(),
        lp_amount,
        timestamp_ms: timestamp,
    });

    ConditionalLPPosition {
        id: position_id,
        pool_id,
        market_id,
        outcome_index,
        lp_amount,
        name,
        description,
        image_url,
        coin_type_asset: asset_type,
        coin_type_stable: stable_type,
        fee_bps,
        proposal_id,
        is_winning_outcome: false,
        position_created_ms: timestamp,
        last_updated_ms: timestamp,
        metadata: vec_map::empty(), // Initialize empty metadata
    }
}

/// Mark conditional position as winning/losing when proposal finalizes
public fun mark_outcome_result<AssetType, StableType>(
    position: &mut ConditionalLPPosition<AssetType, StableType>,
    is_winner: bool,
) {
    position.is_winning_outcome = is_winner;
}

/// Increase liquidity in conditional position
public fun increase_conditional_position<AssetType, StableType>(
    position: &mut ConditionalLPPosition<AssetType, StableType>,
    pool_id: ID,
    additional_lp: u64,
    clock: &Clock,
) {
    assert!(position.pool_id == pool_id, EPositionMismatch);
    assert!(additional_lp > 0, EZeroAmount);

    position.lp_amount = position.lp_amount + additional_lp;
    position.last_updated_ms = clock.timestamp_ms();

    // Update description with new amount
    position.description =
        format_conditional_description(
            &position.coin_type_asset,
            &position.coin_type_stable,
            position.outcome_index,
            position.lp_amount,
            position.proposal_id,
        );
}

/// Decrease liquidity in conditional position
/// Returns remaining LP amount (0 if position should be burned)
public fun decrease_conditional_position<AssetType, StableType>(
    position: &mut ConditionalLPPosition<AssetType, StableType>,
    pool_id: ID,
    lp_to_remove: u64,
    clock: &Clock,
): u64 {
    assert!(position.pool_id == pool_id, EPositionMismatch);
    assert!(lp_to_remove > 0, EZeroAmount);
    assert!(position.lp_amount >= lp_to_remove, EInsufficientLiquidity);

    position.lp_amount = position.lp_amount - lp_to_remove;
    position.last_updated_ms = clock.timestamp_ms();

    if (position.lp_amount > 0) {
        // Update description
        position.description =
            format_conditional_description(
                &position.coin_type_asset,
                &position.coin_type_stable,
                position.outcome_index,
                position.lp_amount,
                position.proposal_id,
            );
    };

    position.lp_amount
}

/// Burn conditional position NFT
public fun burn_conditional_position<AssetType, StableType>(
    position: ConditionalLPPosition<AssetType, StableType>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let ConditionalLPPosition {
        id,
        pool_id,
        market_id,
        outcome_index,
        lp_amount,
        name: _,
        description: _,
        image_url: _,
        coin_type_asset: _,
        coin_type_stable: _,
        fee_bps: _,
        proposal_id: _,
        is_winning_outcome: _,
        position_created_ms: _,
        last_updated_ms: _,
        metadata: _, // Metadata is dropped when position burns
    } = position;

    event::emit(ConditionalPositionBurned {
        position_id: object::uid_to_inner(&id),
        pool_id,
        market_id,
        outcome_index,
        owner: ctx.sender(),
        lp_amount,
        timestamp_ms: clock.timestamp_ms(),
    });

    object::delete(id);
}

// === View Functions (for other protocols) ===

/// Get spot position details
public fun get_spot_position_info<AssetType, StableType>(
    position: &SpotLPPosition<AssetType, StableType>,
): (ID, u64, TypeName, TypeName, u64) {
    (
        position.pool_id,
        position.lp_amount,
        position.coin_type_asset,
        position.coin_type_stable,
        position.fee_bps,
    )
}

/// Get conditional position details
public fun get_conditional_position_info<AssetType, StableType>(
    position: &ConditionalLPPosition<AssetType, StableType>,
): (ID, ID, u8, u64, TypeName, TypeName, u64, bool) {
    (
        position.pool_id,
        position.market_id,
        position.outcome_index,
        position.lp_amount,
        position.coin_type_asset,
        position.coin_type_stable,
        position.fee_bps,
        position.is_winning_outcome,
    )
}

/// Get spot LP amount
public fun get_spot_lp_amount<AssetType, StableType>(
    position: &SpotLPPosition<AssetType, StableType>,
): u64 {
    position.lp_amount
}

/// Get conditional LP amount
public fun get_conditional_lp_amount<AssetType, StableType>(
    position: &ConditionalLPPosition<AssetType, StableType>,
): u64 {
    position.lp_amount
}

// === Helper Functions ===

fun format_spot_description(asset_type: &TypeName, stable_type: &TypeName, lp_amount: u64): String {
    // Format: "LP Position: {lp_amount} shares in {Asset}/{Stable} pool"
    let mut desc = string::utf8(b"LP Position: ");
    string::append(&mut desc, u64_to_string(lp_amount));
    string::append(&mut desc, string::utf8(b" shares in "));
    string::append(&mut desc, string::from_ascii(type_name::into_string(*asset_type)));
    string::append(&mut desc, string::utf8(b"/"));
    string::append(&mut desc, string::from_ascii(type_name::into_string(*stable_type)));
    string::append(&mut desc, string::utf8(b" spot pool"));
    desc
}

fun format_conditional_description(
    asset_type: &TypeName,
    stable_type: &TypeName,
    outcome_index: u8,
    lp_amount: u64,
    proposal_id: ID,
): String {
    // Format: "Conditional LP: {lp_amount} shares in Outcome {index} for Proposal {id}"
    let mut desc = string::utf8(b"Conditional LP: ");
    string::append(&mut desc, u64_to_string(lp_amount));
    string::append(&mut desc, string::utf8(b" shares in Outcome "));
    string::append(&mut desc, u8_to_string(outcome_index));
    string::append(&mut desc, string::utf8(b" ("));
    string::append(&mut desc, string::from_ascii(type_name::into_string(*asset_type)));
    string::append(&mut desc, string::utf8(b"/"));
    string::append(&mut desc, string::from_ascii(type_name::into_string(*stable_type)));
    string::append(&mut desc, string::utf8(b")"));
    desc
}

fun format_conditional_name(outcome_index: u8): String {
    let mut name = string::utf8(b"Futarchy Conditional LP - Outcome ");
    string::append(&mut name, u8_to_string(outcome_index));
    name
}

fun u64_to_string(value: u64): String {
    if (value == 0) return string::utf8(b"0");

    let mut buffer = vector::empty<u8>();
    let mut n = value;

    while (n > 0) {
        let digit = ((n % 10) as u8) + 48; // ASCII '0' = 48
        vector::push_back(&mut buffer, digit);
        n = n / 10;
    };

    vector::reverse(&mut buffer);
    string::utf8(buffer)
}

fun u8_to_string(value: u8): String {
    u64_to_string((value as u64))
}

// === Display Setup (one-time publisher call) ===

/// Initialize display for spot positions
public fun create_spot_display<AssetType, StableType>(
    publisher: &Publisher,
    ctx: &mut TxContext,
): Display<SpotLPPosition<AssetType, StableType>> {
    let keys = vector[
        string::utf8(b"name"),
        string::utf8(b"description"),
        string::utf8(b"image_url"),
        string::utf8(b"pool_id"),
        string::utf8(b"lp_amount"),
        string::utf8(b"coin_type_asset"),
        string::utf8(b"coin_type_stable"),
        string::utf8(b"fee_bps"),
    ];

    let values = vector[
        string::utf8(b"{name}"),
        string::utf8(b"{description}"),
        string::utf8(b"{image_url}"),
        string::utf8(b"{pool_id}"),
        string::utf8(b"{lp_amount}"),
        string::utf8(b"{coin_type_asset}"),
        string::utf8(b"{coin_type_stable}"),
        string::utf8(b"{fee_bps}"),
    ];

    let mut display = display::new_with_fields<SpotLPPosition<AssetType, StableType>>(
        publisher,
        keys,
        values,
        ctx,
    );

    display::update_version(&mut display);
    display
}

/// Initialize display for conditional positions
public fun create_conditional_display<AssetType, StableType>(
    publisher: &Publisher,
    ctx: &mut TxContext,
): Display<ConditionalLPPosition<AssetType, StableType>> {
    let keys = vector[
        string::utf8(b"name"),
        string::utf8(b"description"),
        string::utf8(b"image_url"),
        string::utf8(b"pool_id"),
        string::utf8(b"market_id"),
        string::utf8(b"outcome_index"),
        string::utf8(b"lp_amount"),
        string::utf8(b"coin_type_asset"),
        string::utf8(b"coin_type_stable"),
        string::utf8(b"fee_bps"),
        string::utf8(b"is_winning_outcome"),
    ];

    let values = vector[
        string::utf8(b"{name}"),
        string::utf8(b"{description}"),
        string::utf8(b"{image_url}"),
        string::utf8(b"{pool_id}"),
        string::utf8(b"{market_id}"),
        string::utf8(b"{outcome_index}"),
        string::utf8(b"{lp_amount}"),
        string::utf8(b"{coin_type_asset}"),
        string::utf8(b"{coin_type_stable}"),
        string::utf8(b"{fee_bps}"),
        string::utf8(b"{is_winning_outcome}"),
    ];

    let mut display = display::new_with_fields<ConditionalLPPosition<AssetType, StableType>>(
        publisher,
        keys,
        values,
        ctx,
    );

    display::update_version(&mut display);
    display
}

#[test_only]
public fun destroy_spot_position_for_testing<AssetType, StableType>(
    position: SpotLPPosition<AssetType, StableType>,
) {
    let SpotLPPosition {
        id,
        pool_id: _,
        lp_amount: _,
        name: _,
        description: _,
        image_url: _,
        coin_type_asset: _,
        coin_type_stable: _,
        fee_bps: _,
        position_created_ms: _,
        last_updated_ms: _,
        metadata: _,
    } = position;
    object::delete(id);
}

#[test_only]
public fun destroy_conditional_position_for_testing<AssetType, StableType>(
    position: ConditionalLPPosition<AssetType, StableType>,
) {
    let ConditionalLPPosition {
        id,
        pool_id: _,
        market_id: _,
        outcome_index: _,
        lp_amount: _,
        name: _,
        description: _,
        image_url: _,
        coin_type_asset: _,
        coin_type_stable: _,
        fee_bps: _,
        proposal_id: _,
        is_winning_outcome: _,
        position_created_ms: _,
        last_updated_ms: _,
        metadata: _,
    } = position;
    object::delete(id);
}
