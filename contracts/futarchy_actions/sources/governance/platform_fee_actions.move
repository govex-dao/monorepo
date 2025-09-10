module futarchy_actions::platform_fee_actions;

use sui::{
    coin::{Self, Coin},
    sui::SUI,
    clock::Clock,
    transfer,
    tx_context,
};
use std::type_name;
use std::string::String;

use account_protocol::{
    account::{Self, Account, Auth},
    executable::Executable,
    version_witness::VersionWitness,
};
use account_actions::vault;
use futarchy_core::{
    version,
    futarchy_config::{Self, FutarchyConfig},
    dao_payment_tracker::{Self, DaoPaymentTracker},
};
use futarchy_markets::fee::{Self, FeeManager};

// === Errors ===
const EInsufficientVaultBalance: u64 = 0;
const EFeeCollectionFailed: u64 = 1;

// === Actions ===

/// Action to collect platform fee from DAO vault
public struct CollectPlatformFeeAction has store {
    vault_name: String,
    max_amount: u64, // Maximum amount to withdraw for fee payment
}

// === Public Functions ===

/// Create action to collect platform fee
public fun new_collect_platform_fee(
    vault_name: String,
    max_amount: u64,
): CollectPlatformFeeAction {
    CollectPlatformFeeAction {
        vault_name,
        max_amount,
    }
}

/// Execute platform fee collection with provided coin
/// This function expects the coin to be provided by the caller
/// It will pay the fee and return any remaining funds
public fun do_collect_platform_fee<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    fee_manager: &mut FeeManager,
    payment_tracker: &mut DaoPaymentTracker,
    mut payment_coin: Coin<SUI>,
    clock: &Clock,
    version_witness: VersionWitness,
    intent_witness: IW,
    ctx: &mut TxContext,
): Coin<SUI> {
    let action: &CollectPlatformFeeAction = executable.next_action(intent_witness);
    let dao_id = object::id(account);
    
    // Collect fee or accumulate debt  
    let sui_type = type_name::get<SUI>();
    let (remaining, _periods_collected) = fee::collect_dao_platform_fee_with_dao_coin(
        fee_manager,
        payment_tracker,
        dao_id,
        sui_type,
        payment_coin,
        clock,
        ctx
    );
    
    remaining
}

/// Permissionless function to trigger fee collection for any DAO
/// Anyone can call this to ensure DAOs pay their fees on time
public entry fun trigger_fee_collection(
    account: &mut Account<FutarchyConfig>,
    fee_manager: &mut FeeManager,
    payment_tracker: &mut DaoPaymentTracker,
    payment_coin: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let dao_id = object::id(account);
    
    // Collect fee or accumulate debt using the provided payment coin
    let sui_type = type_name::get<SUI>();
    let (remaining, _) = fee::collect_dao_platform_fee_with_dao_coin(
        fee_manager,
        payment_tracker,
        dao_id,
        sui_type,
        payment_coin,
        clock,
        ctx
    );
    
    // Return remainder to sender
    if (remaining.value() > 0) {
        transfer::public_transfer(remaining, tx_context::sender(ctx));
    } else {
        remaining.destroy_zero();
    };
}

/// Witness for permissionless fee collection
public struct TriggerFeeCollectionWitness has drop {}

/// Delete action from expired intent
public fun delete_collect_platform_fee(expired: &mut account_protocol::intents::Expired) {
    let CollectPlatformFeeAction { vault_name: _, max_amount: _ } = expired.remove_action();
}