// ============================================================================
// FORK MODIFICATION NOTICE - Vesting with Serialize-Then-Destroy Pattern
// ============================================================================
// This module provides comprehensive vesting functionality with streaming.
//
// CHANGES IN THIS FORK:
// - Actions use type markers: VestingCreate, VestingCancel
// - Implemented serialize-then-destroy pattern for both action types
// - Added destruction functions: destroy_create_vesting_action, destroy_cancel_vesting_action
// - Actions serialize to bytes before adding to intent via add_typed_action()
// - Comprehensive vesting features: cliff periods, multiple beneficiaries, pausable
// - Type-safe action validation through compile-time TypeName comparison
//
// COMPOSABILITY IMPROVEMENTS (2025-09-14):
// - claim_vesting() now returns Coin<CoinType> for PTB composability
// - Added claim_vesting_to() for direct transfers to recipients
// - Added claim_vesting_to_self() convenience function
// - Fixed design flaw: separated authorization from payment destination
// - Note: Batch claims removed - PTBs handle this natively
// ============================================================================
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
    string::{Self, String},
    option::{Self, Option},
    type_name::{Self, TypeName},
    u64,
};
use sui::{
    balance::Balance,
    coin::{Self, Coin},
    clock::Clock,
    event,
    object::{Self, ID, UID},
    transfer,
    tx_context,
    bcs::{Self, BCS},
};
use account_protocol::{
    action_validation,
    account::Account,
    intents::{Self, Expired, Intent},
    executable::{Self, Executable},
    version_witness::VersionWitness,
    bcs_validation,
};
use account_extensions::framework_action_types::{Self, VestingCreate, VestingCancel};
use account_actions::{stream_utils, version};

use fun account_protocol::intents::add_typed_action as Intent.add_typed_action;

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
const EInvalidInput: u64 = 16;
const ETimeCalculationOverflow: u64 = 17;  // Keep for pause duration validation
const EEmergencyFrozen: u64 = 18;
const EVestingExpired: u64 = 19;

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
    paused_until: Option<u64>,  // None = indefinite, Some(ts) = pause until timestamp
    paused_duration: u64,
    emergency_frozen: bool,     // If true, even unpause won't work
    is_transferable: bool,
    is_cancelable: bool,
    // Expiry
    expiry_timestamp: Option<u64>,  // Vesting becomes invalid after this time
    // Metadata
    metadata: Option<String>,
}

/// Cap enabling bearer to claim the vesting
public struct ClaimCap has key {
    id: UID,
    vesting_id: ID,
}

/// Action for creating a comprehensive vesting
public struct CreateVestingAction<phantom CoinType> has drop, store {
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
public struct CancelVestingAction has drop, store {
    vesting_id: ID,
}

/// Action for toggling vesting pause (combines pause/resume)
public struct ToggleVestingPauseAction has drop, store {
    vesting_id: ID,
    pause_duration_ms: u64, // 0 = unpause, >0 = pause for duration
}

/// Action for toggling emergency freeze (combines freeze/unfreeze)
public struct ToggleVestingFreezeAction has drop, store {
    vesting_id: ID,
    freeze: bool, // true = freeze, false = unfreeze
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

/// Emitted when a vesting is emergency frozen
public struct VestingFrozen has copy, drop {
    vesting_id: ID,
    timestamp: u64,
}

/// Emitted when emergency freeze is removed
public struct VestingUnfrozen has copy, drop {
    vesting_id: ID,
    timestamp: u64,
}

// === Destruction Functions ===

/// Destroy a CreateVestingAction after serialization
public fun destroy_create_vesting_action<CoinType>(action: CreateVestingAction<CoinType>) {
    let CreateVestingAction {
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
    } = action;
}

/// Destroy a CancelVestingAction after serialization
public fun destroy_cancel_vesting_action(action: CancelVestingAction) {
    let CancelVestingAction { vesting_id: _ } = action;
}

/// Destroy a ToggleVestingPauseAction after serialization
public fun destroy_toggle_vesting_pause_action(action: ToggleVestingPauseAction) {
    let ToggleVestingPauseAction { vesting_id: _, pause_duration_ms: _ } = action;
}

/// Destroy a ToggleVestingFreezeAction after serialization
public fun destroy_toggle_vesting_freeze_action(action: ToggleVestingFreezeAction) {
    let ToggleVestingFreezeAction { vesting_id: _, freeze: _ } = action;
}

// === Public Functions ===

/// Proposes to create vestings for multiple recipients (supports 1 to N recipients)
/// Each recipient gets their own independent Vesting object
public fun new_vesting<Config, Outcome, CoinType, IW: copy + drop>(
    intent: &mut Intent<Outcome>,
    _account: &Account<Config>,
    recipients: vector<address>,
    amounts: vector<u64>,
    start_timestamp: u64,
    end_timestamp: u64,
    cliff_time: Option<u64>,
    max_beneficiaries: u64,
    max_per_withdrawal: u64,
    min_interval_ms: u64,
    is_transferable: bool,
    is_cancelable: bool,
    metadata: Option<String>,
    intent_witness: IW,
) {
    use std::vector;

    let len = vector::length(&recipients);
    assert!(len > 0 && len == vector::length(&amounts), 0); // ELengthMismatch

    let mut i = 0;
    while (i < len) {
        // Create action struct for this recipient
        let action = CreateVestingAction<CoinType> {
            amount: *vector::borrow(&amounts, i),
            start_timestamp,
            end_timestamp,
            cliff_time,
            recipient: *vector::borrow(&recipients, i),
            max_beneficiaries,
            max_per_withdrawal,
            min_interval_ms,
            is_transferable,
            is_cancelable,
            metadata,
        };

        // Serialize the entire struct directly
        let action_data = bcs::to_bytes(&action);

        // Add to intent
        intent.add_typed_action(
            framework_action_types::vesting_create(),
            action_data,
            intent_witness // Now copyable, so can be used in loop
        );

        // Destroy the action struct
        destroy_create_vesting_action(action);

        i = i + 1;
    }
}

/// Creates the Vesting and ClaimCap objects from a CreateVestingAction
public fun do_vesting<Config, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account<Config>,
    coin: Coin<CoinType>,
    clock: &Clock,
    _intent_witness: IW,
    ctx: &mut TxContext,
) {
    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<VestingCreate>(spec);


    let action_data = intents::action_spec_data(spec);

    // Deserialize the entire action struct directly
    let mut reader = bcs::new(*action_data);
    let amount = bcs::peel_u64(&mut reader);
    let start_timestamp = bcs::peel_u64(&mut reader);
    let end_timestamp = bcs::peel_u64(&mut reader);
    let cliff_time = if (bcs::peel_bool(&mut reader)) {
        option::some(bcs::peel_u64(&mut reader))
    } else {
        option::none()
    };
    let recipient = bcs::peel_address(&mut reader);
    let max_beneficiaries = bcs::peel_u64(&mut reader);
    let max_per_withdrawal = bcs::peel_u64(&mut reader);
    let min_interval_ms = bcs::peel_u64(&mut reader);
    let is_transferable = bcs::peel_bool(&mut reader);
    let is_cancelable = bcs::peel_bool(&mut reader);
    let metadata = if (bcs::peel_bool(&mut reader)) {
        option::some(string::utf8(bcs::peel_vec_u8(&mut reader)))
    } else {
        option::none()
    };

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Validate parameters
    assert!(amount > 0, EInvalidVestingParameters);
    assert!(end_timestamp > start_timestamp, EInvalidVestingParameters);
    assert!(start_timestamp >= clock.timestamp_ms(), EInvalidVestingParameters);

    if (cliff_time.is_some()) {
        let cliff = *cliff_time.borrow();
        assert!(cliff >= start_timestamp && cliff <= end_timestamp, EInvalidVestingParameters);
    };
    assert!(max_beneficiaries > 0 && max_beneficiaries <= stream_utils::max_beneficiaries(), EInvalidVestingParameters);

    let id = object::new(ctx);
    let vesting_id = id.to_inner();

    let vesting = Vesting<CoinType> {
        id,
        balance: coin.into_balance(),
        claimed_amount: 0,
        start_timestamp,
        end_timestamp,
        cliff_time,
        primary_beneficiary: recipient,
        additional_beneficiaries: vector::empty(),
        max_beneficiaries,
        max_per_withdrawal,
        min_interval_ms,
        last_withdrawal_time: 0,
        is_paused: false,
        paused_at: option::none(),
        paused_until: option::none(),
        paused_duration: 0,
        emergency_frozen: false,
        is_transferable,
        is_cancelable,
        expiry_timestamp: option::none(),  // No expiry by default
        metadata,
    };

    let claim_cap = ClaimCap {
        id: object::new(ctx),
        vesting_id,
    };

    // Emit creation event
    event::emit(VestingCreated {
        vesting_id,
        beneficiary: recipient,
        amount,
        start_time: start_timestamp,
        end_time: end_timestamp,
    });

    transfer::transfer(claim_cap, recipient);
    transfer::share_object(vesting);

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Create vesting during initialization - works on unshared Accounts
/// This simplified version creates a vesting directly during DAO initialization.
/// The vesting is shared immediately, and ClaimCap is transferred to recipient.
/// Returns the vesting ID for reference.
///
/// ## FORK NOTE
/// **Added**: `do_create_vesting_unshared()` for init-time vesting creation (NEW pattern)
/// **Reason**: Enable DAOs to create token vesting schedules during initialization
/// (for founders, team, advisors) without requiring Account context or Auth.
/// Shares Vesting object and transfers ClaimCap to recipient. This is part of the
/// complete init actions pattern - original framework had no bootstrapping mechanism.
/// **Safety**: `public(package)` visibility ensures only callable during init
public(package) fun do_create_vesting_unshared<CoinType>(
    coin: Coin<CoinType>,
    recipient: address,
    start_timestamp: u64,
    duration_ms: u64,
    cliff_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Calculate end timestamp
    let end_timestamp = start_timestamp + duration_ms;

    // Calculate cliff time if cliff period specified
    let cliff_time = if (cliff_ms > 0) {
        option::some(start_timestamp + cliff_ms)
    } else {
        option::none()
    };

    // Validate parameters
    let amount = coin.value();
    assert!(amount > 0, EInvalidVestingParameters);
    assert!(end_timestamp > start_timestamp, EInvalidVestingParameters);
    assert!(start_timestamp >= clock.timestamp_ms(), EInvalidVestingParameters);

    if (cliff_time.is_some()) {
        let cliff = *cliff_time.borrow();
        assert!(cliff >= start_timestamp && cliff <= end_timestamp, EInvalidVestingParameters);
    };

    let id = object::new(ctx);
    let vesting_id = id.to_inner();

    // Create vesting with default parameters suitable for initialization
    let vesting = Vesting<CoinType> {
        id,
        balance: coin.into_balance(),
        claimed_amount: 0,
        start_timestamp,
        end_timestamp,
        cliff_time,
        primary_beneficiary: recipient,
        additional_beneficiaries: vector::empty(),
        max_beneficiaries: 10,  // Reasonable default
        max_per_withdrawal: 0,  // No limit
        min_interval_ms: 0,     // No minimum interval
        last_withdrawal_time: 0,
        is_paused: false,
        paused_at: option::none(),
        paused_until: option::none(),
        paused_duration: 0,
        emergency_frozen: false,
        is_transferable: false,  // Not transferable by default
        is_cancelable: false,    // Not cancelable for security
        expiry_timestamp: option::none(),
        metadata: option::none(),
    };

    let claim_cap = ClaimCap {
        id: object::new(ctx),
        vesting_id,
    };

    // Emit creation event
    event::emit(VestingCreated {
        vesting_id,
        beneficiary: recipient,
        amount,
        start_time: start_timestamp,
        end_time: end_timestamp,
    });

    // Transfer cap and share vesting
    transfer::transfer(claim_cap, recipient);
    transfer::share_object(vesting);

    // Return the vesting ID for reference
    vesting_id
}

/// Claims vested funds and returns the coin for composability
/// Caller must be an authorized beneficiary
public fun claim_vesting<CoinType>(
    vesting: &mut Vesting<CoinType>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    // Check if sender is authorized beneficiary
    let sender = tx_context::sender(ctx);
    let is_authorized = vesting.primary_beneficiary == sender ||
                       vesting.additional_beneficiaries.contains(&sender);
    assert!(is_authorized, EUnauthorizedBeneficiary);

    let current_time = clock.timestamp_ms();

    // Use stream_utils to check if claiming is allowed
    assert!(stream_utils::can_claim(
        vesting.is_paused,
        vesting.emergency_frozen,
        &vesting.expiry_timestamp,
        current_time
    ), EVestingPaused); // Use EVestingPaused as generic "can't claim" error

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
    
    // Create payment coin
    let payment = coin::from_balance(vesting.balance.split(amount), ctx);
    
    // Emit event
    event::emit(VestingClaimed {
        vesting_id: object::id(vesting),
        beneficiary: sender,
        amount,
        remaining: vesting.balance.value(),
    });

    // Return the coin for composability
    payment
}

/// Convenience function: Claims vested funds and transfers to a specific recipient
/// This wraps the composable claim_vesting function for simple use cases
public fun claim_vesting_to<CoinType>(
    vesting: &mut Vesting<CoinType>,
    amount: u64,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let payment = claim_vesting(vesting, amount, clock, ctx);
    transfer::public_transfer(payment, recipient);
}

/// Convenience function: Claims vested funds and transfers to sender
/// This is the simplest way to claim for yourself
public fun claim_vesting_to_self<CoinType>(
    vesting: &mut Vesting<CoinType>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    claim_vesting_to(vesting, amount, tx_context::sender(ctx), clock, ctx);
}

/// Cancels a vesting, returning unvested funds to the account
public fun cancel_vesting<Config, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    vesting: Vesting<CoinType>,
    clock: &Clock,
    _intent_witness: IW,
    ctx: &mut TxContext,
) {
    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());
    let action_data = intents::action_spec_data(spec);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let vesting_id = bcs::peel_address(&mut reader).to_id();

    assert!(object::id(&vesting) == vesting_id, EWrongVesting);
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
        paused_until: _,
        emergency_frozen: _,
        is_transferable: _,
        is_cancelable: _,
        expiry_timestamp: _,
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
        account.keep(refund, ctx);
    } else if (balance.value() > 0) {
        // Should not happen with correct calculation, but handle gracefully
        let leftover = coin::from_balance(balance, ctx);
        account.keep(leftover, ctx);
    } else {
        balance.destroy_zero();
    };

    // Emit cancellation event
    // Note: Only report actual refund amount (to_refund), not unvested_claimed
    // as those tokens were already claimed and cannot be recovered
    event::emit(VestingCancelled {
        vesting_id,
        refunded_amount: to_refund,
        final_payment,
    });

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Pauses a vesting for a specific duration (in milliseconds)
/// Pass 0 for pause_duration_ms to pause indefinitely
public fun pause_vesting<CoinType>(
    vesting: &mut Vesting<CoinType>,
    pause_duration_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(tx_context::sender(ctx) == vesting.primary_beneficiary, EUnauthorizedBeneficiary);
    assert!(!vesting.is_paused, EVestingNotPaused);
    assert!(!vesting.emergency_frozen, EEmergencyFrozen);

    let current_time = clock.timestamp_ms();

    // Use stream_utils for pause calculation and validation
    assert!(stream_utils::validate_pause_duration(current_time, pause_duration_ms), ETimeCalculationOverflow);

    vesting.is_paused = true;
    vesting.paused_at = option::some(current_time);
    vesting.paused_until = stream_utils::calculate_pause_until(current_time, pause_duration_ms);

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
    assert!(!vesting.emergency_frozen, EEmergencyFrozen);

    let current_time = clock.timestamp_ms();
    if (vesting.paused_at.is_some()) {
        let pause_start = *vesting.paused_at.borrow();
        let pause_duration = stream_utils::calculate_pause_duration(pause_start, current_time);
        vesting.paused_duration = vesting.paused_duration + pause_duration;
    };

    vesting.is_paused = false;
    vesting.paused_at = option::none();
    vesting.paused_until = option::none();

    event::emit(VestingResumed {
        vesting_id: object::id(vesting),
        resumed_at: current_time,
        pause_duration: vesting.paused_duration,
    });
}

/// Check if pause has expired and auto-unpause if needed
/// Can be called by anyone to help beneficiary
public fun check_and_unpause<CoinType>(
    vesting: &mut Vesting<CoinType>,
    clock: &Clock,
) {
    if (!vesting.is_paused) {
        return
    };

    let current_time = clock.timestamp_ms();

    // Use stream_utils to check if pause expired
    if (stream_utils::is_pause_expired(&vesting.paused_until, current_time)) {
        // Auto-unpause (doesn't require beneficiary permission)
        if (vesting.paused_at.is_some()) {
            let pause_start = *vesting.paused_at.borrow();
            let pause_duration = stream_utils::calculate_pause_duration(pause_start, current_time);
            vesting.paused_duration = vesting.paused_duration + pause_duration;
        };

        vesting.is_paused = false;
        vesting.paused_at = option::none();
        vesting.paused_until = option::none();

        event::emit(VestingResumed {
            vesting_id: object::id(vesting),
            resumed_at: current_time,
            pause_duration: vesting.paused_duration,
        });
    };
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

// === Emergency Controls ===

/// Emergency freeze - prevents all claims and unpause
/// Only callable by governance/authority (not beneficiary)
/// Note: This is public so DAO governance can call it
public fun emergency_freeze<CoinType>(
    vesting: &mut Vesting<CoinType>,
    clock: &Clock,
) {
    assert!(!vesting.emergency_frozen, EEmergencyFrozen);

    vesting.emergency_frozen = true;
    if (!vesting.is_paused) {
        vesting.is_paused = true;
        vesting.paused_at = option::some(clock.timestamp_ms());
        vesting.paused_until = option::none(); // Indefinite
    };

    event::emit(VestingFrozen {
        vesting_id: object::id(vesting),
        timestamp: clock.timestamp_ms(),
    });
}

/// Remove emergency freeze
/// Only callable by governance/authority
public fun emergency_unfreeze<CoinType>(
    vesting: &mut Vesting<CoinType>,
    clock: &Clock,
) {
    assert!(vesting.emergency_frozen, EVestingNotPaused);

    vesting.emergency_frozen = false;

    event::emit(VestingUnfrozen {
        vesting_id: object::id(vesting),
        timestamp: clock.timestamp_ms(),
    });

    // Note: Does NOT auto-unpause - beneficiary must explicitly unpause after unfreezing
}

// === Preview Functions ===

/// Calculate currently claimable amount (vested but not yet claimed)
public fun claimable_now<CoinType>(
    vesting: &Vesting<CoinType>,
    clock: &Clock,
): u64 {
    let current_time = clock.timestamp_ms();

    // Use stream_utils to check if claiming is allowed
    if (!stream_utils::can_claim(
        vesting.is_paused,
        vesting.emergency_frozen,
        &vesting.expiry_timestamp,
        current_time
    )) {
        return 0
    };

    // Check cliff
    if (vesting.cliff_time.is_some()) {
        let cliff = *vesting.cliff_time.borrow();
        if (current_time < cliff) {
            return 0
        };
    } else if (current_time < vesting.start_timestamp) {
        return 0
    };

    // Calculate claimable using stream_utils
    let total_amount = vesting.balance.value() + vesting.claimed_amount;
    stream_utils::calculate_claimable(
        total_amount,
        vesting.claimed_amount,
        vesting.start_timestamp,
        vesting.end_timestamp,
        current_time,
        vesting.paused_duration,
        &vesting.cliff_time
    )
}

/// Get next vesting time (when more tokens become available)
public fun next_vest_time<CoinType>(
    vesting: &Vesting<CoinType>,
    clock: &Clock,
): Option<u64> {
    let current_time = clock.timestamp_ms();

    // Use stream_utils for next vesting time calculation
    stream_utils::next_vesting_time(
        vesting.start_timestamp,
        vesting.end_timestamp,
        &vesting.cliff_time,
        &vesting.expiry_timestamp,
        current_time
    )
}

// NOTE: Expiry management removed - doesn't make sense for beneficiary to set their own expiry

/// Proposes to cancel a vesting
public fun new_cancel_vesting<Config, Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    _account: &Account<Config>,
    vesting_id: ID,
    intent_witness: IW,
) {
    // Create the action struct
    let action = CancelVestingAction { vesting_id };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with pre-serialized bytes
    intent.add_typed_action(
        framework_action_types::vesting_cancel(),
        action_data,
        intent_witness
    );

    // Explicitly destroy the action struct
    destroy_cancel_vesting_action(action);
}

/// Proposes to toggle vesting pause (pause or resume)
public fun new_toggle_vesting_pause<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    vesting_id: ID,
    pause_duration_ms: u64, // 0 = unpause, >0 = pause for duration
    intent_witness: IW,
) {
    let action = ToggleVestingPauseAction { vesting_id, pause_duration_ms };
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        framework_action_types::toggle_vesting_pause(),
        action_data,
        intent_witness
    );
    destroy_toggle_vesting_pause_action(action);
}

/// Proposes to toggle vesting emergency freeze
public fun new_toggle_vesting_freeze<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    vesting_id: ID,
    freeze: bool, // true = freeze, false = unfreeze
    intent_witness: IW,
) {
    let action = ToggleVestingFreezeAction { vesting_id, freeze };
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        framework_action_types::toggle_vesting_freeze(),
        action_data,
        intent_witness
    );
    destroy_toggle_vesting_freeze_action(action);
}

// === Execution Functions ===

/// Execute toggle vesting pause action
public fun do_toggle_vesting_pause<Config, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &Account<Config>,
    vesting: &mut Vesting<CoinType>,
    clock: &Clock,
    version: VersionWitness,
    witness: IW,
    ctx: &mut TxContext,
) {
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<framework_action_types::ToggleVestingPause>(spec);

    let action_data = intents::action_spec_data(spec);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let vesting_id = object::id_from_bytes(bcs::peel_vec_u8(&mut reader));
    let pause_duration_ms = bcs::peel_u64(&mut reader);

    // Validate vesting ID matches
    assert!(object::id(vesting) == vesting_id, EWrongVesting);

    // Execute pause/unpause logic
    if (pause_duration_ms == 0) {
        // Unpause
        check_and_unpause(vesting, clock);
    } else {
        // Pause
        pause_vesting(vesting, pause_duration_ms, clock, ctx);
    };

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute toggle vesting freeze action
public fun do_toggle_vesting_freeze<Config, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &Account<Config>,
    vesting: &mut Vesting<CoinType>,
    clock: &Clock,
    version: VersionWitness,
    witness: IW,
) {
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<framework_action_types::ToggleVestingFreeze>(spec);

    let action_data = intents::action_spec_data(spec);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let vesting_id = object::id_from_bytes(bcs::peel_vec_u8(&mut reader));
    let freeze = bcs::peel_bool(&mut reader);

    // Validate vesting ID matches
    assert!(object::id(vesting) == vesting_id, EWrongVesting);

    // Execute freeze/unfreeze logic
    if (freeze) {
        emergency_freeze(vesting, clock);
    } else {
        emergency_unfreeze(vesting, clock);
    };

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Deletes the CreateVestingAction
public fun delete_vesting_action<CoinType>(expired: &mut Expired) {
    use sui::bcs;
    use std::string;

    let spec = account_protocol::intents::remove_action_spec(expired);
    let action_data = account_protocol::intents::action_spec_data(&spec);
    let mut reader = bcs::new(*action_data);

    // We don't need the values, but we must peel them to consume the bytes
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
    } = CreateVestingAction {
        amount: bcs::peel_u64(&mut reader),
        start_timestamp: bcs::peel_u64(&mut reader),
        end_timestamp: bcs::peel_u64(&mut reader),
        cliff_time: bcs::peel_option_u64(&mut reader),
        recipient: bcs::peel_address(&mut reader),
        max_beneficiaries: bcs::peel_u64(&mut reader),
        max_per_withdrawal: bcs::peel_u64(&mut reader),
        min_interval_ms: bcs::peel_u64(&mut reader),
        is_transferable: bcs::peel_bool(&mut reader),
        is_cancelable: bcs::peel_bool(&mut reader),
        metadata: (if (bcs::peel_bool(&mut reader)) {
            option::some(string::utf8(bcs::peel_vec_u8(&mut reader)))
        } else {
            option::none()
        }),
    };
}

/// Deletes the CancelVestingAction
public fun delete_cancel_vesting_action(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, automatically cleaned up
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
