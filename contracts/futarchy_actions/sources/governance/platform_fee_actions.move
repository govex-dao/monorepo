module futarchy_actions::platform_fee_actions;

use sui::{
    coin::{Self, Coin},
    sui::SUI,
    clock::Clock,
    transfer,
    tx_context::{Self, TxContext},
    object::{Self, ID},
    bcs::{Self, BCS},
};
use std::type_name;
use std::string::{Self, String};

use account_protocol::{
    account::{Self, Account, Auth},
    executable::{Self, Executable},
    version_witness::VersionWitness,
    intents::{Self, Intent, Expired},
    bcs_validation,
};
use account_actions::vault;
use futarchy_core::{
    version,
    futarchy_config::{Self, FutarchyConfig},
    dao_payment_tracker::{Self, DaoPaymentTracker},
    action_validation,
    action_types,
};
use futarchy_markets::fee::{Self, FeeManager};

// === Aliases ===
use account_protocol::intents as protocol_intents;

// === Errors ===
const EInsufficientVaultBalance: u64 = 0;
const EFeeCollectionFailed: u64 = 1;
const EWrongAction: u64 = 2;
const EUnsupportedActionVersion: u64 = 3;

// === Actions ===

/// Action to collect platform fee from DAO vault
public struct CollectPlatformFeeAction has store, drop, copy {
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
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // CRITICAL - Type check BEFORE deserialization
    action_validation::assert_action_type<action_types::PlatformFeeWithdraw>(spec);

    // Get action data
    let action_data = protocol_intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Safe deserialization with BCS reader
    let mut reader = bcs::new(*action_data);
    let vault_name = string::utf8(reader.peel_vec_u8());
    let max_amount = reader.peel_u64();

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Create action for use (will be destroyed later)
    let action = CollectPlatformFeeAction { vault_name, max_amount };

    let dao_id = object::id(account);

    // Collect fee or accumulate debt
    let sui_type = type_name::with_defining_ids<SUI>();
    let (remaining, _periods_collected) = fee::collect_dao_platform_fee_with_dao_coin(
        fee_manager,
        payment_tracker,
        dao_id,
        sui_type,
        payment_coin,
        clock,
        ctx
    );

    // Increment action index
    executable::increment_action_idx(executable);

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
    let sui_type = type_name::with_defining_ids<SUI>();
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

// === Destruction Functions ===

/// Destroy a CollectPlatformFeeAction
public fun destroy_collect_platform_fee(action: CollectPlatformFeeAction) {
    let CollectPlatformFeeAction { vault_name: _, max_amount: _ } = action;
}

// === Cleanup Functions ===

/// Delete action from expired intent
public fun delete_collect_platform_fee(expired: &mut Expired) {
    let CollectPlatformFeeAction { vault_name: _, max_amount: _ } = expired.remove_action();
}

// === Intent Creation Functions (with serialize-then-destroy pattern) ===

/// Add a CollectPlatformFee action to an intent
public fun new_collect_platform_fee<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    vault_name: String,
    max_amount: u64,
    intent_witness: IW,
) {
    let action = CollectPlatformFeeAction { vault_name, max_amount };
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        action_types::platform_fee_withdraw(),
        action_data,
        intent_witness
    );
    destroy_collect_platform_fee(action);
}

// === Deserialization Functions ===

/// Deserialize CollectPlatformFeeAction from bytes
public(package) fun collect_platform_fee_action_from_bytes(bytes: vector<u8>): CollectPlatformFeeAction {
    let mut bcs = bcs::new(bytes);
    CollectPlatformFeeAction {
        vault_name: string::utf8(bcs.peel_vec_u8()),
        max_amount: bcs.peel_u64(),
    }
}