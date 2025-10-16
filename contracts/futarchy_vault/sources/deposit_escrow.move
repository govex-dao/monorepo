/// Deposit Escrow - Hold user deposits until proposal outcome
/// User deposits coins when creating intent
/// If proposal passes → AcceptDepositAction moves coins to vault
/// If proposal fails → Anyone can crank to refund depositor + claim gas reward
module futarchy_vault::deposit_escrow;

use std::option::{Self, Option};
use std::string::String;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, ID, UID};
use sui::transfer;
use sui::tx_context::TxContext;

// === Errors ===
const EInsufficientDeposit: u64 = 0;
const EAlreadyExecuted: u64 = 1;
const ENotDepositor: u64 = 2;
const EProposalStillActive: u64 = 3;
const EInsufficientGasReward: u64 = 4;
const EAlreadyCranked: u64 = 5;

// Public error code accessors for testing
public fun e_insufficient_deposit(): u64 { EInsufficientDeposit }

public fun e_already_executed(): u64 { EAlreadyExecuted }

public fun e_not_depositor(): u64 { ENotDepositor }

public fun e_proposal_still_active(): u64 { EProposalStillActive }

public fun e_insufficient_gas_reward(): u64 { EInsufficientGasReward }

public fun e_already_cranked(): u64 { EAlreadyCranked }

// === Constants ===
const MIN_DEPOSIT_AMOUNT: u64 = 1_000_000; // 0.001 token
const MIN_GAS_REWARD: u64 = 100_000; // 0.0001 token

// === Events ===

public struct DepositEscrowCreated has copy, drop {
    escrow_id: ID,
    depositor: address,
    amount: u64,
    gas_reward: u64,
    proposal_id: Option<ID>,
    description: String,
}

public struct DepositAccepted has copy, drop {
    escrow_id: ID,
    amount: u64,
    timestamp: u64,
}

public struct DepositCranked has copy, drop {
    escrow_id: ID,
    depositor: address,
    cranker: address,
    refund_amount: u64,
    gas_reward: u64,
    timestamp: u64,
}

// === Structs ===

/// Escrow holding user deposit until proposal outcome
public struct DepositEscrow<phantom CoinType> has key, store {
    id: UID,
    // Depositor info
    depositor: address,
    // Escrowed coins
    deposit_amount: u64,
    escrowed_coins: Balance<CoinType>,
    // Gas reward for cranker (deducted from deposit if failed)
    gas_reward: u64,
    // Optional proposal ID this deposit is tied to
    proposal_id: Option<ID>,
    // Execution state
    executed: bool, // Moved to vault
    cranked: bool, // Refunded to depositor
    // Timestamps
    created_at: u64,
    deadline: u64, // After this, can be cranked
    // Metadata
    description: String,
}

// === Constructor ===

/// Create deposit escrow - user deposits coins upfront
public fun create_deposit_escrow<CoinType>(
    depositor: address,
    deposit_coins: Coin<CoinType>,
    gas_reward: u64,
    proposal_id: Option<ID>,
    deadline: u64,
    description: String,
    clock: &Clock,
    ctx: &mut TxContext,
): DepositEscrow<CoinType> {
    let deposit_amount = coin::value(&deposit_coins);

    assert!(deposit_amount >= MIN_DEPOSIT_AMOUNT, EInsufficientDeposit);
    assert!(gas_reward >= MIN_GAS_REWARD && gas_reward < deposit_amount, EInsufficientGasReward);

    let id = object::new(ctx);
    let created_at = clock.timestamp_ms();

    event::emit(DepositEscrowCreated {
        escrow_id: object::uid_to_inner(&id),
        depositor,
        amount: deposit_amount,
        gas_reward,
        proposal_id,
        description,
    });

    DepositEscrow {
        id,
        depositor,
        deposit_amount,
        escrowed_coins: coin::into_balance(deposit_coins),
        gas_reward,
        proposal_id,
        executed: false,
        cranked: false,
        created_at,
        deadline,
        description,
    }
}

// === Execution ===

/// Accept deposit into vault (called when proposal passes)
public fun accept_deposit<CoinType: drop>(
    escrow: &mut DepositEscrow<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    assert!(!escrow.executed, EAlreadyExecuted);
    assert!(!escrow.cranked, EAlreadyCranked);

    // Withdraw all coins from escrow
    let deposit_coin = coin::from_balance(
        balance::withdraw_all(&mut escrow.escrowed_coins),
        ctx,
    );

    escrow.executed = true;

    event::emit(DepositAccepted {
        escrow_id: object::uid_to_inner(&escrow.id),
        amount: escrow.deposit_amount,
        timestamp: clock.timestamp_ms(),
    });

    deposit_coin
}

// === Crank / Cleanup ===

/// Crank failed deposit - refund to depositor, gas reward to cranker
/// Anyone can call this after deadline if proposal failed
public fun crank_failed_deposit<CoinType: drop>(
    escrow: &mut DepositEscrow<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(!escrow.executed, EAlreadyExecuted);
    assert!(!escrow.cranked, EAlreadyCranked);
    assert!(clock.timestamp_ms() >= escrow.deadline, EProposalStillActive);

    let cranker = tx_context::sender(ctx);

    // Split gas reward for cranker
    let gas_reward_coin = coin::from_balance(
        balance::split(&mut escrow.escrowed_coins, escrow.gas_reward),
        ctx,
    );

    // Remaining goes back to depositor
    let refund_coin = coin::from_balance(
        balance::withdraw_all(&mut escrow.escrowed_coins),
        ctx,
    );

    let refund_amount = coin::value(&refund_coin);

    escrow.cranked = true;

    event::emit(DepositCranked {
        escrow_id: object::uid_to_inner(&escrow.id),
        depositor: escrow.depositor,
        cranker,
        refund_amount,
        gas_reward: escrow.gas_reward,
        timestamp: clock.timestamp_ms(),
    });

    // Transfer rewards
    transfer::public_transfer(gas_reward_coin, cranker);
    transfer::public_transfer(refund_coin, escrow.depositor);
}

// === Getters ===

public fun get_depositor<CoinType>(escrow: &DepositEscrow<CoinType>): address {
    escrow.depositor
}

public fun get_deposit_amount<CoinType>(escrow: &DepositEscrow<CoinType>): u64 {
    escrow.deposit_amount
}

public fun get_gas_reward<CoinType>(escrow: &DepositEscrow<CoinType>): u64 {
    escrow.gas_reward
}

public fun is_executed<CoinType>(escrow: &DepositEscrow<CoinType>): bool {
    escrow.executed
}

public fun is_cranked<CoinType>(escrow: &DepositEscrow<CoinType>): bool {
    escrow.cranked
}

public fun get_deadline<CoinType>(escrow: &DepositEscrow<CoinType>): u64 {
    escrow.deadline
}
