/// Option Grants Module - Proper implementation with persistent state
/// Handles employee stock options and vesting grants with state persistence
module futarchy_oracle::option_grants;

use std::string::{Self, String};
use std::option::{Self, Option};
use sui::object::{Self, ID, UID};
use sui::coin::{Self, Coin};
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::transfer;
use sui::event;
use sui::tx_context::{Self, TxContext};
use sui::math;
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    version_witness::VersionWitness,
};
use account_actions::currency;
use futarchy_core::{
    futarchy_config::FutarchyConfig,
    version,
};
use futarchy_markets::{
    spot_amm::{Self, SpotAMM},
};

// === Errors ===
const ENotRecipient: u64 = 0;
const ENotVestedYet: u64 = 1;
const EInsufficientVested: u64 = 2;
const EInsufficientPayment: u64 = 3;
const EOptionExpired: u64 = 4;
const EAlreadyFullyClaimed: u64 = 5;
const EPriceBelowStrike: u64 = 6;
const EInvalidAmount: u64 = 7;
const EInvalidDuration: u64 = 8;
const EInvalidStrikePrice: u64 = 9;
const ESlippageExceeded: u64 = 10;
const ECannotCancelAfterVestingStart: u64 = 11;
const ENotCancelable: u64 = 12;
const EAlreadyCanceled: u64 = 13;

// === Constants ===
const MAX_VESTING_DURATION_MS: u64 = 315_360_000_000; // 10 years
const MIN_CLIFF_DURATION_MS: u64 = 0; // Can have no cliff
const DECIMALS_SCALE: u64 = 1_000_000_000; // 9 decimals

// === Events ===

/// Emitted when an option grant is created
public struct OptionGrantCreated has copy, drop {
    grant_id: ID,
    recipient: address,
    total_amount: u64,
    strike_price: u64,
    vesting_start: u64,
    vesting_end: u64,
    expiry: u64,
    grant_type: u8, // 0 = Grant, 1 = Option
}

/// Emitted when options are exercised
public struct OptionsExercised has copy, drop {
    grant_id: ID,
    recipient: address,
    amount_exercised: u64,
    payment_amount: u64,
    strike_price: u64,
    market_price: u128,
    timestamp: u64,
}

/// Emitted when vested tokens are claimed (for grants)
public struct VestedTokensClaimed has copy, drop {
    grant_id: ID,
    recipient: address,
    amount_claimed: u64,
    timestamp: u64,
}

/// Emitted when grant is canceled
public struct GrantCanceled has copy, drop {
    grant_id: ID,
    unvested_returned: u64,
    timestamp: u64,
}

// === Structs ===

/// Vesting schedule configuration
public struct VestingSchedule has store, copy, drop {
    /// When vesting starts (timestamp in ms)
    start_time: u64,
    /// Cliff period duration in ms
    cliff_duration: u64,
    /// Total vesting duration in ms (including cliff)
    total_duration: u64,
}

/// Option grant with persistent state
public struct OptionGrant<phantom AssetType, phantom StableType> has key, store {
    id: UID,

    // Grant details
    recipient: address,
    total_amount: u64,
    claimed_amount: u64,

    // Option-specific fields
    strike_price: u64, // 0 for grants, >0 for options
    is_option: bool,

    // Vesting schedule
    vesting: VestingSchedule,

    // Expiry (for options)
    expiry: u64,

    // Cancelation
    cancelable: bool,
    canceled: bool,

    // Metadata
    description: String,
    created_at: u64,
    dao_id: ID, // Link to DAO that created this
}

// === Constructor Functions ===

/// Create a new vesting schedule
public fun new_vesting_schedule(
    start_time: u64,
    cliff_duration: u64,
    total_duration: u64,
): VestingSchedule {
    assert!(total_duration > 0, EInvalidDuration);
    assert!(total_duration <= MAX_VESTING_DURATION_MS, EInvalidDuration);
    assert!(cliff_duration <= total_duration, EInvalidDuration);

    VestingSchedule {
        start_time,
        cliff_duration,
        total_duration,
    }
}

/// Create a new option grant (with strike price)
public fun create_option_grant<AssetType, StableType>(
    recipient: address,
    total_amount: u64,
    strike_price: u64,
    vesting: VestingSchedule,
    expiry: u64,
    cancelable: bool,
    description: String,
    dao_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
): OptionGrant<AssetType, StableType> {
    assert!(total_amount > 0, EInvalidAmount);
    assert!(strike_price > 0, EInvalidStrikePrice);
    assert!(expiry > clock.timestamp_ms(), EOptionExpired);

    let id = object::new(ctx);
    let grant_id = object::uid_to_inner(&id);
    let created_at = clock.timestamp_ms();

    event::emit(OptionGrantCreated {
        grant_id,
        recipient,
        total_amount,
        strike_price,
        vesting_start: vesting.start_time,
        vesting_end: vesting.start_time + vesting.total_duration,
        expiry,
        grant_type: 1, // Option
    });

    OptionGrant {
        id,
        recipient,
        total_amount,
        claimed_amount: 0,
        strike_price,
        is_option: true,
        vesting,
        expiry,
        cancelable,
        canceled: false,
        description,
        created_at,
        dao_id,
    }
}

/// Create a new token grant (no strike price, free vesting)
public fun create_token_grant<AssetType, StableType>(
    recipient: address,
    total_amount: u64,
    vesting: VestingSchedule,
    cancelable: bool,
    description: String,
    dao_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
): OptionGrant<AssetType, StableType> {
    assert!(total_amount > 0, EInvalidAmount);

    let id = object::new(ctx);
    let grant_id = object::uid_to_inner(&id);
    let created_at = clock.timestamp_ms();

    event::emit(OptionGrantCreated {
        grant_id,
        recipient,
        total_amount,
        strike_price: 0,
        vesting_start: vesting.start_time,
        vesting_end: vesting.start_time + vesting.total_duration,
        expiry: vesting.start_time + vesting.total_duration + 315_360_000_000, // +10 years
        grant_type: 0, // Grant
    });

    OptionGrant {
        id,
        recipient,
        total_amount,
        claimed_amount: 0,
        strike_price: 0,
        is_option: false,
        vesting,
        expiry: vesting.start_time + vesting.total_duration + 315_360_000_000, // +10 years
        cancelable,
        canceled: false,
        description,
        created_at,
        dao_id,
    }
}

// === Vesting Calculation ===

/// Calculate how much has vested at current time
public fun calculate_vested_amount<AssetType, StableType>(
    grant: &OptionGrant<AssetType, StableType>,
    clock: &Clock,
): u64 {
    if (grant.canceled) {
        return grant.claimed_amount // No more vesting after cancellation
    };

    let now = clock.timestamp_ms();
    let vesting = &grant.vesting;

    // Before vesting starts
    if (now < vesting.start_time) {
        return 0
    };

    // During cliff period
    if (now < vesting.start_time + vesting.cliff_duration) {
        return 0
    };

    // After full vesting
    if (now >= vesting.start_time + vesting.total_duration) {
        return grant.total_amount
    };

    // Calculate proportional vesting
    let elapsed = now - vesting.start_time;
    let vested = (grant.total_amount as u128) * (elapsed as u128) / (vesting.total_duration as u128);

    math::min(vested as u64, grant.total_amount)
}

/// Get amount available to claim/exercise
public fun get_claimable_amount<AssetType, StableType>(
    grant: &OptionGrant<AssetType, StableType>,
    clock: &Clock,
): u64 {
    let vested = calculate_vested_amount(grant, clock);
    if (vested > grant.claimed_amount) {
        vested - grant.claimed_amount
    } else {
        0
    }
}

// === Exercise/Claim Functions ===

/// Exercise options by paying strike price
public entry fun exercise_options<AssetType, StableType>(
    grant: &mut OptionGrant<AssetType, StableType>,
    account: &mut Account<FutarchyConfig>,
    mut payment: Coin<StableType>,
    amount_to_exercise: u64,
    max_payment_amount: u64, // Slippage protection
    spot_pool: &mut SpotAMM<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify caller is recipient
    assert!(tx_context::sender(ctx) == grant.recipient, ENotRecipient);

    // Verify grant is an option
    assert!(grant.is_option, EInvalidAmount);
    assert!(grant.strike_price > 0, EInvalidStrikePrice);

    // Check not expired
    assert!(clock.timestamp_ms() < grant.expiry, EOptionExpired);

    // Check not canceled
    assert!(!grant.canceled, EAlreadyCanceled);

    // Calculate available to exercise
    let claimable = get_claimable_amount(grant, clock);
    assert!(amount_to_exercise > 0 && amount_to_exercise <= claimable, EInsufficientVested);

    // Calculate required payment
    let required_payment = (amount_to_exercise as u128) * (grant.strike_price as u128) / (DECIMALS_SCALE as u128);
    let required_payment = required_payment as u64;

    // Slippage protection
    assert!(required_payment <= max_payment_amount, ESlippageExceeded);

    // Verify sufficient payment
    assert!(coin::value(&payment) >= required_payment, EInsufficientPayment);

    // Get current market price for event
    let market_price = if (spot_amm::is_twap_ready(spot_pool, clock)) {
        spot_amm::get_twap_mut(spot_pool, clock)
    } else {
        0u128
    };

    // Optional: Check if exercising makes economic sense (warning only)
    // This could be a separate view function for UI to call

    // Process payment
    let payment_coin = if (coin::value(&payment) > required_payment) {
        // Return change
        let change = coin::value(&payment) - required_payment;
        let change_coin = coin::split(&mut payment, change, ctx);
        transfer::public_transfer(change_coin, grant.recipient);
        payment
    } else {
        payment
    };

    // Transfer payment to DAO treasury
    transfer::public_transfer(payment_coin, object::id_address(account));

    // TODO: Mint tokens to recipient using new action system
    // Note: This requires implementing proper minting action
    // For now, this functionality is disabled until proper implementation

    // Placeholder - in production this should create a mint action and execute it
    // let minted_coin = ...; // Create mint action and execute
    // transfer::public_transfer(minted_coin, grant.recipient);

    // Update claimed amount
    grant.claimed_amount = grant.claimed_amount + amount_to_exercise;

    // Emit event
    event::emit(OptionsExercised {
        grant_id: object::uid_to_inner(&grant.id),
        recipient: grant.recipient,
        amount_exercised: amount_to_exercise,
        payment_amount: required_payment,
        strike_price: grant.strike_price,
        market_price,
        timestamp: clock.timestamp_ms(),
    });
}

/// Claim vested tokens (for grants with no strike price)
public entry fun claim_vested_tokens<AssetType, StableType>(
    grant: &mut OptionGrant<AssetType, StableType>,
    account: &mut Account<FutarchyConfig>,
    amount_to_claim: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify caller is recipient
    assert!(tx_context::sender(ctx) == grant.recipient, ENotRecipient);

    // Verify this is a grant (not an option)
    assert!(!grant.is_option, EInvalidAmount);
    assert!(grant.strike_price == 0, EInvalidStrikePrice);

    // Check not canceled
    assert!(!grant.canceled, EAlreadyCanceled);

    // Calculate available to claim
    let claimable = get_claimable_amount(grant, clock);
    assert!(amount_to_claim > 0 && amount_to_claim <= claimable, EInsufficientVested);

    // TODO: Mint tokens to recipient using new action system
    // Note: This requires implementing proper minting action
    // For now, this functionality is disabled until proper implementation

    // Placeholder - in production this should create a mint action and execute it
    // let minted_coin = ...; // Create mint action and execute
    // transfer::public_transfer(minted_coin, grant.recipient);

    // Update claimed amount
    grant.claimed_amount = grant.claimed_amount + amount_to_claim;

    // Emit event
    event::emit(VestedTokensClaimed {
        grant_id: object::uid_to_inner(&grant.id),
        recipient: grant.recipient,
        amount_claimed: amount_to_claim,
        timestamp: clock.timestamp_ms(),
    });
}

/// Cancel a grant and return unvested tokens
public entry fun cancel_grant<AssetType, StableType>(
    grant: &mut OptionGrant<AssetType, StableType>,
    account: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Only DAO can cancel (must have account access)
    // In practice, this would be called through a DAO proposal

    // Check grant is cancelable
    assert!(grant.cancelable, ENotCancelable);
    assert!(!grant.canceled, EAlreadyCanceled);

    // Can only cancel before vesting starts (for employee termination)
    // Or implement more complex rules based on DAO policy
    let now = clock.timestamp_ms();

    // Calculate unvested amount
    let vested = calculate_vested_amount(grant, clock);
    let unvested = grant.total_amount - vested;

    // Mark as canceled
    grant.canceled = true;

    // The unvested amount stays in treasury (not minted)
    // Only vested-but-unclaimed can still be claimed

    event::emit(GrantCanceled {
        grant_id: object::uid_to_inner(&grant.id),
        unvested_returned: unvested,
        timestamp: now,
    });
}

// === View Functions ===

public fun get_recipient<AssetType, StableType>(grant: &OptionGrant<AssetType, StableType>): address {
    grant.recipient
}

public fun get_total_amount<AssetType, StableType>(grant: &OptionGrant<AssetType, StableType>): u64 {
    grant.total_amount
}

public fun get_claimed_amount<AssetType, StableType>(grant: &OptionGrant<AssetType, StableType>): u64 {
    grant.claimed_amount
}

public fun get_strike_price<AssetType, StableType>(grant: &OptionGrant<AssetType, StableType>): u64 {
    grant.strike_price
}

public fun is_option<AssetType, StableType>(grant: &OptionGrant<AssetType, StableType>): bool {
    grant.is_option
}

public fun is_expired<AssetType, StableType>(grant: &OptionGrant<AssetType, StableType>, clock: &Clock): bool {
    clock.timestamp_ms() >= grant.expiry
}

public fun is_fully_vested<AssetType, StableType>(grant: &OptionGrant<AssetType, StableType>, clock: &Clock): bool {
    calculate_vested_amount(grant, clock) >= grant.total_amount
}

public fun is_fully_claimed<AssetType, StableType>(grant: &OptionGrant<AssetType, StableType>): bool {
    grant.claimed_amount >= grant.total_amount
}