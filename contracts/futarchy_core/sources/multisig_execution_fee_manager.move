module futarchy_core::multisig_execution_fee_manager;

use sui::{
    coin::{Self, Coin},
    balance::{Self, Balance},
    sui::SUI,
    clock::Clock,
    event,
};

// === Errors ===
const EInvalidFeeAmount: u64 = 0;

// === Constants ===
const FIXED_EXECUTOR_REWARD: u64 = 1_000_000; // 0.001 SUI fixed reward for executors

// === Structs ===

/// Manages execution fees for multisig intent batches
/// Unlike ProposalFeeManager which holds fees during queue waiting,
/// this collects fees at execution time and immediately distributes them
public struct MultisigExecutionFeeManager has key, store {
    id: UID,
    /// Total fees collected by the protocol from intent executions
    protocol_revenue: Balance<SUI>,
    /// Accumulated rewards pool for executors
    executor_rewards: Balance<SUI>,
}

// === Events ===

public struct ExecutionFeeCollected has copy, drop {
    multisig_id: ID,
    intent_count: u64,
    total_fee: u64,
    executor_reward: u64,
    protocol_share: u64,
    timestamp: u64,
}

// === Public Functions ===

/// Creates a new MultisigExecutionFeeManager
public fun new(ctx: &mut TxContext): MultisigExecutionFeeManager {
    MultisigExecutionFeeManager {
        id: object::new(ctx),
        protocol_revenue: balance::zero(),
        executor_rewards: balance::zero(),
    }
}

/// Called when a multisig intent batch is executed
/// Collects fee and splits it between executor reward and protocol revenue
/// Fee structure:
/// - Base fee per intent in the batch
/// - Executor gets fixed reward (FIXED_EXECUTOR_REWARD)
/// - Protocol gets the rest
public fun collect_execution_fee(
    manager: &mut MultisigExecutionFeeManager,
    multisig_id: ID,
    intent_count: u64,
    fee_coin: Coin<SUI>,
    clock: &Clock,
    ctx: &TxContext
) {
    let total_fee = fee_coin.value();
    assert!(total_fee > 0, EInvalidFeeAmount);

    let mut fee_balance = fee_coin.into_balance();

    // Give fixed reward to executor, rest goes to protocol
    let executor_reward = if (total_fee >= FIXED_EXECUTOR_REWARD) {
        FIXED_EXECUTOR_REWARD
    } else {
        total_fee // If fee is less than fixed reward, give entire fee to executor
    };

    let protocol_share = total_fee - executor_reward;

    // Split the fee
    if (executor_reward > 0) {
        manager.executor_rewards.join(fee_balance.split(executor_reward));
    };

    if (protocol_share > 0) {
        manager.protocol_revenue.join(fee_balance);
    } else {
        fee_balance.destroy_zero();
    };

    event::emit(ExecutionFeeCollected {
        multisig_id,
        intent_count,
        total_fee,
        executor_reward,
        protocol_share,
        timestamp: clock.timestamp_ms(),
    });
}

/// Called by executor to claim their accumulated rewards
public fun claim_executor_rewards(
    manager: &mut MultisigExecutionFeeManager,
    amount: u64,
    ctx: &mut TxContext
): Coin<SUI> {
    assert!(amount > 0, EInvalidFeeAmount);
    assert!(manager.executor_rewards.value() >= amount, EInvalidFeeAmount);
    coin::from_balance(manager.executor_rewards.split(amount), ctx)
}

/// Gets the current protocol revenue
public fun protocol_revenue(manager: &MultisigExecutionFeeManager): u64 {
    manager.protocol_revenue.value()
}

/// Gets the current executor rewards pool
public fun executor_rewards(manager: &MultisigExecutionFeeManager): u64 {
    manager.executor_rewards.value()
}

/// Withdraws accumulated protocol revenue
/// Should be called by the protocol admin DAO
public fun withdraw_protocol_revenue(
    manager: &mut MultisigExecutionFeeManager,
    amount: u64,
    ctx: &mut TxContext
): Coin<SUI> {
    assert!(amount > 0, EInvalidFeeAmount);
    assert!(manager.protocol_revenue.value() >= amount, EInvalidFeeAmount);
    coin::from_balance(manager.protocol_revenue.split(amount), ctx)
}

/// Calculate the execution fee for a batch of intents
/// Base fee multiplied by number of intents
public fun calculate_execution_fee(
    base_fee_per_intent: u64,
    intent_count: u64,
): u64 {
    base_fee_per_intent * intent_count
}
