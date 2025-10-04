module futarchy_governance_actions::protocol_admin_intents;

// === Imports ===
use std::{
    string::String,
    type_name::TypeName,
    bcs,
};
use sui::{
    transfer::Receiving,
    object::ID,
};
use account_protocol::{
    account::{Self, Account, Auth},
    executable::Executable,
    owned,
    intents::{Self, Intent, Params},
    intent_interface,
};
use futarchy_core::{
    version,
    action_types,
};
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_factory::factory::{FactoryOwnerCap, ValidatorAdminCap};
use futarchy_markets::fee::FeeAdminCap;
use futarchy_governance_actions::protocol_admin_actions;

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
            owned::new_withdraw_object(intent, account, cap_id, iw);
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
            owned::new_withdraw_object(intent, account, cap_id, iw);
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
            owned::new_withdraw_object(intent, account, cap_id, iw);
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
            let cap = owned::do_withdraw_object(executable, account, receiving, iw);
            
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
            let cap = owned::do_withdraw_object(executable, account, receiving, iw);
            
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
            let cap = owned::do_withdraw_object(executable, account, receiving, iw);
            
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

// === New Intent Helper Functions for All Protocol Admin Actions ===

// === Factory Admin Intent Helpers ===

/// Add set factory paused action to an intent
public fun add_set_factory_paused_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    paused: bool,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_set_factory_paused(paused);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::set_factory_paused(), action_data, intent_witness);
}

/// Add stable type to factory whitelist
public fun add_stable_type_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    stable_type: TypeName,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_add_stable_type(stable_type);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::add_stable_type(), action_data, intent_witness);
}

/// Remove stable type from factory whitelist
public fun remove_stable_type_from_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    stable_type: TypeName,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_remove_stable_type(stable_type);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::remove_stable_type(), action_data, intent_witness);
}

// === Fee Management Intent Helpers ===

/// Update DAO creation fee
public fun add_update_dao_creation_fee_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    new_fee: u64,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_update_dao_creation_fee(new_fee);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::update_dao_creation_fee(), action_data, intent_witness);
}

/// Update proposal fee
public fun add_update_proposal_fee_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    new_fee: u64,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_update_proposal_fee(new_fee);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::update_proposal_fee(), action_data, intent_witness);
}

/// Update monthly DAO fee
public fun add_update_monthly_dao_fee_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    new_fee: u64,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_update_monthly_dao_fee(new_fee);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::update_monthly_dao_fee(), action_data, intent_witness);
}

/// Update verification fee
public fun add_update_verification_fee_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    level: u8,
    new_fee: u64,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_update_verification_fee(level, new_fee);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::update_verification_fee(), action_data, intent_witness);
}

/// Update recovery fee
public fun add_update_recovery_fee_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    new_fee: u64,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_update_recovery_fee(new_fee);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::update_recovery_fee(), action_data, intent_witness);
}

/// Withdraw fees to treasury
public fun add_withdraw_fees_to_treasury_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    amount: u64,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_withdraw_fees_to_treasury(amount);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::withdraw_fees_to_treasury(), action_data, intent_witness);
}

// === Verification Intent Helpers ===

/// Add verification level
public fun add_verification_level_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    level: u8,
    fee: u64,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_add_verification_level(level, fee);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::add_verification_level(), action_data, intent_witness);
}

/// Remove verification level
public fun remove_verification_level_from_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    level: u8,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_remove_verification_level(level);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::remove_verification_level(), action_data, intent_witness);
}

/// Request DAO verification (DAO requests its own verification)
public fun add_request_verification_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    level: u8,
    attestation_url: String,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_request_verification(level, attestation_url);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::request_verification(), action_data, intent_witness);
}

/// Approve verification request (validator action)
public fun add_approve_verification_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    dao_id: ID,
    verification_id: ID,
    level: u8,
    attestation_url: String,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_approve_verification(dao_id, verification_id, level, attestation_url);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::approve_verification(), action_data, intent_witness);
}

/// Reject verification request (validator action)
public fun add_reject_verification_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    dao_id: ID,
    verification_id: ID,
    reason: String,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_reject_verification(dao_id, verification_id, reason);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::reject_verification(), action_data, intent_witness);
}

// === DAO Management Intent Helpers ===

/// Set DAO score
public fun add_set_dao_score_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    dao_id: ID,
    score: u64,
    reason: String,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_set_dao_score(dao_id, score, reason);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::set_dao_score(), action_data, intent_witness);
}

/// Apply DAO fee discount
public fun add_apply_dao_fee_discount_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    dao_id: ID,
    discount_amount: u64,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_apply_dao_fee_discount(dao_id, discount_amount);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::apply_dao_fee_discount(), action_data, intent_witness);
}

// === Coin Fee Configuration Intent Helpers ===

/// Add coin fee configuration
public fun add_coin_fee_config_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    coin_type: TypeName,
    decimals: u8,
    dao_monthly_fee: u64,
    dao_creation_fee: u64,
    proposal_fee_per_outcome: u64,
    recovery_fee: u64,
    multisig_creation_fee: u64,
    multisig_monthly_fee: u64,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_add_coin_fee_config(
        coin_type,
        decimals,
        dao_monthly_fee,
        dao_creation_fee,
        proposal_fee_per_outcome,
        recovery_fee,
        multisig_creation_fee,
        multisig_monthly_fee,
    );
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::add_coin_fee_config(), action_data, intent_witness);
}

/// Update coin monthly fee
public fun add_update_coin_monthly_fee_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    coin_type: TypeName,
    new_fee: u64,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_update_coin_monthly_fee(coin_type, new_fee);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::update_coin_monthly_fee(), action_data, intent_witness);
}

/// Update coin creation fee
public fun add_update_coin_creation_fee_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    coin_type: TypeName,
    new_fee: u64,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_update_coin_creation_fee(coin_type, new_fee);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::update_coin_creation_fee(), action_data, intent_witness);
}

/// Update coin proposal fee
public fun add_update_coin_proposal_fee_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    coin_type: TypeName,
    new_fee: u64,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_update_coin_proposal_fee(coin_type, new_fee);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::update_coin_proposal_fee(), action_data, intent_witness);
}

/// Update coin recovery fee
public fun add_update_coin_recovery_fee_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    coin_type: TypeName,
    new_fee: u64,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_update_coin_recovery_fee(coin_type, new_fee);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::update_coin_recovery_fee(), action_data, intent_witness);
}

/// Apply pending coin fees
public fun add_apply_pending_coin_fees_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    coin_type: TypeName,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_apply_pending_coin_fees(coin_type);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::apply_pending_coin_fees(), action_data, intent_witness);
}

// === Launchpad Admin Intent Helpers ===

/// Set launchpad raise trust score and review
public fun add_set_launchpad_trust_score_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    raise_id: ID,
    trust_score: u64,
    review_text: String,
    intent_witness: IW,
) {
    let action = protocol_admin_actions::new_set_launchpad_trust_score(raise_id, trust_score, review_text);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::set_launchpad_trust_score(), action_data, intent_witness);
}