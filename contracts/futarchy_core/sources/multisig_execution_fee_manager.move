// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_core::multisig_execution_fee_manager;

use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;

// === Errors ===
const EInvalidFeeAmount: u64 = 0;

// === Structs ===

/// Manages execution fees for multisig intent batches
/// Unlike ProposalFeeManager which holds fees during queue waiting,
/// this collects fees at execution time and all fees go to protocol revenue
public struct MultisigExecutionFeeManager has key, store {
    id: UID,
    /// Total fees collected by the protocol from intent executions
    protocol_revenue: Balance<SUI>,
}

// === Events ===

public struct ExecutionFeeCollected has copy, drop {
    multisig_id: ID,
    intent_count: u64,
    total_fee: u64,
    protocol_share: u64,
    timestamp: u64,
}

// === Public Functions ===

/// Creates a new MultisigExecutionFeeManager
public fun new(ctx: &mut TxContext): MultisigExecutionFeeManager {
    MultisigExecutionFeeManager {
        id: object::new(ctx),
        protocol_revenue: balance::zero(),
    }
}

/// Called when a multisig intent batch is executed
/// Collects fee and sends it all to protocol revenue
/// Fee structure:
/// - Base fee per intent in the batch
/// - All fees go to protocol revenue
public fun collect_execution_fee(
    manager: &mut MultisigExecutionFeeManager,
    multisig_id: ID,
    intent_count: u64,
    fee_coin: Coin<SUI>,
    clock: &Clock,
) {
    let total_fee = fee_coin.value();
    assert!(total_fee > 0, EInvalidFeeAmount);

    let fee_balance = fee_coin.into_balance();

    // All fees go to protocol revenue
    manager.protocol_revenue.join(fee_balance);

    event::emit(ExecutionFeeCollected {
        multisig_id,
        intent_count,
        total_fee,
        protocol_share: total_fee,
        timestamp: clock.timestamp_ms(),
    });
}

/// Gets the current protocol revenue
public fun protocol_revenue(manager: &MultisigExecutionFeeManager): u64 {
    manager.protocol_revenue.value()
}

/// Withdraws accumulated protocol revenue
/// Should be called by the protocol admin DAO
public fun withdraw_protocol_revenue(
    manager: &mut MultisigExecutionFeeManager,
    amount: u64,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert!(amount > 0, EInvalidFeeAmount);
    assert!(manager.protocol_revenue.value() >= amount, EInvalidFeeAmount);
    coin::from_balance(manager.protocol_revenue.split(amount), ctx)
}

/// Calculate the execution fee for a batch of intents
/// Base fee multiplied by number of intents
public fun calculate_execution_fee(base_fee_per_intent: u64, intent_count: u64): u64 {
    base_fee_per_intent * intent_count
}
