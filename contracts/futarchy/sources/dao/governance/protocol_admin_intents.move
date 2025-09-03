/// Protocol admin intents for transferring admin capabilities to a futarchy DAO
/// This module enables the initial migration of protocol admin caps to be governed by a DAO
module futarchy::protocol_admin_intents;

// === Imports ===
use std::string::String;
use sui::{
    transfer::Receiving,
    object::ID,
};
use account_protocol::{
    account::{Self, Account, Auth},
    executable::Executable,
    owned,
    intents::{Self, Params},
    intent_interface,
};
use futarchy::version;
use futarchy::{
    factory::{FactoryOwnerCap, ValidatorAdminCap},
    fee::FeeAdminCap,
    futarchy_config::FutarchyConfig,
};

// === Aliases ===
use fun intent_interface::process_intent as Account.process_intent;

// === Intent Witness Types ===

/// Intent to accept the FactoryOwnerCap into the DAO's custody
public struct AcceptFactoryOwnerCapIntent() has copy, drop;

/// Intent to accept the FeeAdminCap into the DAO's custody  
public struct AcceptFeeAdminCapIntent() has copy, drop;

/// Intent to accept the ValidatorAdminCap into the DAO's custody
public struct AcceptValidatorAdminCapIntent() has copy, drop;

// === Request Functions ===

/// Request to accept the FactoryOwnerCap into the DAO's custody
public fun request_accept_factory_owner_cap<Outcome: store>(
    auth: Auth,
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: Outcome,
    cap_id: ID,
    ctx: &mut TxContext,
) {
    account.verify(auth);
    params.assert_single_execution();
    
    intent_interface::build_intent!(
        account,
        params,
        outcome,
        b"Accept FactoryOwnerCap into protocol DAO custody".to_string(),
        version::current(),
        AcceptFactoryOwnerCapIntent(),
        ctx,
        |intent, iw| {
            owned::new_withdraw(intent, account, cap_id, iw);
        }
    );
}

/// Request to accept the FeeAdminCap into the DAO's custody
public fun request_accept_fee_admin_cap<Outcome: store>(
    auth: Auth,
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: Outcome,
    cap_id: ID,
    ctx: &mut TxContext,
) {
    account.verify(auth);
    params.assert_single_execution();
    
    intent_interface::build_intent!(
        account,
        params,
        outcome,
        b"Accept FeeAdminCap into protocol DAO custody".to_string(),
        version::current(),
        AcceptFeeAdminCapIntent(),
        ctx,
        |intent, iw| {
            owned::new_withdraw(intent, account, cap_id, iw);
        }
    );
}

/// Request to accept the ValidatorAdminCap into the DAO's custody
public fun request_accept_validator_admin_cap<Outcome: store>(
    auth: Auth,
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: Outcome,
    cap_id: ID,
    ctx: &mut TxContext,
) {
    account.verify(auth);
    params.assert_single_execution();
    
    intent_interface::build_intent!(
        account,
        params,
        outcome,
        b"Accept ValidatorAdminCap into protocol DAO custody".to_string(),
        version::current(),
        AcceptValidatorAdminCapIntent(),
        ctx,
        |intent, iw| {
            owned::new_withdraw(intent, account, cap_id, iw);
        }
    );
}

// === Execution Functions ===

/// Execute the intent to accept FactoryOwnerCap
public fun execute_accept_factory_owner_cap<Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    receiving: Receiving<FactoryOwnerCap>,
) {
    account.process_intent!(
        executable,
        version::current(),
        AcceptFactoryOwnerCapIntent(),
        |executable, iw| {
            let cap = owned::do_withdraw(executable, account, receiving, iw);
            
            // Store the cap in the account's managed assets
            account::add_managed_asset(
                account,
                b"protocol:factory_owner_cap".to_string(),
                cap,
                version::current()
            );
        }
    );
}

/// Execute the intent to accept FeeAdminCap
public fun execute_accept_fee_admin_cap<Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    receiving: Receiving<FeeAdminCap>,
) {
    account.process_intent!(
        executable,
        version::current(),
        AcceptFeeAdminCapIntent(),
        |executable, iw| {
            let cap = owned::do_withdraw(executable, account, receiving, iw);
            
            // Store the cap in the account's managed assets
            account::add_managed_asset(
                account,
                b"protocol:fee_admin_cap".to_string(),
                cap,
                version::current()
            );
        }
    );
}

/// Execute the intent to accept ValidatorAdminCap
public fun execute_accept_validator_admin_cap<Outcome: store>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    receiving: Receiving<ValidatorAdminCap>,
) {
    account.process_intent!(
        executable,
        version::current(),
        AcceptValidatorAdminCapIntent(),
        |executable, iw| {
            let cap = owned::do_withdraw(executable, account, receiving, iw);
            
            // Store the cap in the account's managed assets
            account::add_managed_asset(
                account,
                b"protocol:validator_admin_cap".to_string(),
                cap,
                version::current()
            );
        }
    );
}

// === Migration Helper Functions ===

/// One-time migration function to transfer all admin caps to the protocol DAO
/// This should be called by the current admin cap holders to transfer control
public entry fun migrate_admin_caps_to_dao(
    account: &mut Account<FutarchyConfig>,
    factory_cap: FactoryOwnerCap,
    fee_cap: FeeAdminCap,
    validator_cap: ValidatorAdminCap,
    ctx: &mut TxContext,
) {
    // Store all caps in the DAO's account
    account::add_managed_asset(
        account,
        b"protocol:factory_owner_cap".to_string(),
        factory_cap,
        version::current()
    );
    
    account::add_managed_asset(
        account,
        b"protocol:fee_admin_cap".to_string(),
        fee_cap,
        version::current()
    );
    
    account::add_managed_asset(
        account,
        b"protocol:validator_admin_cap".to_string(),
        validator_cap,
        version::current()
    );
}

/// Transfer a specific admin cap to the protocol DAO (for gradual migration)
public entry fun migrate_factory_cap_to_dao(
    account: &mut Account<FutarchyConfig>,
    cap: FactoryOwnerCap,
    ctx: &mut TxContext,
) {
    account::add_managed_asset(
        account,
        b"protocol:factory_owner_cap".to_string(),
        cap,
        version::current()
    );
}

public entry fun migrate_fee_cap_to_dao(
    account: &mut Account<FutarchyConfig>,
    cap: FeeAdminCap,
    ctx: &mut TxContext,
) {
    account::add_managed_asset(
        account,
        b"protocol:fee_admin_cap".to_string(),
        cap,
        version::current()
    );
}

public entry fun migrate_validator_cap_to_dao(
    account: &mut Account<FutarchyConfig>,
    cap: ValidatorAdminCap,
    ctx: &mut TxContext,
) {
    account::add_managed_asset(
        account,
        b"protocol:validator_admin_cap".to_string(),
        cap,
        version::current()
    );
}