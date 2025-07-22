module futarchy::fee;

use std::ascii::String as AsciiString;
use std::option;
use std::type_name;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::dynamic_field;
use sui::event;
use sui::sui::SUI;
use sui::transfer::{public_share_object, public_transfer};

// === Introduction ===
// Manages all fees earnt by the protocol. It is also the interface for admin fee withdrawal

// === Errors ===
const EInvalidPayment: u64 = 0;
const EStableTypeNotFound: u64 = 1;
const EBadWitness: u64 = 2;
const ERecurringFeeNotDue: u64 = 3;
const EWrongStableTypeForFee: u64 = 4;
const EInsufficientTreasuryBalance: u64 = 5;

// === Constants ===
const DEFAULT_DAO_CREATION_FEE: u64 = 10_000;
const DEFAULT_PROPOSAL_CREATION_FEE_PER_OUTCOME: u64 = 1000;
const DEFAULT_VERIFICATION_FEE: u64 = 10_000;
const MONTHLY_FEE_PERIOD_MS: u64 = 2_592_000_000; // 30 days
const FEE_UPDATE_DELAY_MS: u64 = 15_552_000_000; // 6 months (180 days)

// === Structs ===

public struct FEE has drop {}

public struct FeeManager has key, store {
    id: UID,
    dao_creation_fee: u64,
    proposal_creation_fee_per_outcome: u64,
    verification_fee: u64,
    dao_monthly_fee: u64,
    pending_dao_monthly_fee: Option<u64>,
    pending_fee_effective_timestamp: Option<u64>,
    sui_balance: Balance<SUI>,
}

public struct FeeAdminCap has key, store {
    id: UID,
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
    old_fee: u64,
    new_fee: u64,
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

public struct VerificationFeeCollected has copy, drop {
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

// === Public Functions ===
fun init(witness: FEE, ctx: &mut TxContext) {
    // Verify that the witness is valid and one-time only.
    assert!(sui::types::is_one_time_witness(&witness), EBadWitness);

    let fee_manager = FeeManager {
        id: object::new(ctx),
        dao_creation_fee: DEFAULT_DAO_CREATION_FEE,
        proposal_creation_fee_per_outcome: DEFAULT_PROPOSAL_CREATION_FEE_PER_OUTCOME,
        verification_fee: DEFAULT_VERIFICATION_FEE,
        dao_monthly_fee: 10_000_000, // e.g. 10 of a 6-decimal stable coin
        pending_dao_monthly_fee: option::none(),
        pending_fee_effective_timestamp: option::none(),
        sui_balance: balance::zero<SUI>(),
    };

    let fee_admin_cap = FeeAdminCap {
        id: object::new(ctx),
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
public(package) fun deposit_dao_creation_payment(
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

// Function to collect proposal creation fee
public(package) fun deposit_proposal_creation_payment(
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    outcome_count: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    let fee_amount = fee_manager.proposal_creation_fee_per_outcome * outcome_count;

    // deposit_payment asserts the payment amount is exactly the fee_amount
    let payment_amount = deposit_payment(fee_manager, fee_amount, payment);

    // Emit event
    event::emit(ProposalCreationFeeCollected {
        amount: payment_amount,
        payer: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

// Function to collect verification fee
public(package) fun deposit_verification_payment(
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let fee_amount = fee_manager.verification_fee;
    let payment_amount = deposit_payment(fee_manager, fee_amount, payment);

    // Emit event
    event::emit(VerificationFeeCollected {
        amount: payment_amount,
        payer: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

// === Admin Functions ===
// Admin function to withdraw fees
public entry fun withdraw_all_fees(
    fee_manager: &mut FeeManager,
    _admin_cap: &FeeAdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
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
    _admin_cap: &FeeAdminCap,
    new_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
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
    _admin_cap: &FeeAdminCap,
    new_fee_per_outcome: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let old_fee = fee_manager.proposal_creation_fee_per_outcome;
    fee_manager.proposal_creation_fee_per_outcome = new_fee_per_outcome;

    event::emit(ProposalCreationFeeUpdated {
        old_fee,
        new_fee_per_outcome,
        admin: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

// Admin function to update verification fee
public entry fun update_verification_fee(
    fee_manager: &mut FeeManager,
    _admin_cap: &FeeAdminCap,
    new_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let old_fee = fee_manager.verification_fee;
    fee_manager.verification_fee = new_fee;

    event::emit(VerificationFeeUpdated {
        old_fee,
        new_fee,
        admin: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });
}

public(package) fun collect_dao_recurring_fee<StableType: drop>(
    fee_manager: &mut FeeManager,
    treasury: &mut futarchy::treasury::Treasury,
    _admin_cap: &FeeAdminCap,
    dao_id: ID,
    dao_stable_type: &AsciiString,
    next_fee_due_timestamp: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (u64, bool) { // Returns (new_timestamp, collection_successful)
    // 1. Verify fee is due
    assert!(clock.timestamp_ms() >= next_fee_due_timestamp, ERecurringFeeNotDue);

    // 2. Check and apply any pending fee updates
    apply_pending_fee_if_due(fee_manager, clock);

    // 3. Verify StableType matches the DAO's stable type for fee collection
    let stable_type_str = type_name::get<StableType>().into_string();
    assert!(&stable_type_str == dao_stable_type, EWrongStableTypeForFee);

    // 4. Calculate how many months of fees are due
    let current_time = clock.timestamp_ms();
    let months_overdue = ((current_time - next_fee_due_timestamp) / MONTHLY_FEE_PERIOD_MS) + 1;
    let total_fee_amount = fee_manager.dao_monthly_fee * months_overdue;

    // 5. Check if treasury has sufficient balance
    let treasury_balance = futarchy::treasury::coin_type_value<StableType>(treasury);
    if (treasury_balance < total_fee_amount) {
        // Insufficient funds - return failure
        return (next_fee_due_timestamp, false)
    };

    // 6. Withdraw fee from DAO's treasury
    let fee_coin = futarchy::treasury::platform_withdraw<StableType>(treasury, total_fee_amount, clock, ctx);

    // 7. Deposit the collected fee into the FeeManager
    deposit_dao_platform_fee(fee_manager, fee_coin, dao_id, clock, ctx);

    // 8. Return the new next fee due timestamp (advance by number of months collected)
    let new_timestamp = next_fee_due_timestamp + (months_overdue * MONTHLY_FEE_PERIOD_MS);
    (new_timestamp, true)
}

public(package) fun deposit_dao_platform_fee<StableType: drop>(
    fee_manager: &mut FeeManager,
    fee_coin: Coin<StableType>,
    dao_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let amount = fee_coin.value();
    let stable_type_str = type_name::get<StableType>().into_string();
    
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

public entry fun update_dao_monthly_fee(
    fee_manager: &mut FeeManager,
    _admin_cap: &FeeAdminCap,
    new_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
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
public(package) fun deposit_stable_fees<StableType>(
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

    let type_name = type_name::get<StableType>();
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
    _admin_cap: &FeeAdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
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

        let type_name = type_name::get<StableType>();
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

public fun get_verification_fee(fee_manager: &FeeManager): u64 {
    fee_manager.verification_fee
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

// ======== Test Functions ========
#[test_only]
public fun create_fee_manager_for_testing(ctx: &mut TxContext) {
    let fee_manager = FeeManager {
        id: object::new(ctx),
        dao_creation_fee: DEFAULT_DAO_CREATION_FEE,
        proposal_creation_fee_per_outcome: DEFAULT_PROPOSAL_CREATION_FEE_PER_OUTCOME,
        verification_fee: DEFAULT_VERIFICATION_FEE,
        dao_monthly_fee: 10_000_000, // e.g. 10 of a 6-decimal stable coin
        pending_dao_monthly_fee: option::none(),
        pending_fee_effective_timestamp: option::none(),
        sui_balance: balance::zero<SUI>(),
    };

    let admin_cap = FeeAdminCap {
        id: object::new(ctx),
    };

    public_share_object(fee_manager);
    public_transfer(admin_cap, ctx.sender());
}
