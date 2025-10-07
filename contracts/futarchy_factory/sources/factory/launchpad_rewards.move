/// Module to handle founder rewards setup during launchpad DAO creation
///
/// # Multi-Founder Support
///
/// Supports flexible founder reward distribution with custom allocations per founder.
///
/// ## Example 1: Single Founder
/// ```
/// setup_founder_rewards(
///     dao_id,
///     treasury_cap,
///     founders: vector[@0xALICE],
///     founder_allocations_bps: vector[1000],  // 100% of founder allocation
///     total_founder_allocation_bps: 1000,     // 10% total
///     ...
/// )
/// // Result: Alice gets 10% of total supply across all tiers
/// ```
///
/// ## Example 2: Three Co-Founders (Equal Split)
/// ```
/// setup_founder_rewards(
///     dao_id,
///     treasury_cap,
///     founders: vector[@0xALICE, @0xBOB, @0xCHARLIE],
///     founder_allocations_bps: vector[500, 250, 250],  // 50%, 25%, 25%
///     total_founder_allocation_bps: 1500,              // 15% total
///     ...
/// )
/// // Result:
/// // - Alice:   7.5% (50% of 15%)
/// // - Bob:     3.75% (25% of 15%)
/// // - Charlie: 3.75% (25% of 15%)
/// ```
///
/// ## Example 3: Five Tiers (Linear Vesting)
/// ```
/// linear_vesting: true,
/// min_price_ratio: 2e9,   // 2x launchpad price
/// max_price_ratio: 10e9,  // 10x launchpad price
///
/// // Creates 5 tiers at: 2x, 4x, 6x, 8x, 10x
/// // Each tier unlocks 20% of founder allocation when price hits milestone
/// ```
module futarchy_factory::launchpad_rewards;

use std::string::{Self, String};
use std::vector;
use sui::coin::TreasuryCap;
use sui::clock::Clock;
use sui::object::ID;
use sui::tx_context::TxContext;
use futarchy_oracle::{
    oracle_actions::{Self, RecipientMint},
};
use futarchy_one_shot_utils::constants;

// === Errors ===
const EInvalidFounderAllocation: u64 = 1;
const EInvalidPriceRatio: u64 = 2;
const EFounderVectorsMismatch: u64 = 3;
const EFounderAllocationMismatch: u64 = 4;
const ENoFounders: u64 = 5;

// === Constants ===
const MAX_FOUNDER_ALLOCATION_BPS: u64 = 2000; // Max 20% for founders

/// Set up founder rewards as pre-approved oracle actions on the newly created DAO
/// This is called automatically during launchpad DAO creation
///
/// # Arguments
/// * `founders` - Vector of founder addresses
/// * `founder_allocations_bps` - Vector of allocations in basis points (must sum to total_founder_allocation_bps)
/// * `total_founder_allocation_bps` - Total allocation for all founders (max 20% = 2000 bps)
///
/// # Example
/// For 3 founders with 10% total allocation split 40%/35%/25%:
/// - total_founder_allocation_bps = 1000 (10%)
/// - founder_allocations_bps = [400, 350, 250] (40%, 35%, 25% of the 10%)
public fun setup_founder_rewards<AssetType>(
    dao_id: ID,
    treasury_cap: &TreasuryCap<AssetType>,
    founders: vector<address>,
    founder_allocations_bps: vector<u64>,
    total_founder_allocation_bps: u64,
    min_price_ratio: u64, // e.g., 2e9 = 2x
    max_price_ratio: u64, // e.g., 10e9 = 10x
    unlock_delay_ms: u64,
    linear_vesting: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    // Validate founder vectors
    let founder_count = vector::length(&founders);
    assert!(founder_count > 0, ENoFounders);
    assert!(founder_count == vector::length(&founder_allocations_bps), EFounderVectorsMismatch);

    // Validate allocations sum correctly
    let mut allocation_sum = 0u64;
    let mut i = 0;
    while (i < founder_count) {
        allocation_sum = allocation_sum + *vector::borrow(&founder_allocations_bps, i);
        i = i + 1;
    };
    assert!(allocation_sum == total_founder_allocation_bps, EFounderAllocationMismatch);

    // Validate parameters with explicit overflow protection
    assert!(total_founder_allocation_bps <= MAX_FOUNDER_ALLOCATION_BPS, EInvalidFounderAllocation);
    assert!(min_price_ratio > 0, EInvalidPriceRatio);
    assert!(max_price_ratio >= min_price_ratio, EInvalidPriceRatio);
    // Additional check to prevent arithmetic overflow in price calculations
    // Max 1000x multiplier
    assert!(max_price_ratio <= (constants::price_multiplier_scale() * 1000), EInvalidPriceRatio);

    let total_supply = treasury_cap.total_supply();
    let total_founder_allocation = (total_supply * total_founder_allocation_bps) / 10000;

    // Always use tiered mints (simpler, more flexible)
    setup_tiered_founder_rewards<AssetType>(
        dao_id,
        founders,
        founder_allocations_bps,
        total_founder_allocation,
        min_price_ratio,
        max_price_ratio,
        unlock_delay_ms,
        linear_vesting,
        clock,
        ctx
    )
}

/// Set up tiered founder rewards using new PriceBasedMintGrant system
/// Distributes rewards across multiple founders with custom allocations
fun setup_tiered_founder_rewards<AssetType>(
    dao_id: ID,
    founders: vector<address>,
    founder_allocations_bps: vector<u64>,
    total_allocation: u64,
    min_price_ratio: u64,
    max_price_ratio: u64,
    unlock_delay_ms: u64,
    linear_vesting: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    // Create either multiple tiers (linear) or single tier (cliff)
    let num_tiers = if (linear_vesting) { 5u64 } else { 1u64 };
    let mut price_multipliers = vector::empty<u64>();
    let mut recipients_per_tier = vector::empty<vector<RecipientMint>>();
    let mut descriptions = vector::empty<String>();

    // Calculate price multiplier step, handling single tier case
    let multiplier_step = if (num_tiers > 1) {
        // Safe subtraction since we already validated max >= min
        let multiplier_range = max_price_ratio - min_price_ratio;
        multiplier_range / (num_tiers - 1)
    } else {
        0 // Single tier uses min_price_ratio only
    };
    let amount_per_tier = total_allocation / num_tiers;

    let mut tier_idx = 0;
    while (tier_idx < num_tiers) {
        // Calculate price multiplier for this tier (scaled by price_multiplier_scale)
        // e.g., 2 * price_multiplier_scale = 2.0x, 5 * price_multiplier_scale = 5.0x
        let multiplier = min_price_ratio + (multiplier_step * tier_idx);
        price_multipliers.push_back(multiplier);

        // Multiple recipients per tier - distribute amount_per_tier among founders
        let mut recipients = vector::empty<RecipientMint>();
        let founder_count = vector::length(&founders);
        let mut founder_idx = 0;

        while (founder_idx < founder_count) {
            let founder_addr = *vector::borrow(&founders, founder_idx);
            let founder_bps = *vector::borrow(&founder_allocations_bps, founder_idx);

            // Calculate this founder's share of this tier
            // (amount_per_tier * founder_bps) / 10000
            let founder_tier_amount = (amount_per_tier * founder_bps) / 10000;

            recipients.push_back(oracle_actions::new_recipient_mint(
                founder_addr,
                founder_tier_amount,
            ));

            founder_idx = founder_idx + 1;
        };

        recipients_per_tier.push_back(recipients);

        // Description with actual multiplier value
        let tier_name = if (tier_idx == 0) {
            string::utf8(b"Initial milestone")
        } else if (tier_idx == num_tiers - 1) {
            string::utf8(b"Final milestone")
        } else {
            string::utf8(b"Progress milestone")
        };
        descriptions.push_back(tier_name);

        tier_idx = tier_idx + 1;
    };

    let current_time = clock.timestamp_ms();
    let earliest_time = current_time + unlock_delay_ms;
    let latest_time = earliest_time + (5 * 365 * 24 * 60 * 60 * 1000); // 5 years

    // Create the shared PriceBasedMintGrant object with proper DAO ID
    oracle_actions::create_milestone_rewards<AssetType, sui::sui::SUI>(
        price_multipliers,
        recipients_per_tier,
        descriptions,
        earliest_time,
        latest_time,
        dao_id,  // Actual DAO ID passed from caller
        clock,
        ctx,
    );

    // Return total allocation for accounting
    total_allocation
}