module futarchy_markets_core::fee;

use std::ascii::String as AsciiString;
use std::type_name::{Self, TypeName};
use sui::bcs;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::dynamic_field;
use sui::event;
use sui::sui::SUI;
use std::u64;
use sui::table::{Self, Table};
use sui::transfer::{public_share_object, public_transfer};
use futarchy_core::dao_payment_tracker::{Self, DaoPaymentTracker};
use futarchy_core::dao_fee_collector;

// === Introduction ===
// Manages all fees earnt by the protocol. It is also the interface for admin fee withdrawal

// === Errors ===
const EInvalidPayment: u64 = 0;
const EStableTypeNotFound: u64 = 1;
const EBadWitness: u64 = 2;
const ERecurringFeeNotDue: u64 = 3;
const EWrongStableTypeForFee: u64 = 4;
const EInsufficientTreasuryBalance: u64 = 5;
const EArithmeticOverflow: u64 = 6;
const EInvalidAdminCap: u64 = 7;
const EInvalidRecoveryFee: u64 = 9;
const EFeeExceedsHardCap: u64 = 10;
const EWrongStableCoinType: u64 = 11;
const EFeeExceedsTenXCap: u64 = 12;

// === Constants ===
const DEFAULT_DAO_CREATION_FEE: u64 = 10_000;
const DEFAULT_PROPOSAL_CREATION_FEE_PER_OUTCOME: u64 = 1000;
const DEFAULT_VERIFICATION_FEE: u64 = 10_000; // Default fee for level 1
const DEFAULT_LAUNCHPAD_CREATION_FEE: u64 = 10_000_000_000; // 10 SUI to create a launchpad
const MONTHLY_FEE_PERIOD_MS: u64 = 2_592_000_000; // 30 days
const FEE_UPDATE_DELAY_MS: u64 = 15_552_000_000; // 6 months (180 days)
const MAX_FEE_COLLECTION_PERIOD_MS: u64 = 7_776_000_000; // 90 days (3 months) - max retroactive collection
const MAX_FEE_MULTIPLIER: u64 = 10; // Maximum 10x increase from baseline
const FEE_BASELINE_RESET_PERIOD_MS: u64 = 15_552_000_000; // 6 months - baseline resets after this
// Remove ABSOLUTE_MAX_MONTHLY_FEE in V3 this is jsut here to build up trust
// Dont want to limit fee as platform gets more mature
const ABSOLUTE_MAX_MONTHLY_FEE: u64 = 10_000_000_000; // 10,000 USDC (6 decimals)

// === Structs ===

public struct FEE has drop {}

public struct FeeManager has key, store {
    id: UID,
    admin_cap_id: ID,
    dao_creation_fee: u64,
    proposal_creation_fee_per_outcome: u64,
    verification_fees: Table<u8, u64>, // Dynamic table mapping level -> fee
    dao_monthly_fee: u64,
    pending_dao_monthly_fee: Option<u64>,
    pending_fee_effective_timestamp: Option<u64>,
    sui_balance: Balance<SUI>,
    recovery_fee: u64,  // Fee for dead-man switch recovery
    launchpad_creation_fee: u64,  // Fee for creating a launchpad
}

public struct FeeAdminCap has key, store {
    id: UID,
}

/// Stores fee amounts for a specific coin type
public struct CoinFeeConfig has store {
    coin_type: TypeName,
    decimals: u8,
    dao_monthly_fee: u64,
    dao_creation_fee: u64,
    proposal_creation_fee_per_outcome: u64,
    recovery_fee: u64,
    multisig_creation_fee: u64,  // One-time fee when creating a multisig
    multisig_monthly_fee: u64,   // Monthly fee per multisig owned by DAO
    verification_fees: Table<u8, u64>,
    // Pending updates with 6-month delay
    pending_monthly_fee: Option<u64>,
    pending_creation_fee: Option<u64>,
    pending_proposal_fee: Option<u64>,
    pending_recovery_fee: Option<u64>,
    pending_multisig_creation_fee: Option<u64>,
    pending_multisig_monthly_fee: Option<u64>,
    pending_fees_effective_timestamp: Option<u64>,
    // 10x cap tracking - baseline fees that reset every 6 months
    monthly_fee_baseline: u64,
    creation_fee_baseline: u64,
    proposal_fee_baseline: u64,
    recovery_fee_baseline: u64,
    multisig_creation_fee_baseline: u64,
    multisig_monthly_fee_baseline: u64,
    baseline_reset_timestamp: u64,
}

/// Tracks fee collection history for each DAO
public struct DaoFeeRecord has store {
    last_collection_timestamp: u64,
    total_collected: u64,
    last_fee_rate: u64,  // Fee rate at last collection to prevent retroactive increases
}


// === Events ===
public struct FeesWithdrawn has copy, drop {
    amount: u64,
    recipient: address,
    timestamp: u64,
}

public struct DAOCreationFeeUpdated has copy, drop {
    old_fee: u64,
    new_fee: u64,
    admin: address,
    timestamp: u64,
}

public struct ProposalCreationFeeUpdated has copy, drop {
    old_fee: u64,
    new_fee_per_outcome: u64,
    admin: address,
    timestamp: u64,
}

public struct VerificationFeeUpdated has copy, drop {
    level: u8,
    old_fee: u64,
    new_fee: u64,
    admin: address,
    timestamp: u64,
}

public struct VerificationLevelAdded has copy, drop {
    level: u8,
    fee: u64,
    admin: address,
    timestamp: u64,
}

public struct VerificationLevelRemoved has copy, drop {
    level: u8,
    admin: address,
    timestamp: u64,
}

public struct DAOCreationFeeCollected has copy, drop {
    amount: u64,
    payer: address,
    timestamp: u64,
}

public struct ProposalCreationFeeCollected has copy, drop {
    amount: u64,
    payer: address,
    timestamp: u64,
}

public struct LaunchpadCreationFeeCollected has copy, drop {
    amount: u64,
    payer: address,
    timestamp: u64,
}

public struct VerificationFeeCollected has copy, drop {
    level: u8,
    amount: u64,
    payer: address,
    timestamp: u64,
}

public struct StableFeesCollected has copy, drop {
    amount: u64,
    stable_type: AsciiString,
    proposal_id: ID,
    timestamp: u64,
}

public struct StableFeesWithdrawn has copy, drop {
    amount: u64,
    stable_type: AsciiString,
    recipient: address,
    timestamp: u64,
}

public struct DaoMonthlyFeeUpdated has copy, drop {
    old_fee: u64,
    new_fee: u64,
    admin: address,
    timestamp: u64,
}

public struct DaoMonthlyFeePending has copy, drop {
    current_fee: u64,
    pending_fee: u64,
    effective_timestamp: u64,
    admin: address,
    timestamp: u64,
}

public struct DaoPlatformFeeCollected has copy, drop {
    dao_id: ID,
    amount: u64,
    stable_type: AsciiString,
    collector: address,
    timestamp: u64,
}

public struct RecoveryFeeUpdated has copy, drop {
    old_fee: u64,
    new_fee: u64,
    admin: address,
    timestamp: u64,
}

public struct RecoveryRequested has copy, drop {
    dao_id: ID,
    council_id: ID,
    fee: u64,
    requester: address,
    timestamp: u64,
}

public struct RecoveryExecuted has copy, drop {
    dao_id: ID,
    new_council_id: ID,
    timestamp: u64,
}

public struct MultisigCreationFeeCollected has copy, drop {
    dao_id: ID,
    multisig_id: ID,
    amount: u64,
    stable_type: AsciiString,
    payer: address,
    timestamp: u64,
}


// === Public Functions ===
fun init(witness: FEE, ctx: &mut TxContext) {
    // Verify that the witness is valid and one-time only.
    assert!(sui::types::is_one_time_witness(&witness), EBadWitness);

    let fee_admin_cap = FeeAdminCap {
        id: object::new(ctx),
    };
    
    let mut verification_fees = table::new<u8, u64>(ctx);
    // Start with just level 1 by default
    table::add(&mut verification_fees, 1, DEFAULT_VERIFICATION_FEE);
    
    let fee_manager = FeeManager {
        id: object::new(ctx),
        admin_cap_id: object::id(&fee_admin_cap),
        dao_creation_fee: DEFAULT_DAO_CREATION_FEE,
        proposal_creation_fee_per_outcome: DEFAULT_PROPOSAL_CREATION_FEE_PER_OUTCOME,
        verification_fees,
        dao_monthly_fee: 10_000_000, // e.g. 10 of a 6-decimal stable coin
        pending_dao_monthly_fee: option::none(),
        pending_fee_effective_timestamp: option::none(),
        sui_balance: balance::zero<SUI>(),
        recovery_fee: 5_000_000_000, // 5 SUI default (~$5k equivalent)
        launchpad_creation_fee: DEFAULT_LAUNCHPAD_CREATION_FEE,
    };

    public_share_object(fee_manager);
    public_transfer(fee_admin_cap, ctx.sender());

    // Consuming the witness ensures one-time initialization.
    let _ = witness;
}

// === Package Functions ===
// Generic internal fee collection function
fun deposit_payment(fee_manager: &mut FeeManager, fee_amount: u64, payment: Coin<SUI>): u64 {
    // Verify payment
    let payment_amount = payment.value();
    assert!(payment_amount == fee_amount, EInvalidPayment);

    // Process payment
    let paid_balance = payment.into_balance();
    fee_manager.sui_balance.join(paid_balance);
    return payment_amount
    // Event emission will be handled by specific wrappers
}

// Function to collect DAO creation fee
public fun deposit_dao_creation_payment(
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let fee_amount = fee_manager.dao_creation_fee;

    let payment_amount = deposit_payment(fee_manager, fee_amount, payment);

    // Emit event
    event::emit(DAOCreationFeeCollected {
        amount: payment_amount,
        payer: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

// Function to collect launchpad creation fee
public fun deposit_launchpad_creation_payment(
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let fee_amount = fee_manager.launchpad_creation_fee;

    let payment_amount = deposit_payment(fee_manager, fee_amount, payment);

    // Emit event
    event::emit(LaunchpadCreationFeeCollected {
        amount: payment_amount,
        payer: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}


// Function to collect proposal creation fee
public fun deposit_proposal_creation_payment(
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    outcome_count: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    // Use u128 arithmetic to prevent overflow
    let fee_amount_u128 = (fee_manager.proposal_creation_fee_per_outcome as u128) * (outcome_count as u128);
    
    // Check that result fits in u64
    assert!(fee_amount_u128 <= (u64::max_value!() as u128), EArithmeticOverflow); // u64::max_value()
    let fee_amount = (fee_amount_u128 as u64);

    // deposit_payment asserts the payment amount is exactly the fee_amount
    let payment_amount = deposit_payment(fee_manager, fee_amount, payment);

    // Emit event
    event::emit(ProposalCreationFeeCollected {
        amount: payment_amount,
        payer: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}


// Function to collect recovery fee for dead-man switch
public fun deposit_recovery_payment(
    fee_manager: &mut FeeManager,
    dao_id: ID,
    council_id: ID,
    payment: Coin<SUI>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let fee_due = fee_manager.recovery_fee;
    assert!(payment.value() == fee_due, EInvalidPayment);
    let bal = payment.into_balance();
    fee_manager.sui_balance.join(bal);
    event::emit(RecoveryRequested {
        dao_id,
        council_id,
        fee: fee_due,
        requester: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

// Function to collect verification fee for a specific level
public fun deposit_verification_payment(
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    verification_level: u8,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(table::contains(&fee_manager.verification_fees, verification_level), EInvalidPayment);
    let fee_amount = *table::borrow(&fee_manager.verification_fees, verification_level);
    let payment_amount = deposit_payment(fee_manager, fee_amount, payment);

    // Emit event
    event::emit(VerificationFeeCollected {
        level: verification_level,
        amount: payment_amount,
        payer: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

// === Admin Functions ===
// Admin function to withdraw fees
public entry fun withdraw_all_fees(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify the admin cap belongs to this fee manager
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    let amount = fee_manager.sui_balance.value();
    let sender = ctx.sender();

    let withdrawal = fee_manager.sui_balance.split(amount).into_coin(ctx);

    event::emit(FeesWithdrawn {
        amount,
        recipient: sender,
        timestamp: clock.timestamp_ms(),
    });

    public_transfer(withdrawal, sender);
}

// Admin function to update DAO creation fee
public entry fun update_dao_creation_fee(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    new_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    let old_fee = fee_manager.dao_creation_fee;
    fee_manager.dao_creation_fee = new_fee;

    event::emit(DAOCreationFeeUpdated {
        old_fee,
        new_fee,
        admin: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

// Admin function to update proposal creation fee
public entry fun update_proposal_creation_fee(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    new_fee_per_outcome: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    let old_fee = fee_manager.proposal_creation_fee_per_outcome;
    fee_manager.proposal_creation_fee_per_outcome = new_fee_per_outcome;

    event::emit(ProposalCreationFeeUpdated {
        old_fee,
        new_fee_per_outcome,
        admin: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

// Admin function to add a new verification level
public entry fun add_verification_level(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    level: u8,
    fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    assert!(!table::contains(&fee_manager.verification_fees, level), EInvalidPayment);
    
    table::add(&mut fee_manager.verification_fees, level, fee);
    
    event::emit(VerificationLevelAdded {
        level,
        fee,
        admin: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

// Admin function to remove a verification level
public entry fun remove_verification_level(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    level: u8,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    assert!(table::contains(&fee_manager.verification_fees, level), EInvalidPayment);
    
    table::remove(&mut fee_manager.verification_fees, level);
    
    event::emit(VerificationLevelRemoved {
        level,
        admin: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

// Admin function to update verification fee for a specific level
public entry fun update_verification_fee(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    level: u8,
    new_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    assert!(table::contains(&fee_manager.verification_fees, level), EInvalidPayment);
    
    let old_fee = *table::borrow(&fee_manager.verification_fees, level);
    *table::borrow_mut(&mut fee_manager.verification_fees, level) = new_fee;

    event::emit(VerificationFeeUpdated {
        level,
        old_fee,
        new_fee,
        admin: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

// Admin function to update recovery fee
public entry fun update_recovery_fee(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    new_fee: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    let old_fee = fee_manager.recovery_fee;
    fee_manager.recovery_fee = new_fee;
    event::emit(RecoveryFeeUpdated {
        old_fee,
        new_fee,
        admin: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

// View function for recovery fee
public fun get_recovery_fee(fee_manager: &FeeManager): u64 {
    fee_manager.recovery_fee
}

// Function removed to avoid circular dependency with treasury module
// This functionality should be moved to a separate module

/// Collect platform fee from a DAO's vault with 3-month retroactive limit
/// IMPORTANT: Uses the fee rate from when periods were incurred, not current rate
public fun collect_dao_platform_fee<StableType: drop>(
    fee_manager: &mut FeeManager,
    dao_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
): (u64, u64) { // Returns (fee_amount, periods_collected)
    let current_time = clock.timestamp_ms();
    
    // Apply pending fee if due (before we calculate anything)
    apply_pending_fee_if_due(fee_manager, clock);
    
    // Get current fee rate
    let current_fee_rate = fee_manager.dao_monthly_fee;
    
    // Get or create fee record for this DAO
    let record_key = dao_id;
    let (last_collection, last_rate, is_new) = if (dynamic_field::exists_(&fee_manager.id, record_key)) {
        let record: &DaoFeeRecord = dynamic_field::borrow(&fee_manager.id, record_key);
        (record.last_collection_timestamp, record.last_fee_rate, false)
    } else {
        // First time collecting from this DAO - initialize with current rate
        let new_record = DaoFeeRecord {
            last_collection_timestamp: current_time,
            total_collected: 0,
            last_fee_rate: current_fee_rate,
        };
        dynamic_field::add(&mut fee_manager.id, record_key, new_record);
        return (0, 0) // No retroactive fees on first collection
    };
    
    // Calculate how many periods we can collect
    let time_since_last = if (current_time > last_collection) {
        current_time - last_collection
    } else {
        0
    };
    
    // Cap at 3 months max
    let collectible_time = if (time_since_last > MAX_FEE_COLLECTION_PERIOD_MS) {
        MAX_FEE_COLLECTION_PERIOD_MS
    } else {
        time_since_last
    };
    
    // Calculate number of monthly periods to collect
    let periods_to_collect = collectible_time / MONTHLY_FEE_PERIOD_MS;
    
    if (periods_to_collect == 0) {
        return (0, 0)
    };
    
    // CRITICAL: Use the LOWER of last rate or current rate to prevent retroactive increases
    // DAOs benefit from fee decreases immediately but are protected from increases
    let fee_per_period = if (last_rate < current_fee_rate) {
        last_rate  // Protect DAO from retroactive fee increases
    } else {
        current_fee_rate  // Allow DAO to benefit from fee decreases
    };

    // Use u128 arithmetic to prevent overflow
    let total_fee_u128 = (fee_per_period as u128) * (periods_to_collect as u128);
    assert!(total_fee_u128 <= (u64::max_value!() as u128), EArithmeticOverflow);
    let total_fee = (total_fee_u128 as u64);
    
    // Update the record with new timestamp and current rate for future collections
    let record: &mut DaoFeeRecord = dynamic_field::borrow_mut(&mut fee_manager.id, record_key);
    record.last_collection_timestamp = current_time;
    record.total_collected = record.total_collected + total_fee;
    record.last_fee_rate = current_fee_rate;  // Store current rate for next time
    
    (total_fee, periods_to_collect)
}

/// Collect platform fee from DAO vault using DAO's own stablecoin
/// If the DAO doesn't have sufficient funds, debt is accumulated and DAO is blocked
/// If payment succeeds, resets ALL other coin debt for this DAO (forgiveness)
public fun collect_dao_platform_fee_with_dao_coin<StableType>(
    fee_manager: &mut FeeManager,
    payment_tracker: &mut DaoPaymentTracker,
    dao_id: ID,
    coin_type: TypeName,
    all_coin_types: vector<TypeName>,  // All coins to reset on success
    mut available_funds: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<StableType>, u64) { // Returns (remaining_funds, periods_collected)
    // CRITICAL: Verify type safety - ensure StableType matches the coin_type parameter
    assert!(
        type_name::get<StableType>() == coin_type,
        EWrongStableCoinType
    );
    
    // Apply any pending fee updates for this coin type
    apply_pending_coin_fees(fee_manager, coin_type, clock);
    
    // Get fee amount for this specific coin type
    let fee_amount = if (dynamic_field::exists_(&fee_manager.id, coin_type)) {
        let config: &CoinFeeConfig = dynamic_field::borrow(&fee_manager.id, coin_type);
        config.dao_monthly_fee
    } else {
        // Fallback to default fee if coin not configured
        fee_manager.dao_monthly_fee
    };
    
    // Calculate periods to collect
    let current_time = clock.timestamp_ms();
    let record_key = dao_id;
    
    // Get or create fee record
    let periods_to_collect = if (dynamic_field::exists_(&fee_manager.id, record_key)) {
        let record: &DaoFeeRecord = dynamic_field::borrow(&fee_manager.id, record_key);
        let time_since_last = if (current_time > record.last_collection_timestamp) {
            current_time - record.last_collection_timestamp
        } else {
            0
        };
        
        // Cap at 3 months max
        let collectible_time = if (time_since_last > MAX_FEE_COLLECTION_PERIOD_MS) {
            MAX_FEE_COLLECTION_PERIOD_MS
        } else {
            time_since_last
        };
        
        collectible_time / MONTHLY_FEE_PERIOD_MS
    } else {
        // First time - create record but don't collect
        let new_record = DaoFeeRecord {
            last_collection_timestamp: current_time,
            total_collected: 0,
            last_fee_rate: fee_amount,
        };
        dynamic_field::add(&mut fee_manager.id, record_key, new_record);
        0
    };
    
    if (periods_to_collect == 0 || fee_amount == 0) {
        // No fee due, return all funds
        return (available_funds, 0)
    };

    // Use u128 arithmetic to prevent overflow
    let total_fee_u128 = (fee_amount as u128) * (periods_to_collect as u128);
    assert!(total_fee_u128 <= (u64::max_value!() as u128), EArithmeticOverflow);
    let total_fee = (total_fee_u128 as u64);
    
    // Update the record
    let record: &mut DaoFeeRecord = dynamic_field::borrow_mut(&mut fee_manager.id, record_key);
    record.last_collection_timestamp = current_time;
    record.total_collected = record.total_collected + total_fee;
    record.last_fee_rate = fee_amount;
    
    // Check if DAO has enough funds
    let available_amount = available_funds.value();
    if (available_amount >= total_fee) {
        // PAYMENT SUCCESS - Full payment available
        let fee_coin = available_funds.split(total_fee, ctx);

        // Deposit the fee
        deposit_stable_fees(fee_manager, fee_coin.into_balance(), dao_id, clock);

        // CRITICAL: Reset ALL other coin payment timestamps (forgiveness mechanism)
        reset_dao_coin_debts(fee_manager, dao_id, all_coin_types, current_time);

        (available_funds, periods_to_collect)
    } else {
        // Insufficient funds - take what's available and accumulate debt
        let debt_amount = total_fee - available_amount;
        
        // Accumulate debt in the payment tracker
        dao_payment_tracker::accumulate_debt(payment_tracker, dao_id, debt_amount);
        
        // Take all available funds as partial payment
        if (available_amount > 0) {
            deposit_stable_fees(fee_manager, available_funds.into_balance(), dao_id, clock);
            // Return empty coin since all funds were taken
            (coin::zero<StableType>(ctx), periods_to_collect)
        } else {
            // No funds available, destroy the zero coin and return a new zero coin
            available_funds.destroy_zero();
            (coin::zero<StableType>(ctx), periods_to_collect)
        }
    }
}

public fun deposit_dao_platform_fee<StableType: drop>(
    fee_manager: &mut FeeManager,
    fee_coin: Coin<StableType>,
    dao_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let amount = fee_coin.value();
    let stable_type_str = type_name::with_defining_ids<StableType>().into_string();
    
    deposit_stable_fees(fee_manager, fee_coin.into_balance(), dao_id, clock);
    
    // Emit platform fee collection event
    event::emit(DaoPlatformFeeCollected {
        dao_id,
        amount,
        stable_type: stable_type_str,
        collector: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

/// Collect DAO platform fee with admin-approved discount
/// Admin can collect any amount between 0 and the full fee owed
public fun collect_dao_platform_fee_with_discount<StableType: drop>(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    dao_id: ID,
    discount_amount: u64, // Amount to discount from the full fee
    clock: &Clock,
    ctx: &mut TxContext,
): (u64, u64) { // Returns (actual_fee_charged, periods_collected)
    // Verify admin cap
    assert!(fee_manager.admin_cap_id == object::id(admin_cap), EInvalidAdminCap);
    
    // Calculate the full fee owed
    let (full_fee, periods) = collect_dao_platform_fee<StableType>(fee_manager, dao_id, clock, ctx);
    
    // Apply discount (ensure we don't go negative)
    let actual_fee = if (discount_amount >= full_fee) {
        0 // Full discount (free)
    } else {
        full_fee - discount_amount
    };
    
    (actual_fee, periods)
}

public entry fun update_dao_monthly_fee(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    new_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    
    // V2 Hard cap enforcement - prevents excessive fees while protocol matures
    assert!(new_fee <= ABSOLUTE_MAX_MONTHLY_FEE, EFeeExceedsHardCap);
    
    let current_fee = fee_manager.dao_monthly_fee;
    let effective_timestamp = clock.timestamp_ms() + FEE_UPDATE_DELAY_MS;
    
    // Set the pending fee
    fee_manager.pending_dao_monthly_fee = option::some(new_fee);
    fee_manager.pending_fee_effective_timestamp = option::some(effective_timestamp);

    event::emit(DaoMonthlyFeePending {
        current_fee,
        pending_fee: new_fee,
        effective_timestamp,
        admin: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

/// Apply pending fee if the delay period has passed
public fun apply_pending_fee_if_due(
    fee_manager: &mut FeeManager,
    clock: &Clock,
) {
    if (fee_manager.pending_dao_monthly_fee.is_some() && 
        fee_manager.pending_fee_effective_timestamp.is_some()) {
        
        let effective_timestamp = *fee_manager.pending_fee_effective_timestamp.borrow();
        
        if (clock.timestamp_ms() >= effective_timestamp) {
            let old_fee = fee_manager.dao_monthly_fee;
            let new_fee = *fee_manager.pending_dao_monthly_fee.borrow();
            
            // Apply the pending fee
            fee_manager.dao_monthly_fee = new_fee;
            
            // Clear pending fee data
            fee_manager.pending_dao_monthly_fee = option::none();
            fee_manager.pending_fee_effective_timestamp = option::none();
            
            event::emit(DaoMonthlyFeeUpdated {
                old_fee,
                new_fee,
                admin: @0x0, // System update, no specific admin
                timestamp: clock.timestamp_ms(),
            });
        }
    }
}

// === AMM Fees ===

// Structure to store stable coin balance information
public struct StableCoinBalance<phantom T> has store {
    balance: Balance<T>,
}

public struct StableFeeRegistry<phantom T> has copy, drop, store {}

// Modified stable fees storage with more structure
public fun deposit_stable_fees<StableType>(
    fee_manager: &mut FeeManager,
    fees: Balance<StableType>,
    proposal_id: ID,
    clock: &Clock,
) {
    let amount = fees.value();

    if (
        dynamic_field::exists_with_type<
            StableFeeRegistry<StableType>,
            StableCoinBalance<StableType>,
        >(&fee_manager.id, StableFeeRegistry<StableType> {})
    ) {
        let fee_balance_wrapper = dynamic_field::borrow_mut<
            StableFeeRegistry<StableType>,
            StableCoinBalance<StableType>,
        >(&mut fee_manager.id, StableFeeRegistry<StableType> {});
        fee_balance_wrapper.balance.join(fees);
    } else {
        let balance_wrapper = StableCoinBalance<StableType> {
            balance: fees,
        };
        dynamic_field::add(&mut fee_manager.id, StableFeeRegistry<StableType> {}, balance_wrapper);
    };

    let type_name = type_name::with_defining_ids<StableType>();
    let type_str = type_name.into_string();
    // Emit collection event
    event::emit(StableFeesCollected {
        amount,
        stable_type: type_str,
        proposal_id,
        timestamp: clock.timestamp_ms(),
    });
}

public entry fun withdraw_stable_fees<StableType>(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify the admin cap belongs to this fee manager
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    
    // Check if the stable type exists in the registry
    if (!dynamic_field::exists_with_type<
            StableFeeRegistry<StableType>,
            StableCoinBalance<StableType>,
        >(
            &fee_manager.id,
            StableFeeRegistry<StableType> {},
        )
    ) {
        // No fees of this type have been collected, nothing to withdraw
        return
    };

    let fee_balance_wrapper = dynamic_field::borrow_mut<
        StableFeeRegistry<StableType>,
        StableCoinBalance<StableType>,
    >(&mut fee_manager.id, StableFeeRegistry<StableType> {});
    let amount = fee_balance_wrapper.balance.value();

    if (amount > 0) {
        let withdrawn = fee_balance_wrapper.balance.split(amount);
        let coin = withdrawn.into_coin(ctx);

        let type_name = type_name::with_defining_ids<StableType>();
        let type_str = type_name.into_string();
        // Emit withdrawal event
        event::emit(StableFeesWithdrawn {
            amount,
            stable_type: type_str,
            recipient: ctx.sender(),
            timestamp: clock.timestamp_ms(),
        });

        // Transfer to sender
        public_transfer(coin, ctx.sender());
    }
}

// === View Functions ===
public fun get_dao_creation_fee(fee_manager: &FeeManager): u64 {
    fee_manager.dao_creation_fee
}

public fun get_proposal_creation_fee_per_outcome(fee_manager: &FeeManager): u64 {
    fee_manager.proposal_creation_fee_per_outcome
}

public fun get_launchpad_creation_fee(fee_manager: &FeeManager): u64 {
    fee_manager.launchpad_creation_fee
}

public fun get_verification_fee_for_level(fee_manager: &FeeManager, level: u8): u64 {
    assert!(table::contains(&fee_manager.verification_fees, level), EInvalidPayment);
    *table::borrow(&fee_manager.verification_fees, level)
}

public fun has_verification_level(fee_manager: &FeeManager, level: u8): bool {
    table::contains(&fee_manager.verification_fees, level)
}

public fun get_dao_monthly_fee(fee_manager: &FeeManager): u64 {
    fee_manager.dao_monthly_fee
}

public fun get_pending_dao_monthly_fee(fee_manager: &FeeManager): Option<u64> {
    fee_manager.pending_dao_monthly_fee
}

public fun get_pending_fee_effective_timestamp(fee_manager: &FeeManager): Option<u64> {
    fee_manager.pending_fee_effective_timestamp
}

public fun get_sui_balance(fee_manager: &FeeManager): u64 {
    fee_manager.sui_balance.value()
}

public fun get_stable_fee_balance<StableType>(fee_manager: &FeeManager): u64 {
    if (
        dynamic_field::exists_with_type<
            StableFeeRegistry<StableType>,
            StableCoinBalance<StableType>,
        >(&fee_manager.id, StableFeeRegistry<StableType> {})
    ) {
        let balance_wrapper = dynamic_field::borrow<
            StableFeeRegistry<StableType>,
            StableCoinBalance<StableType>,
        >(&fee_manager.id, StableFeeRegistry<StableType> {});
        balance_wrapper.balance.value()
    } else {
        0
    }
}

/// Get the hard cap for monthly fees (V2 safety limit)
public fun get_max_monthly_fee_cap(): u64 {
    ABSOLUTE_MAX_MONTHLY_FEE
}

// === Coin-specific Fee Management ===

/// Add a new coin type with its fee configuration
public fun add_coin_fee_config(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    coin_type: TypeName,
    decimals: u8,
    dao_monthly_fee: u64,
    dao_creation_fee: u64,
    proposal_fee_per_outcome: u64,
    recovery_fee: u64,
    multisig_creation_fee: u64,
    multisig_monthly_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);

    // Create verification fees table
    let mut verification_fees = table::new<u8, u64>(ctx);
    // Add default verification levels
    table::add(&mut verification_fees, 1, DEFAULT_VERIFICATION_FEE);

    let config = CoinFeeConfig {
        coin_type,
        decimals,
        dao_monthly_fee,
        dao_creation_fee,
        proposal_creation_fee_per_outcome: proposal_fee_per_outcome,
        recovery_fee,
        multisig_creation_fee,
        multisig_monthly_fee,
        verification_fees,
        pending_monthly_fee: option::none(),
        pending_creation_fee: option::none(),
        pending_proposal_fee: option::none(),
        pending_recovery_fee: option::none(),
        pending_multisig_creation_fee: option::none(),
        pending_multisig_monthly_fee: option::none(),
        pending_fees_effective_timestamp: option::none(),
        // Initialize baselines to current fees
        monthly_fee_baseline: dao_monthly_fee,
        creation_fee_baseline: dao_creation_fee,
        proposal_fee_baseline: proposal_fee_per_outcome,
        recovery_fee_baseline: recovery_fee,
        multisig_creation_fee_baseline: multisig_creation_fee,
        multisig_monthly_fee_baseline: multisig_monthly_fee,
        baseline_reset_timestamp: clock.timestamp_ms(),
    };

    // Store using coin type as key
    dynamic_field::add(&mut fee_manager.id, coin_type, config);
}

/// Update monthly fee for a specific coin type (with 6-month delay and 10x cap)
public fun update_coin_monthly_fee(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    coin_type: TypeName,
    new_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    assert!(dynamic_field::exists_(&fee_manager.id, coin_type), EStableTypeNotFound);
    
    let config: &mut CoinFeeConfig = dynamic_field::borrow_mut(&mut fee_manager.id, coin_type);
    let current_time = clock.timestamp_ms();
    
    // Check if 6 months have passed since baseline was set - if so, reset baseline
    if (current_time >= config.baseline_reset_timestamp + FEE_BASELINE_RESET_PERIOD_MS) {
        config.monthly_fee_baseline = config.dao_monthly_fee;
        config.baseline_reset_timestamp = current_time;
    };
    
    // Enforce 10x cap from baseline
    assert!(
        new_fee <= config.monthly_fee_baseline * MAX_FEE_MULTIPLIER,
        EFeeExceedsTenXCap
    );
    
    // Allow immediate decrease, delayed increase
    if (new_fee <= config.dao_monthly_fee) {
        // Fee decrease - apply immediately
        config.dao_monthly_fee = new_fee;
    } else {
        // Fee increase - apply after delay
        let effective_timestamp = current_time + FEE_UPDATE_DELAY_MS;
        config.pending_monthly_fee = option::some(new_fee);
        config.pending_fees_effective_timestamp = option::some(effective_timestamp);
    };
}

/// Update creation fee for a specific coin type (with 6-month delay and 10x cap)
public fun update_coin_creation_fee(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    coin_type: TypeName,
    new_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    assert!(dynamic_field::exists_(&fee_manager.id, coin_type), EStableTypeNotFound);
    
    let config: &mut CoinFeeConfig = dynamic_field::borrow_mut(&mut fee_manager.id, coin_type);
    let current_time = clock.timestamp_ms();
    
    // Check if 6 months have passed since baseline was set - if so, reset baseline
    if (current_time >= config.baseline_reset_timestamp + FEE_BASELINE_RESET_PERIOD_MS) {
        config.creation_fee_baseline = config.dao_creation_fee;
        config.baseline_reset_timestamp = current_time;
    };
    
    // Enforce 10x cap from baseline
    assert!(
        new_fee <= config.creation_fee_baseline * MAX_FEE_MULTIPLIER,
        EFeeExceedsTenXCap
    );
    
    // Allow immediate decrease, delayed increase
    if (new_fee <= config.dao_creation_fee) {
        // Fee decrease - apply immediately
        config.dao_creation_fee = new_fee;
    } else {
        // Fee increase - apply after delay
        let effective_timestamp = current_time + FEE_UPDATE_DELAY_MS;
        config.pending_creation_fee = option::some(new_fee);
        config.pending_fees_effective_timestamp = option::some(effective_timestamp);
    };
}

/// Update proposal fee for a specific coin type (with 6-month delay and 10x cap)
public fun update_coin_proposal_fee(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    coin_type: TypeName,
    new_fee_per_outcome: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    assert!(dynamic_field::exists_(&fee_manager.id, coin_type), EStableTypeNotFound);
    
    let config: &mut CoinFeeConfig = dynamic_field::borrow_mut(&mut fee_manager.id, coin_type);
    let current_time = clock.timestamp_ms();
    
    // Check if 6 months have passed since baseline was set - if so, reset baseline
    if (current_time >= config.baseline_reset_timestamp + FEE_BASELINE_RESET_PERIOD_MS) {
        config.proposal_fee_baseline = config.proposal_creation_fee_per_outcome;
        config.baseline_reset_timestamp = current_time;
    };
    
    // Enforce 10x cap from baseline
    assert!(
        new_fee_per_outcome <= config.proposal_fee_baseline * MAX_FEE_MULTIPLIER,
        EFeeExceedsTenXCap
    );
    
    // Allow immediate decrease, delayed increase
    if (new_fee_per_outcome <= config.proposal_creation_fee_per_outcome) {
        // Fee decrease - apply immediately
        config.proposal_creation_fee_per_outcome = new_fee_per_outcome;
    } else {
        // Fee increase - apply after delay
        let effective_timestamp = current_time + FEE_UPDATE_DELAY_MS;
        config.pending_proposal_fee = option::some(new_fee_per_outcome);
        config.pending_fees_effective_timestamp = option::some(effective_timestamp);
    };
}

/// Update recovery fee for a specific coin type (with 6-month delay and 10x cap)
public fun update_coin_recovery_fee(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    coin_type: TypeName,
    new_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    assert!(dynamic_field::exists_(&fee_manager.id, coin_type), EStableTypeNotFound);
    
    let config: &mut CoinFeeConfig = dynamic_field::borrow_mut(&mut fee_manager.id, coin_type);
    let current_time = clock.timestamp_ms();
    
    // Check if 6 months have passed since baseline was set - if so, reset baseline
    if (current_time >= config.baseline_reset_timestamp + FEE_BASELINE_RESET_PERIOD_MS) {
        config.recovery_fee_baseline = config.recovery_fee;
        config.baseline_reset_timestamp = current_time;
    };
    
    // Enforce 10x cap from baseline
    assert!(
        new_fee <= config.recovery_fee_baseline * MAX_FEE_MULTIPLIER,
        EFeeExceedsTenXCap
    );
    
    // Allow immediate decrease, delayed increase
    if (new_fee <= config.recovery_fee) {
        // Fee decrease - apply immediately
        config.recovery_fee = new_fee;
    } else {
        // Fee increase - apply after delay
        let effective_timestamp = current_time + FEE_UPDATE_DELAY_MS;
        config.pending_recovery_fee = option::some(new_fee);
        config.pending_fees_effective_timestamp = option::some(effective_timestamp);
    };
}

/// Apply pending fee updates if the delay has passed
public fun apply_pending_coin_fees(
    fee_manager: &mut FeeManager,
    coin_type: TypeName,
    clock: &Clock,
) {
    if (!dynamic_field::exists_(&fee_manager.id, coin_type)) {
        return
    };

    let config: &mut CoinFeeConfig = dynamic_field::borrow_mut(&mut fee_manager.id, coin_type);

    if (config.pending_fees_effective_timestamp.is_some()) {
        let effective_time = *config.pending_fees_effective_timestamp.borrow();

        if (clock.timestamp_ms() >= effective_time) {
            // Apply all pending fees
            if (config.pending_monthly_fee.is_some()) {
                config.dao_monthly_fee = *config.pending_monthly_fee.borrow();
                config.pending_monthly_fee = option::none();
            };

            if (config.pending_creation_fee.is_some()) {
                config.dao_creation_fee = *config.pending_creation_fee.borrow();
                config.pending_creation_fee = option::none();
            };

            if (config.pending_proposal_fee.is_some()) {
                config.proposal_creation_fee_per_outcome = *config.pending_proposal_fee.borrow();
                config.pending_proposal_fee = option::none();
            };

            if (config.pending_recovery_fee.is_some()) {
                config.recovery_fee = *config.pending_recovery_fee.borrow();
                config.pending_recovery_fee = option::none();
            };

            if (config.pending_multisig_creation_fee.is_some()) {
                config.multisig_creation_fee = *config.pending_multisig_creation_fee.borrow();
                config.pending_multisig_creation_fee = option::none();
            };

            if (config.pending_multisig_monthly_fee.is_some()) {
                config.multisig_monthly_fee = *config.pending_multisig_monthly_fee.borrow();
                config.pending_multisig_monthly_fee = option::none();
            };

            config.pending_fees_effective_timestamp = option::none();
        }
    }
}

/// Get fee config for a specific coin type
public fun get_coin_fee_config(
    fee_manager: &FeeManager,
    coin_type: TypeName,
): &CoinFeeConfig {
    assert!(dynamic_field::exists_(&fee_manager.id, coin_type), EStableTypeNotFound);
    dynamic_field::borrow(&fee_manager.id, coin_type)
}

/// Get monthly fee for a specific coin type
public fun get_coin_monthly_fee(
    fee_manager: &FeeManager,
    coin_type: TypeName,
): u64 {
    get_coin_fee_config(fee_manager, coin_type).dao_monthly_fee
}

// === Multisig Fee Management ===

/// Update multisig creation fee for a specific coin type (with 6-month delay and 10x cap)
public fun update_coin_multisig_creation_fee(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    coin_type: TypeName,
    new_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    assert!(dynamic_field::exists_(&fee_manager.id, coin_type), EStableTypeNotFound);

    let config: &mut CoinFeeConfig = dynamic_field::borrow_mut(&mut fee_manager.id, coin_type);
    let current_time = clock.timestamp_ms();

    // Check if 6 months have passed since baseline was set - if so, reset baseline
    if (current_time >= config.baseline_reset_timestamp + FEE_BASELINE_RESET_PERIOD_MS) {
        config.multisig_creation_fee_baseline = config.multisig_creation_fee;
        config.baseline_reset_timestamp = current_time;
    };

    // Enforce 10x cap from baseline
    assert!(
        new_fee <= config.multisig_creation_fee_baseline * MAX_FEE_MULTIPLIER,
        EFeeExceedsTenXCap
    );

    // Allow immediate decrease, delayed increase
    if (new_fee <= config.multisig_creation_fee) {
        // Fee decrease - apply immediately
        config.multisig_creation_fee = new_fee;
    } else {
        // Fee increase - apply after delay
        let effective_timestamp = current_time + FEE_UPDATE_DELAY_MS;
        config.pending_multisig_creation_fee = option::some(new_fee);
        config.pending_fees_effective_timestamp = option::some(effective_timestamp);
    };
}

/// Update multisig monthly fee for a specific coin type (with 6-month delay and 10x cap)
public fun update_coin_multisig_monthly_fee(
    fee_manager: &mut FeeManager,
    admin_cap: &FeeAdminCap,
    coin_type: TypeName,
    new_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(admin_cap) == fee_manager.admin_cap_id, EInvalidAdminCap);
    assert!(dynamic_field::exists_(&fee_manager.id, coin_type), EStableTypeNotFound);

    let config: &mut CoinFeeConfig = dynamic_field::borrow_mut(&mut fee_manager.id, coin_type);
    let current_time = clock.timestamp_ms();

    // Check if 6 months have passed since baseline was set - if so, reset baseline
    if (current_time >= config.baseline_reset_timestamp + FEE_BASELINE_RESET_PERIOD_MS) {
        config.multisig_monthly_fee_baseline = config.multisig_monthly_fee;
        config.baseline_reset_timestamp = current_time;
    };

    // Enforce 10x cap from baseline
    assert!(
        new_fee <= config.multisig_monthly_fee_baseline * MAX_FEE_MULTIPLIER,
        EFeeExceedsTenXCap
    );

    // Allow immediate decrease, delayed increase
    if (new_fee <= config.multisig_monthly_fee) {
        // Fee decrease - apply immediately
        config.multisig_monthly_fee = new_fee;
    } else {
        // Fee increase - apply after delay
        let effective_timestamp = current_time + FEE_UPDATE_DELAY_MS;
        config.pending_multisig_monthly_fee = option::some(new_fee);
        config.pending_fees_effective_timestamp = option::some(effective_timestamp);
    };
}

/// Get multisig creation fee for a specific coin type
public fun get_coin_multisig_creation_fee(
    fee_manager: &FeeManager,
    coin_type: TypeName,
): u64 {
    get_coin_fee_config(fee_manager, coin_type).multisig_creation_fee
}

/// Get multisig monthly fee for a specific coin type
public fun get_coin_multisig_monthly_fee(
    fee_manager: &FeeManager,
    coin_type: TypeName,
): u64 {
    get_coin_fee_config(fee_manager, coin_type).multisig_monthly_fee
}

// === Multisig Fee Collection ===

/// Collect one-time multisig creation fee
public fun collect_multisig_creation_fee<StableType>(
    fee_manager: &mut FeeManager,
    dao_id: ID,
    multisig_id: ID,
    coin_type: TypeName,
    mut payment: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableType> {
    // CRITICAL: Verify type safety
    assert!(
        type_name::get<StableType>() == coin_type,
        EWrongStableCoinType
    );

    // Apply any pending fee updates
    apply_pending_coin_fees(fee_manager, coin_type, clock);

    // Get fee amount for this coin type
    let fee_amount = if (dynamic_field::exists_(&fee_manager.id, coin_type)) {
        let config: &CoinFeeConfig = dynamic_field::borrow(&fee_manager.id, coin_type);
        config.multisig_creation_fee
    } else {
        // Fallback to 0 if coin not configured (no fee)
        0
    };

    if (fee_amount == 0) {
        return payment
    };

    // Check payment amount
    let payment_amount = payment.value();
    assert!(payment_amount >= fee_amount, EInvalidPayment);

    // Split fee from payment
    let fee_coin = payment.split(fee_amount, ctx);

    // Deposit fee
    deposit_stable_fees(fee_manager, fee_coin.into_balance(), dao_id, clock);

    // Emit event
    let stable_type_str = type_name::with_defining_ids<StableType>().into_string();
    event::emit(MultisigCreationFeeCollected {
        dao_id,
        multisig_id,
        amount: fee_amount,
        stable_type: stable_type_str,
        payer: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });

    // Return remaining payment
    payment
}

/// Reset payment timestamps for all coin types for a DAO
/// Called when ANY fee is successfully paid (forgiveness mechanism)
fun reset_dao_coin_debts(
    fee_manager: &mut FeeManager,
    dao_id: ID,
    coin_types: vector<TypeName>,
    current_time: u64,
) {
    let mut i = 0;
    while (i < coin_types.length()) {
        let coin_type = *coin_types.borrow(i);

        // DAO records are keyed directly by dao_id (single record per DAO)
        // But we need per-coin-type tracking, so we need composite keys too
        // For now, just reset the main DaoFeeRecord timestamp
        // TODO: Implement per-coin-type DAO records like multisigs
        if (dynamic_field::exists_(&fee_manager.id, dao_id)) {
            let record: &mut DaoFeeRecord = dynamic_field::borrow_mut(&mut fee_manager.id, dao_id);
            record.last_collection_timestamp = current_time;
        };

        i = i + 1;
    };
}

// === Multisig Fee Collection (Same Pattern as DAOs) ===

/// Multisig fee record - tracks per-coin-type payments
/// Key: (multisig_id, coin_type) as composite
public struct MultisigFeeRecord has store {
    multisig_id: ID,
    coin_type: TypeName,
    last_payment_timestamp: u64,
    total_paid: u64,
}

/// Collect monthly fee from a multisig for a specific coin type
/// If payment succeeds, resets ALL other coin debt for this multisig (forgiveness)
/// Returns (remaining_funds, periods_collected)
public fun collect_multisig_fee<StableType>(
    fee_manager: &mut FeeManager,
    multisig_id: ID,
    coin_type: TypeName,
    mut available_funds: Coin<StableType>,
    all_coin_types: vector<TypeName>,  // All coins to reset on success
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<StableType>, u64) {
    // CRITICAL: Verify type safety
    assert!(
        type_name::get<StableType>() == coin_type,
        EWrongStableCoinType
    );

    // Apply any pending fee updates
    apply_pending_coin_fees(fee_manager, coin_type, clock);

    // Get monthly fee for this coin type
    let monthly_fee = if (dynamic_field::exists_(&fee_manager.id, coin_type)) {
        let config: &CoinFeeConfig = dynamic_field::borrow(&fee_manager.id, coin_type);
        config.multisig_monthly_fee
    } else {
        0 // No fee if coin not configured
    };

    if (monthly_fee == 0) {
        return (available_funds, 0)
    };

    let current_time = clock.timestamp_ms();

    // Create composite key: multisig_id + coin_type
    let mut record_key_bytes = b"multisig_";
    let id_bytes = object::id_to_bytes(&multisig_id);
    vector::append(&mut record_key_bytes, id_bytes);
    let coin_type_bytes = bcs::to_bytes(&coin_type);
    vector::append(&mut record_key_bytes, coin_type_bytes);

    // Get or create fee record for this multisig + coin type
    let periods_to_collect = if (dynamic_field::exists_with_type<vector<u8>, MultisigFeeRecord>(&fee_manager.id, record_key_bytes)) {
        let record: &MultisigFeeRecord = dynamic_field::borrow(&fee_manager.id, record_key_bytes);
        let time_since_last = if (current_time > record.last_payment_timestamp) {
            current_time - record.last_payment_timestamp
        } else {
            0
        };

        // Cap at 3 months max
        let collectible_time = if (time_since_last > MAX_FEE_COLLECTION_PERIOD_MS) {
            MAX_FEE_COLLECTION_PERIOD_MS
        } else {
            time_since_last
        };

        collectible_time / MONTHLY_FEE_PERIOD_MS
    } else {
        // First time - create record but don't collect
        let new_record = MultisigFeeRecord {
            multisig_id,
            coin_type,
            last_payment_timestamp: current_time,
            total_paid: 0,
        };
        dynamic_field::add(&mut fee_manager.id, record_key_bytes, new_record);
        0
    };

    if (periods_to_collect == 0) {
        return (available_funds, 0)
    };

    // Use u128 arithmetic to prevent overflow
    let total_fee_u128 = (monthly_fee as u128) * (periods_to_collect as u128);
    assert!(total_fee_u128 <= (u64::max_value!() as u128), EArithmeticOverflow);
    let total_fee = (total_fee_u128 as u64);
    let available_amount = available_funds.value();

    if (available_amount >= total_fee) {
        // PAYMENT SUCCESS - Full payment available
        let fee_coin = available_funds.split(total_fee, ctx);

        // Deposit the fee
        deposit_stable_fees(fee_manager, fee_coin.into_balance(), multisig_id, clock);

        // Update this coin's record
        let record: &mut MultisigFeeRecord = dynamic_field::borrow_mut(&mut fee_manager.id, record_key_bytes);
        record.last_payment_timestamp = current_time;
        record.total_paid = record.total_paid + total_fee;

        // CRITICAL: Reset ALL other coin payment timestamps (forgiveness mechanism)
        reset_multisig_coin_debts(fee_manager, multisig_id, all_coin_types, current_time);

        // Emit success event
        let stable_type_str = type_name::with_defining_ids<StableType>().into_string();
        event::emit(DaoPlatformFeeCollected {  // Reuse DAO event for now
            dao_id: multisig_id,
            amount: total_fee,
            stable_type: stable_type_str,
            collector: ctx.sender(),
            timestamp: current_time,
        });

        (available_funds, periods_to_collect)
    } else {
        // PAYMENT FAILED - Insufficient funds, don't take anything
        // Multisig will be paused if ALL required coins fail
        (available_funds, 0)
    }
}

/// Reset payment timestamps for all coin types for a multisig
/// Called when ANY fee is successfully paid (forgiveness mechanism)
fun reset_multisig_coin_debts(
    fee_manager: &mut FeeManager,
    multisig_id: ID,
    coin_types: vector<TypeName>,
    current_time: u64,
) {
    let mut i = 0;
    while (i < coin_types.length()) {
        let coin_type = *coin_types.borrow(i);

        // Create composite key
        let mut record_key_bytes = b"multisig_";
        let id_bytes = object::id_to_bytes(&multisig_id);
        vector::append(&mut record_key_bytes, id_bytes);
        let coin_type_bytes = bcs::to_bytes(&coin_type);
        vector::append(&mut record_key_bytes, coin_type_bytes);

        // Reset timestamp if record exists
        if (dynamic_field::exists_with_type<vector<u8>, MultisigFeeRecord>(&fee_manager.id, record_key_bytes)) {
            let record: &mut MultisigFeeRecord = dynamic_field::borrow_mut(&mut fee_manager.id, record_key_bytes);
            record.last_payment_timestamp = current_time;
        };

        i = i + 1;
    };
}

/// Check if a multisig should be paused
/// ONLY pauses if ALL required coin types are overdue
public fun is_multisig_paused(
    fee_manager: &FeeManager,
    multisig_id: ID,
    required_coin_types: vector<TypeName>,
    clock: &Clock,
): bool {
    let current_time = clock.timestamp_ms();
    let mut all_overdue = true;

    let mut i = 0;
    while (i < required_coin_types.length()) {
        let coin_type = *required_coin_types.borrow(i);

        // Get monthly fee for this coin type
        let monthly_fee = if (dynamic_field::exists_(&fee_manager.id, coin_type)) {
            let config: &CoinFeeConfig = dynamic_field::borrow(&fee_manager.id, coin_type);
            config.multisig_monthly_fee
        } else {
            0
        };

        if (monthly_fee == 0) {
            // No fee required = not overdue
            all_overdue = false;
        } else {
            // Create composite key
            let mut record_key_bytes = b"multisig_";
            let id_bytes = object::id_to_bytes(&multisig_id);
            vector::append(&mut record_key_bytes, id_bytes);
            let coin_type_bytes = bcs::to_bytes(&coin_type);
            vector::append(&mut record_key_bytes, coin_type_bytes);

            if (!dynamic_field::exists_with_type<vector<u8>, MultisigFeeRecord>(&fee_manager.id, record_key_bytes)) {
                // No record = newly created = not overdue
                all_overdue = false;
            } else {
                let record: &MultisigFeeRecord = dynamic_field::borrow(&fee_manager.id, record_key_bytes);
                let time_since_last = if (current_time > record.last_payment_timestamp) {
                    current_time - record.last_payment_timestamp
                } else {
                    0
                };

                if (time_since_last < MONTHLY_FEE_PERIOD_MS) {
                    // This coin is current = not all overdue
                    all_overdue = false;
                };
            };
        };

        i = i + 1;
    };

    all_overdue
}

// ======== Test Functions ========
#[test_only]
public fun create_fee_manager_for_testing(ctx: &mut TxContext) {
    let admin_cap = FeeAdminCap {
        id: object::new(ctx),
    };
    
    let mut verification_fees = table::new<u8, u64>(ctx);
    // Start with just level 1 by default
    table::add(&mut verification_fees, 1, DEFAULT_VERIFICATION_FEE);
    
    let fee_manager = FeeManager {
        id: object::new(ctx),
        admin_cap_id: object::id(&admin_cap),
        dao_creation_fee: DEFAULT_DAO_CREATION_FEE,
        proposal_creation_fee_per_outcome: DEFAULT_PROPOSAL_CREATION_FEE_PER_OUTCOME,
        verification_fees,
        dao_monthly_fee: 10_000_000, // e.g. 10 of a 6-decimal stable coin
        pending_dao_monthly_fee: option::none(),
        pending_fee_effective_timestamp: option::none(),
        sui_balance: balance::zero<SUI>(),
        recovery_fee: 5_000_000_000, // 5 SUI default
        launchpad_creation_fee: DEFAULT_LAUNCHPAD_CREATION_FEE,
    };

    public_share_object(fee_manager);
    public_transfer(admin_cap, ctx.sender());
}
