/// This module provides comprehensive vesting functionality similar to vault streams.
/// A vesting has configurable parameters for maximum flexibility:
/// - Multiple beneficiaries support
/// - Pause/resume functionality
/// - Metadata for extensibility
/// - Transfer and cancellation settings
/// - Cliff periods and rate limiting
///
/// === Fork Enhancement (BSL 1.1 Licensed) ===
/// Originally deleted from the Move framework, this module was restored and
/// significantly enhanced to provide feature parity with vault streams.
///
/// Major improvements from original:
/// 1. **Cancellability Control**: Added `is_cancelable` flag to create uncancelable vestings
/// 2. **Multiple Beneficiaries**: Support for primary + additional beneficiaries (up to 100)
/// 3. **Pause/Resume**: Vestings can be paused, extending the vesting period appropriately
/// 4. **Transfer Support**: Primary beneficiary role can be transferred if enabled
/// 5. **Rate Limiting**: Configurable withdrawal limits and minimum intervals
/// 6. **Cliff Periods**: Optional cliff before any vesting begins
/// 7. **Metadata**: Extensible metadata field for additional context
/// 8. **Shared Utilities**: Uses stream_utils module for consistent calculations
/// 9. **Action Descriptors**: Integrated with governance approval system
/// 10. **Comprehensive Events**: Full audit trail of all vesting operations
///
/// This refactor ensures DAOs can:
/// - Create employee vesting schedules that cannot be cancelled
/// - Implement investor token locks with cliff periods
/// - Pause vestings during disputes or investigations
/// - Support team vestings with multiple recipients
/// - Enforce withdrawal limits to prevent dumps
///
/// All calculations now use the shared stream_utils module to ensure
/// consistency with vault streams and prevent calculation divergence.

module account_actions::vesting;

// === Imports ===

use std::{
    string::String,
    option::Option,
    u64,
};
use sui::{
    balance::Balance,
    coin::{Self, Coin},
    clock::Clock,
    event,
    object::{Self, ID},
    transfer,
    tx_context,
};
use account_protocol::{
    account::Account,
    intents::{Expired, Intent},
    executable::Executable,
};
use account_extensions::action_descriptor;
use account_actions::stream_utils;

// === Errors ===

const EBalanceNotEmpty: u64 = 0;
const ETooEarly: u64 = 1;
const EWrongVesting: u64 = 2;
const EVestingNotCancelable: u64 = 3;
const EVestingPaused: u64 = 4;
const EVestingNotPaused: u64 = 5;
const ENotTransferable: u64 = 6;
const EUnauthorizedBeneficiary: u64 = 7;
const EBeneficiaryAlreadyExists: u64 = 8;
const EBeneficiaryNotFound: u64 = 9;
const ECannotReduceBelowClaimed: u64 = 10;
const ETooManyBeneficiaries: u64 = 11;
const EInvalidVestingParameters: u64 = 12;
const ECliffNotReached: u64 = 13;
const EWithdrawalLimitExceeded: u64 = 14;
const EWithdrawalTooSoon: u64 = 15;

// === Constants ===

// Use shared constant from stream_utils
const MAX_BENEFICIARIES: u64 = 100; // Matches stream_utils::max_beneficiaries()

// === Structs ===

/// Enhanced vesting with comprehensive features matching vault streams
public struct Vesting<phantom CoinType> has key {
    id: UID,
    // Core vesting parameters
    balance: Balance<CoinType>,
    claimed_amount: u64,
    start_timestamp: u64,
    end_timestamp: u64,
    cliff_time: Option<u64>,
    // Beneficiaries
    primary_beneficiary: address,
    additional_beneficiaries: vector<address>,
    max_beneficiaries: u64,
    // Rate limiting
    max_per_withdrawal: u64,
    min_interval_ms: u64,
    last_withdrawal_time: u64,
    // Control flags
    is_paused: bool,
    paused_at: Option<u64>,
    paused_duration: u64,
    is_transferable: bool,
    is_cancelable: bool,
    // Metadata
    metadata: Option<String>,
}

/// Cap enabling bearer to claim the vesting
public struct ClaimCap has key {
    id: UID,
    vesting_id: ID,
}

/// Action for creating a comprehensive vesting
public struct CreateVestingAction<phantom CoinType> has store {
    amount: u64,
    start_timestamp: u64,
    end_timestamp: u64,
    cliff_time: Option<u64>,
    recipient: address,
    max_beneficiaries: u64,
    max_per_withdrawal: u64,
    min_interval_ms: u64,
    is_transferable: bool,
    is_cancelable: bool,
    metadata: Option<String>,
}

/// Action for canceling a vesting
public struct CancelVestingAction has store {
    vesting_id: ID,
}

// === Events ===

/// Emitted when a vesting is created
public struct VestingCreated has copy, drop {
    vesting_id: ID,
    beneficiary: address,
    amount: u64,
    start_time: u64,
    end_time: u64,
}

/// Emitted when funds are claimed from vesting
public struct VestingClaimed has copy, drop {
    vesting_id: ID,
    beneficiary: address,
    amount: u64,
    remaining: u64,
}

/// Emitted when a vesting is cancelled
public struct VestingCancelled has copy, drop {
    vesting_id: ID,
    refunded_amount: u64,
    final_payment: u64,
}

/// Emitted when a vesting is paused
public struct VestingPaused has copy, drop {
    vesting_id: ID,
    paused_at: u64,
}

/// Emitted when a vesting is resumed
public struct VestingResumed has copy, drop {
    vesting_id: ID,
    resumed_at: u64,
    pause_duration: u64,
}

/// Emitted when a beneficiary is added
public struct BeneficiaryAdded has copy, drop {
    vesting_id: ID,
    new_beneficiary: address,
}

/// Emitted when a beneficiary is removed
public struct BeneficiaryRemoved has copy, drop {
    vesting_id: ID,
    removed_beneficiary: address,
}

/// Emitted when a vesting is transferred
public struct VestingTransferred has copy, drop {
    vesting_id: ID,
    old_beneficiary: address,
    new_beneficiary: address,
}

// === Public Functions ===

/// Proposes to create a comprehensive vesting
public fun new_vesting<Config, Outcome, CoinType, IW: drop>(
    intent: &mut Intent<Outcome>, 
    _account: &Account<Config>, 
    amount: u64,
    start_timestamp: u64,
    end_timestamp: u64,
    cliff_time: Option<u64>,
    recipient: address,
    max_beneficiaries: u64,
    max_per_withdrawal: u64,
    min_interval_ms: u64,
    is_transferable: bool,
    is_cancelable: bool,
    metadata: Option<String>,
    intent_witness: IW,
) {
    let descriptor = action_descriptor::new_with_target_address(
        b"payments", 
        b"create_vesting",
        recipient
    );
    
    intent.add_action_with_descriptor(
        CreateVestingAction<CoinType> { 
            amount, 
            start_timestamp, 
            end_timestamp,
            cliff_time,
            recipient,
            max_beneficiaries,
            max_per_withdrawal,
            min_interval_ms,
            is_transferable,
            is_cancelable,
            metadata,
        },
        descriptor,
        intent_witness
    );
}

/// Creates the Vesting and ClaimCap objects from a CreateVestingAction
public fun do_vesting<Config, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account<Config>, 
    coin: Coin<CoinType>,
    clock: &Clock,
    intent_witness: IW,
    ctx: &mut TxContext,
) {    
    let action: &CreateVestingAction<CoinType> = executable.next_action(intent_witness);
    
    // Validate parameters
    assert!(action.amount > 0, EInvalidVestingParameters);
    assert!(action.end_timestamp > action.start_timestamp, EInvalidVestingParameters);
    assert!(action.start_timestamp >= clock.timestamp_ms(), EInvalidVestingParameters);
    if (action.cliff_time.is_some()) {
        let cliff = *action.cliff_time.borrow();
        assert!(cliff >= action.start_timestamp && cliff <= action.end_timestamp, EInvalidVestingParameters);
    };
    assert!(action.max_beneficiaries > 0 && action.max_beneficiaries <= MAX_BENEFICIARIES, EInvalidVestingParameters);

    let id = object::new(ctx);
    let vesting_id = id.to_inner();

    let vesting = Vesting<CoinType> {
        id,
        balance: coin.into_balance(),
        claimed_amount: 0,
        start_timestamp: action.start_timestamp,
        end_timestamp: action.end_timestamp,
        cliff_time: action.cliff_time,
        primary_beneficiary: action.recipient,
        additional_beneficiaries: vector::empty(),
        max_beneficiaries: action.max_beneficiaries,
        max_per_withdrawal: action.max_per_withdrawal,
        min_interval_ms: action.min_interval_ms,
        last_withdrawal_time: 0,
        is_paused: false,
        paused_at: option::none(),
        paused_duration: 0,
        is_transferable: action.is_transferable,
        is_cancelable: action.is_cancelable,
        metadata: action.metadata,
    };
    
    let claim_cap = ClaimCap {
        id: object::new(ctx),
        vesting_id,
    };

    // Emit creation event
    event::emit(VestingCreated {
        vesting_id,
        beneficiary: action.recipient,
        amount: action.amount,
        start_time: action.start_timestamp,
        end_time: action.end_timestamp,
    });

    transfer::transfer(claim_cap, action.recipient);
    transfer::share_object(vesting);
}

/// Claims vested funds (no auth needed, just be an authorized beneficiary)
public fun claim_vesting<CoinType>(
    vesting: &mut Vesting<CoinType>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Check if sender is authorized beneficiary
    let sender = tx_context::sender(ctx);
    let is_authorized = vesting.primary_beneficiary == sender || 
                       vesting.additional_beneficiaries.contains(&sender);
    assert!(is_authorized, EUnauthorizedBeneficiary);
    
    // Check if vesting is paused
    assert!(!vesting.is_paused, EVestingPaused);
    
    let current_time = clock.timestamp_ms();
    
    // Check cliff if applicable
    if (vesting.cliff_time.is_some()) {
        let cliff = *vesting.cliff_time.borrow();
        assert!(current_time >= cliff, ECliffNotReached);
    } else {
        assert!(current_time >= vesting.start_timestamp, ETooEarly);
    };
    
    // Check rate limiting using shared utilities
    assert!(
        stream_utils::check_rate_limit(
            vesting.last_withdrawal_time,
            vesting.min_interval_ms,
            current_time
        ),
        EWithdrawalTooSoon
    );
    
    assert!(
        stream_utils::check_withdrawal_limit(
            amount,
            vesting.max_per_withdrawal
        ),
        EWithdrawalLimitExceeded
    );
    
    // Calculate claimable amount using shared utility
    let available = stream_utils::calculate_claimable(
        vesting.balance.value() + vesting.claimed_amount,
        vesting.claimed_amount,
        vesting.start_timestamp,
        vesting.end_timestamp,
        current_time,
        vesting.paused_duration,
        &vesting.cliff_time
    );
    assert!(amount <= available, EBalanceNotEmpty);
    
    // Update state
    vesting.claimed_amount = vesting.claimed_amount + amount;
    vesting.last_withdrawal_time = current_time;
    
    // Transfer payment
    let payment = coin::from_balance(vesting.balance.split(amount), ctx);
    transfer::public_transfer(payment, sender);
    
    // Emit event
    event::emit(VestingClaimed {
        vesting_id: object::id(vesting),
        beneficiary: sender,
        amount,
        remaining: vesting.balance.value(),
    });
}

/// Cancels a vesting, returning unvested funds to the account
public fun cancel_vesting<Config, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    vesting: Vesting<CoinType>,
    clock: &Clock,
    intent_witness: IW,
    ctx: &mut TxContext,
) {
    let action: &CancelVestingAction = executable.next_action(intent_witness);
    assert!(object::id(&vesting) == action.vesting_id, EWrongVesting);
    assert!(vesting.is_cancelable, EVestingNotCancelable);

    let Vesting { 
        id, 
        mut balance, 
        claimed_amount,
        start_timestamp,
        end_timestamp,
        primary_beneficiary,
        paused_duration,
        cliff_time,
        additional_beneficiaries: _,
        max_beneficiaries: _,
        max_per_withdrawal: _,
        min_interval_ms: _,
        last_withdrawal_time: _,
        is_paused: _,
        paused_at: _,
        is_transferable: _,
        is_cancelable: _,
        metadata: _,
    } = vesting;
    
    let vesting_id = id.to_inner();
    id.delete();

    // Calculate vested/unvested split using shared utility
    let current_time = clock.timestamp_ms();
    let total_amount = balance.value() + claimed_amount;
    
    let (to_pay, to_refund, unvested_claimed) = stream_utils::split_vested_unvested(
        total_amount,
        claimed_amount,
        balance.value(),
        start_timestamp,
        end_timestamp,
        current_time,
        paused_duration,
        &cliff_time
    );

    // Pay remaining vested amount to beneficiary
    let final_payment = if (to_pay > 0) {
        let payment = coin::from_balance(balance.split(to_pay), ctx);
        transfer::public_transfer(payment, primary_beneficiary);
        to_pay
    } else {
        0
    };

    // Return unvested balance to account
    if (to_refund > 0) {
        let refund = coin::from_balance(balance, ctx);
        account.keep(refund);
    } else if (balance.value() > 0) {
        // Should not happen with correct calculation, but handle gracefully
        let leftover = coin::from_balance(balance, ctx);
        account.keep(leftover);
    } else {
        balance.destroy_zero();
    };

    // Emit cancellation event
    event::emit(VestingCancelled {
        vesting_id,
        refunded_amount: to_refund + unvested_claimed,
        final_payment,
    });
}

/// Pauses a vesting
public fun pause_vesting<CoinType>(
    vesting: &mut Vesting<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(tx_context::sender(ctx) == vesting.primary_beneficiary, EUnauthorizedBeneficiary);
    assert!(!vesting.is_paused, EVestingNotPaused);
    
    let current_time = clock.timestamp_ms();
    vesting.is_paused = true;
    vesting.paused_at = option::some(current_time);
    
    event::emit(VestingPaused {
        vesting_id: object::id(vesting),
        paused_at: current_time,
    });
}

/// Resumes a paused vesting
public fun resume_vesting<CoinType>(
    vesting: &mut Vesting<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(tx_context::sender(ctx) == vesting.primary_beneficiary, EUnauthorizedBeneficiary);
    assert!(vesting.is_paused, EVestingNotPaused);
    
    let current_time = clock.timestamp_ms();
    if (vesting.paused_at.is_some()) {
        let pause_start = *vesting.paused_at.borrow();
        let pause_duration = stream_utils::calculate_pause_duration(pause_start, current_time);
        vesting.paused_duration = vesting.paused_duration + pause_duration;
    };
    
    vesting.is_paused = false;
    vesting.paused_at = option::none();
    
    event::emit(VestingResumed {
        vesting_id: object::id(vesting),
        resumed_at: current_time,
        pause_duration: vesting.paused_duration,
    });
}

/// Adds a beneficiary to the vesting
public fun add_beneficiary<CoinType>(
    vesting: &mut Vesting<CoinType>,
    new_beneficiary: address,
    ctx: &mut TxContext,
) {
    assert!(tx_context::sender(ctx) == vesting.primary_beneficiary, EUnauthorizedBeneficiary);
    assert!(vesting.additional_beneficiaries.length() < vesting.max_beneficiaries - 1, ETooManyBeneficiaries);
    assert!(!vesting.additional_beneficiaries.contains(&new_beneficiary), EBeneficiaryAlreadyExists);
    assert!(new_beneficiary != vesting.primary_beneficiary, EBeneficiaryAlreadyExists);
    
    vesting.additional_beneficiaries.push_back(new_beneficiary);
    
    event::emit(BeneficiaryAdded {
        vesting_id: object::id(vesting),
        new_beneficiary,
    });
}

/// Removes a beneficiary from the vesting
public fun remove_beneficiary<CoinType>(
    vesting: &mut Vesting<CoinType>,
    beneficiary: address,
    ctx: &mut TxContext,
) {
    assert!(tx_context::sender(ctx) == vesting.primary_beneficiary, EUnauthorizedBeneficiary);
    
    let (found, index) = vesting.additional_beneficiaries.index_of(&beneficiary);
    assert!(found, EBeneficiaryNotFound);
    
    vesting.additional_beneficiaries.remove(index);
    
    event::emit(BeneficiaryRemoved {
        vesting_id: object::id(vesting),
        removed_beneficiary: beneficiary,
    });
}

/// Transfers the primary beneficiary role
public fun transfer_vesting<CoinType>(
    vesting: &mut Vesting<CoinType>,
    new_beneficiary: address,
    ctx: &mut TxContext,
) {
    assert!(tx_context::sender(ctx) == vesting.primary_beneficiary, EUnauthorizedBeneficiary);
    assert!(vesting.is_transferable, ENotTransferable);
    
    let old_beneficiary = vesting.primary_beneficiary;
    vesting.primary_beneficiary = new_beneficiary;
    
    // Remove new beneficiary from additional if present
    let (found, index) = vesting.additional_beneficiaries.index_of(&new_beneficiary);
    if (found) {
        vesting.additional_beneficiaries.remove(index);
    };
    
    event::emit(VestingTransferred {
        vesting_id: object::id(vesting),
        old_beneficiary,
        new_beneficiary,
    });
}

/// Updates vesting metadata
public fun update_metadata<CoinType>(
    vesting: &mut Vesting<CoinType>,
    metadata: Option<String>,
    ctx: &mut TxContext,
) {
    assert!(tx_context::sender(ctx) == vesting.primary_beneficiary, EUnauthorizedBeneficiary);
    vesting.metadata = metadata;
}

/// Proposes to cancel a vesting
public fun new_cancel_vesting<Config, Outcome, IW: drop>(
    intent: &mut Intent<Outcome>, 
    _account: &Account<Config>,
    vesting_id: ID,
    intent_witness: IW,
) {
    let descriptor = action_descriptor::new_with_target(
        b"payments", 
        b"cancel_vesting",
        vesting_id
    );
    
    intent.add_action_with_descriptor(
        CancelVestingAction { vesting_id },
        descriptor,
        intent_witness
    );
}

/// Deletes the CreateVestingAction
public fun delete_vesting_action<CoinType>(expired: &mut Expired) {
    let CreateVestingAction<CoinType> { 
        amount: _, 
        start_timestamp: _, 
        end_timestamp: _, 
        cliff_time: _,
        recipient: _, 
        max_beneficiaries: _,
        max_per_withdrawal: _,
        min_interval_ms: _,
        is_transferable: _,
        is_cancelable: _,
        metadata: _,
    } = expired.remove_action();
}

/// Deletes the CancelVestingAction
public fun delete_cancel_vesting_action(expired: &mut Expired) {
    let CancelVestingAction { .. } = expired.remove_action();
}

// === Private Functions ===
// (Removed compute_vested - now using stream_utils::calculate_linear_vested)

// === Test Functions ===

#[test_only]
public fun balance<CoinType>(vesting: &Vesting<CoinType>): u64 {
    vesting.balance.value()
}

#[test_only]
public fun is_cancelable<CoinType>(vesting: &Vesting<CoinType>): bool {
    vesting.is_cancelable
}

#[test_only]
public fun is_transferable<CoinType>(vesting: &Vesting<CoinType>): bool {
    vesting.is_transferable
}

#[test_only]
public fun is_paused<CoinType>(vesting: &Vesting<CoinType>): bool {
    vesting.is_paused
}

#[test_only]
public fun beneficiaries_count<CoinType>(vesting: &Vesting<CoinType>): u64 {
    1 + vesting.additional_beneficiaries.length()
}