/// Commitment Proposals - Founders/whales lock tokens to reduce centralization risk
///
/// === Design ===
/// Allows major token holders to propose locking their tokens with price-based tiers.
/// Markets decide if this decentralization commitment would increase DAO value.
///
/// === Flow ===
/// 1. Proposer deposits tokens into escrow
/// 2. Creates proposal with price tiers (e.g., lock 10% if TWAP > $1.50, 20% if > $2.00)
/// 3. Markets trade on conditional tokens
/// 4. After trading: Check ACCEPT market TWAP, lock tokens based on highest tier reached
/// 5. If rejected: Return all tokens to proposer
///
/// === Cancelability ===
/// - `cancelable_before_trading`: Can withdraw tokens before trading starts
/// - Once trading starts → commitment is binding (no cancellation)
/// - After execution → time-lock enforced (no early unlock)

module futarchy_actions::commitment_proposal;

use std::option::{Self, Option};
use std::string::String;
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::TxContext;

// === Errors ===
const EInvalidTierConfiguration: u64 = 1;
const ETiersNotSorted: u64 = 2;
const ENotProposer: u64 = 3;
const ECannotCancelAfterTrading: u64 = 4;
const EStillLocked: u64 = 5;
const ENotLocked: u64 = 6;
const EInvalidState: u64 = 7;
const ETierAmountsExceedTotal: u64 = 8;
const ETierVectorLengthMismatch: u64 = 9;
const EInvalidTradingPeriod: u64 = 10;
const ETradingStartInPast: u64 = 11;
const EAlreadyWithdrawn: u64 = 12;

// === Constants ===
const MAX_TIERS: u64 = 10;

// Proposal state constants (match futarchy_markets::proposal)
const STATE_PENDING: u8 = 0;
const STATE_TRADING: u8 = 2;
const STATE_PASSED: u8 = 3;
const STATE_FAILED: u8 = 4;
const STATE_CANCELLED: u8 = 5;

// Cancelability modes
const CANCELABLE_ALWAYS: u8 = 0;
const CANCELABLE_BEFORE_START: u8 = 1;
const CANCELABLE_NEVER: u8 = 2;

// === Structs ===

/// Price-based lock tier
public struct PriceTier has copy, drop, store {
    /// TWAP price threshold to trigger this tier (in price_scale precision)
    twap_threshold: u128,
    /// Amount of tokens to lock at this tier
    lock_amount: u64,
    /// Duration to lock tokens (milliseconds)
    lock_duration_ms: u64,
}

/// Commitment proposal where founder/whale locks tokens based on price performance
public struct CommitmentProposal<phantom AssetType> has key, store {
    id: UID,
    // Proposer info
    proposer: address,
    withdrawal_recipient: address,
    // Commitment details
    committed_amount: u64,
    committed_coins: Balance<AssetType>,
    // Price-based lock tiers (sorted ascending by threshold)
    tiers: vector<PriceTier>,
    // Execution results
    tier_reached: Option<u64>, // Index of tier that was executed
    locked_amount: u64,
    unlock_time: Option<u64>,
    withdrawn: bool, // Prevents double-withdrawal
    // Cancelability
    cancelable_before_trading: bool,
    trading_started: bool,
    // Standard proposal tracking
    proposal_state: u8, // Uses proposal_state constants
    created_at: u64,
    trading_start: u64,
    trading_end: u64,
    // Associated conditional market proposal ID
    market_proposal_id: Option<ID>,
}

// === Events ===

public struct CommitmentProposalCreated has copy, drop {
    proposal_id: ID,
    proposer: address,
    committed_amount: u64,
    tier_count: u64,
    cancelable_before_trading: bool,
    created_at: u64,
}

public struct CommitmentExecuted has copy, drop {
    proposal_id: ID,
    tier_reached: u64,
    locked_amount: u64,
    lock_duration_ms: u64,
    unlock_time: u64,
}

public struct CommitmentCancelled has copy, drop {
    proposal_id: ID,
    returned_amount: u64,
    cancelled_at: u64,
}

public struct CommitmentWithdrawn has copy, drop {
    proposal_id: ID,
    recipient: address,
    amount: u64,
    withdrawn_at: u64,
}

public struct RecipientUpdated has copy, drop {
    proposal_id: ID,
    old_recipient: address,
    new_recipient: address,
}

// === Constructor Helpers ===

/// Creates a new price tier
public fun new_price_tier(
    twap_threshold: u128,
    lock_amount: u64,
    lock_duration_ms: u64,
): PriceTier {
    PriceTier {
        twap_threshold,
        lock_amount,
        lock_duration_ms,
    }
}

// === Helper Functions ===

/// Validates that tiers are sorted in ascending order by threshold
fun validate_tiers_sorted(tier_thresholds: &vector<u128>): bool {
    let len = tier_thresholds.length();
    if (len <= 1) return true;

    let mut i = 1;
    while (i < len) {
        let prev = *tier_thresholds.borrow(i - 1);
        let curr = *tier_thresholds.borrow(i);
        if (curr <= prev) return false;
        i = i + 1;
    };

    true
}

/// Validates tier amounts don't exceed total available
fun validate_tier_amounts(tier_amounts: &vector<u64>, total_available: u64): bool {
    let len = tier_amounts.length();
    let mut i = 0;

    while (i < len) {
        let amount = *tier_amounts.borrow(i);
        if (amount > total_available) return false;
        i = i + 1;
    };

    true
}

/// Finds the highest tier reached based on current value
/// Returns (tier_index, tier_reached)
fun find_highest_tier(current_value: u128, tier_thresholds: &vector<u128>): (u64, bool) {
    let mut highest_index = 0;
    let mut found = false;
    let len = tier_thresholds.length();

    let mut i = 0;
    while (i < len) {
        let threshold = *tier_thresholds.borrow(i);
        if (current_value >= threshold) {
            highest_index = i;
            found = true;
        };
        i = i + 1;
    };

    (highest_index, found)
}

/// Checks if an escrow can be canceled at current time
fun can_cancel(cancelable_mode: u8, start_time: u64, current_time: u64, has_started: bool): bool {
    if (cancelable_mode == CANCELABLE_ALWAYS) {
        return true
    };

    if (cancelable_mode == CANCELABLE_BEFORE_START) {
        if (current_time < start_time && !has_started) {
            return true
        } else {
            return false
        }
    };

    if (cancelable_mode == CANCELABLE_NEVER) {
        return false
    };

    false
}

/// Checks if time lock has expired
fun is_unlocked(unlock_time_opt: &Option<u64>, current_time: u64): bool {
    if (unlock_time_opt.is_none()) {
        return true // No lock = already unlocked
    };

    let unlock_time = *unlock_time_opt.borrow();
    current_time >= unlock_time
}

// === Public Functions ===

/// Creates a new commitment proposal with price-based tiers
public fun create_commitment_proposal<AssetType>(
    deposit: Coin<AssetType>,
    tiers: vector<PriceTier>,
    cancelable_before_trading: bool,
    trading_start: u64,
    trading_end: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): CommitmentProposal<AssetType> {
    let committed_amount = deposit.value();
    let current_time = clock.timestamp_ms();

    // Validate time parameters
    assert!(trading_start < trading_end, EInvalidTradingPeriod);
    assert!(trading_start >= current_time, ETradingStartInPast);

    // Validate tiers
    assert!(tiers.length() > 0 && tiers.length() <= MAX_TIERS, EInvalidTierConfiguration);

    // Extract tier thresholds and amounts for validation
    let mut thresholds = vector::empty<u128>();
    let mut amounts = vector::empty<u64>();
    let mut i = 0;
    while (i < tiers.length()) {
        let tier = tiers.borrow(i);
        thresholds.push_back(tier.twap_threshold);
        amounts.push_back(tier.lock_amount);
        i = i + 1;
    };

    // Validate tiers are sorted by price
    assert!(validate_tiers_sorted(&thresholds), ETiersNotSorted);

    // Validate tier amounts don't exceed total committed
    assert!(validate_tier_amounts(&amounts, committed_amount), ETierAmountsExceedTotal);

    let id = object::new(ctx);
    let proposal_id = id.to_inner();

    let proposal = CommitmentProposal {
        id,
        proposer: ctx.sender(),
        withdrawal_recipient: ctx.sender(),
        committed_amount,
        committed_coins: deposit.into_balance(),
        tiers,
        tier_reached: option::none(),
        locked_amount: 0,
        unlock_time: option::none(),
        withdrawn: false,
        cancelable_before_trading,
        trading_started: false,
        proposal_state: STATE_PENDING,
        created_at: current_time,
        trading_start,
        trading_end,
        market_proposal_id: option::none(),
    };

    event::emit(CommitmentProposalCreated {
        proposal_id,
        proposer: ctx.sender(),
        committed_amount,
        tier_count: tiers.length(),
        cancelable_before_trading,
        created_at: current_time,
    });

    proposal
}

/// Marks trading as started (called when market opens)
public fun mark_trading_started<AssetType>(proposal: &mut CommitmentProposal<AssetType>) {
    proposal.trading_started = true;
    proposal.proposal_state = STATE_TRADING;
}

/// Executes commitment based on TWAP from ACCEPT market
/// Returns coins to refund to proposer (unlocked portion)
public fun execute_commitment<AssetType>(
    proposal: &mut CommitmentProposal<AssetType>,
    accept_market_twap: u128, // TWAP from conditional ACCEPT market
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    assert!(
        proposal.proposal_state == STATE_TRADING ||
        proposal.proposal_state == STATE_PENDING,
        EInvalidState,
    );

    // Find highest tier reached
    let mut tier_thresholds = vector::empty<u128>();
    let mut i = 0;
    while (i < proposal.tiers.length()) {
        let tier = proposal.tiers.borrow(i);
        tier_thresholds.push_back(tier.twap_threshold);
        i = i + 1;
    };

    let (tier_index, tier_found) = find_highest_tier(
        accept_market_twap,
        &tier_thresholds,
    );

    let current_time = clock.timestamp_ms();

    if (tier_found) {
        // Tier reached! Lock tokens
        let tier = proposal.tiers.borrow(tier_index);

        proposal.tier_reached = option::some(tier_index);
        proposal.locked_amount = tier.lock_amount;
        proposal.unlock_time = option::some(current_time + tier.lock_duration_ms);
        proposal.proposal_state = STATE_PASSED;

        event::emit(CommitmentExecuted {
            proposal_id: object::id(proposal),
            tier_reached: tier_index,
            locked_amount: tier.lock_amount,
            lock_duration_ms: tier.lock_duration_ms,
            unlock_time: current_time + tier.lock_duration_ms,
        });

        // Return unlocked portion to proposer
        let to_return = proposal.committed_amount - tier.lock_amount;
        if (to_return > 0) {
            let refund = proposal.committed_coins.split(to_return);
            coin::from_balance(refund, ctx)
        } else {
            coin::zero(ctx)
        }
    } else {
        // No tier reached - return all tokens
        proposal.proposal_state = STATE_FAILED;
        let all_coins = proposal.committed_coins.withdraw_all();
        coin::from_balance(all_coins, ctx)
    }
}

/// Cancels commitment before trading starts (if cancelable)
/// Returns all escrowed tokens
public fun cancel_commitment<AssetType>(
    proposal: &mut CommitmentProposal<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    assert!(ctx.sender() == proposal.proposer, ENotProposer);

    // Check cancelability
    let cancelable = can_cancel(
        if (proposal.cancelable_before_trading) {
            CANCELABLE_BEFORE_START
        } else {
            CANCELABLE_NEVER
        },
        proposal.trading_start,
        clock.timestamp_ms(),
        proposal.trading_started,
    );

    assert!(cancelable, ECannotCancelAfterTrading);

    let returned_amount = proposal.committed_amount;
    let returned_coins = proposal.committed_coins.withdraw_all();

    // Update state to reflect cancellation
    proposal.committed_amount = 0;
    proposal.proposal_state = STATE_CANCELLED;

    event::emit(CommitmentCancelled {
        proposal_id: object::id(proposal),
        returned_amount,
        cancelled_at: clock.timestamp_ms(),
    });

    coin::from_balance(returned_coins, ctx)
}

/// Withdraws locked tokens after unlock time
public fun withdraw_locked_commitment<AssetType>(
    proposal: &mut CommitmentProposal<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    assert!(ctx.sender() == proposal.proposer, ENotProposer);
    assert!(proposal.tier_reached.is_some(), ENotLocked);
    assert!(!proposal.withdrawn, EAlreadyWithdrawn);

    // Check unlock
    assert!(is_unlocked(&proposal.unlock_time, clock.timestamp_ms()), EStillLocked);

    let amount = proposal.committed_coins.value();
    let unlocked_coins = proposal.committed_coins.withdraw_all();

    // Mark as withdrawn BEFORE returning coins (reentrancy protection)
    proposal.withdrawn = true;

    event::emit(CommitmentWithdrawn {
        proposal_id: object::id(proposal),
        recipient: proposal.withdrawal_recipient,
        amount,
        withdrawn_at: clock.timestamp_ms(),
    });

    coin::from_balance(unlocked_coins, ctx)
}

/// Updates withdrawal recipient (proposer can change who receives unlocked tokens)
public fun update_withdrawal_recipient<AssetType>(
    proposal: &mut CommitmentProposal<AssetType>,
    new_recipient: address,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == proposal.proposer, ENotProposer);

    let old_recipient = proposal.withdrawal_recipient;
    proposal.withdrawal_recipient = new_recipient;

    event::emit(RecipientUpdated {
        proposal_id: object::id(proposal),
        old_recipient,
        new_recipient,
    });
}

/// Links this commitment proposal to its conditional market proposal
public fun set_market_proposal_id<AssetType>(
    proposal: &mut CommitmentProposal<AssetType>,
    market_proposal_id: ID,
) {
    proposal.market_proposal_id = option::some(market_proposal_id);
}

// === Getters ===

public fun committed_amount<AssetType>(proposal: &CommitmentProposal<AssetType>): u64 {
    proposal.committed_amount
}

public fun locked_amount<AssetType>(proposal: &CommitmentProposal<AssetType>): u64 {
    proposal.locked_amount
}

public fun tier_reached<AssetType>(proposal: &CommitmentProposal<AssetType>): Option<u64> {
    proposal.tier_reached
}

public fun unlock_time<AssetType>(proposal: &CommitmentProposal<AssetType>): Option<u64> {
    proposal.unlock_time
}

public fun proposer<AssetType>(proposal: &CommitmentProposal<AssetType>): address {
    proposal.proposer
}

public fun withdrawal_recipient<AssetType>(proposal: &CommitmentProposal<AssetType>): address {
    proposal.withdrawal_recipient
}

public fun is_cancelable_before_trading<AssetType>(proposal: &CommitmentProposal<AssetType>): bool {
    proposal.cancelable_before_trading
}

public fun proposal_state<AssetType>(proposal: &CommitmentProposal<AssetType>): u8 {
    proposal.proposal_state
}

public fun tiers<AssetType>(proposal: &CommitmentProposal<AssetType>): &vector<PriceTier> {
    &proposal.tiers
}

public fun tier_info(tier: &PriceTier): (u128, u64, u64) {
    (tier.twap_threshold, tier.lock_amount, tier.lock_duration_ms)
}
