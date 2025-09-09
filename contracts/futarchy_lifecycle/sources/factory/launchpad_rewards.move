/// Module to handle founder rewards setup during launchpad DAO creation
module futarchy_lifecycle::launchpad_rewards;

use std::string::{Self, String};
use std::vector;
use std::option::{Self, Option};
use sui::coin::TreasuryCap;
use sui::clock::Clock;
use sui::tx_context::TxContext;
use futarchy_lifecycle::{
    oracle_actions::{Self, TieredMintAction, PriceTier, RecipientMint},
};

// === Errors ===
const EInvalidFounderAllocation: u64 = 1;
const EInvalidPriceRatio: u64 = 2;

// === Constants ===
const MAX_FOUNDER_ALLOCATION_BPS: u64 = 2000; // Max 20% for founders

/// Set up founder rewards as pre-approved oracle actions on the newly created DAO
/// This is called automatically during launchpad DAO creation
public fun setup_founder_rewards<AssetType>(
    treasury_cap: &TreasuryCap<AssetType>,
    founder_address: address,
    founder_allocation_bps: u64,
    min_price_ratio: u64, // e.g., 2e9 = 2x
    max_price_ratio: u64, // e.g., 10e9 = 10x  
    unlock_delay_ms: u64,
    linear_vesting: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): TieredMintAction<AssetType> {
    // Validate parameters with explicit overflow protection
    assert!(founder_allocation_bps <= MAX_FOUNDER_ALLOCATION_BPS, EInvalidFounderAllocation);
    assert!(min_price_ratio > 0, EInvalidPriceRatio);
    assert!(max_price_ratio >= min_price_ratio, EInvalidPriceRatio);
    // Additional check to prevent arithmetic overflow in price calculations
    assert!(max_price_ratio <= 1_000_000_000_000, EInvalidPriceRatio); // Max 1000x
    
    let total_supply = treasury_cap.total_supply();
    let founder_allocation = (total_supply * founder_allocation_bps) / 10000;
    
    // Always use tiered mints (simpler, more flexible)
    setup_tiered_founder_rewards<AssetType>(
        founder_address,
        founder_allocation,
        min_price_ratio,
        max_price_ratio,
        unlock_delay_ms,
        linear_vesting,
        clock,
        ctx
    )
}

/// Set up tiered founder rewards
fun setup_tiered_founder_rewards<AssetType>(
    founder_address: address,
    total_allocation: u64,
    min_price_ratio: u64,
    max_price_ratio: u64,
    unlock_delay_ms: u64,
    linear_vesting: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): TieredMintAction<AssetType> {
    // Create either multiple tiers (linear) or single tier (cliff)
    let num_tiers = if (linear_vesting) { 5u64 } else { 1u64 };
    let mut price_thresholds = vector::empty<u128>();
    let mut recipients_per_tier = vector::empty<vector<address>>();
    let mut amounts_per_tier = vector::empty<vector<u64>>();
    let mut descriptions = vector::empty<String>();
    let mut is_above_thresholds = vector::empty<bool>();
    
    // Calculate price step, handling single tier case to avoid division by zero
    let price_step = if (num_tiers > 1) {
        // Safe subtraction since we already validated max >= min
        let price_range = max_price_ratio - min_price_ratio;
        price_range / (num_tiers - 1)
    } else {
        0 // Single tier uses min_price_ratio only
    };
    let amount_per_tier = total_allocation / num_tiers;
    
    let mut i = 0;
    while (i < num_tiers) {
        // Calculate price threshold for this tier
        let price_ratio = min_price_ratio + (price_step * i);
        // Convert from 1e9 to 1e12 scale for oracle
        let threshold = (price_ratio as u128) * 1000;
        price_thresholds.push_back(threshold);
        
        // Single recipient per tier
        let mut recipients = vector::empty<address>();
        recipients.push_back(founder_address);
        recipients_per_tier.push_back(recipients);
        
        // Equal amount per tier
        let mut amounts = vector::empty<u64>();
        amounts.push_back(amount_per_tier);
        amounts_per_tier.push_back(amounts);
        
        // Description
        let tier_name = if (i == 0) {
            string::utf8(b"Initial milestone")
        } else if (i == num_tiers - 1) {
            string::utf8(b"Final milestone")  
        } else {
            string::utf8(b"Progress milestone")
        };
        descriptions.push_back(tier_name);
        
        // All tiers are "above" thresholds
        is_above_thresholds.push_back(true);
        
        i = i + 1;
    };
    
    let current_time = clock.timestamp_ms();
    let earliest_time = current_time + unlock_delay_ms;
    let latest_time = earliest_time + (5 * 365 * 24 * 60 * 60 * 1000); // 5 years
    
    // Build PriceTier objects
    let mut tiers = vector::empty<PriceTier>();
    let mut i = 0;
    while (i < vector::length(&price_thresholds)) {
        let mut recipients = vector::empty<RecipientMint>();
        let tier_recipients = vector::borrow(&recipients_per_tier, i);
        let tier_amounts = vector::borrow(&amounts_per_tier, i);
        
        let mut j = 0;
        while (j < vector::length(tier_recipients)) {
            vector::push_back(&mut recipients, oracle_actions::new_recipient_mint(
                *vector::borrow(tier_recipients, j),
                *vector::borrow(tier_amounts, j)
            ));
            j = j + 1;
        };
        
        vector::push_back(&mut tiers, oracle_actions::new_price_tier(
            *vector::borrow(&price_thresholds, i),
            *vector::borrow(&is_above_thresholds, i),
            recipients,
            *vector::borrow(&descriptions, i)
        ));
        i = i + 1;
    };
    
    // Create the tiered mint action
    let tiered_action = oracle_actions::new_tiered_mint<AssetType>(
        tiers,
        earliest_time,
        latest_time,
        string::utf8(b"Founder vesting rewards"),
        option::none(), // No security council ID
    );
    
    // Return the action to be added to the DAO's initial intents
    tiered_action
}