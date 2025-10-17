// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Generic per-outcome escrow for proposal deposits
///
/// === Security Model ===
/// - Each outcome has its own isolated escrow + receipt
/// - Receipt stored as dynamic field keyed by outcome index (primary defense)
/// - Only winning outcome can access its escrow
/// - State-locked: deposits only after outcomes finalized (STATE ≥ REVIEW)
/// - Outcome count verification (defense-in-depth, detects proposal mutation)
///
/// === Design ===
/// - ProposalEscrow: Shared object holding funds/objects
/// - EscrowReceipt: Stored in proposal's dynamic fields per outcome (no drop ability)
/// - OutcomeEscrowKey: Dynamic field key tying receipt to specific outcome
///
/// === Flow ===
/// 1. Proposal reaches REVIEW state (outcomes locked)
/// 2. Create escrow for specific outcome → receipt
/// 3. Store receipt in proposal's dynamic field with outcome key
/// 4. When outcome wins, retrieve receipt and withdraw
/// 5. Losing outcomes can't access winning outcome's escrow (keying prevents theft)

module futarchy_actions::proposal_escrow;

use std::option::{Self, Option};
use sui::balance::{Self, Balance};
use sui::bag::{Self, Bag};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::dynamic_field;
use sui::event;
use sui::object::{Self, UID, ID};
use sui::tx_context::TxContext;

// === Errors ===
const EInvalidReceipt: u64 = 1;
const ENotEmpty: u64 = 2;
const EInsufficientBalance: u64 = 3;
const EObjectNotFound: u64 = 4;
const EInvalidProposal: u64 = 5;
const EAlreadyWithdrawn: u64 = 6;
const EProposalNotReady: u64 = 7;
const EOutcomeCountMismatch: u64 = 8;
const EMarketNotInitialized: u64 = 9;
const EInvalidOutcome: u64 = 10;

// Proposal state constants (must match proposal.move)
const STATE_PREMARKET: u8 = 0;
const STATE_REVIEW: u8 = 1;
const STATE_TRADING: u8 = 2;
const STATE_FINALIZED: u8 = 3;

// === Structs ===

/// Key for storing escrow receipt in proposal's dynamic fields
/// Each outcome has its own receipt - prevents cross-outcome theft
public struct OutcomeEscrowKey has copy, drop, store {
    outcome_index: u64,
}

/// Generic escrow holding either coins or objects for a SPECIFIC outcome
public struct ProposalEscrow<phantom AssetType> has key {
    id: UID,
    proposal_id: ID,
    outcome_index: u64,  // Which outcome owns this escrow
    locked_outcome_count: u64,  // Outcome count when created (prevent mutation)
    /// Fungible balance (for coins)
    balance: Balance<AssetType>,
    /// Object storage (for NFTs, LP tokens, etc.)
    objects: Bag,
    /// Track if primary balance has been withdrawn
    balance_withdrawn: bool,
    created_at: u64,
}

/// Receipt proving deposit into escrow - grants withdrawal authority
/// Stored in proposal's dynamic field keyed by outcome
public struct EscrowReceipt<phantom AssetType> has store {
    escrow_id: ID,
    proposal_id: ID,
    outcome_index: u64,  // Which outcome owns this
    locked_outcome_count: u64,  // Verify outcome count hasn't changed (defense-in-depth)
    /// Amount deposited at creation (for coins)
    initial_coin_amount: u64,
    /// Object IDs deposited (for objects)
    object_ids: vector<ID>,
}


// === Events ===

public struct OutcomeEscrowCreated has copy, drop {
    escrow_id: ID,
    proposal_id: ID,
    outcome_index: u64,
    coin_amount: u64,
    object_count: u64,
    created_at: u64,
}

public struct FundsWithdrawn has copy, drop {
    escrow_id: ID,
    proposal_id: ID,
    outcome_index: u64,
    amount: u64,
    withdrawn_at: u64,
}

public struct ObjectWithdrawn has copy, drop {
    escrow_id: ID,
    proposal_id: ID,
    outcome_index: u64,
    object_id: ID,
    withdrawn_at: u64,
}

public struct EscrowDestroyed has copy, drop {
    escrow_id: ID,
    proposal_id: ID,
    outcome_index: u64,
}

// === Constructor Functions ===

/// Create escrow for specific outcome with state verification
/// SECURITY: Only works if proposal state ≥ REVIEW (outcomes locked)
/// Returns (escrow, receipt) - caller must store receipt in proposal
public fun create_for_outcome_with_coin<AssetType, StableType>(
    proposal: &futarchy_markets_core::proposal::Proposal<AssetType, StableType>,
    outcome_index: u64,
    deposit: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (ProposalEscrow<AssetType>, EscrowReceipt<AssetType>) {
    // SECURITY: Verify proposal is ready (outcomes finalized)
    let state = futarchy_markets_core::proposal::state(proposal);
    assert!(state >= STATE_REVIEW, EProposalNotReady);

    // SECURITY: Verify outcome index is valid
    let outcome_count = futarchy_markets_core::proposal::outcome_count(proposal);
    assert!(outcome_index < outcome_count, EInvalidOutcome);

    // Lock outcome count at escrow creation time
    let locked_outcome_count = outcome_count;

    let coin_amount = deposit.value();
    let id = object::new(ctx);
    let escrow_id = object::uid_to_inner(&id);
    let proposal_id = object::id(proposal);
    let created_at = clock.timestamp_ms();

    let escrow = ProposalEscrow {
        id,
        proposal_id,
        outcome_index,
        locked_outcome_count,
        balance: deposit.into_balance(),
        objects: bag::new(ctx),
        balance_withdrawn: false,
        created_at,
    };

    let receipt = EscrowReceipt {
        escrow_id,
        proposal_id,
        outcome_index,
        locked_outcome_count,
        initial_coin_amount: coin_amount,
        object_ids: vector::empty(),
    };

    event::emit(OutcomeEscrowCreated {
        escrow_id,
        proposal_id,
        outcome_index,
        coin_amount,
        object_count: 0,
        created_at,
    });

    (escrow, receipt)
}

/// Create escrow with object deposit for specific outcome
public fun create_for_outcome_with_object<AssetType, StableType, T: key + store>(
    proposal: &futarchy_markets_core::proposal::Proposal<AssetType, StableType>,
    outcome_index: u64,
    object: T,
    clock: &Clock,
    ctx: &mut TxContext,
): (ProposalEscrow<AssetType>, EscrowReceipt<AssetType>) {
    // SECURITY: Verify proposal is ready
    let state = futarchy_markets_core::proposal::state(proposal);
    assert!(state >= STATE_REVIEW, EProposalNotReady);

    let outcome_count = futarchy_markets_core::proposal::outcome_count(proposal);
    assert!(outcome_index < outcome_count, EInvalidOutcome);

    let locked_outcome_count = outcome_count;
    let id = object::new(ctx);
    let escrow_id = object::uid_to_inner(&id);
    let proposal_id = object::id(proposal);
    let created_at = clock.timestamp_ms();

    let mut objects = bag::new(ctx);
    let object_id = object::id(&object);
    bag::add(&mut objects, object_id, object);

    let escrow = ProposalEscrow<AssetType> {
        id,
        proposal_id,
        outcome_index,
        locked_outcome_count,
        balance: balance::zero<AssetType>(),
        objects,
        balance_withdrawn: false,
        created_at,
    };

    let mut object_ids = vector::empty();
    object_ids.push_back(object_id);

    let receipt = EscrowReceipt {
        escrow_id,
        proposal_id,
        outcome_index,
        locked_outcome_count,
        initial_coin_amount: 0,
        object_ids,
    };

    event::emit(OutcomeEscrowCreated {
        escrow_id,
        proposal_id,
        outcome_index,
        coin_amount: 0,
        object_count: 1,
        created_at,
    });

    (escrow, receipt)
}

// === Receipt Management (Generic Pattern) ===

/// Store escrow receipt in proposal's dynamic fields
/// SECURITY: Keyed by outcome index - prevents cross-outcome access
public fun store_receipt_in_proposal<AssetType, StableType>(
    proposal: &mut futarchy_markets_core::proposal::Proposal<AssetType, StableType>,
    outcome_index: u64,
    receipt: EscrowReceipt<AssetType>,
) {
    // Verify outcome index matches receipt
    assert!(receipt.outcome_index == outcome_index, EInvalidOutcome);

    let key = OutcomeEscrowKey { outcome_index };
    dynamic_field::add(
        futarchy_markets_core::proposal::borrow_uid_mut(proposal),
        key,
        receipt
    );
}

/// Retrieve escrow receipt from proposal for specific outcome
/// SECURITY: Only returns receipt if outcome index matches
public fun get_receipt_from_proposal<AssetType, StableType>(
    proposal: &futarchy_markets_core::proposal::Proposal<AssetType, StableType>,
    outcome_index: u64,
): &EscrowReceipt<AssetType> {
    let key = OutcomeEscrowKey { outcome_index };
    dynamic_field::borrow(
        futarchy_markets_core::proposal::borrow_uid(proposal),
        key
    )
}

/// Remove escrow receipt from proposal (for winning outcome execution)
/// Package-private to prevent external code from stealing receipts
public(package) fun remove_receipt_from_proposal<AssetType, StableType>(
    proposal: &mut futarchy_markets_core::proposal::Proposal<AssetType, StableType>,
    outcome_index: u64,
): EscrowReceipt<AssetType> {
    let key = OutcomeEscrowKey { outcome_index };
    dynamic_field::remove(
        futarchy_markets_core::proposal::borrow_uid_mut(proposal),
        key
    )
}

/// Check if outcome has escrow receipt
public fun has_escrow_receipt<AssetType, StableType>(
    proposal: &futarchy_markets_core::proposal::Proposal<AssetType, StableType>,
    outcome_index: u64,
): bool {
    let key = OutcomeEscrowKey { outcome_index };
    dynamic_field::exists_<OutcomeEscrowKey, EscrowReceipt<AssetType>>(
        futarchy_markets_core::proposal::borrow_uid(proposal),
        key
    )
}

// === Withdrawal Functions ===

/// Withdraw partial amount using receipt
/// SECURITY: Verifies outcome count hasn't changed since creation
public fun withdraw_partial<AssetType, StableType>(
    escrow: &mut ProposalEscrow<AssetType>,
    proposal: &futarchy_markets_core::proposal::Proposal<AssetType, StableType>,
    receipt: &EscrowReceipt<AssetType>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    // Verify receipt matches escrow
    assert!(object::id(escrow) == receipt.escrow_id, EInvalidReceipt);
    assert!(escrow.proposal_id == receipt.proposal_id, EInvalidProposal);
    assert!(escrow.outcome_index == receipt.outcome_index, EInvalidReceipt);
    assert!(!escrow.balance_withdrawn, EAlreadyWithdrawn);

    // SECURITY: Verify outcome count hasn't changed (mutation protection)
    let current_outcome_count = futarchy_markets_core::proposal::outcome_count(proposal);
    assert!(
        current_outcome_count == escrow.locked_outcome_count,
        EOutcomeCountMismatch
    );
    assert!(
        current_outcome_count == receipt.locked_outcome_count,
        EOutcomeCountMismatch
    );

    // Verify sufficient balance
    assert!(escrow.balance.value() >= amount, EInsufficientBalance);

    let withdrawn = escrow.balance.split(amount);

    event::emit(FundsWithdrawn {
        escrow_id: receipt.escrow_id,
        proposal_id: receipt.proposal_id,
        outcome_index: receipt.outcome_index,
        amount,
        withdrawn_at: clock.timestamp_ms(),
    });

    coin::from_balance(withdrawn, ctx)
}

/// Withdraw all coins using receipt (consumes receipt)
public fun withdraw_all_coins<AssetType, StableType>(
    escrow: &mut ProposalEscrow<AssetType>,
    proposal: &futarchy_markets_core::proposal::Proposal<AssetType, StableType>,
    receipt: EscrowReceipt<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    // Verify receipt
    assert!(object::id(escrow) == receipt.escrow_id, EInvalidReceipt);
    assert!(escrow.proposal_id == receipt.proposal_id, EInvalidProposal);
    assert!(escrow.outcome_index == receipt.outcome_index, EInvalidReceipt);
    assert!(!escrow.balance_withdrawn, EAlreadyWithdrawn);

    // SECURITY: Verify outcome count
    let current_outcome_count = futarchy_markets_core::proposal::outcome_count(proposal);
    assert!(
        current_outcome_count == escrow.locked_outcome_count,
        EOutcomeCountMismatch
    );
    assert!(
        current_outcome_count == receipt.locked_outcome_count,
        EOutcomeCountMismatch
    );

    let amount = escrow.balance.value();
    let withdrawn = escrow.balance.withdraw_all();

    // Mark as withdrawn
    escrow.balance_withdrawn = true;

    event::emit(FundsWithdrawn {
        escrow_id: receipt.escrow_id,
        proposal_id: receipt.proposal_id,
        outcome_index: receipt.outcome_index,
        amount,
        withdrawn_at: clock.timestamp_ms(),
    });

    // Consume receipt (no drop ability, so must destructure)
    let EscrowReceipt {
        escrow_id: _,
        proposal_id: _,
        outcome_index: _,
        locked_outcome_count: _,
        initial_coin_amount: _,
        object_ids: _
    } = receipt;

    coin::from_balance(withdrawn, ctx)
}

/// Withdraw specific object using receipt
public fun withdraw_object<AssetType, StableType, T: key + store>(
    escrow: &mut ProposalEscrow<AssetType>,
    proposal: &futarchy_markets_core::proposal::Proposal<AssetType, StableType>,
    receipt: &EscrowReceipt<AssetType>,
    object_id: ID,
    clock: &Clock,
    _ctx: &mut TxContext,
): T {
    // Verify receipt
    assert!(object::id(escrow) == receipt.escrow_id, EInvalidReceipt);
    assert!(escrow.proposal_id == receipt.proposal_id, EInvalidProposal);
    assert!(escrow.outcome_index == receipt.outcome_index, EInvalidReceipt);

    // SECURITY: Verify outcome count
    let current_outcome_count = futarchy_markets_core::proposal::outcome_count(proposal);
    assert!(
        current_outcome_count == escrow.locked_outcome_count,
        EOutcomeCountMismatch
    );

    // Verify object was deposited
    assert!(receipt.object_ids.contains(&object_id), EObjectNotFound);

    // Remove object directly from bag
    let object: T = bag::remove(&mut escrow.objects, object_id);

    event::emit(ObjectWithdrawn {
        escrow_id: receipt.escrow_id,
        proposal_id: receipt.proposal_id,
        outcome_index: receipt.outcome_index,
        object_id,
        withdrawn_at: clock.timestamp_ms(),
    });

    object
}

// === Cleanup Functions ===

/// Destroy empty escrow
public fun destroy_empty<AssetType>(escrow: ProposalEscrow<AssetType>) {
    let ProposalEscrow {
        id,
        proposal_id,
        outcome_index,
        locked_outcome_count: _,
        balance,
        objects,
        balance_withdrawn: _,
        created_at: _,
    } = escrow;

    assert!(balance.value() == 0, ENotEmpty);
    assert!(objects.is_empty(), ENotEmpty);

    balance.destroy_zero();
    objects.destroy_empty();

    event::emit(EscrowDestroyed {
        escrow_id: object::uid_to_inner(&id),
        proposal_id,
        outcome_index,
    });

    object::delete(id);
}

// === Getters ===

public fun escrow_outcome_index<AssetType>(escrow: &ProposalEscrow<AssetType>): u64 {
    escrow.outcome_index
}

public fun escrow_locked_outcome_count<AssetType>(escrow: &ProposalEscrow<AssetType>): u64 {
    escrow.locked_outcome_count
}

public fun receipt_outcome_index<AssetType>(receipt: &EscrowReceipt<AssetType>): u64 {
    receipt.outcome_index
}

public fun receipt_escrow_id<AssetType>(receipt: &EscrowReceipt<AssetType>): ID {
    receipt.escrow_id
}

public fun receipt_initial_coin_amount<AssetType>(receipt: &EscrowReceipt<AssetType>): u64 {
    receipt.initial_coin_amount
}

public fun balance<AssetType>(escrow: &ProposalEscrow<AssetType>): u64 {
    escrow.balance.value()
}

public fun is_empty<AssetType>(escrow: &ProposalEscrow<AssetType>): bool {
    escrow.balance.value() == 0 && escrow.objects.is_empty()
}
