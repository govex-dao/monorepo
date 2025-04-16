module futarchy::fee;

use std::ascii::String as AsciiString;
use std::type_name;
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::dynamic_field;
use sui::event;
use sui::sui::SUI;
use sui::transfer::{public_share_object, public_transfer};

// === Introduction ===
// Manages all fees earnt by the protocol. It is also the interface for admin fee withdrawal

// === Errors ===
const EINVALID_PAYMENT: u64 = 0;
const ESTABLE_TYPE_NOT_FOUND: u64 = 1;
const EBAD_WITNESS: u64 = 2;

// === Constants ===
const DEFAULT_DAO_CREATION_FEE: u64 = 10_000;
const DEFAULT_PROPOSAL_CREATION_FEE: u64 = 10_000;
const DEFAULT_VERIFICATION_FEE: u64 = 10_000;

// === Structs ===

public struct FEE has drop {}

public struct FeeManager has key, store {
    id: UID,
    dao_creation_fee: u64,
    proposal_creation_fee: u64,
    verification_fee: u64,
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
    new_fee: u64,
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

// === Public Functions ===
fun init(witness: FEE, ctx: &mut TxContext) {
    // Verify that the witness is valid and one-time only.
    assert!(sui::types::is_one_time_witness(&witness), EBAD_WITNESS);

    let fee_manager = FeeManager {
        id: object::new(ctx),
        dao_creation_fee: DEFAULT_DAO_CREATION_FEE,
        proposal_creation_fee: DEFAULT_PROPOSAL_CREATION_FEE,
        verification_fee: DEFAULT_VERIFICATION_FEE,
        sui_balance: balance::zero<SUI>(),
    };

    let fee_admin_cap = FeeAdminCap {
        id: object::new(ctx),
    };

    public_share_object(fee_manager);
    public_transfer(fee_admin_cap, tx_context::sender(ctx));

    // Consuming the witness ensures one-time initialization.
    let _ = witness;
}

// === Fee Collection Functions ===
// Generic internal fee collection function
fun deposit_payment(fee_manager: &mut FeeManager, fee_amount: u64, payment: Coin<SUI>): u64 {
    // Verify payment
    let payment_amount = coin::value(&payment);
    assert!(payment_amount == fee_amount, EINVALID_PAYMENT);

    // Process payment
    let paid_balance = coin::into_balance(payment);
    balance::join(&mut fee_manager.sui_balance, paid_balance);
    return payment_amount
    // Event emission will be handled by specific wrappers
}

// Function to collect DAO creation fee
public(package) fun deposit_dao_creation_payment(
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let fee_amount = fee_manager.dao_creation_fee;

    let payment_amount = deposit_payment(fee_manager, fee_amount, payment);

    // Emit event
    event::emit(DAOCreationFeeCollected {
        amount: payment_amount,
        payer: tx_context::sender(ctx),
        timestamp: clock::timestamp_ms(clock),
    });
}

// Function to collect proposal creation fee
public(package) fun deposit_proposal_creation_payment(
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let fee_amount = fee_manager.proposal_creation_fee;

    let payment_amount = deposit_payment(fee_manager, fee_amount, payment);

    // Emit event
    event::emit(ProposalCreationFeeCollected {
        amount: payment_amount,
        payer: tx_context::sender(ctx),
        timestamp: clock::timestamp_ms(clock),
    });
}

// Function to collect verification fee
public(package) fun deposit_verification_payment(
    fee_manager: &mut FeeManager,
    payment: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let fee_amount = fee_manager.verification_fee;
    let payment_amount = deposit_payment(fee_manager, fee_amount, payment);

    // Emit event
    event::emit(VerificationFeeCollected {
        amount: payment_amount,
        payer: tx_context::sender(ctx),
        timestamp: clock::timestamp_ms(clock),
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
    let amount = balance::value(&fee_manager.sui_balance);
    let sender = tx_context::sender(ctx);

    let withdrawal = coin::from_balance(
        balance::split(&mut fee_manager.sui_balance, amount),
        ctx,
    );

    event::emit(FeesWithdrawn {
        amount,
        recipient: sender,
        timestamp: clock::timestamp_ms(clock),
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
        admin: tx_context::sender(ctx),
        timestamp: clock::timestamp_ms(clock),
    });
}

// Admin function to update proposal creation fee
public entry fun update_proposal_creation_fee(
    fee_manager: &mut FeeManager,
    _admin_cap: &FeeAdminCap,
    new_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let old_fee = fee_manager.proposal_creation_fee;
    fee_manager.proposal_creation_fee = new_fee;

    event::emit(ProposalCreationFeeUpdated {
        old_fee,
        new_fee,
        admin: tx_context::sender(ctx),
        timestamp: clock::timestamp_ms(clock),
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
        admin: tx_context::sender(ctx),
        timestamp: clock::timestamp_ms(clock),
    });
}

// ========== AMM Fees ============

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
    let amount = balance::value(&fees);

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
        balance::join(&mut fee_balance_wrapper.balance, fees);
    } else {
        let balance_wrapper = StableCoinBalance<StableType> {
            balance: fees,
        };
        dynamic_field::add(&mut fee_manager.id, StableFeeRegistry<StableType> {}, balance_wrapper);
    };

    let type_name = type_name::get<StableType>();
    let type_str = type_name::into_string(type_name);
    // Emit collection event
    event::emit(StableFeesCollected {
        amount,
        stable_type: type_str,
        proposal_id,
        timestamp: clock::timestamp_ms(clock),
    });
}

public entry fun withdraw_stable_fees<StableType>(
    fee_manager: &mut FeeManager,
    _admin_cap: &FeeAdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(
        dynamic_field::exists_with_type<
            StableFeeRegistry<StableType>,
            StableCoinBalance<StableType>,
        >(
            &fee_manager.id,
            StableFeeRegistry<StableType> {},
        ),
        ESTABLE_TYPE_NOT_FOUND,
    );

    let fee_balance_wrapper = dynamic_field::borrow_mut<
        StableFeeRegistry<StableType>,
        StableCoinBalance<StableType>,
    >(&mut fee_manager.id, StableFeeRegistry<StableType> {});
    let amount = balance::value(&fee_balance_wrapper.balance);

    if (amount > 0) {
        let withdrawn = balance::split(&mut fee_balance_wrapper.balance, amount);
        let coin = coin::from_balance(withdrawn, ctx);

        let type_name = type_name::get<StableType>();
        let type_str = type_name::into_string(type_name);
        // Emit withdrawal event
        event::emit(StableFeesWithdrawn {
            amount,
            stable_type: type_str,
            recipient: tx_context::sender(ctx),
            timestamp: clock::timestamp_ms(clock),
        });

        // Transfer to sender
        transfer::public_transfer(coin, tx_context::sender(ctx));
    }
}

// === View Functions ===
public fun get_dao_creation_fee(fee_manager: &FeeManager): u64 {
    fee_manager.dao_creation_fee
}

public fun get_proposal_creation_fee(fee_manager: &FeeManager): u64 {
    fee_manager.proposal_creation_fee
}

public fun get_verification_fee(fee_manager: &FeeManager): u64 {
    fee_manager.verification_fee
}

public fun get_sui_balance(fee_manager: &FeeManager): u64 {
    balance::value(&fee_manager.sui_balance)
}

public(package) fun get_stable_fee_balance<StableType>(fee_manager: &FeeManager): u64 {
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
        balance::value(&balance_wrapper.balance)
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
        proposal_creation_fee: DEFAULT_PROPOSAL_CREATION_FEE,
        verification_fee: DEFAULT_VERIFICATION_FEE,
        sui_balance: balance::zero<SUI>(),
    };

    let admin_cap = FeeAdminCap {
        id: object::new(ctx),
    };

    public_share_object(fee_manager);
    public_transfer(admin_cap, tx_context::sender(ctx));
}
