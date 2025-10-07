/// Multisig fee collection - bridges shared FeeManager and owned FeeState
///
/// Architecture:
/// - FeeManager (shared) = Historical records + fee collection
/// - FeeState (owned in Account) = Fast operational checks
///
/// This module ensures both states stay in sync during fee payment
module futarchy_multisig::fee_collection;

use std::type_name::TypeName;
use sui::clock::Clock;
use sui::coin::Coin;
use account_protocol::account::Account;
use futarchy_multisig::weighted_multisig::WeightedMultisig;
use futarchy_multisig::fee_state;
use futarchy_markets::fee::{Self, FeeManager};

/// Atomic wrapper that updates BOTH shared FeeManager and owned FeeState
/// This ensures consistency between historical records and operational state
///
/// Flow:
/// 1. Collect fee from shared FeeManager (creates history record)
/// 2. If successful, update owned FeeState (enables zero-contention checking)
/// 3. Both updates happen atomically in same transaction
///
/// Returns: (remaining_funds, periods_collected)
public fun pay_multisig_fee_and_update_state<StableType>(
    account: &mut Account<WeightedMultisig>,
    fee_manager: &mut FeeManager,
    coin_type: TypeName,
    all_coin_types: vector<TypeName>,
    payment: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<StableType>, u64) {
    let multisig_id = object::id(account);

    // Update shared FeeManager state
    let (remaining_funds, periods_collected) = fee::collect_multisig_fee(
        fee_manager,
        multisig_id,
        coin_type,
        payment,
        all_coin_types,
        clock,
        ctx,
    );

    // If payment was successful, update owned FeeState
    if (periods_collected > 0) {
        fee_state::mark_fees_paid(account, periods_collected, clock);
    };

    (remaining_funds, periods_collected)
}
