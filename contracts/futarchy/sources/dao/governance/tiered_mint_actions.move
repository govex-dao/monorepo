/// Tiered oracle-based minting for multiple recipients (cofounders)
/// Each price tier can mint to multiple addresses with different amounts
module futarchy::tiered_mint_actions;

use std::string::{Self, String};
use std::vector;
use std::option::{Self, Option};
use sui::coin::{Self, TreasuryCap};
use sui::clock::Clock;
use sui::transfer;
use sui::tx_context::TxContext;
use sui::object::{Self, ID};
use futarchy::spot_amm::{Self, SpotAMM};
use futarchy::weighted_multisig::{Self, WeightedMultisig};
use account_protocol::account::{Self, Account};

// === Errors ===
const EPriceThresholdNotMet: u64 = 0;
const EInvalidMintAmount: u64 = 1;
const EInvalidRecipient: u64 = 2;
const ETimeConditionNotMet: u64 = 3;
const ETwapNotReady: u64 = 4;
const EAlreadyExecuted: u64 = 5;
const EInvalidThreshold: u64 = 6;
const EOverflow: u64 = 7;
const EMismatchedVectors: u64 = 8;
const EEmptyRecipients: u64 = 9;
const ETierOutOfBounds: u64 = 10;
const EInvalidSecurityCouncil: u64 = 11;
const ERecipientNotFound: u64 = 12;

// === Constants ===
const MAX_RECIPIENTS_PER_TIER: u64 = 20; // Max cofounders per tier
const MAX_TIERS: u64 = 10; // Max price tiers
const MAX_MINT_PERCENTAGE: u64 = 500; // 5% max mint per tier (in basis points)

// === Structs ===

/// A single recipient's mint configuration
public struct RecipientMint has store, copy, drop {
    recipient: address,
    mint_amount: u64,
}

/// A price tier with multiple recipients
public struct PriceTier has store {
    /// Price threshold that must be reached (scaled by 1e12)
    price_threshold: u128,
    /// Whether price must be above (true) or below (false) threshold
    is_above_threshold: bool,
    /// Recipients and their mint amounts for this tier
    recipients: vector<RecipientMint>,
    /// Whether this tier has been executed
    executed: bool,
    /// Description of this tier (e.g., "2x milestone rewards")
    description: String,
}

/// Multi-tiered mint action for cofounders
/// Each tier can be executed independently when its price is reached
public struct TieredMintAction<phantom T> has store {
    /// All price tiers with their recipients
    tiers: vector<PriceTier>,
    /// Earliest time any tier can execute (milliseconds)
    earliest_execution_time: u64,
    /// Latest time any tier can execute (milliseconds)
    latest_execution_time: u64,
    /// Overall description
    description: String,
    /// Optional: Security council that can update recipients
    security_council_id: Option<ID>,
}

// === Constructor Functions ===

/// Create a new tiered mint action with multiple price levels and recipients
public fun new_tiered_mint<T>(
    price_thresholds: vector<u128>,
    is_above_thresholds: vector<bool>,
    recipients_per_tier: vector<vector<address>>,
    amounts_per_tier: vector<vector<u64>>,
    descriptions_per_tier: vector<String>,
    earliest_time: u64,
    latest_time: u64,
    description: String,
): TieredMintAction<T> {
    // Validate inputs
    let num_tiers = price_thresholds.length();
    assert!(num_tiers > 0 && num_tiers <= MAX_TIERS, EInvalidThreshold);
    assert!(is_above_thresholds.length() == num_tiers, EMismatchedVectors);
    assert!(recipients_per_tier.length() == num_tiers, EMismatchedVectors);
    assert!(amounts_per_tier.length() == num_tiers, EMismatchedVectors);
    assert!(descriptions_per_tier.length() == num_tiers, EMismatchedVectors);
    assert!(latest_time > earliest_time, ETimeConditionNotMet);
    
    // Build tiers
    let mut tiers = vector::empty<PriceTier>();
    let mut i = 0;
    while (i < num_tiers) {
        let recipients_vec = recipients_per_tier.borrow(i);
        let amounts_vec = amounts_per_tier.borrow(i);
        
        assert!(recipients_vec.length() > 0, EEmptyRecipients);
        assert!(recipients_vec.length() == amounts_vec.length(), EMismatchedVectors);
        assert!(recipients_vec.length() <= MAX_RECIPIENTS_PER_TIER, EOverflow);
        
        // Build recipient mints for this tier
        let mut recipients = vector::empty<RecipientMint>();
        let mut j = 0;
        while (j < recipients_vec.length()) {
            let recipient = *recipients_vec.borrow(j);
            let amount = *amounts_vec.borrow(j);
            assert!(amount > 0, EInvalidMintAmount);
            
            recipients.push_back(RecipientMint {
                recipient,
                mint_amount: amount,
            });
            j = j + 1;
        };
        
        let tier = PriceTier {
            price_threshold: *price_thresholds.borrow(i),
            is_above_threshold: *is_above_thresholds.borrow(i),
            recipients,
            executed: false,
            description: *descriptions_per_tier.borrow(i),
        };
        
        tiers.push_back(tier);
        i = i + 1;
    };
    
    TieredMintAction {
        tiers,
        earliest_execution_time: earliest_time,
        latest_execution_time: latest_time,
        description,
        security_council_id: option::none(),
    }
}

/// Simplified constructor for common case: multiple tiers, same recipients
public fun new_tiered_mint_same_recipients<T>(
    price_thresholds: vector<u128>,
    recipients: vector<address>,
    base_amounts: vector<u64>, // Base amount per recipient
    multipliers_per_tier: vector<u64>, // Multiplier for each tier (in basis points)
    earliest_time: u64,
    latest_time: u64,
    description: String,
): TieredMintAction<T> {
    assert!(price_thresholds.length() > 0, EInvalidThreshold);
    assert!(recipients.length() > 0, EEmptyRecipients);
    assert!(base_amounts.length() == recipients.length(), EMismatchedVectors);
    assert!(multipliers_per_tier.length() == price_thresholds.length(), EMismatchedVectors);
    
    // Build tier data
    let mut recipients_per_tier = vector::empty<vector<address>>();
    let mut amounts_per_tier = vector::empty<vector<u64>>();
    let mut is_above_thresholds = vector::empty<bool>();
    let mut descriptions_per_tier = vector::empty<String>();
    
    let mut tier_idx = 0;
    while (tier_idx < price_thresholds.length()) {
        let multiplier = *multipliers_per_tier.borrow(tier_idx);
        
        // Calculate amounts for this tier
        let mut tier_amounts = vector::empty<u64>();
        let mut j = 0;
        while (j < base_amounts.length()) {
            let base = *base_amounts.borrow(j);
            let amount = (base * multiplier) / 10000; // Convert from basis points
            tier_amounts.push_back(amount);
            j = j + 1;
        };
        
        recipients_per_tier.push_back(recipients);
        amounts_per_tier.push_back(tier_amounts);
        is_above_thresholds.push_back(true); // All tiers are "above" thresholds
        
        // Generate tier description
        let tier_desc = string::utf8(b"Tier rewards");
        descriptions_per_tier.push_back(tier_desc);
        
        tier_idx = tier_idx + 1;
    };
    
    new_tiered_mint(
        price_thresholds,
        is_above_thresholds,
        recipients_per_tier,
        amounts_per_tier,
        descriptions_per_tier,
        earliest_time,
        latest_time,
        description,
    )
}

/// Create a tiered mint with security council governance
public fun new_tiered_mint_with_council<T>(
    price_thresholds: vector<u128>,
    is_above_thresholds: vector<bool>,
    recipients_per_tier: vector<vector<address>>,
    amounts_per_tier: vector<vector<u64>>,
    descriptions_per_tier: vector<String>,
    earliest_time: u64,
    latest_time: u64,
    description: String,
    security_council_id: ID,
): TieredMintAction<T> {
    let mut action = new_tiered_mint(
        price_thresholds,
        is_above_thresholds,
        recipients_per_tier,
        amounts_per_tier,
        descriptions_per_tier,
        earliest_time,
        latest_time,
        description,
    );
    
    action.security_council_id = option::some(security_council_id);
    action
}

// === Security Council Functions ===

/// Update a recipient's address (e.g., if they lose access to their wallet)
public fun update_recipient_address<T>(
    action: &mut TieredMintAction<T>,
    council: &Account<WeightedMultisig>,
    old_address: address,
    new_address: address,
    ctx: &TxContext,
) {
    // Verify caller is authorized via security council
    assert!(action.security_council_id.is_some(), EInvalidSecurityCouncil);
    let council_id = *action.security_council_id.borrow();
    assert!(object::id(council) == council_id, EInvalidSecurityCouncil);
    weighted_multisig::assert_is_member(account::config(council), ctx.sender());
    
    // Update address in all tiers where it appears
    let mut updated = false;
    let mut i = 0;
    while (i < action.tiers.length()) {
        let tier = action.tiers.borrow_mut(i);
        
        // Skip already executed tiers
        if (!tier.executed) {
            let mut j = 0;
            while (j < tier.recipients.length()) {
                let recipient = tier.recipients.borrow_mut(j);
                if (recipient.recipient == old_address) {
                    recipient.recipient = new_address;
                    updated = true;
                };
                j = j + 1;
            };
        };
        i = i + 1;
    };
    
    assert!(updated, ERecipientNotFound);
}

/// Remove a recipient from all unexecuted tiers
public fun remove_recipient<T>(
    action: &mut TieredMintAction<T>,
    council: &Account<WeightedMultisig>,
    address_to_remove: address,
    ctx: &TxContext,
) {
    // Verify caller is authorized via security council
    assert!(action.security_council_id.is_some(), EInvalidSecurityCouncil);
    let council_id = *action.security_council_id.borrow();
    assert!(object::id(council) == council_id, EInvalidSecurityCouncil);
    weighted_multisig::assert_is_member(account::config(council), ctx.sender());
    
    // Remove from all unexecuted tiers
    let mut removed = false;
    let mut i = 0;
    while (i < action.tiers.length()) {
        let tier = action.tiers.borrow_mut(i);
        
        // Skip already executed tiers
        if (!tier.executed) {
            let mut j = 0;
            while (j < tier.recipients.length()) {
                if (tier.recipients.borrow(j).recipient == address_to_remove) {
                    tier.recipients.swap_remove(j);
                    removed = true;
                    // Don't increment j since we removed an element
                } else {
                    j = j + 1;
                };
            };
        };
        i = i + 1;
    };
    
    assert!(removed, ERecipientNotFound);
}


// === Execution Functions ===

/// Execute a specific tier when its price condition is met
public fun execute_tier<AssetType, StableType, T>(
    action: &mut TieredMintAction<T>,
    tier_index: u64,
    treasury_cap: &mut TreasuryCap<T>,
    spot_pool: &mut SpotAMM<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let now = clock.timestamp_ms();
    
    // Check time bounds
    assert!(now >= action.earliest_execution_time, ETimeConditionNotMet);
    assert!(now <= action.latest_execution_time, ETimeConditionNotMet);
    
    // Check tier index
    assert!(tier_index < action.tiers.length(), ETierOutOfBounds);
    
    let tier = action.tiers.borrow_mut(tier_index);
    assert!(!tier.executed, EAlreadyExecuted);
    
    // Check price condition
    let current_price = spot_amm::get_twap_mut(spot_pool, clock);
    let threshold_met = if (tier.is_above_threshold) {
        current_price >= tier.price_threshold
    } else {
        current_price <= tier.price_threshold
    };
    assert!(threshold_met, EPriceThresholdNotMet);
    
    // Check total mint doesn't exceed max percentage
    let current_supply = treasury_cap.total_supply();
    let mut total_mint = 0u64;
    let mut i = 0;
    while (i < tier.recipients.length()) {
        let recipient_mint = tier.recipients.borrow(i);
        total_mint = total_mint + recipient_mint.mint_amount;
        i = i + 1;
    };
    
    let max_mint = (current_supply * MAX_MINT_PERCENTAGE) / 10000;
    if (total_mint > max_mint) {
        total_mint = max_mint; // Cap total mint
    };
    
    // Mint to all recipients in this tier
    let mut j = 0;
    let mut remaining_mint = total_mint;
    while (j < tier.recipients.length()) {
        let recipient_mint = tier.recipients.borrow(j);
        
        // Calculate proportional amount if we hit the cap
        let mint_amount = if (total_mint < max_mint) {
            recipient_mint.mint_amount
        } else {
            // Proportionally reduce based on cap
            let proportion = (recipient_mint.mint_amount * 10000) / total_mint;
            (max_mint * proportion) / 10000
        };
        
        // Ensure we don't exceed remaining mint
        let actual_mint = if (mint_amount > remaining_mint) {
            remaining_mint
        } else {
            mint_amount
        };
        
        if (actual_mint > 0) {
            let minted_coin = coin::mint(treasury_cap, actual_mint, ctx);
            transfer::public_transfer(minted_coin, recipient_mint.recipient);
            remaining_mint = remaining_mint - actual_mint;
        };
        
        j = j + 1;
    };
    
    // Mark tier as executed
    tier.executed = true;
}

/// Execute all eligible tiers at once
public fun execute_all_eligible_tiers<AssetType, StableType, T>(
    action: &mut TieredMintAction<T>,
    treasury_cap: &mut TreasuryCap<T>,
    spot_pool: &mut SpotAMM<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let mut executed_count = 0;
    let mut i = 0;
    
    while (i < action.tiers.length()) {
        if (is_tier_ready(action, i, spot_pool, clock)) {
            execute_tier(action, i, treasury_cap, spot_pool, clock, ctx);
            executed_count = executed_count + 1;
        };
        i = i + 1;
    };
    
    executed_count
}

// === View Functions ===

/// Check if a specific tier is ready to execute
public fun is_tier_ready<AssetType, StableType, T>(
    action: &TieredMintAction<T>,
    tier_index: u64,
    spot_pool: &SpotAMM<AssetType, StableType>,
    clock: &Clock,
): bool {
    let now = clock.timestamp_ms();
    
    // Check time bounds
    if (now < action.earliest_execution_time) return false;
    if (now > action.latest_execution_time) return false;
    
    // Check tier index
    if (tier_index >= action.tiers.length()) return false;
    
    let tier = action.tiers.borrow(tier_index);
    if (tier.executed) return false;
    
    // Check TWAP is ready
    if (!spot_amm::is_twap_ready(spot_pool, clock)) return false;
    
    // Check price condition
    let current_price = spot_amm::get_twap(spot_pool, clock);
    if (tier.is_above_threshold) {
        current_price >= tier.price_threshold
    } else {
        current_price <= tier.price_threshold
    }
}

/// Get status of all tiers
public fun get_tiers_status<T>(
    action: &TieredMintAction<T>,
): (vector<bool>, vector<u128>) {
    let mut executed_statuses = vector::empty<bool>();
    let mut thresholds = vector::empty<u128>();
    
    let mut i = 0;
    while (i < action.tiers.length()) {
        let tier = action.tiers.borrow(i);
        executed_statuses.push_back(tier.executed);
        thresholds.push_back(tier.price_threshold);
        i = i + 1;
    };
    
    (executed_statuses, thresholds)
}

/// Get total recipients across all tiers
public fun get_total_recipients<T>(action: &TieredMintAction<T>): u64 {
    let mut total = 0;
    let mut seen_addresses = vector::empty<address>();
    
    let mut i = 0;
    while (i < action.tiers.length()) {
        let tier = action.tiers.borrow(i);
        let mut j = 0;
        while (j < tier.recipients.length()) {
            let recipient = tier.recipients.borrow(j).recipient;
            if (!vector::contains(&seen_addresses, &recipient)) {
                seen_addresses.push_back(recipient);
                total = total + 1;
            };
            j = j + 1;
        };
        i = i + 1;
    };
    
    total
}

/// Get number of executed tiers
public fun get_executed_tiers_count<T>(action: &TieredMintAction<T>): u64 {
    let mut count = 0;
    let mut i = 0;
    while (i < action.tiers.length()) {
        if (action.tiers.borrow(i).executed) {
            count = count + 1;
        };
        i = i + 1;
    };
    count
}

/// Check if all tiers have been executed
public fun all_tiers_executed<T>(action: &TieredMintAction<T>): bool {
    get_executed_tiers_count(action) == action.tiers.length()
}