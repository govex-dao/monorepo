module futarchy::oracle_mint_actions;

use std::string::String;
use std::option::{Self, Option};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::clock::Clock;
use sui::transfer;
use sui::tx_context::TxContext;
use futarchy::spot_amm::{Self, SpotAMM};
use futarchy::proposal::Proposal;
use futarchy::spot_conditional_quoter;
use account_protocol::intents::{Expired};

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

// === Constants ===
const MAX_MINT_PERCENTAGE: u64 = 500; // 5% max mint per execution (in basis points)
const COOLDOWN_PERIOD_MS: u64 = 86_400_000; // 24 hours between mints

// === Structs ===

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

/// Action to read oracle and mint based on AMM ratio
/// Used for launchpad founder rewards based on market performance
public struct RatioBasedMintAction<phantom AssetType, phantom StableType> has store {
    /// Address to receive minted tokens
    recipient: address,
    /// Base amount to calculate mint from
    base_amount: u64,
    /// Multiplier based on price ratio (in basis points)
    /// e.g., 100 = 1% of base_amount per 1x price ratio
    ratio_multiplier_bps: u64,
    /// Minimum price ratio required (scaled by 1e9)
    min_ratio: u64,
    /// Maximum price ratio cap (scaled by 1e9)
    max_ratio: u64,
    /// Time after which this can be executed
    unlock_time: u64,
    /// Whether this has been executed
    executed: bool,
    /// Description
    description: String,
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

public fun new_ratio_based_mint<AssetType, StableType>(
    recipient: address,
    base_amount: u64,
    ratio_multiplier_bps: u64,
    min_ratio: u64,
    max_ratio: u64,
    unlock_time: u64,
    description: String,
): RatioBasedMintAction<AssetType, StableType> {
    assert!(base_amount > 0, EInvalidMintAmount);
    assert!(min_ratio > 0 && max_ratio >= min_ratio, EInvalidThreshold);
    
    RatioBasedMintAction {
        recipient,
        base_amount,
        ratio_multiplier_bps,
        min_ratio,
        max_ratio,
        unlock_time,
        executed: false,
        description,
    }
}

/// Create a founder reward mint with explicit time bounds
/// This is pre-approved at DAO creation and can sit for years
public fun new_founder_reward_mint<T>(
    recipient: address,
    mint_amount: u64,
    price_threshold: u128,
    is_above_threshold: bool,
    activation_delay_ms: u64,  // How long after DAO creation before it can execute
    validity_duration_ms: u64, // How long the reward is valid for (max 5 years)
    description: String,
    current_time: u64,
): ConditionalMintAction<T> {
    assert!(mint_amount > 0, EInvalidMintAmount);
    assert!(price_threshold > 0, EInvalidThreshold);
    
    // Validate duration bounds (min 1 day, max 5 years)
    let min_duration = 24 * 60 * 60 * 1000; // 1 day
    let max_duration = 5 * 365 * 24 * 60 * 60 * 1000; // 5 years
    assert!(validity_duration_ms >= min_duration, ETimeConditionNotMet);
    assert!(validity_duration_ms <= max_duration, ETimeConditionNotMet);
    
    let earliest_time = current_time + activation_delay_ms;
    let latest_time = earliest_time + validity_duration_ms;
    
    ConditionalMintAction {
        recipient,
        mint_amount,
        price_threshold,
        is_above_threshold,
        earliest_execution_time: option::some(earliest_time),
        latest_execution_time: option::some(latest_time),
        is_repeatable: false, // Founder rewards are typically one-time
        cooldown_ms: 0,
        last_execution: option::none(),
        max_executions: 1,
        execution_count: 0,
        description,
    }
}

// === Execution Functions ===

/// Execute conditional mint based on oracle price
public fun execute_conditional_mint<AssetType, StableType, T>(
    action: &mut ConditionalMintAction<T>,
    treasury_cap: &mut TreasuryCap<T>,
    spot_pool: &mut SpotAMM<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let now = clock.timestamp_ms();
    
    // Check time conditions
    if (action.earliest_execution_time.is_some()) {
        assert!(now >= *action.earliest_execution_time.borrow(), ETimeConditionNotMet);
    };
    
    if (action.latest_execution_time.is_some()) {
        assert!(now <= *action.latest_execution_time.borrow(), ETimeConditionNotMet);
    };
    
    // Check execution limits
    if (!action.is_repeatable) {
        assert!(action.execution_count == 0, EAlreadyExecuted);
    } else {
        // Check cooldown
        if (action.last_execution.is_some()) {
            let last = *action.last_execution.borrow();
            assert!(now >= last + action.cooldown_ms, ETimeConditionNotMet);
        };
        
        // Check max executions
        if (action.max_executions > 0) {
            assert!(action.execution_count < action.max_executions, EAlreadyExecuted);
        };
    };
    
    // Get oracle price from spot AMM TWAP
    let oracle_price = spot_amm::get_twap_mut(spot_pool, clock);
    
    // Check price threshold
    let threshold_met = spot_conditional_quoter::check_price_threshold(
        oracle_price,
        action.price_threshold,
        action.is_above_threshold
    );
    assert!(threshold_met, EPriceThresholdNotMet);
    
    // Check mint doesn't exceed max supply percentage with safe math
    let current_supply = treasury_cap.total_supply();
    let max_mint = safe_mul_div_u64(current_supply, MAX_MINT_PERCENTAGE, 10000);
    let mint_amount = if (action.mint_amount > max_mint) {
        max_mint
    } else {
        action.mint_amount
    };
    
    // Mint tokens
    let minted_coin = coin::mint(treasury_cap, mint_amount, ctx);
    transfer::public_transfer(minted_coin, action.recipient);
    
    // Update action state
    action.execution_count = action.execution_count + 1;
    action.last_execution = option::some(now);
}

/// Execute ratio-based mint (for launchpad founder rewards) with overflow protection
public fun execute_ratio_mint<AssetType, StableType>(
    action: &mut RatioBasedMintAction<AssetType, StableType>,
    treasury_cap: &mut TreasuryCap<AssetType>,
    spot_pool: &mut SpotAMM<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(!action.executed, EAlreadyExecuted);
    assert!(clock.timestamp_ms() >= action.unlock_time, ETimeConditionNotMet);
    
    // Ensure TWAP is ready
    assert!(spot_amm::is_twap_ready(spot_pool, clock), ETwapNotReady);
    
    // Get current price ratio (asset price in stable terms)
    let current_price = spot_amm::get_twap_mut(spot_pool, clock);
    
    // Price ratio scaled by 1e9 (comparing to initial price of 1:1)
    // Safe division with validation
    assert!(current_price >= 1000, EDivisionByZero);
    let price_ratio_u128 = safe_div_u128(current_price, 1000); // Convert from 1e12 to 1e9 scale
    
    // Convert to u64 for comparison with action fields
    assert!(price_ratio_u128 <= (std::u64::max_value!() as u128), EOverflow);
    let price_ratio = price_ratio_u128 as u64;
    
    // Check minimum ratio
    assert!(price_ratio >= action.min_ratio, EPriceThresholdNotMet);
    
    // Cap at maximum ratio
    let effective_ratio = if (price_ratio > action.max_ratio) {
        action.max_ratio
    } else {
        price_ratio
    };
    
    // Calculate mint amount based on ratio with overflow protection
    // mint_amount = base_amount * effective_ratio * ratio_multiplier_bps / (1e9 * 10000)
    let base_amount_u128 = action.base_amount as u128;
    let effective_ratio_u128 = effective_ratio as u128;
    let ratio_multiplier_u128 = action.ratio_multiplier_bps as u128;
    
    // Step 1: base_amount * effective_ratio
    let step1 = safe_mul_u128(base_amount_u128, effective_ratio_u128);
    
    // Step 2: result * ratio_multiplier_bps
    let step2 = safe_mul_u128(step1, ratio_multiplier_u128);
    
    // Step 3: result / (1e9 * 10000)
    let divisor = safe_mul_u128(1_000_000_000, 10_000);
    let mint_amount = safe_div_u128(step2, divisor);
    
    assert!(mint_amount > 0, EInvalidMintAmount);
    assert!(mint_amount <= (std::u64::max_value!() as u128), EInvalidMintAmount);
    
    let final_mint_amount = mint_amount as u64;
    
    // Check mint doesn't exceed max supply percentage with safe math
    let current_supply = treasury_cap.total_supply();
    let max_mint = safe_mul_div_u64(current_supply, MAX_MINT_PERCENTAGE, 10000);
    let actual_mint = if (final_mint_amount > max_mint) {
        max_mint
    } else {
        final_mint_amount
    };
    
    // Mint tokens
    let minted_coin = coin::mint(treasury_cap, actual_mint, ctx);
    transfer::public_transfer(minted_coin, action.recipient);
    
    // Mark as executed
    action.executed = true;
}

// === Safe Math Functions ===

/// Safe multiplication for u128
fun safe_mul_u128(a: u128, b: u128): u128 {
    assert!(b == 0 || a <= std::u128::max_value!() / b, EOverflow);
    a * b
}

/// Safe division for u128
fun safe_div_u128(a: u128, b: u128): u128 {
    assert!(b > 0, EDivisionByZero);
    a / b
}

/// Safe multiplication then division for u64
fun safe_mul_div_u64(a: u64, b: u64, c: u64): u64 {
    assert!(c > 0, EDivisionByZero);
    let result = ((a as u128) * (b as u128)) / (c as u128);
    assert!(result <= (std::u64::max_value!() as u128), EOverflow);
    result as u64
}

// === Getter Functions for Intent Integration ===

public fun is_repeatable<T>(action: &ConditionalMintAction<T>): bool {
    action.is_repeatable
}

public fun is_max_executions_reached<T>(action: &ConditionalMintAction<T>): bool {
    action.max_executions > 0 && action.execution_count >= action.max_executions
}

public fun get_remaining_executions<T>(action: &ConditionalMintAction<T>): u64 {
    if (action.max_executions == 0) {
        std::u64::max_value!() // Unlimited
    } else {
        if (action.execution_count >= action.max_executions) {
            0
        } else {
            action.max_executions - action.execution_count
        }
    }
}

public fun get_next_execution_time<T>(action: &ConditionalMintAction<T>): Option<u64> {
    if (action.last_execution.is_some()) {
        let last = *action.last_execution.borrow();
        option::some(last + action.cooldown_ms)
    } else {
        action.earliest_execution_time
    }
}

// === View Functions ===

public fun is_conditional_mint_ready<AssetType, StableType, T>(
    action: &ConditionalMintAction<T>,
    spot_pool: &SpotAMM<AssetType, StableType>,
    clock: &Clock,
): bool {
    let now = clock.timestamp_ms();
    
    // Check time conditions
    if (action.earliest_execution_time.is_some()) {
        if (now < *action.earliest_execution_time.borrow()) return false;
    };
    
    if (action.latest_execution_time.is_some()) {
        if (now > *action.latest_execution_time.borrow()) return false;
    };
    
    // Check execution limits
    if (!action.is_repeatable && action.execution_count > 0) return false;
    
    if (action.is_repeatable && action.last_execution.is_some()) {
        let last = *action.last_execution.borrow();
        if (now < last + action.cooldown_ms) return false;
    };
    
    if (action.max_executions > 0 && action.execution_count >= action.max_executions) {
        return false
    };
    
    // Check price threshold
    let oracle_price = spot_amm::get_twap(spot_pool, clock);
    
    if (action.is_above_threshold) {
        oracle_price >= action.price_threshold
    } else {
        oracle_price <= action.price_threshold
    }
}

public fun is_ratio_mint_ready<AssetType, StableType>(
    action: &RatioBasedMintAction<AssetType, StableType>,
    spot_pool: &SpotAMM<AssetType, StableType>,
    clock: &Clock,
): bool {
    if (action.executed) return false;
    if (clock.timestamp_ms() < action.unlock_time) return false;
    if (!spot_amm::is_twap_ready(spot_pool, clock)) return false;
    
    let current_price = spot_amm::get_twap(spot_pool, clock);
    let price_ratio_u128 = current_price / 1000;
    
    // Convert to u64 for comparison
    if (price_ratio_u128 > (std::u64::max_value!() as u128)) return false;
    let price_ratio = price_ratio_u128 as u64;
    
    price_ratio >= action.min_ratio
}

// === Cleanup Functions ===

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

public fun delete_ratio_mint<AssetType, StableType>(expired: &mut Expired) {
    let RatioBasedMintAction<AssetType, StableType> {
        recipient: _,
        base_amount: _,
        ratio_multiplier_bps: _,
        min_ratio: _,
        max_ratio: _,
        unlock_time: _,
        executed: _,
        description: _,
    } = expired.remove_action();
}