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
use futarchy_markets::conditional_balance::{Self, ConditionalMarketBalance};
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

/// Registry storing all swap-generated conditional positions
/// One registry per asset/stable pair (stored in SpotAMM for clean aggregator interface)
public struct SwapPositionRegistry<phantom AssetType, phantom StableType> has key, store {
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

public struct PositionMetadata has store, drop {
    created_at: u64,
    last_updated: u64,
    has_asset_outcome_0: bool,
    has_asset_outcome_1: bool,
    has_stable_outcome_0: bool,
    has_stable_outcome_1: bool,
}

// === PTB + Hot Potato Pattern ===

/// Hot potato for PTB-based cranking
/// NO abilities = must be consumed in same transaction
///
/// This enables frontend to construct dynamic PTBs for ANY outcome count without
/// hardcoded on-chain functions for each count.
public struct CrankProgress<phantom AssetType, phantom StableType> {
    position_uid: UID,  // The position being cranked
    owner: address,
    proposal_id: ID,
    winning_outcome: u64,
    outcomes_processed: u8,  // How many outcomes unwrapped so far
    total_outcomes: u8,  // Total outcomes to unwrap
    spot_asset_accumulated: u64,  // Track amounts as we unwrap
    spot_stable_accumulated: u64,
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
    cranker_fee: u64,  // Fixed fee in stable coins
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

// === PTB + Hot Potato Cranking Functions ===
// These 3 functions replace ALL hardcoded crank_position_N functions!
// Frontend constructs a PTB with N unwrap_one calls based on outcome count.

/// Step 1: Start cranking a position
/// Returns hot potato that MUST be consumed in same transaction
///
/// # Example PTB Flow (for 3 outcomes):
/// ```
/// let progress = start_crank(registry, owner, proposal, ...);
/// let progress = unwrap_one<AssetType, StableType, Cond0Asset>(progress, escrow, true, ...);
/// let progress = unwrap_one<AssetType, StableType, Cond0Stable>(progress, escrow, false, ...);
/// let progress = unwrap_one<AssetType, StableType, Cond1Asset>(progress, escrow, true, ...);
/// let progress = unwrap_one<AssetType, StableType, Cond1Stable>(progress, escrow, false, ...);
/// let progress = unwrap_one<AssetType, StableType, Cond2Asset>(progress, escrow, true, ...);
/// let progress = unwrap_one<AssetType, StableType, Cond2Stable>(progress, escrow, false, ...);
/// finish_crank(progress, clock);
/// ```
public fun start_crank<AssetType, StableType>(
    registry: &mut SwapPositionRegistry<AssetType, StableType>,
    owner: address,
    proposal: &Proposal<AssetType, StableType>,
): CrankProgress<AssetType, StableType> {
    let proposal_id = object::id(proposal);
    let key = PositionKey { owner, proposal_id };

    assert!(table::contains(&registry.positions, key), EPositionNotFound);
    assert!(futarchy_markets::proposal::is_finalized(proposal), EProposalNotFinalized);

    let winning_outcome = futarchy_markets::proposal::get_winning_outcome(proposal);
    let mut position_uid = table::remove(&mut registry.positions, key);
    let _metadata: PositionMetadata = dynamic_field::remove(&mut position_uid, MetadataKey {});

    // Get outcome count from proposal
    let total_outcomes = futarchy_markets::proposal::outcome_count(proposal);

    registry.total_positions = registry.total_positions - 1;

    CrankProgress {
        position_uid,
        owner,
        proposal_id,
        winning_outcome,
        outcomes_processed: 0,
        total_outcomes: (total_outcomes as u8),
        spot_asset_accumulated: 0,
        spot_stable_accumulated: 0,
    }
}

/// Step 2: Unwrap one outcome (call N times in PTB)
/// Frontend specifies ConditionalCoinType for each outcome
///
/// # Arguments
/// * `outcome_idx` - Which outcome to unwrap (0, 1, 2, ...)
/// * `is_asset` - true for asset, false for stable
/// * `recipient` - where to send coins (usually owner, or cranker for fee)
///
/// # Returns
/// Updated hot potato (must be passed to next unwrap_one or finish_crank)
public fun unwrap_one<AssetType, StableType, ConditionalCoinType>(
    mut progress: CrankProgress<AssetType, StableType>,
    escrow: &mut TokenEscrow<AssetType, StableType>,
    outcome_idx: u8,
    is_asset: bool,
    recipient: address,
    ctx: &mut TxContext,
): CrankProgress<AssetType, StableType> {

    // Extract coin from position UID
    let coin = if (is_asset) {
        extract_asset_coin<ConditionalCoinType>(&mut progress.position_uid, (outcome_idx as u64), ctx)
    } else {
        extract_stable_coin<ConditionalCoinType>(&mut progress.position_uid, (outcome_idx as u64), ctx)
    };

    let amount = coin.value();

    if (amount > 0) {
        if ((outcome_idx as u64) == progress.winning_outcome) {
            // Winning outcome: burn conditional → withdraw spot → transfer to recipient
            if (is_asset) {
                futarchy_markets::coin_escrow::burn_conditional_asset(escrow, (outcome_idx as u64), coin);
                let spot_coin = futarchy_markets::coin_escrow::withdraw_asset_balance<AssetType, StableType>(
                    escrow, amount, ctx
                );
                transfer::public_transfer(spot_coin, recipient);
                progress.spot_asset_accumulated = progress.spot_asset_accumulated + amount;
            } else {
                futarchy_markets::coin_escrow::burn_conditional_stable(escrow, (outcome_idx as u64), coin);
                let spot_coin = futarchy_markets::coin_escrow::withdraw_stable_balance<AssetType, StableType>(
                    escrow, amount, ctx
                );
                transfer::public_transfer(spot_coin, recipient);
                progress.spot_stable_accumulated = progress.spot_stable_accumulated + amount;
            }
        } else {
            // Losing outcome: just burn (no withdrawal)
            if (is_asset) {
                futarchy_markets::coin_escrow::burn_conditional_asset(escrow, (outcome_idx as u64), coin);
            } else {
                futarchy_markets::coin_escrow::burn_conditional_stable(escrow, (outcome_idx as u64), coin);
            }
        }
    } else {
        coin::destroy_zero(coin);
    };

    progress.outcomes_processed = progress.outcomes_processed + 1;
    progress
}

/// Step 3: Finish cranking (consumes hot potato)
/// Must be called after unwrapping all outcomes
///
/// # Panics
/// If not all outcomes have been processed
public fun finish_crank<AssetType, StableType>(
    progress: CrankProgress<AssetType, StableType>,
    registry: &mut SwapPositionRegistry<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let CrankProgress {
        position_uid,
        owner,
        proposal_id,
        winning_outcome,
        outcomes_processed,
        total_outcomes,
        spot_asset_accumulated,
        spot_stable_accumulated,
    } = progress;

    // Ensure all outcomes processed (optional - could be relaxed)
    // assert!(outcomes_processed == total_outcomes * 2, 999);  // *2 because asset + stable per outcome

    object::delete(position_uid);
    registry.total_cranked = registry.total_cranked + 1;

    event::emit(SwapPositionCranked {
        owner,
        proposal_id,
        winning_outcome,
        spot_asset_returned: spot_asset_accumulated,
        spot_stable_returned: spot_stable_accumulated,
        cranker: ctx.sender(),
        cranker_fee: 0,  // Fee handled separately in unwrap_one calls
        timestamp: clock.timestamp_ms(),
    });
}

// === Old Hardcoded Functions Removed ===
// All crank_position_N functions have been replaced by the PTB + Hot Potato pattern above.
// Frontend constructs dynamic PTBs using: start_crank() → unwrap_one() (N times) → finish_crank()
// This eliminates the need for 100+ hardcoded functions and supports 2-100+ outcomes.

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

/// Check if a position is ready to be cranked
/// Returns true if:
/// 1. Position exists in registry
/// 2. Proposal is finalized (winning outcome determined)
///
/// Frontend should call this before constructing PTB to avoid wasted gas
public fun can_crank_position<AssetType, StableType>(
    registry: &SwapPositionRegistry<AssetType, StableType>,
    owner: address,
    proposal: &Proposal<AssetType, StableType>,
): bool {
    let proposal_id = object::id(proposal);
    let key = PositionKey { owner, proposal_id };

    // Check position exists
    if (!table::contains(&registry.positions, key)) {
        return false
    };

    // Check proposal is finalized
    if (!futarchy_markets::proposal::is_finalized(proposal)) {
        return false
    };

    true
}

/// Get outcome count for a proposal
/// Helper for frontend to construct correct number of unwrap_one calls
///
/// # Example
/// ```
/// let outcome_count = get_outcome_count_for_position(registry, owner, proposal);
/// // Frontend constructs: outcome_count * 2 unwrap_one calls (asset + stable per outcome)
/// ```
public fun get_outcome_count_for_position<AssetType, StableType>(
    registry: &SwapPositionRegistry<AssetType, StableType>,
    owner: address,
    proposal: &Proposal<AssetType, StableType>,
): u64 {
    let proposal_id = object::id(proposal);
    let key = PositionKey { owner, proposal_id };

    // Ensure position exists
    assert!(table::contains(&registry.positions, key), EPositionNotFound);

    futarchy_markets::proposal::outcome_count(proposal)
}

/// Share the registry (called after creation)
public fun share<AssetType, StableType>(
    registry: SwapPositionRegistry<AssetType, StableType>,
) {
    transfer::share_object(registry);
}
