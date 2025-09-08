/// Unified oracle actions - uses stored TreasuryCap from DAO Account
module futarchy_specialized_actions::oracle_actions;

use std::string::{Self, String};
use std::vector;
use std::option::{Self, Option};
use sui::coin::{Self, Coin};
use sui::clock::Clock;
use sui::transfer;
use sui::tx_context::TxContext;
use sui::object::{Self, ID};
use sui::event;
use account_protocol::{
    intents::{Expired, Intent},
    executable::{Self, Executable},
    account::{Self, Account},
    version_witness::VersionWitness,
};
use account_actions::currency;
use futarchy_core::{
    futarchy_config::FutarchyConfig,
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

/// Emitted when oracle price is read
public struct OraclePriceRead has copy, drop {
    oracle_type: u8, // 0 = spot, 1 = conditional
    price: u128,
    timestamp: u64,
}

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

/// Simple action to read oracle price
public struct ReadOraclePriceAction<phantom AssetType, phantom StableType> has store, drop {
    emit_event: bool,
}

/// Action to read oracle price and conditionally mint tokens
/// This is used for founder rewards, liquidity incentives, etc.
public struct ConditionalMintAction<phantom T> has store {
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
    /// Description of the mint purpose
    description: String,
}


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

/// Create a new PriceTier
public fun new_price_tier(
    price_threshold: u128,
    is_above_threshold: bool,
    recipients: vector<RecipientMint>,
    description: String,
): PriceTier {
    PriceTier {
        price_threshold,
        is_above_threshold,
        recipients,
        description,
        executed: false,
    }
}

/// Create a simple oracle read action
public fun new_read_oracle_action<AssetType, StableType>(
    emit_event: bool,
): ReadOraclePriceAction<AssetType, StableType> {
    ReadOraclePriceAction { emit_event }
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

/// Execute a read oracle price action
public fun do_read_oracle_price<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    witness: IW,
    spot_pool: &mut SpotAMM<AssetType, StableType>,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let action = executable::next_action<Outcome, ReadOraclePriceAction<AssetType, StableType>, IW>(executable, witness);
    
    // Read the price
    assert!(spot_amm::is_twap_ready(spot_pool, clock), ETwapNotReady);
    let price = spot_amm::get_twap_mut(spot_pool, clock);
    
    // Emit event if requested
    if (action.emit_event) {
        event::emit(OraclePriceRead {
            oracle_type: 0, // Spot oracle
            price,
            timestamp: clock.timestamp_ms(),
        });
    };
}

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
    // Get the action from the executable and extract necessary data
    let action = executable::next_action<Outcome, ConditionalMintAction<AssetType>, IW>(executable, witness);
    
    // Extract all needed values from action before any mutable operations
    let recipient = action.recipient;
    let mint_amount = action.mint_amount;
    let price_threshold = action.price_threshold;
    let is_above_threshold = action.is_above_threshold;
    let is_repeatable = action.is_repeatable;
    let execution_count = action.execution_count;
    let cooldown_ms = action.cooldown_ms;
    let earliest_time = action.earliest_execution_time;
    let latest_time = action.latest_execution_time;
    let last_execution = action.last_execution;
    
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
    
    // Check max supply constraint
    let current_supply = currency::coin_type_supply<FutarchyConfig, AssetType>(account);
    let max_mint = (current_supply * MAX_MINT_PERCENTAGE) / 10000;
    let actual_mint = if (mint_amount > max_mint) {
        max_mint
    } else {
        mint_amount
    };
    
    // Now we can safely call do_mint since we're no longer borrowing from action
    let minted_coin = currency::do_mint<FutarchyConfig, Outcome, AssetType, IW>(
        executable,
        account,
        version,
        witness,
        ctx
    );
    
    // Transfer to recipient
    transfer::public_transfer(minted_coin, recipient);
    
    // Emit event
    event::emit(ConditionalMintExecuted {
        recipient,
        amount_minted: actual_mint,
        price_at_execution: current_price,
        timestamp: now,
    });
}

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
    // Get the action from executable
    let action = executable::next_action<Outcome, TieredMintAction<AssetType>, IW>(executable, witness);
    
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
            // Check price threshold
            let threshold_met = if (tier.is_above_threshold) {
                current_price >= tier.price_threshold
            } else {
                current_price <= tier.price_threshold
            };
            
            if (threshold_met) {
                let mut total_tier_minted = 0u64;
                
                // Collect mint operations for all recipients in this tier
                let mut j = 0;
                while (j < tier.recipients.length()) {
                    let recipient = tier.recipients.borrow(j);
                    
                    // Check mint doesn't exceed max supply percentage per mint
                    let current_supply = currency::coin_type_supply<FutarchyConfig, AssetType>(account);
                    let max_mint = (current_supply * MAX_MINT_PERCENTAGE) / 10000;
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

// === Helper Functions ===

/// Safe multiplication with overflow protection  
fun safe_mul_u128(a: u128, b: u128): u128 {
    let max_u128 = 340282366920938463463374607431768211455u128;
    assert!(a == 0 || b <= max_u128 / a, EOverflow);
    a * b
}

/// Safe division with zero check
fun safe_div_u128(a: u128, b: u128): u128 {
    assert!(b != 0, EDivisionByZero);
    a / b
}

/// Safe multiplication then division for u64
fun safe_mul_div_u64(a: u64, b: u64, c: u64): u64 {
    let a_u128 = (a as u128);
    let b_u128 = (b as u128);
    let c_u128 = (c as u128);
    
    let result = safe_div_u128(safe_mul_u128(a_u128, b_u128), c_u128);
    assert!(result <= (std::u64::max_value!() as u128), EOverflow);
    (result as u64)
}

// === Cleanup Functions ===

/// Delete a conditional mint action from expired intent
public fun delete_conditional_mint<T>(expired: &mut Expired) {
    let ConditionalMintAction<T> {
        recipient: _,
        mint_amount: _,
        price_threshold: _,
        is_above_threshold: _,
        earliest_execution_time: _,
        latest_execution_time: _,
        is_repeatable: _,
        cooldown_ms: _,
        last_execution: _,
        max_executions: _,
        execution_count: _,
        description: _,
    } = expired.remove_action();
}


/// Delete a tiered mint action from expired intent
public fun delete_tiered_mint<T>(expired: &mut Expired) {
    let TieredMintAction<T> {
        mut tiers,
        earliest_execution_time: _,
        latest_execution_time: _,
        description: _,
        security_council_id: _,
    } = expired.remove_action();
    
    // Clean up tiers
    while (!tiers.is_empty()) {
        let PriceTier {
            price_threshold: _,
            is_above_threshold: _,
            recipients: _,
            executed: _,
            description: _,
        } = tiers.pop_back();
    };
    tiers.destroy_empty();
}

/// Delete a recurring mint intent
public fun delete_recurring_mint<T>(expired: &mut Expired) {
    let RecurringMintIntent<T> {
        mint_configs: mut mint_configs,
        total_authorized: _,
        total_minted: _,
        expires_at: _,
        is_active: _,
    } = expired.remove_action();
    
    // Properly destroy the vector of ConditionalMintAction which doesn't have drop
    while (!mint_configs.is_empty()) {
        let ConditionalMintAction {
            recipient: _,
            mint_amount: _,
            price_threshold: _,
            is_above_threshold: _,
            earliest_execution_time: _,
            latest_execution_time: _,
            is_repeatable: _,
            cooldown_ms: _,
            last_execution: _,
            max_executions: _,
            execution_count: _,
            description: _,
        } = mint_configs.pop_back();
    };
    mint_configs.destroy_empty();
}