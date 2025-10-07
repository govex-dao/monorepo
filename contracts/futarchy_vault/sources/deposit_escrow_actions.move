/// Generic deposit escrow actions for Account Protocol
/// Works with any Account<Config> type (DAOs, multisigs, etc.)
/// Accept deposited coins into vault
module futarchy_vault::deposit_escrow_actions;

use std::string::String;
use std::option::Option;
use sui::bcs::{Self, BCS};
use sui::coin::Coin;
use sui::clock::Clock;
use sui::object::{Self, ID};
use sui::tx_context::TxContext;
use account_protocol::{
    executable::{Self, Executable},
    intents::{Self, Expired},
    account::Account,
    version_witness::VersionWitness,
    bcs_validation,
};
use account_actions::vault;
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_vault::deposit_escrow::{Self, DepositEscrow};
use futarchy_core::resource_requests::{Self, ResourceRequest, ResourceReceipt};
use futarchy_core::{action_types, action_validation};

// === Errors ===
const EEscrowIdMismatch: u64 = 0;
const EInsufficientDeposit: u64 = 1;

// === Action Struct ===

/// The ONLY action - accept escrowed deposit into vault
/// User deposits coins when intent is created (via ResourceRequest)
/// This action executes if proposal passes
public struct AcceptDepositAction has store, copy, drop {
    /// ID of the escrow holding the deposit
    escrow_id: ID,
    /// Target vault name
    vault_name: String,
}

// === Constructor ===

public fun new_accept_deposit_action(
    escrow_id: ID,
    vault_name: String,
): AcceptDepositAction {
    AcceptDepositAction { escrow_id, vault_name }
}

// === Execution ===

/// Execute accept deposit - move coins from escrow to vault
public fun do_accept_deposit<Config: store, CoinType: drop, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    _version: VersionWitness,
    _witness: IW,
    escrow: &mut DepositEscrow<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get spec and validate type
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::AcceptDeposit>(spec);

    // Deserialize
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);

    let escrow_id = object::id_from_address(bcs::peel_address(&mut bcs));
    let vault_name = bcs::peel_vec_u8(&mut bcs).to_string();

    bcs_validation::validate_all_bytes_consumed(bcs);

    let action = AcceptDepositAction { escrow_id, vault_name };

    // Validate escrow ID matches
    assert!(object::id(escrow) == action.escrow_id, EEscrowIdMismatch);

    executable::increment_action_idx(executable);

    // Accept deposit from escrow (withdraws all coins)
    let deposit_coin = deposit_escrow::accept_deposit(escrow, clock, ctx);

    // Deposit into vault
    vault::deposit_permissionless(account, action.vault_name, deposit_coin);
}

// === Cleanup ===

/// Delete expired accept deposit intent
public fun delete_accept_deposit(expired: &mut Expired) {
    let spec = intents::remove_action_spec(expired);
    let _ = spec;
}
