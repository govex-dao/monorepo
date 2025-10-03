/// Unified oracle actions - uses stored TreasuryCap from DAO Account
module futarchy_oracle::oracle_actions;

use std::string::{Self, String};
use std::vector;
use std::option::{Self, Option};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::clock::Clock;
use sui::transfer;
use sui::tx_context::TxContext;
use sui::object::{Self, ID};
use sui::event;
use sui::bcs::{Self, BCS};
use account_protocol::{
    intents::{Self, Expired, Intent, ActionSpec},
    executable::{Self, Executable},
    account::{Self, Account},
    version_witness::VersionWitness,
    bcs_validation,
};
use account_actions::currency;
use futarchy_core::{
    action_validation,
    action_types,
    futarchy_config::{Self, FutarchyConfig},
    version,
};
use futarchy_markets::{
    spot_amm::{Self, SpotAMM},
    spot_conditional_quoter,
    proposal::Proposal,
    conditional_amm,
};
use futarchy_multisig::{
    weighted_multisig::{Self, WeightedMultisig},
};
use futarchy_one_shot_utils::{math, constants};
// ResourceRequest removed - using direct execution pattern

// === Errors ===
const EPriceThresholdNotMet: u64 = 0;
const EInvalidMintAmount: u64 = 1;
const EInvalidRecipient: u64 = 2;
const ETimeConditionNotMet: u64 = 3;
const ETwapNotReady: u64 = 4;
const EExceedsMaxSupply: u64 = 5;
const EAlreadyExecuted: u64 = 6;
const EInvalidThreshold: u64 = 7;
const EOverflow: u64 = 8;
const EDivisionByZero: u64 = 9;
const ECannotExecuteWithoutTreasuryCap: u64 = 10;
const EMismatchedVectors: u64 = 11;
const EEmptyRecipients: u64 = 12;
const ETierOutOfBounds: u64 = 13;
const EInvalidSecurityCouncil: u64 = 14;
const ERecipientNotFound: u64 = 15;
const EInsufficientPaymentForStrike: u64 = 16;
const ENotVestedYet: u64 = 17;
const ENoVestedTokensAvailable: u64 = 18;
const ELaunchpadPriceRequired: u64 = 19;

// === Constants ===
const MAX_MINT_PERCENTAGE: u64 = 500; // 5% max mint per execution (in basis points)
const COOLDOWN_PERIOD_MS: u64 = 86_400_000; // 24 hours between mints
const MAX_RECIPIENTS_PER_TIER: u64 = 20; // Max cofounders per tier
const MAX_TIERS: u64 = 10; // Max price tiers

// === Helper Structs ===

/// Helper struct to store mint operations
public struct MintOperation has copy, drop {
    recipient: address,
    amount: u64,
}

// === Events ===

/// Emitted when tokens are minted based on oracle conditions
public struct ConditionalMintExecuted has copy, drop {
    recipient: address,
    amount_minted: u64,
    price_at_execution: u128,
    timestamp: u64,
}

/// Emitted when a tier is executed
public struct TierExecuted has copy, drop {
    tier_index: u64,
    total_minted: u64,
    price_at_execution: u128,
    timestamp: u64,
}

// === Structs ===


/// Action to read oracle price and conditionally mint tokens
/// This is used for founder rewards, liquidity incentives, employee options, etc.
public struct ConditionalMintAction<phantom T> has store, drop, copy {
    /// Address to receive minted tokens
    recipient: address,
    /// Amount of tokens to mint if condition is met
    mint_amount: u64,
    /// Price threshold (scaled by 1e12)
    price_threshold: u128,
    /// Whether price must be above (true) or below (false) threshold
    is_above_threshold: bool,
    /// Optional: earliest time this can execute (milliseconds)
    earliest_execution_time: Option<u64>,
    /// Optional: latest time this can execute (milliseconds)
    latest_execution_time: Option<u64>,
    /// Whether this action can be executed multiple times
    is_repeatable: bool,
    /// Cooldown period between executions (if repeatable)
    cooldown_ms: u64,
    /// Last execution timestamp
    last_execution: Option<u64>,
    /// Maximum number of executions (0 = unlimited)
    max_executions: u64,
    /// Current execution count
    execution_count: u64,

    // Option-specific fields
    /// Strike price for options (0 = free grant, >0 = option with strike price)
    strike_price: u64,
    /// Whether this requires payment at strike price to exercise
    is_option: bool,

    // Vesting fields
    /// Cliff period in milliseconds (no vesting during cliff)
    cliff_duration_ms: u64,
    /// Total vesting duration in milliseconds (after cliff)
    vesting_duration_ms: u64,
    /// Start time for vesting calculation
    vesting_start_time: Option<u64>,
    /// Amount already vested and claimed
    vested_amount: u64,

    /// Description of the mint purpose
    description: String,
}


/// A single recipient's mint configuration
public struct RecipientMint has store, copy, drop {
    recipient: address,
    mint_amount: u64,
}

/// A price tier with multiple recipients
public struct PriceTier has store, copy, drop {
    /// Price multiplier (e.g., 2_000_000_000 = 2.0x, scaled by 1e9)
    /// If 0, uses absolute price_threshold instead
    price_multiplier: u64,
    /// Absolute price threshold (only used if price_multiplier is 0, scaled by 1e12)
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
public struct TieredMintAction<phantom T> has store, drop, copy {
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

/// Long-lived pre-approved intent for recurring mints
/// This allows DAOs to set up automated token distribution
public struct RecurringMintIntent<phantom T> has store {
    /// Configurations for multiple mint conditions
    mint_configs: vector<ConditionalMintAction<T>>,
    /// Total amount authorized for minting
    total_authorized: u64,
    /// Amount already minted
    total_minted: u64,
    /// Intent expiration time
    expires_at: u64,
    /// Whether the intent is active
    is_active: bool,
}

// === Constructor Functions ===

/// Create a new RecipientMint
public fun new_recipient_mint(
    recipient: address,
    mint_amount: u64,
): RecipientMint {
    RecipientMint {
        recipient,
        mint_amount,
    }
}

/// Create a new PriceTier with absolute price
public fun new_price_tier(
    price_threshold: u128,
    is_above_threshold: bool,
    recipients: vector<RecipientMint>,
    description: String,
): PriceTier {
    PriceTier {
        price_multiplier: 0, // Using absolute price
        price_threshold,
        is_above_threshold,
        recipients,
        description,
        executed: false,
    }
}

/// Create a new PriceTier with price multiplier (for founder rewards)
public fun new_price_tier_with_multiplier(
    price_multiplier: u64, // e.g., 2_000_000_000 = 2.0x
    is_above_threshold: bool,
    recipients: vector<RecipientMint>,
    description: String,
): PriceTier {
    PriceTier {
        price_multiplier,
        price_threshold: 0, // Will be calculated at execution
        is_above_threshold,
        recipients,
        description,
        executed: false,
    }
}

public fun new_conditional_mint<T>(
    recipient: address,
    mint_amount: u64,
    price_threshold: u128,
    is_above_threshold: bool,
    earliest_time: Option<u64>,
    latest_time: Option<u64>,
    is_repeatable: bool,
    description: String,
): ConditionalMintAction<T> {
    assert!(mint_amount > 0, EInvalidMintAmount);
    assert!(price_threshold > 0, EInvalidThreshold);

    // Validate time range if both are specified
    if (earliest_time.is_some() && latest_time.is_some()) {
        let earliest = *earliest_time.borrow();
        let latest = *latest_time.borrow();
        assert!(latest > earliest, ETimeConditionNotMet);

        // Max 5 years validity (in milliseconds)
        let max_duration = 5 * 365 * 24 * 60 * 60 * 1000; // 5 years
        assert!(latest - earliest <= max_duration, ETimeConditionNotMet);
    };

    ConditionalMintAction {
        recipient,
        mint_amount,
        price_threshold,
        is_above_threshold,
        earliest_execution_time: earliest_time,
        latest_execution_time: latest_time,
        is_repeatable,
        cooldown_ms: if (is_repeatable) COOLDOWN_PERIOD_MS else 0,
        last_execution: option::none(),
        max_executions: if (is_repeatable) 0 else 1,
        execution_count: 0,
        strike_price: 0, // Default to free grant
        is_option: false,
        cliff_duration_ms: 0,
        vesting_duration_ms: 0,
        vesting_start_time: option::none(),
        vested_amount: 0,
        description,
    }
}


/// Create an employee stock option with strike price and vesting
public fun new_employee_option<T>(
    recipient: address,
    option_amount: u64,
    strike_price: u64,
    price_threshold: u128, // Market price must reach this to enable exercise
    cliff_duration_ms: u64,
    vesting_duration_ms: u64,
    expiry_ms: u64,
    description: String,
    clock: &Clock,
): ConditionalMintAction<T> {
    let now = clock.timestamp_ms();

    ConditionalMintAction {
        recipient,
        mint_amount: option_amount,
        price_threshold,
        is_above_threshold: true, // Options typically require price above threshold
        earliest_execution_time: option::some(now + cliff_duration_ms),
        latest_execution_time: option::some(now + expiry_ms),
        is_repeatable: false,
        cooldown_ms: 0,
        last_execution: option::none(),
        max_executions: 1,
        execution_count: 0,
        strike_price,
        is_option: true,
        cliff_duration_ms,
        vesting_duration_ms,
        vesting_start_time: option::some(now),
        vested_amount: 0,
        description,
    }
}

/// Create a founder reward mint with explicit time bounds
public fun new_founder_reward_mint<T>(
    founder: address,
    amount: u64,
    unlock_price: u128,
    unlock_delay_ms: u64,
    description: String,
    clock: &Clock,
): ConditionalMintAction<T> {
    let now = clock.timestamp_ms();
    new_conditional_mint(
        founder,
        amount,
        unlock_price,
        true, // Above threshold
        option::some(now + unlock_delay_ms),
        option::none(), // No latest time
        false, // Not repeatable
        description,
    )
}

/// Create a liquidity incentive mint (repeatable)
public fun new_liquidity_incentive<T>(
    lp_address: address,
    amount_per_period: u64,
    min_price: u128,
    description: String,
): ConditionalMintAction<T> {
    new_conditional_mint(
        lp_address,
        amount_per_period,
        min_price,
        true, // Above threshold
        option::none(), // Can start immediately
        option::none(), // No end time
        true, // Repeatable
        description,
    )
}

/// Create a tiered mint action with multiple recipients
public fun new_tiered_mint<T>(
    tiers: vector<PriceTier>,
    earliest_time: u64,
    latest_time: u64,
    description: String,
    security_council_id: Option<ID>,
): TieredMintAction<T> {
    assert!(tiers.length() > 0 && tiers.length() <= MAX_TIERS, ETierOutOfBounds);
    assert!(latest_time > earliest_time, ETimeConditionNotMet);

    // Validate each tier
    let mut i = 0;
    while (i < tiers.length()) {
        let tier = tiers.borrow(i);
        assert!(tier.recipients.length() > 0, EEmptyRecipients);
        assert!(tier.recipients.length() <= MAX_RECIPIENTS_PER_TIER, ETierOutOfBounds);
        i = i + 1;
    };

    TieredMintAction {
        tiers,
        earliest_execution_time: earliest_time,
        latest_execution_time: latest_time,
        description,
        security_council_id,
    }
}

/// Create a tiered founder reward structure
public fun new_tiered_founder_rewards<T>(
    recipients_per_tier: vector<vector<address>>,
    amounts_per_tier: vector<vector<u64>>,
    price_thresholds: vector<u128>,
    descriptions_per_tier: vector<String>,
    earliest_time: u64,
    latest_time: u64,
    description: String,
): TieredMintAction<T> {
    assert!(
        recipients_per_tier.length() == amounts_per_tier.length() &&
        amounts_per_tier.length() == price_thresholds.length() &&
        price_thresholds.length() == descriptions_per_tier.length(),
        EMismatchedVectors
    );
    
    let mut tiers = vector::empty();
    let mut i = 0;
    
    while (i < recipients_per_tier.length()) {
        let recipients = recipients_per_tier.borrow(i);
        let amounts = amounts_per_tier.borrow(i);
        assert!(recipients.length() == amounts.length(), EMismatchedVectors);
        
        let mut recipient_mints = vector::empty();
        let mut j = 0;
        while (j < recipients.length()) {
            vector::push_back(&mut recipient_mints, RecipientMint {
                recipient: *recipients.borrow(j),
                mint_amount: *amounts.borrow(j),
            });
            j = j + 1;
        };
        
        vector::push_back(&mut tiers, PriceTier {
            price_threshold: *price_thresholds.borrow(i),
            price_multiplier: 0, // Absolute price threshold, not multiplier-based
            is_above_threshold: true,
            recipients: recipient_mints,
            executed: false,
            description: *descriptions_per_tier.borrow(i),
        });
        
        i = i + 1;
    };
    
    new_tiered_mint(
        tiers,
        earliest_time,
        latest_time,
        description,
        option::none(),
    )
}

// === Execution Functions ===

/// Execute conditional mint using stored TreasuryCap
public fun do_conditional_mint<AssetType, StableType, Outcome: store, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    spot_pool: &mut SpotAMM<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::ConditionalMint>(spec);

    let action_data = intents::action_spec_data(spec);

    // Safe BCS deserialization
    let mut reader = bcs::new(*action_data);
    let recipient = bcs::peel_address(&mut reader);
    let mint_amount = bcs::peel_u64(&mut reader);
    let price_threshold = bcs::peel_u128(&mut reader);
    let is_above_threshold = bcs::peel_bool(&mut reader);
    let is_repeatable = bcs::peel_bool(&mut reader);
    let execution_count = bcs::peel_u64(&mut reader);
    let cooldown_ms = bcs::peel_u64(&mut reader);
    let has_earliest = bcs::peel_bool(&mut reader);
    let earliest_time = if (has_earliest) { option::some(bcs::peel_u64(&mut reader)) } else { option::none() };
    let has_latest = bcs::peel_bool(&mut reader);
    let latest_time = if (has_latest) { option::some(bcs::peel_u64(&mut reader)) } else { option::none() };
    let has_last = bcs::peel_bool(&mut reader);
    let last_execution = if (has_last) { option::some(bcs::peel_u64(&mut reader)) } else { option::none() };
    bcs_validation::validate_all_bytes_consumed(reader);
    
    // Validate time conditions
    let now = clock.timestamp_ms();
    if (earliest_time.is_some()) {
        assert!(now >= *earliest_time.borrow(), ETimeConditionNotMet);
    };
    if (latest_time.is_some()) {
        assert!(now <= *latest_time.borrow(), ETimeConditionNotMet);
    };
    
    // Check if already executed (if not repeatable)
    if (!is_repeatable && execution_count > 0) {
        abort EAlreadyExecuted
    };
    
    // Check cooldown if repeatable
    if (is_repeatable && last_execution.is_some()) {
        let last = *last_execution.borrow();
        assert!(now >= last + cooldown_ms, ETimeConditionNotMet);
    };
    
    // Get current price
    assert!(spot_amm::is_twap_ready(spot_pool, clock), ETwapNotReady);
    let current_price = spot_amm::get_twap_mut(spot_pool, clock);
    
    // Check price threshold
    let threshold_met = if (is_above_threshold) {
        current_price >= price_threshold
    } else {
        current_price <= price_threshold
    };
    
    // Only mint if threshold is met
    assert!(threshold_met, EPriceThresholdNotMet);
    
    // Check that DAO has treasury cap
    assert!(currency::has_cap<FutarchyConfig, AssetType>(account), ECannotExecuteWithoutTreasuryCap);
    
    // Check max supply constraint with overflow protection
    let current_supply = currency::coin_type_supply<FutarchyConfig, AssetType>(account);
    // Use safe math to prevent overflow
    let max_mint = math::mul_div_to_64(current_supply, MAX_MINT_PERCENTAGE, 10000);
    let actual_mint = if (mint_amount > max_mint) {
        max_mint
    } else {
        mint_amount
    };
    
    // Mint using stored TreasuryCap
    let minted_coin = currency::do_mint<FutarchyConfig, Outcome, AssetType, IW>(
        executable,
        account,
        version,
        witness,
        ctx
    );

    // Verify minted amount
    assert!(coin::value(&minted_coin) == actual_mint, EInvalidMintAmount);

    // Transfer to recipient
    transfer::public_transfer(minted_coin, recipient);

    // Emit event
    event::emit(ConditionalMintExecuted {
        recipient,
        amount_minted: actual_mint,
        price_at_execution: current_price,
        timestamp: now,
    });

    // Increment action index after all is done
    executable::increment_action_idx(executable);
}

// fulfill_conditional_mint removed - using direct execution pattern

/// Execute tiered mint using stored TreasuryCap
public fun do_tiered_mint<AssetType, StableType, Outcome: store, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    spot_pool: &mut SpotAMM<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::TieredMint>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);

    // Deserialize TieredMintAction fields
    let tiers_count = bcs::peel_vec_length(&mut reader);
    let mut tiers = vector::empty<PriceTier>();
    let mut i = 0;
    while (i < tiers_count) {
        let price_threshold = bcs::peel_u128(&mut reader);
        let is_above_threshold = bcs::peel_bool(&mut reader);
        let recipients_count = bcs::peel_vec_length(&mut reader);
        let mut recipients = vector::empty<RecipientMint>();
        let mut j = 0;
        while (j < recipients_count) {
            let recipient = bcs::peel_address(&mut reader);
            let mint_amount = bcs::peel_u64(&mut reader);
            vector::push_back(&mut recipients, RecipientMint {
                recipient,
                mint_amount,
            });
            j = j + 1;
        };
        let executed = bcs::peel_bool(&mut reader);
        let desc_bytes = bcs::peel_vec_u8(&mut reader);
        let description = string::utf8(desc_bytes);
        vector::push_back(&mut tiers, PriceTier {
            price_threshold,
            price_multiplier: 0, // Absolute price threshold (legacy format)
            is_above_threshold,
            recipients,
            executed,
            description,
        });
        i = i + 1;
    };
    let earliest_execution_time = bcs::peel_u64(&mut reader);
    let latest_execution_time = bcs::peel_u64(&mut reader);
    let desc_bytes = bcs::peel_vec_u8(&mut reader);
    let description = string::utf8(desc_bytes);
    bcs_validation::validate_all_bytes_consumed(reader);

    let action = TieredMintAction<AssetType> {
        tiers,
        earliest_execution_time,
        latest_execution_time,
        description,
        security_council_id: option::none(),
    };

    // Increment action index
    executable::increment_action_idx(executable);
    
    // Validate time conditions
    let now = clock.timestamp_ms();
    assert!(now >= action.earliest_execution_time, ETimeConditionNotMet);
    assert!(now <= action.latest_execution_time, ETimeConditionNotMet);
    
    // Check that DAO has treasury cap
    assert!(currency::has_cap<FutarchyConfig, AssetType>(account), ECannotExecuteWithoutTreasuryCap);
    
    // Get current price
    assert!(spot_amm::is_twap_ready(spot_pool, clock), ETwapNotReady);
    let current_price = spot_amm::get_twap_mut(spot_pool, clock);
    
    // Collect all minting operations to perform
    let mut mints_to_perform = vector::empty<MintOperation>();
    let mut tier_events = vector::empty<TierExecuted>();
    
    // Check which tiers can execute and collect the mints
    let mut i = 0;
    while (i < action.tiers.length()) {
        let tier = &action.tiers[i];
        
        // Skip if already executed
        if (!tier.executed) {
            // Get launchpad initial price from DAO config (set during launchpad raise)
            let launchpad_price_opt = futarchy_config::get_launchpad_initial_price(
                account::config(account)
            );

            // Calculate actual threshold based on multiplier or use absolute threshold
            let actual_threshold = if (tier.price_multiplier > 0) {
                // Multiplier-based tiers REQUIRE launchpad price
                assert!(launchpad_price_opt.is_some(), ELaunchpadPriceRequired);

                let launchpad_price = *launchpad_price_opt.borrow();
                // Calculate threshold as: launchpad_price * multiplier / price_multiplier_scale
                // Use safe math from futarchy_one_shot_utils
                math::mul_div_mixed(
                    launchpad_price,
                    tier.price_multiplier,
                    (constants::price_multiplier_scale() as u128)
                )
            } else {
                // Use absolute price threshold
                tier.price_threshold
            };

            // CRITICAL: Check price threshold - use strict inequality to prevent minting AT starting price
            // AND ensure current price is ALWAYS above launchpad price (never mint if price dropped below raise price)
            let threshold_met = if (launchpad_price_opt.is_some()) {
                let launchpad_price = *launchpad_price_opt.borrow();
                if (tier.is_above_threshold) {
                    current_price > actual_threshold && current_price > launchpad_price
                } else {
                    current_price < actual_threshold && current_price > launchpad_price
                }
            } else {
                // No launchpad price (DAO not from launchpad), just check threshold
                if (tier.is_above_threshold) {
                    current_price > actual_threshold
                } else {
                    current_price < actual_threshold
                }
            };
            
            if (threshold_met) {
                let mut total_tier_minted = 0u64;
                
                // Collect mint operations for all recipients in this tier
                let mut j = 0;
                while (j < tier.recipients.length()) {
                    let recipient = tier.recipients.borrow(j);
                    
                    // Check mint doesn't exceed max supply percentage per mint with overflow protection
                    let current_supply = currency::coin_type_supply<FutarchyConfig, AssetType>(account);
                    // Use safe math to prevent overflow
                    let max_mint = math::mul_div_to_64(current_supply, MAX_MINT_PERCENTAGE, 10000);
                    let actual_mint = if (recipient.mint_amount > max_mint) {
                        max_mint
                    } else {
                        recipient.mint_amount
                    };
                    
                    // Store the mint operation to perform later
                    vector::push_back(&mut mints_to_perform, MintOperation {
                        recipient: recipient.recipient,
                        amount: actual_mint,
                    });
                    
                    total_tier_minted = total_tier_minted + actual_mint;
                    j = j + 1;
                };
                
                // Store event to emit later
                vector::push_back(&mut tier_events, TierExecuted {
                    tier_index: i,
                    total_minted: total_tier_minted,
                    price_at_execution: current_price,
                    timestamp: now,
                });
            };
        };
        
        i = i + 1;
    };
    
    // Now perform all the mints after we're done with the action reference
    let mut k = 0;
    while (k < vector::length(&mints_to_perform)) {
        let mint_op = vector::borrow(&mints_to_perform, k);
        
        // Mint using stored TreasuryCap
        let minted_coin = currency::do_mint<FutarchyConfig, Outcome, AssetType, IW>(
            executable,
            account,
            version,
            witness,
            ctx
        );
        
        // Transfer to recipient
        transfer::public_transfer(minted_coin, mint_op.recipient);
        k = k + 1;
    };
    
    // Emit all tier events
    let mut m = 0;
    while (m < vector::length(&tier_events)) {
        let tier_event = vector::pop_back(&mut tier_events);
        event::emit(tier_event);
        m = m + 1;
    };
}

// === Vesting and Option Functions ===

/// Calculate how much has vested based on time
fun calculate_vested_amount<T>(
    action: &ConditionalMintAction<T>,
    clock: &Clock,
): u64 {
    // If no vesting schedule, everything is immediately available
    if (action.vesting_duration_ms == 0) {
        return action.mint_amount
    };

    // Get vesting start time
    let vesting_start = if (action.vesting_start_time.is_some()) {
        *action.vesting_start_time.borrow()
    } else {
        return 0 // No vesting has started
    };

    let now = clock.timestamp_ms();

    // Still in cliff period
    if (now < vesting_start + action.cliff_duration_ms) {
        return 0
    };

    // Calculate time since cliff ended
    let cliff_end = vesting_start + action.cliff_duration_ms;
    let time_since_cliff = now - cliff_end;

    // If past total vesting duration, everything is vested
    if (time_since_cliff >= action.vesting_duration_ms) {
        return action.mint_amount
    };

    // Calculate proportional vesting with safe math
    let vested = math::mul_div_to_64(
        action.mint_amount,
        time_since_cliff,
        action.vesting_duration_ms
    );

    vested
}

/// Exercise an option by paying the strike price
public fun exercise_option<AssetType, StableType, Outcome: store, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    mut payment: Coin<StableType>, // Payment in stable coin at strike price
    spot_pool: &mut SpotAMM<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::ConditionalMint>(spec);

    // Deserialize the action data field by field
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);

    let recipient = bcs::peel_address(&mut bcs);
    let mint_amount = bcs::peel_u64(&mut bcs);
    let price_threshold = bcs::peel_u128(&mut bcs);
    let is_above_threshold = bcs::peel_bool(&mut bcs);
    let earliest_execution_time = bcs::peel_option_u64(&mut bcs);
    let latest_execution_time = bcs::peel_option_u64(&mut bcs);
    let is_repeatable = bcs::peel_bool(&mut bcs);
    let cooldown_ms = bcs::peel_u64(&mut bcs);
    let last_execution = bcs::peel_option_u64(&mut bcs);
    let max_executions = bcs::peel_u64(&mut bcs);
    let execution_count = bcs::peel_u64(&mut bcs);
    let strike_price = bcs::peel_u64(&mut bcs);
    let is_option = bcs::peel_bool(&mut bcs);
    let cliff_duration_ms = bcs::peel_u64(&mut bcs);
    let vesting_duration_ms = bcs::peel_u64(&mut bcs);
    let vesting_start_time = bcs::peel_option_u64(&mut bcs);
    let vested_amount = bcs::peel_u64(&mut bcs);
    let description = bcs::peel_vec_u8(&mut bcs).to_string();

    let action = ConditionalMintAction<AssetType> {
        recipient,
        mint_amount,
        price_threshold,
        is_above_threshold,
        earliest_execution_time,
        latest_execution_time,
        is_repeatable,
        cooldown_ms,
        last_execution,
        max_executions,
        execution_count,
        strike_price,
        is_option,
        cliff_duration_ms,
        vesting_duration_ms,
        vesting_start_time,
        vested_amount,
        description,
    };

    // Increment action index
    executable::increment_action_idx(executable);

    // Verify this is an option (not a grant)
    assert!(action.is_option, EInvalidMintAmount);
    assert!(action.strike_price > 0, EInvalidMintAmount);

    // Calculate vested amount available to exercise
    let vested_available = calculate_vested_amount(&action, clock);
    let claimable = vested_available - action.vested_amount;
    assert!(claimable > 0, ENoVestedTokensAvailable);

    // Calculate required payment with safe math
    let required_payment = math::mul_div_to_64(claimable, action.strike_price, constants::price_multiplier_scale());
    assert!(coin::value(&payment) >= required_payment, EInsufficientPaymentForStrike);

    // Take exact payment amount
    let payment_to_dao = if (coin::value(&payment) > required_payment) {
        let change = coin::value(&payment) - required_payment;
        let change_coin = coin::split(&mut payment, change, ctx);
        transfer::public_transfer(change_coin, action.recipient);
        payment
    } else {
        payment
    };

    // Transfer payment to DAO treasury
    transfer::public_transfer(payment_to_dao, account::addr(account));

    // Mint the vested tokens
    let minted_coin = currency::do_mint<FutarchyConfig, Outcome, AssetType, IW>(
        executable,
        account,
        version,
        witness,
        ctx
    );

    // Verify minted amount
    assert!(coin::value(&minted_coin) == claimable, EInvalidMintAmount);

    // Transfer to recipient
    transfer::public_transfer(minted_coin, action.recipient);

    // Update vested amount in action
    // Note: This would need to be stored in the Intent for persistence
    // action.vested_amount = vested_available;

    event::emit(ConditionalMintExecuted {
        recipient: action.recipient,
        amount_minted: claimable,
        price_at_execution: spot_amm::get_twap_mut(spot_pool, clock),
        timestamp: clock.timestamp_ms(),
    });
}

// === Helper Functions ===
// Note: Safe math functions removed - use futarchy_one_shot_utils::math instead

// === Cleanup Functions ===

/// Delete a conditional mint action from expired intent
public fun delete_conditional_mint<T>(expired: &mut Expired) {
    // Remove the action spec from expired intent
    let spec = intents::remove_action_spec(expired);
    // Action has drop, will be automatically cleaned up
    let _ = spec;
}


/// Delete a tiered mint action from expired intent
public fun delete_tiered_mint<T>(expired: &mut Expired) {
    // Remove the action spec from expired intent
    let spec = intents::remove_action_spec(expired);
    // Action has drop, will be automatically cleaned up
    let _ = spec;

    // Note: Tiers are cleaned up automatically
}

/// Delete a recurring mint intent
public fun delete_recurring_mint<T>(expired: &mut Expired) {
    // Remove the action spec from expired intent
    let spec = intents::remove_action_spec(expired);
    // Action has drop, will be automatically cleaned up
    let _ = spec;
}

// === Read Oracle Price Action ===

/// Simple action to read oracle price and emit an event
public struct ReadOraclePriceAction<phantom AssetType, phantom StableType> has store, drop, copy {
    /// Whether to emit a price update event
    emit_event: bool,
}

/// Create a new read oracle price action
public fun new_read_oracle_action<AssetType, StableType>(emit_event: bool): ReadOraclePriceAction<AssetType, StableType> {
    ReadOraclePriceAction<AssetType, StableType> {
        emit_event,
    }
}

/// Execute the read oracle price action - placeholder for now
public fun do_read_oracle_price<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    witness: IW,
    ctx: &mut TxContext,
) {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::ReadOraclePrice>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let emit_event = bcs::peel_bool(&mut bcs);

    // For now, just emit an event if requested
    if (emit_event) {
        // Add actual price reading and event emission
        // event::emit(OraclePriceRead { ... });
    };

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Delete a read oracle price action from expired intent
public fun delete_read_oracle_price<AssetType, StableType>(expired: &mut Expired) {
    // Remove the action spec from expired intent
    let spec = intents::remove_action_spec(expired);
    // Action has drop, will be automatically cleaned up
    let _ = spec;
}