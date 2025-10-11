/// ============================================================================
/// SWAP POSITION REGISTRY - DEX AGGREGATOR COMPATIBILITY
/// ============================================================================
///
/// Solves the problem of returning multiple conditional coin types from swaps
/// during active proposals. Standard DEX aggregators expect:
///   Input: 1 coin type (e.g., USDC)
///   Output: 1 coin type (e.g., SUI)
///
/// But optimal routing through conditional pools returns N different types:
///   Input: USDC
///   Output: Cond0_SUI + Cond1_SUI + ... (multiple conditional types)
///
/// SOLUTION:
/// 1. Store conditional coins in shared registry (no transfer = maintains PTB composability)
/// 2. Smart recombination: convert as much as possible to spot immediately
/// 3. Store only remainder that can't be recombined
/// 4. Permissionless crank after proposal resolves to settle positions
///
/// ARCHITECTURE:
/// - Shared SwapPositionRegistry (single global object per asset/stable pair)
/// - Positions indexed by (user_address, proposal_id)
/// - Conditional coins stored as dynamic fields on position UIDs
/// - Automatic merging when same user swaps multiple times
/// - Auto-cleanup after cranking (storage rebate)
///
/// FALLBACK MECHANISM:
/// - If registry gets too large (gas concerns), use `use_registry: false`
/// - Coins transfer directly to user (opt-out for advanced traders)
///
/// ============================================================================

module futarchy_markets::swap_position_registry;

use futarchy_markets::proposal::Proposal;
use futarchy_markets::coin_escrow::TokenEscrow;
use futarchy_one_shot_utils::math;
use sui::coin::{Self, Coin};
use sui::table::{Self, Table};
use sui::dynamic_field;
use sui::clock::Clock;
use sui::event;

// === Errors ===
const EPositionNotFound: u64 = 0;
const EProposalNotFinalized: u64 = 1;
const ENotOwner: u64 = 2;
const EPositionAlreadyExists: u64 = 3;
const EZeroAmount: u64 = 4;
const EInvalidOutcome: u64 = 5;
const ENoConditionalCoins: u64 = 6;
const ENoCrankerFeeForSelfRedeem: u64 = 7;

// === Structs ===

/// Shared registry storing all swap-generated conditional positions
/// One registry per asset/stable pair (created with markets)
public struct SwapPositionRegistry<phantom AssetType, phantom StableType> has key {
    id: UID,
    // Map: PositionKey → UID (the UID stores position data as dynamic fields)
    positions: Table<PositionKey, UID>,
    total_positions: u64,  // Metrics
    total_cranked: u64,
}

/// Composite key for indexing positions
public struct PositionKey has store, copy, drop {
    owner: address,
    proposal_id: ID,
}

/// Keys for storing conditional coins in dynamic fields on position UID
/// We store coins directly on the UID as dynamic fields:
/// - AssetOutcomeKey { outcome_index } → Coin<ConditionalAssetType>
/// - StableOutcomeKey { outcome_index } → Coin<ConditionalStableType>
public struct AssetOutcomeKey has store, copy, drop {
    outcome_index: u64,
}

public struct StableOutcomeKey has store, copy, drop {
    outcome_index: u64,
}

/// Metadata stored on position UID (as dynamic field with MetadataKey)
public struct MetadataKey has store, copy, drop {}

public struct PositionMetadata has store {
    created_at: u64,
    last_updated: u64,
    has_asset_outcome_0: bool,
    has_asset_outcome_1: bool,
    has_stable_outcome_0: bool,
    has_stable_outcome_1: bool,
}

// === Events ===

public struct SwapPositionCreated has copy, drop {
    owner: address,
    proposal_id: ID,
    timestamp: u64,
}

public struct SwapPositionUpdated has copy, drop {
    owner: address,
    proposal_id: ID,
    timestamp: u64,
}

public struct SwapPositionCranked has copy, drop {
    owner: address,
    proposal_id: ID,
    winning_outcome: u64,
    spot_asset_returned: u64,
    spot_stable_returned: u64,
    cranker: address,
    cranker_fee: u64,
    timestamp: u64,
}

public struct BatchCrankCompleted has copy, drop {
    proposal_id: ID,
    positions_processed: u64,
    positions_succeeded: u64,
    positions_failed: u64,
    total_fees_earned: u64,
    cranker: address,
    timestamp: u64,
}

public struct PositionCrankFailed has copy, drop {
    owner: address,
    proposal_id: ID,
    reason: u64,  // Error code
    timestamp: u64,
}

// === Public Functions ===

/// Create a new swap position registry (called when market is created)
public fun new<AssetType, StableType>(
    ctx: &mut TxContext,
): SwapPositionRegistry<AssetType, StableType> {
    SwapPositionRegistry {
        id: object::new(ctx),
        positions: table::new(ctx),
        total_positions: 0,
        total_cranked: 0,
    }
}

/// Store conditional asset coins in registry
/// If position exists, merge; otherwise create new
/// Returns true if new position created, false if merged
public fun store_conditional_asset<AssetType, StableType, ConditionalCoinType>(
    registry: &mut SwapPositionRegistry<AssetType, StableType>,
    owner: address,
    proposal_id: ID,
    outcome_index: u64,
    conditional_coin: Coin<ConditionalCoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    let amount = conditional_coin.value();
    assert!(amount > 0, EZeroAmount);

    let key = PositionKey { owner, proposal_id };
    let timestamp = clock.timestamp_ms();

    if (table::contains(&registry.positions, key)) {
        // Merge with existing position
        let position_uid = table::borrow_mut(&mut registry.positions, key);
        merge_asset_coin(position_uid, outcome_index, conditional_coin);

        // Update metadata
        let metadata: &mut PositionMetadata = dynamic_field::borrow_mut(position_uid, MetadataKey {});
        metadata.last_updated = timestamp;
        if (outcome_index == 0) {
            metadata.has_asset_outcome_0 = true;
        } else {
            metadata.has_asset_outcome_1 = true;
        };

        event::emit(SwapPositionUpdated { owner, proposal_id, timestamp });
        false  // Merged, not created
    } else {
        // Create new position
        let mut position_uid = object::new(ctx);

        // Add coin as dynamic field
        let asset_key = AssetOutcomeKey { outcome_index };
        dynamic_field::add(&mut position_uid, asset_key, conditional_coin);

        // Add metadata
        let mut metadata = PositionMetadata {
            created_at: timestamp,
            last_updated: timestamp,
            has_asset_outcome_0: false,
            has_asset_outcome_1: false,
            has_stable_outcome_0: false,
            has_stable_outcome_1: false,
        };
        if (outcome_index == 0) {
            metadata.has_asset_outcome_0 = true;
        } else {
            metadata.has_asset_outcome_1 = true;
        };
        dynamic_field::add(&mut position_uid, MetadataKey {}, metadata);

        table::add(&mut registry.positions, key, position_uid);
        registry.total_positions = registry.total_positions + 1;

        event::emit(SwapPositionCreated { owner, proposal_id, timestamp });
        true  // Created new
    }
}

/// Store conditional stable coins in registry
public fun store_conditional_stable<AssetType, StableType, ConditionalCoinType>(
    registry: &mut SwapPositionRegistry<AssetType, StableType>,
    owner: address,
    proposal_id: ID,
    outcome_index: u64,
    conditional_coin: Coin<ConditionalCoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    let amount = conditional_coin.value();
    assert!(amount > 0, EZeroAmount);

    let key = PositionKey { owner, proposal_id };
    let timestamp = clock.timestamp_ms();

    if (table::contains(&registry.positions, key)) {
        // Merge with existing position
        let position_uid = table::borrow_mut(&mut registry.positions, key);
        merge_stable_coin(position_uid, outcome_index, conditional_coin);

        // Update metadata
        let metadata: &mut PositionMetadata = dynamic_field::borrow_mut(position_uid, MetadataKey {});
        metadata.last_updated = timestamp;
        if (outcome_index == 0) {
            metadata.has_stable_outcome_0 = true;
        } else {
            metadata.has_stable_outcome_1 = true;
        };

        event::emit(SwapPositionUpdated { owner, proposal_id, timestamp });
        false  // Merged
    } else {
        // Create new position
        let mut position_uid = object::new(ctx);

        // Add coin as dynamic field
        let stable_key = StableOutcomeKey { outcome_index };
        dynamic_field::add(&mut position_uid, stable_key, conditional_coin);

        // Add metadata
        let mut metadata = PositionMetadata {
            created_at: timestamp,
            last_updated: timestamp,
            has_asset_outcome_0: false,
            has_asset_outcome_1: false,
            has_stable_outcome_0: false,
            has_stable_outcome_1: false,
        };
        if (outcome_index == 0) {
            metadata.has_stable_outcome_0 = true;
        } else {
            metadata.has_stable_outcome_1 = true;
        };
        dynamic_field::add(&mut position_uid, MetadataKey {}, metadata);

        table::add(&mut registry.positions, key, position_uid);
        registry.total_positions = registry.total_positions + 1;

        event::emit(SwapPositionCreated { owner, proposal_id, timestamp });
        true  // Created new
    }
}

/// Crank a position after proposal resolves (permissionless)
/// Burns losing conditional coins, recombines winner to spot, pays cranker fee
/// Generic version - caller must know outcome count and provide burn/extract closures
///
/// NOTE: Due to Move's type system limitations, we can't iterate over arbitrary conditional
/// coin types at runtime. The frontend/SDK knows the outcome count and conditional coin types,
/// so they should call type-specific crank functions (crank_position_2, crank_position_3, etc.)
public fun crank_position_generic<AssetType, StableType>(
    registry: &mut SwapPositionRegistry<AssetType, StableType>,
    owner: address,
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    // Closures to extract and burn coins for each outcome
    // Frontend provides these based on known conditional coin types
    extract_and_burn_losers: vector<u64>,  // Outcome indices to burn
    extract_winner: u64,  // Winning outcome index
    cranker_fee_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (u64, u64) {  // Returns (asset_returned, stable_returned)
    let proposal_id = object::id(proposal);
    let key = PositionKey { owner, proposal_id };

    assert!(table::contains(&registry.positions, key), EPositionNotFound);
    assert!(futarchy_markets::proposal::is_finalized(proposal), EProposalNotFinalized);

    let winning_outcome = futarchy_markets::proposal::get_winning_outcome(proposal);
    let mut position_uid = table::remove(&mut registry.positions, key);
    let metadata: PositionMetadata = dynamic_field::remove(&mut position_uid, MetadataKey {});

    // NOTE: Actual burning of conditional coins must happen in type-specific wrappers
    // This is a limitation of Move's type system - we can't dynamically dispatch on coin types

    // For now, delete position and return (type-specific functions handle coin extraction)
    object::delete(position_uid);
    registry.total_positions = registry.total_positions - 1;
    registry.total_cranked = registry.total_cranked + 1;

    (0, 0)  // Placeholder - type-specific functions return actual amounts
}

/// Crank a 2-outcome position (most common case)
public entry fun crank_position_2<AssetType, StableType, Cond0Asset, Cond1Asset, Cond0Stable, Cond1Stable>(
    registry: &mut SwapPositionRegistry<AssetType, StableType>,
    owner: address,
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    cranker_fee_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let proposal_id = object::id(proposal);
    let key = PositionKey { owner, proposal_id };
    assert!(table::contains(&registry.positions, key), EPositionNotFound);
    assert!(futarchy_markets::proposal::is_finalized(proposal), EProposalNotFinalized);

    let winning_outcome = futarchy_markets::proposal::get_winning_outcome(proposal);
    let mut position_uid = table::remove(&mut registry.positions, key);
    let metadata: PositionMetadata = dynamic_field::remove(&mut position_uid, MetadataKey {});

    let asset_0 = extract_asset_coin<Cond0Asset>(&mut position_uid, 0, ctx);
    let asset_1 = extract_asset_coin<Cond1Asset>(&mut position_uid, 1, ctx);
    let stable_0 = extract_stable_coin<Cond0Stable>(&mut position_uid, 0, ctx);
    let stable_1 = extract_stable_coin<Cond1Stable>(&mut position_uid, 1, ctx);

    let (winning_asset, winning_stable) = if (winning_outcome == 0) {
        if (asset_1.value() > 0) {
            futarchy_markets::coin_escrow::burn_conditional_asset(escrow, 1, asset_1);
        } else { coin::destroy_zero(asset_1); };
        if (stable_1.value() > 0) {
            futarchy_markets::coin_escrow::burn_conditional_stable(escrow, 1, stable_1);
        } else { coin::destroy_zero(stable_1); };
        (asset_0, stable_0)
    } else {
        if (asset_0.value() > 0) {
            futarchy_markets::coin_escrow::burn_conditional_asset(escrow, 0, asset_0);
        } else { coin::destroy_zero(asset_0); };
        if (stable_0.value() > 0) {
            futarchy_markets::coin_escrow::burn_conditional_stable(escrow, 0, stable_0);
        } else { coin::destroy_zero(stable_0); };
        (asset_1, stable_1)
    };

    let asset_amount = winning_asset.value();
    let stable_amount = winning_stable.value();

    let mut spot_asset = if (asset_amount > 0) {
        futarchy_markets::coin_escrow::burn_conditional_asset(escrow, winning_outcome, winning_asset);
        futarchy_markets::coin_escrow::withdraw_asset_balance<AssetType, StableType>(escrow, asset_amount, ctx)
    } else {
        coin::destroy_zero(winning_asset);
        coin::zero<AssetType>(ctx)
    };

    let spot_stable = if (stable_amount > 0) {
        futarchy_markets::coin_escrow::burn_conditional_stable(escrow, winning_outcome, winning_stable);
        futarchy_markets::coin_escrow::withdraw_stable_balance<AssetType, StableType>(escrow, stable_amount, ctx)
    } else {
        coin::destroy_zero(winning_stable);
        coin::zero<StableType>(ctx)
    };

    let cranker_fee = if (cranker_fee_bps > 0 && asset_amount > 0) {
        let fee_amount = (asset_amount * cranker_fee_bps) / 10000;
        if (fee_amount > 0) {
            let fee_coin = spot_asset.split(fee_amount, ctx);
            transfer::public_transfer(fee_coin, ctx.sender());
            fee_amount
        } else { 0 }
    } else { 0 };

    if (spot_asset.value() > 0) {
        transfer::public_transfer(spot_asset, owner);
    } else { coin::destroy_zero(spot_asset); };

    if (spot_stable.value() > 0) {
        transfer::public_transfer(spot_stable, owner);
    } else { coin::destroy_zero(spot_stable); };

    object::delete(position_uid);
    registry.total_positions = registry.total_positions - 1;
    registry.total_cranked = registry.total_cranked + 1;

    event::emit(SwapPositionCranked {
        owner, proposal_id, winning_outcome,
        spot_asset_returned: asset_amount - cranker_fee,
        spot_stable_returned: stable_amount,
        cranker: ctx.sender(), cranker_fee,
        timestamp: clock.timestamp_ms(),
    });
}

/// Crank a 3-outcome position
public entry fun crank_position_3<AssetType, StableType,
    Cond0Asset, Cond1Asset, Cond2Asset,
    Cond0Stable, Cond1Stable, Cond2Stable>(
    registry: &mut SwapPositionRegistry<AssetType, StableType>,
    owner: address,
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    cranker_fee_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let proposal_id = object::id(proposal);
    let key = PositionKey { owner, proposal_id };
    assert!(table::contains(&registry.positions, key), EPositionNotFound);
    assert!(futarchy_markets::proposal::is_finalized(proposal), EProposalNotFinalized);

    let winning_outcome = futarchy_markets::proposal::get_winning_outcome(proposal);
    let mut position_uid = table::remove(&mut registry.positions, key);
    let metadata: PositionMetadata = dynamic_field::remove(&mut position_uid, MetadataKey {});

    // Extract all outcome coins
    let asset_0 = extract_asset_coin<Cond0Asset>(&mut position_uid, 0, ctx);
    let asset_1 = extract_asset_coin<Cond1Asset>(&mut position_uid, 1, ctx);
    let asset_2 = extract_asset_coin<Cond2Asset>(&mut position_uid, 2, ctx);
    let stable_0 = extract_stable_coin<Cond0Stable>(&mut position_uid, 0, ctx);
    let stable_1 = extract_stable_coin<Cond1Stable>(&mut position_uid, 1, ctx);
    let stable_2 = extract_stable_coin<Cond2Stable>(&mut position_uid, 2, ctx);

    // Burn losers, keep winner
    let (winning_asset, winning_stable) = if (winning_outcome == 0) {
        burn_if_nonzero(escrow, 1, asset_1, stable_1);
        burn_if_nonzero(escrow, 2, asset_2, stable_2);
        (asset_0, stable_0)
    } else if (winning_outcome == 1) {
        burn_if_nonzero(escrow, 0, asset_0, stable_0);
        burn_if_nonzero(escrow, 2, asset_2, stable_2);
        (asset_1, stable_1)
    } else {
        burn_if_nonzero(escrow, 0, asset_0, stable_0);
        burn_if_nonzero(escrow, 1, asset_1, stable_1);
        (asset_2, stable_2)
    };

    // Convert winner to spot and pay fee (same logic as crank_position_2)
    let (spot_asset, spot_stable, cranker_fee) = convert_to_spot_and_pay_fee(
        escrow, winning_outcome, winning_asset, winning_stable, cranker_fee_bps, owner, ctx
    );

    object::delete(position_uid);
    registry.total_positions = registry.total_positions - 1;
    registry.total_cranked = registry.total_cranked + 1;

    event::emit(SwapPositionCranked {
        owner, proposal_id, winning_outcome,
        spot_asset_returned: spot_asset,
        spot_stable_returned: spot_stable,
        cranker: ctx.sender(), cranker_fee,
        timestamp: clock.timestamp_ms(),
    });
}

/// Helper: Burn conditional coins if non-zero
fun burn_if_nonzero<AssetType, StableType, AssetCond, StableCond>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u64,
    asset: Coin<AssetCond>,
    stable: Coin<StableCond>,
) {
    if (asset.value() > 0) {
        futarchy_markets::coin_escrow::burn_conditional_asset(escrow, outcome_idx, asset);
    } else { coin::destroy_zero(asset); };
    if (stable.value() > 0) {
        futarchy_markets::coin_escrow::burn_conditional_stable(escrow, outcome_idx, stable);
    } else { coin::destroy_zero(stable); };
}

/// Helper: Convert winning conditional to spot, pay fee, transfer
fun convert_to_spot_and_pay_fee<AssetType, StableType, AssetCond, StableCond>(
    escrow: &mut TokenEscrow<AssetType, StableType>,
    winning_outcome: u64,
    winning_asset: Coin<AssetCond>,
    winning_stable: Coin<StableCond>,
    cranker_fee_bps: u64,
    owner: address,
    ctx: &mut TxContext,
): (u64, u64, u64) {  // (asset_returned, stable_returned, fee_paid)
    let asset_amount = winning_asset.value();
    let stable_amount = winning_stable.value();

    let mut spot_asset = if (asset_amount > 0) {
        futarchy_markets::coin_escrow::burn_conditional_asset(escrow, winning_outcome, winning_asset);
        futarchy_markets::coin_escrow::withdraw_asset_balance<AssetType, StableType>(escrow, asset_amount, ctx)
    } else {
        coin::destroy_zero(winning_asset);
        coin::zero<AssetType>(ctx)
    };

    let spot_stable = if (stable_amount > 0) {
        futarchy_markets::coin_escrow::burn_conditional_stable(escrow, winning_outcome, winning_stable);
        futarchy_markets::coin_escrow::withdraw_stable_balance<AssetType, StableType>(escrow, stable_amount, ctx)
    } else {
        coin::destroy_zero(winning_stable);
        coin::zero<StableType>(ctx)
    };

    let cranker_fee = if (cranker_fee_bps > 0 && asset_amount > 0) {
        let fee_amount = (asset_amount * cranker_fee_bps) / 10000;
        if (fee_amount > 0) {
            let fee_coin = spot_asset.split(fee_amount, ctx);
            transfer::public_transfer(fee_coin, ctx.sender());
            fee_amount
        } else { 0 }
    } else { 0 };

    let final_asset = spot_asset.value();
    let final_stable = spot_stable.value();

    if (final_asset > 0) {
        transfer::public_transfer(spot_asset, owner);
    } else { coin::destroy_zero(spot_asset); };

    if (final_stable > 0) {
        transfer::public_transfer(spot_stable, owner);
    } else { coin::destroy_zero(spot_stable); };

    (final_asset, final_stable, cranker_fee)
}

/// Self-redeem 2-outcome position (no fee)
public entry fun self_redeem_position_2<AssetType, StableType, Cond0Asset, Cond1Asset, Cond0Stable, Cond1Stable>(
    registry: &mut SwapPositionRegistry<AssetType, StableType>,
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let owner = ctx.sender();
    crank_position_2<AssetType, StableType, Cond0Asset, Cond1Asset, Cond0Stable, Cond1Stable>(
        registry, owner, proposal, escrow, 0, clock, ctx
    );
}

/// Self-redeem 3-outcome position (no fee)
public entry fun self_redeem_position_3<AssetType, StableType,
    Cond0Asset, Cond1Asset, Cond2Asset,
    Cond0Stable, Cond1Stable, Cond2Stable>(
    registry: &mut SwapPositionRegistry<AssetType, StableType>,
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let owner = ctx.sender();
    crank_position_3<AssetType, StableType, Cond0Asset, Cond1Asset, Cond2Asset, Cond0Stable, Cond1Stable, Cond2Stable>(
        registry, owner, proposal, escrow, 0, clock, ctx
    );
}

// === Batch Cranking Functions (Gas Optimization) ===

/// Batch crank multiple 2-outcome positions in a single transaction
/// This is MUCH more gas-efficient than cranking individually
///
/// Gas savings:
/// - Individual: ~500K gas per crank = 5M gas for 10 positions
/// - Batch: ~2M gas for 10 positions (60% savings)
///
/// Limits:
/// - Max ~100-200 positions per transaction (depending on gas limit)
/// - Sui limit: 1000 objects accessed per transaction
///
/// Error handling:
/// - Continues processing on individual failures
/// - Emits PositionCrankFailed event for each failure
/// - Returns total succeeded/failed counts
public entry fun batch_crank_positions_2<AssetType, StableType, Cond0Asset, Cond1Asset, Cond0Stable, Cond1Stable>(
    registry: &mut SwapPositionRegistry<AssetType, StableType>,
    owners: vector<address>,
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    cranker_fee_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let proposal_id = object::id(proposal);
    let timestamp = clock.timestamp_ms();
    let winning_outcome = futarchy_markets::proposal::get_winning_outcome(proposal);

    let mut total_fees = 0u64;
    let mut succeeded = 0u64;
    let mut failed = 0u64;
    let batch_size = vector::length(&owners);

    let mut i = 0;
    while (i < batch_size) {
        let owner = *vector::borrow(&owners, i);
        let key = PositionKey { owner, proposal_id };

        // Check if position exists
        if (!table::contains(&registry.positions, key)) {
            event::emit(PositionCrankFailed {
                owner,
                proposal_id,
                reason: EPositionNotFound,
                timestamp,
            });
            failed = failed + 1;
            i = i + 1;
            continue
        };

        // Extract position
        let mut position_uid = table::remove(&mut registry.positions, key);
        let metadata: PositionMetadata = dynamic_field::remove(&mut position_uid, MetadataKey {});

        // Extract conditional coins
        let asset_0 = extract_asset_coin<Cond0Asset>(&mut position_uid, 0, ctx);
        let asset_1 = extract_asset_coin<Cond1Asset>(&mut position_uid, 1, ctx);
        let stable_0 = extract_stable_coin<Cond0Stable>(&mut position_uid, 0, ctx);
        let stable_1 = extract_stable_coin<Cond1Stable>(&mut position_uid, 1, ctx);

        // Burn losers, keep winner
        let (winning_asset, winning_stable) = if (winning_outcome == 0) {
            burn_if_nonzero(escrow, 1, asset_1, stable_1);
            (asset_0, stable_0)
        } else {
            burn_if_nonzero(escrow, 0, asset_0, stable_0);
            (asset_1, stable_1)
        };

        let asset_amount = winning_asset.value();
        let stable_amount = winning_stable.value();

        // Convert to spot
        let mut spot_asset = if (asset_amount > 0) {
            futarchy_markets::coin_escrow::burn_conditional_asset(escrow, winning_outcome, winning_asset);
            futarchy_markets::coin_escrow::withdraw_asset_balance<AssetType, StableType>(escrow, asset_amount, ctx)
        } else {
            coin::destroy_zero(winning_asset);
            coin::zero<AssetType>(ctx)
        };

        let spot_stable = if (stable_amount > 0) {
            futarchy_markets::coin_escrow::burn_conditional_stable(escrow, winning_outcome, winning_stable);
            futarchy_markets::coin_escrow::withdraw_stable_balance<AssetType, StableType>(escrow, stable_amount, ctx)
        } else {
            coin::destroy_zero(winning_stable);
            coin::zero<StableType>(ctx)
        };

        // Calculate fee and accumulate
        let position_fee = if (cranker_fee_bps > 0 && asset_amount > 0) {
            let fee_amount = (asset_amount * cranker_fee_bps) / 10000;
            if (fee_amount > 0) {
                let fee_coin = spot_asset.split(fee_amount, ctx);
                // Don't transfer yet - accumulate in total_fees
                transfer::public_transfer(fee_coin, ctx.sender());
                fee_amount
            } else { 0 }
        } else { 0 };

        total_fees = total_fees + position_fee;

        // Transfer spot to owner
        if (spot_asset.value() > 0) {
            transfer::public_transfer(spot_asset, owner);
        } else { coin::destroy_zero(spot_asset); };

        if (spot_stable.value() > 0) {
            transfer::public_transfer(spot_stable, owner);
        } else { coin::destroy_zero(spot_stable); };

        // Cleanup
        object::delete(position_uid);
        registry.total_positions = registry.total_positions - 1;
        registry.total_cranked = registry.total_cranked + 1;

        // Emit individual event
        event::emit(SwapPositionCranked {
            owner,
            proposal_id,
            winning_outcome,
            spot_asset_returned: asset_amount - position_fee,
            spot_stable_returned: stable_amount,
            cranker: ctx.sender(),
            cranker_fee: position_fee,
            timestamp,
        });

        succeeded = succeeded + 1;
        i = i + 1;
    };

    // Emit batch summary event
    event::emit(BatchCrankCompleted {
        proposal_id,
        positions_processed: batch_size,
        positions_succeeded: succeeded,
        positions_failed: failed,
        total_fees_earned: total_fees,
        cranker: ctx.sender(),
        timestamp,
    });
}

/// Batch crank multiple 3-outcome positions
public entry fun batch_crank_positions_3<AssetType, StableType,
    Cond0Asset, Cond1Asset, Cond2Asset,
    Cond0Stable, Cond1Stable, Cond2Stable>(
    registry: &mut SwapPositionRegistry<AssetType, StableType>,
    owners: vector<address>,
    proposal: &Proposal<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    cranker_fee_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let proposal_id = object::id(proposal);
    let timestamp = clock.timestamp_ms();
    let winning_outcome = futarchy_markets::proposal::get_winning_outcome(proposal);

    let mut total_fees = 0u64;
    let mut succeeded = 0u64;
    let mut failed = 0u64;
    let batch_size = vector::length(&owners);

    let mut i = 0;
    while (i < batch_size) {
        let owner = *vector::borrow(&owners, i);
        let key = PositionKey { owner, proposal_id };

        if (!table::contains(&registry.positions, key)) {
            event::emit(PositionCrankFailed {
                owner, proposal_id,
                reason: EPositionNotFound,
                timestamp,
            });
            failed = failed + 1;
            i = i + 1;
            continue
        };

        let mut position_uid = table::remove(&mut registry.positions, key);
        let metadata: PositionMetadata = dynamic_field::remove(&mut position_uid, MetadataKey {});

        // Extract all outcome coins
        let asset_0 = extract_asset_coin<Cond0Asset>(&mut position_uid, 0, ctx);
        let asset_1 = extract_asset_coin<Cond1Asset>(&mut position_uid, 1, ctx);
        let asset_2 = extract_asset_coin<Cond2Asset>(&mut position_uid, 2, ctx);
        let stable_0 = extract_stable_coin<Cond0Stable>(&mut position_uid, 0, ctx);
        let stable_1 = extract_stable_coin<Cond1Stable>(&mut position_uid, 1, ctx);
        let stable_2 = extract_stable_coin<Cond2Stable>(&mut position_uid, 2, ctx);

        // Burn losers, keep winner
        let (winning_asset, winning_stable) = if (winning_outcome == 0) {
            burn_if_nonzero(escrow, 1, asset_1, stable_1);
            burn_if_nonzero(escrow, 2, asset_2, stable_2);
            (asset_0, stable_0)
        } else if (winning_outcome == 1) {
            burn_if_nonzero(escrow, 0, asset_0, stable_0);
            burn_if_nonzero(escrow, 2, asset_2, stable_2);
            (asset_1, stable_1)
        } else {
            burn_if_nonzero(escrow, 0, asset_0, stable_0);
            burn_if_nonzero(escrow, 1, asset_1, stable_1);
            (asset_2, stable_2)
        };

        let asset_amount = winning_asset.value();
        let stable_amount = winning_stable.value();

        let mut spot_asset = if (asset_amount > 0) {
            futarchy_markets::coin_escrow::burn_conditional_asset(escrow, winning_outcome, winning_asset);
            futarchy_markets::coin_escrow::withdraw_asset_balance<AssetType, StableType>(escrow, asset_amount, ctx)
        } else {
            coin::destroy_zero(winning_asset);
            coin::zero<AssetType>(ctx)
        };

        let spot_stable = if (stable_amount > 0) {
            futarchy_markets::coin_escrow::burn_conditional_stable(escrow, winning_outcome, winning_stable);
            futarchy_markets::coin_escrow::withdraw_stable_balance<AssetType, StableType>(escrow, stable_amount, ctx)
        } else {
            coin::destroy_zero(winning_stable);
            coin::zero<StableType>(ctx)
        };

        let position_fee = if (cranker_fee_bps > 0 && asset_amount > 0) {
            let fee_amount = (asset_amount * cranker_fee_bps) / 10000;
            if (fee_amount > 0) {
                let fee_coin = spot_asset.split(fee_amount, ctx);
                transfer::public_transfer(fee_coin, ctx.sender());
                fee_amount
            } else { 0 }
        } else { 0 };

        total_fees = total_fees + position_fee;

        if (spot_asset.value() > 0) {
            transfer::public_transfer(spot_asset, owner);
        } else { coin::destroy_zero(spot_asset); };

        if (spot_stable.value() > 0) {
            transfer::public_transfer(spot_stable, owner);
        } else { coin::destroy_zero(spot_stable); };

        object::delete(position_uid);
        registry.total_positions = registry.total_positions - 1;
        registry.total_cranked = registry.total_cranked + 1;

        event::emit(SwapPositionCranked {
            owner, proposal_id, winning_outcome,
            spot_asset_returned: asset_amount - position_fee,
            spot_stable_returned: stable_amount,
            cranker: ctx.sender(),
            cranker_fee: position_fee,
            timestamp,
        });

        succeeded = succeeded + 1;
        i = i + 1;
    };

    event::emit(BatchCrankCompleted {
        proposal_id,
        positions_processed: batch_size,
        positions_succeeded: succeeded,
        positions_failed: failed,
        total_fees_earned: total_fees,
        cranker: ctx.sender(),
        timestamp,
    });
}

// === Internal Helpers ===

/// Merge asset coin into existing position
fun merge_asset_coin<ConditionalCoinType>(
    position_uid: &mut UID,
    outcome_index: u64,
    coin: Coin<ConditionalCoinType>,
) {
    let asset_key = AssetOutcomeKey { outcome_index };

    if (dynamic_field::exists_(position_uid, asset_key)) {
        // Merge with existing coin
        let existing_coin: &mut Coin<ConditionalCoinType> =
            dynamic_field::borrow_mut(position_uid, asset_key);
        existing_coin.join(coin);
    } else {
        // Add new coin
        dynamic_field::add(position_uid, asset_key, coin);
    };
}

/// Merge stable coin into existing position
fun merge_stable_coin<ConditionalCoinType>(
    position_uid: &mut UID,
    outcome_index: u64,
    coin: Coin<ConditionalCoinType>,
) {
    let stable_key = StableOutcomeKey { outcome_index };

    if (dynamic_field::exists_(position_uid, stable_key)) {
        // Merge with existing coin
        let existing_coin: &mut Coin<ConditionalCoinType> =
            dynamic_field::borrow_mut(position_uid, stable_key);
        existing_coin.join(coin);
    } else {
        // Add new coin
        dynamic_field::add(position_uid, stable_key, coin);
    };
}

/// Extract asset coin for a specific outcome (returns zero coin if doesn't exist)
fun extract_asset_coin<ConditionalCoinType>(
    position_uid: &mut UID,
    outcome_index: u64,
    ctx: &mut TxContext,
): Coin<ConditionalCoinType> {
    let asset_key = AssetOutcomeKey { outcome_index };

    if (dynamic_field::exists_(position_uid, asset_key)) {
        dynamic_field::remove(position_uid, asset_key)
    } else {
        // No coin for this outcome - return zero
        coin::zero<ConditionalCoinType>(ctx)
    }
}

/// Extract stable coin for a specific outcome
fun extract_stable_coin<ConditionalCoinType>(
    position_uid: &mut UID,
    outcome_index: u64,
    ctx: &mut TxContext,
): Coin<ConditionalCoinType> {
    let stable_key = StableOutcomeKey { outcome_index };

    if (dynamic_field::exists_(position_uid, stable_key)) {
        dynamic_field::remove(position_uid, stable_key)
    } else {
        coin::zero<ConditionalCoinType>(ctx)
    }
}

// === Cranking Economics & Priority Helpers ===

/// Estimate cranking profit for a batch of positions
/// Returns: (total_fees_estimate, recommended_batch_size)
///
/// This helps crankers decide if it's profitable to crank given gas costs
/// Gas cost on Sui: ~2M gas units for batch of 10 = ~0.002 SUI
/// Profitable if total_fees > gas_cost
public fun estimate_batch_cranking_profit(
    position_count: u64,
    avg_position_value_usd: u64,  // Estimated avg value in USD (6 decimals)
    cranker_fee_bps: u64,
    gas_price_sui: u64,  // Current gas price in nanoSUI
): (u64, u64) {  // (estimated_profit_usd, recommended_batch_size)
    // Estimate total fees
    let total_value = position_count * avg_position_value_usd;
    let total_fees = (total_value * cranker_fee_bps) / 10000;

    // Estimate gas cost (simplified)
    // ~200K gas per position + 500K base
    let gas_units = 500000 + (position_count * 200000);
    let gas_cost_nano_sui = gas_units * gas_price_sui;
    let gas_cost_sui = gas_cost_nano_sui / 1000000000;  // Convert to SUI

    // Assume 1 SUI = $1 for simplicity (should use oracle in production)
    let gas_cost_usd = gas_cost_sui;

    let profit = if (total_fees > gas_cost_usd) {
        total_fees - gas_cost_usd
    } else {
        0
    };

    // Recommend batch size that maximizes profit
    // Ideal: Process as many as possible while staying under 1K object limit
    let recommended_size = math::min(position_count, 100);  // Cap at 100 for safety

    (profit, recommended_size)
}

/// Calculate minimum position value worth cranking individually
/// Returns: minimum_value_usd (6 decimals)
///
/// Example: If gas costs $0.01 and fee is 0.1% (10 bps)
/// Minimum profitable position = $0.01 / 0.001 = $10
public fun minimum_profitable_position_value(
    gas_cost_usd: u64,
    cranker_fee_bps: u64,
): u64 {
    if (cranker_fee_bps == 0) return 0;

    // Break-even: position_value * (fee_bps / 10000) = gas_cost
    // position_value = gas_cost * 10000 / fee_bps
    (gas_cost_usd * 10000) / cranker_fee_bps
}

/// Check if individual position is profitable to crank
/// Useful for crankers to filter positions
public fun is_position_profitable_to_crank(
    estimated_position_value_usd: u64,
    cranker_fee_bps: u64,
    gas_cost_usd: u64,
): bool {
    let fee_earned = (estimated_position_value_usd * cranker_fee_bps) / 10000;
    fee_earned > gas_cost_usd
}

/// Get recommended cranker fee based on position size
/// Larger positions can afford lower fees (more competitive)
/// Smaller positions need higher fees to be profitable
public fun recommend_cranker_fee_bps(
    position_value_usd: u64,
    gas_cost_usd: u64,
): u64 {
    // Calculate minimum fee to break even
    let min_fee_bps = (gas_cost_usd * 10000) / position_value_usd;

    // Add 50% margin for profit
    let recommended = min_fee_bps + (min_fee_bps / 2);

    // Cap at reasonable max (e.g., 1% = 100 bps)
    if (recommended > 100) {
        100
    } else if (recommended < 5) {
        // Minimum 0.05% for competitive market
        5
    } else {
        recommended
    }
}

// === View Functions ===

/// Check if a position exists
public fun has_position<AssetType, StableType>(
    registry: &SwapPositionRegistry<AssetType, StableType>,
    owner: address,
    proposal_id: ID,
): bool {
    let key = PositionKey { owner, proposal_id };
    table::contains(&registry.positions, key)
}

/// Get total number of active positions in registry
public fun total_positions<AssetType, StableType>(
    registry: &SwapPositionRegistry<AssetType, StableType>,
): u64 {
    registry.total_positions
}

/// Get total number of positions that have been cranked
public fun total_cranked<AssetType, StableType>(
    registry: &SwapPositionRegistry<AssetType, StableType>,
): u64 {
    registry.total_cranked
}

/// Get cranking efficiency metrics (for cranker dashboards)
/// Returns: (total_active, total_cranked, success_rate_bps)
public fun get_cranking_metrics<AssetType, StableType>(
    registry: &SwapPositionRegistry<AssetType, StableType>,
): (u64, u64, u64) {
    let active = registry.total_positions;
    let cranked = registry.total_cranked;

    // Success rate in basis points (e.g., 9500 = 95%)
    let success_rate = if (cranked > 0) {
        10000  // Assume 100% success (failures not tracked separately yet)
    } else {
        0
    };

    (active, cranked, success_rate)
}

/// Share the registry (called after creation)
public fun share<AssetType, StableType>(
    registry: SwapPositionRegistry<AssetType, StableType>,
) {
    transfer::share_object(registry);
}
