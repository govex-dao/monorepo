/// Actions specific to the role of a Security Council Account.
/// This enables the council to accept and manage critical capabilities like UpgradeCaps
/// through its own internal M-of-N governance process.
module futarchy_multisig::security_council_actions;

use std::{string::{Self, String}, option::Option};
use sui::{object::{Self, ID}, bcs::{Self, BCS}, clock::Clock, tx_context::TxContext};
use account_protocol::{
    intents::{Self as protocol_intents, Expired, Intent, ActionSpec},
    executable::{Self, Executable},
    account::{Self, Account},
    version_witness::VersionWitness,
    bcs_validation,
    action_validation,
};
use futarchy_core::{futarchy_config::FutarchyConfig, version};
use futarchy_multisig::approved_intent_spec;
// Removed dependency on action_data_structs module which doesn't exist

/// Create a new Security Council (WeightedMultisig) for the DAO.
public struct CreateSecurityCouncilAction has store, copy, drop {
    members: vector<address>,
    weights: vector<u64>,
    threshold: u64,
}

// === Constants ===
const EUnsupportedActionVersion: u64 = 1;
/// Error when member and weight vectors have different lengths
const EMemberWeightMismatch: u64 = 2;
/// Error when member list is empty
const EEmptyMemberList: u64 = 3;
/// Error when threshold is zero
const EInvalidThreshold: u64 = 4;
/// Error when threshold exceeds total weight
const EThresholdExceedsTotalWeight: u64 = 5;

// === Witness Types for Action Validation ===
public struct CreateSecurityCouncilWitness has drop {}
public struct UpdateCouncilMembershipWitness has drop {}
public struct UpdateTimeLockWitness has drop {}
public struct UpdateUpgradeRulesWitness has drop {}
public struct ApproveOAChangeWitness has drop {}
public struct UnlockAndReturnUpgradeCapWitness has drop {}
public struct ApproveGenericWitness has drop {}
public struct SweepIntentsWitness has drop {}
public struct CouncilCreateOptimisticIntentWitness has drop {}
public struct CouncilExecuteOptimisticIntentWitness has drop {}
public struct CouncilCancelOptimisticIntentWitness has drop {}
public struct CouncilApproveIntentSpecWitness has drop {}

// --- Constructors, Getters, Cleanup ---

public fun new_create_council_action(
    members: vector<address>,
    weights: vector<u64>,
    threshold: u64,
): CreateSecurityCouncilAction {
    CreateSecurityCouncilAction { members, weights, threshold }
}

public fun get_create_council_params(
    action: &CreateSecurityCouncilAction
): (&vector<address>, &vector<u64>, u64) {
    (&action.members, &action.weights, action.threshold)
}

public fun delete_create_council(expired: &mut Expired) {
    let spec = expired.remove_action_spec();
    let action_data = protocol_intents::action_spec_data(&spec);
    let mut bcs = bcs::new(*action_data);
    let _members = bcs::peel_vec_address(&mut bcs);
    let _weights = bcs::peel_vec_u64(&mut bcs);
    let _threshold = bcs::peel_u64(&mut bcs);
}

/// Action to update the council's own membership, weights, and threshold.
public struct UpdateCouncilMembershipAction has store {
    new_members: vector<address>,
    new_weights: vector<u64>,
    new_threshold: u64,
}

/// Action to update the council's time lock delay.
/// This requires multisig approval to change the time lock security parameter.
public struct UpdateTimeLockAction has store {
    new_delay_ms: u64,  // 0 = disabled, >0 = delay in milliseconds
}

/// Action to unlock an UpgradeCap and return it to the main DAO.
public struct UnlockAndReturnUpgradeCapAction has store {
    package_name: String,
    /// The address of the main DAO's treasury vault.
    return_vault_name: String,
}

/// Generic approval action for any non-OA council approval
/// This replaces ApprovePolicyChangeAction, ApproveUpgradeCapAction, etc.
public struct ApproveGenericAction has store {
    dao_id: ID,
    action_type: String,  // "policy_remove", "policy_set", "custody_accept", etc.
    resource_key: String,  // The resource being acted upon
    metadata: vector<String>,  // Pairs of key-value strings [k1, v1, k2, v2, ...]
    expires_at: u64,
}

/// Action to sweep/cleanup expired intents from the Security Council account
public struct SweepIntentsAction has store {
    intent_keys: vector<String>,  // Specific intent keys to clean up
}

/// Action for security council to create an optimistic intent
public struct CouncilCreateOptimisticIntentAction has store {
    dao_id: ID,
    intent_key: String,
    title: String,
    description: String,
}

/// Action for security council to execute a matured optimistic intent
public struct CouncilExecuteOptimisticIntentAction has store {
    dao_id: ID,
    intent_id: ID,
}

/// Action for security council to cancel their own optimistic intent
public struct CouncilCancelOptimisticIntentAction has store {
    dao_id: ID,
    intent_id: ID,
    reason: String,
}

/// Action for council to approve an IntentSpec for proposal creation
/// Creates a shared ApprovedIntentSpec object that users can reference
public struct CouncilApproveIntentSpecAction has store, drop {
    intent_spec: futarchy_types::init_action_specs::InitActionSpecs,
    dao_id: ID,
    expiration_period_ms: u64,
    metadata: String,
}

// === Execution Functions (do_ pattern) ===

/// Execute create security council action
public fun do_create_security_council<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Assert action type with witness
    action_validation::assert_action_type<CreateSecurityCouncilWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);
    let members_len = bcs::peel_vec_length(&mut reader);
    let mut members = vector[];
    let mut i = 0;
    while (i < members_len) {
        members.push_back(bcs::peel_address(&mut reader));
        i = i + 1;
    };

    let weights_len = bcs::peel_vec_length(&mut reader);
    let mut weights = vector[];
    i = 0;
    while (i < weights_len) {
        weights.push_back(bcs::peel_u64(&mut reader));
        i = i + 1;
    };

    let threshold = bcs::peel_u64(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Input validation
    assert!(members.length() == weights.length(), EMemberWeightMismatch);
    assert!(members.length() > 0, EEmptyMemberList);
    assert!(threshold > 0, EInvalidThreshold);

    // Calculate total weight and ensure threshold doesn't exceed it
    let mut total_weight = 0u64;
    let mut j = 0;
    while (j < weights.length()) {
        total_weight = total_weight + *weights.borrow(j);
        j = j + 1;
    };
    assert!(threshold <= total_weight, EThresholdExceedsTotalWeight);

    // Note: Actual security council creation logic would go here
    // This is just the validation and deserialization

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute update time lock action
public fun do_update_time_lock<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Assert action type with witness
    action_validation::assert_action_type<UpdateTimeLockWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);
    let new_delay_ms = bcs::peel_u64(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Note: Actual time lock update logic would go here
    // This would call weighted_multisig::set_time_lock_delay()

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute update council membership action
public fun do_update_council_membership<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Assert action type with witness
    action_validation::assert_action_type<UpdateCouncilMembershipWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);

    // Read new members
    let members_len = bcs::peel_vec_length(&mut reader);
    let mut new_members = vector[];
    let mut i = 0;
    while (i < members_len) {
        new_members.push_back(bcs::peel_address(&mut reader));
        i = i + 1;
    };

    // Read new weights
    let weights_len = bcs::peel_vec_length(&mut reader);
    let mut new_weights = vector[];
    i = 0;
    while (i < weights_len) {
        new_weights.push_back(bcs::peel_u64(&mut reader));
        i = i + 1;
    };

    let new_threshold = bcs::peel_u64(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Input validation
    assert!(new_members.length() == new_weights.length(), EMemberWeightMismatch);
    assert!(new_members.length() > 0, EEmptyMemberList);
    assert!(new_threshold > 0, EInvalidThreshold);

    // Calculate total weight and ensure threshold doesn't exceed it
    let mut total_weight = 0u64;
    let mut j = 0;
    while (j < new_weights.length()) {
        total_weight = total_weight + *new_weights.borrow(j);
        j = j + 1;
    };
    assert!(new_threshold <= total_weight, EThresholdExceedsTotalWeight);

    // Note: Actual council update logic would go here
    // This is just the validation and deserialization

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute unlock and return upgrade cap action
public fun do_unlock_and_return_upgrade_cap<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Assert action type with witness
    action_validation::assert_action_type<UnlockAndReturnUpgradeCapWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);
    let package_name = string::utf8(bcs::peel_vec_u8(&mut reader));
    let return_vault_name = string::utf8(bcs::peel_vec_u8(&mut reader));

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute approve generic action
public fun do_approve_generic<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Assert action type with witness
    action_validation::assert_action_type<ApproveGenericWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);
    let dao_id = object::id_from_address(bcs::peel_address(&mut reader));
    let action_type = string::utf8(bcs::peel_vec_u8(&mut reader));
    let resource_key = string::utf8(bcs::peel_vec_u8(&mut reader));

    // Read metadata vector
    let metadata_len = bcs::peel_vec_length(&mut reader);
    let mut metadata = vector[];
    let mut i = 0;
    while (i < metadata_len) {
        metadata.push_back(string::utf8(bcs::peel_vec_u8(&mut reader)));
        i = i + 1;
    };

    let expires_at = bcs::peel_u64(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute sweep intents action
public fun do_sweep_intents<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Assert action type with witness
    action_validation::assert_action_type<SweepIntentsWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);

    // Read intent keys vector
    let keys_len = bcs::peel_vec_length(&mut reader);
    let mut intent_keys = vector[];
    let mut i = 0;
    while (i < keys_len) {
        intent_keys.push_back(string::utf8(bcs::peel_vec_u8(&mut reader)));
        i = i + 1;
    };

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute council create optimistic intent action
public fun do_council_create_optimistic_intent<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Assert action type with witness
    action_validation::assert_action_type<CouncilCreateOptimisticIntentWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);
    let dao_id = object::id_from_address(bcs::peel_address(&mut reader));
    let intent_key = string::utf8(bcs::peel_vec_u8(&mut reader));
    let title = string::utf8(bcs::peel_vec_u8(&mut reader));
    let description = string::utf8(bcs::peel_vec_u8(&mut reader));

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute council execute optimistic intent action
public fun do_council_execute_optimistic_intent<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Assert action type with witness
    action_validation::assert_action_type<CouncilExecuteOptimisticIntentWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);
    let dao_id = object::id_from_address(bcs::peel_address(&mut reader));
    let intent_id = object::id_from_address(bcs::peel_address(&mut reader));

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute council cancel optimistic intent action
public fun do_council_cancel_optimistic_intent<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Assert action type with witness
    action_validation::assert_action_type<CouncilCancelOptimisticIntentWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize with BCS reader
    let mut reader = bcs::new(*action_data);
    let dao_id = object::id_from_address(bcs::peel_address(&mut reader));
    let intent_id = object::id_from_address(bcs::peel_address(&mut reader));
    let reason = string::utf8(bcs::peel_vec_u8(&mut reader));

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute council approve intent spec action
/// Creates a shared ApprovedIntentSpec object that users can reference
public fun do_council_approve_intent_spec<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    dao_account: &Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Assert action type with witness
    action_validation::assert_action_type<CouncilApproveIntentSpecWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // The action_data contains a serialized CouncilApproveIntentSpecAction
    // We need to extract dao_id, expiration_period_ms, and metadata
    // But we DON'T deserialize the InitActionSpecs (it has TypeName which can't be deserialized)
    // Instead we just pass the whole action_data as bytes

    // Copy the bytes so we can use them later
    let action_data_copy = *action_data;
    let mut reader = bcs::new(action_data_copy);

    // Skip over InitActionSpecs (it's a vector of ActionSpecs)
    let action_count = bcs::peel_vec_length(&mut reader);
    let mut i = 0;
    while (i < action_count) {
        let _action_type_bytes = bcs::peel_vec_u8(&mut reader); // TypeName as bytes
        let _action_data_bytes = bcs::peel_vec_u8(&mut reader); // Action data
        i = i + 1;
    };

    // Now extract the other fields
    let dao_id = object::id_from_address(bcs::peel_address(&mut reader));
    let expiration_period_ms = bcs::peel_u64(&mut reader);
    let metadata = string::utf8(bcs::peel_vec_u8(&mut reader));

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Increment action index
    executable::increment_action_idx(executable);

    // Get council ID from the account executing this action
    let account_address = protocol_intents::account(executable::intent(executable));
    let council_id = object::id_from_address(account_address);

    // Create and share the approval object with the serialized bytes
    // Users will deserialize the full struct off-chain to inspect InitActionSpecs
    let approval_id = approved_intent_spec::create_and_share(
        action_data_copy,
        dao_id,
        council_id,
        expiration_period_ms,
        metadata,
        clock,
        ctx
    );

    approval_id
}

// === New Constructor Functions with Serialize-Then-Destroy Pattern ===

/// Create and add a create security council action to an intent
public fun new_create_security_council<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    members: vector<address>,
    weights: vector<u64>,
    threshold: u64,
    intent_witness: IW,
) {
    // Serialize action data
    let mut data = vector[];
    data.append(bcs::to_bytes(&members));
    data.append(bcs::to_bytes(&weights));
    data.append(bcs::to_bytes(&threshold));

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        CreateSecurityCouncilWitness {},
        data,
        intent_witness,
    );
}

/// Create and add an approve OA change action to an intent
public fun new_approve_oa_change<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    dao_id: ID,
    batch_id: ID,
    expires_at: u64,
    intent_witness: IW,
) {
    // Serialize action data
    let mut data = vector[];
    data.append(bcs::to_bytes(&object::id_to_address(&dao_id)));
    data.append(bcs::to_bytes(&object::id_to_address(&batch_id)));
    data.append(bcs::to_bytes(&expires_at));

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        ApproveOAChangeWitness {},
        data,
        intent_witness,
    );
}

/// Create and add an update upgrade rules action to an intent
public fun new_update_upgrade_rules<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    package_name: String,
    intent_witness: IW,
) {
    // Serialize action data
    let mut data = vector[];
    data.append(bcs::to_bytes(package_name.as_bytes()));

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        UpdateUpgradeRulesWitness {},
        data,
        intent_witness,
    );
}

/// Create and add an update council membership action to an intent
public fun new_update_council_membership<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    new_members: vector<address>,
    new_weights: vector<u64>,
    new_threshold: u64,
    intent_witness: IW,
) {
    // Serialize action data
    let mut data = vector[];
    data.append(bcs::to_bytes(&new_members));
    data.append(bcs::to_bytes(&new_weights));
    data.append(bcs::to_bytes(&new_threshold));

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        UpdateCouncilMembershipWitness {},
        data,
        intent_witness,
    );
}

/// Create and add an update time lock action to an intent
public fun new_update_time_lock<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    new_delay_ms: u64,
    intent_witness: IW,
) {
    // Serialize action data
    let mut data = vector[];
    data.append(bcs::to_bytes(&new_delay_ms));

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        UpdateTimeLockWitness {},
        data,
        intent_witness,
    );
}

/// Create and add an unlock and return upgrade cap action to an intent
public fun new_unlock_and_return_upgrade_cap<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    package_name: String,
    return_vault_name: String,
    intent_witness: IW,
) {
    // Serialize action data
    let mut data = vector[];
    data.append(bcs::to_bytes(package_name.as_bytes()));
    data.append(bcs::to_bytes(return_vault_name.as_bytes()));

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        UnlockAndReturnUpgradeCapWitness {},
        data,
        intent_witness,
    );
}

/// Create and add an approve generic action to an intent
public fun new_approve_generic<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    dao_id: ID,
    action_type: String,
    resource_key: String,
    metadata: vector<String>,
    expires_at: u64,
    intent_witness: IW,
) {
    // Serialize action data
    let mut data = vector[];
    data.append(bcs::to_bytes(&object::id_to_address(&dao_id)));
    data.append(bcs::to_bytes(action_type.as_bytes()));
    data.append(bcs::to_bytes(resource_key.as_bytes()));

    // Serialize metadata vector
    data.append(bcs::to_bytes(&metadata.length()));
    let mut i = 0;
    while (i < metadata.length()) {
        data.append(bcs::to_bytes(metadata[i].as_bytes()));
        i = i + 1;
    };

    data.append(bcs::to_bytes(&expires_at));

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        ApproveGenericWitness {},
        data,
        intent_witness,
    );
}

/// Create and add a sweep intents action to an intent
public fun new_sweep_intents<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    intent_keys: vector<String>,
    intent_witness: IW,
) {
    // Serialize action data
    let mut data = vector[];
    data.append(bcs::to_bytes(&intent_keys.length()));
    let mut i = 0;
    while (i < intent_keys.length()) {
        data.append(bcs::to_bytes(intent_keys[i].as_bytes()));
        i = i + 1;
    };

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        SweepIntentsWitness {},
        data,
        intent_witness,
    );
}

/// Create and add a council create optimistic intent action to an intent
public fun new_council_create_optimistic_intent<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    dao_id: ID,
    intent_key: String,
    title: String,
    description: String,
    intent_witness: IW,
) {
    // Serialize action data
    let mut data = vector[];
    data.append(bcs::to_bytes(&object::id_to_address(&dao_id)));
    data.append(bcs::to_bytes(intent_key.as_bytes()));
    data.append(bcs::to_bytes(title.as_bytes()));
    data.append(bcs::to_bytes(description.as_bytes()));

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        CouncilCreateOptimisticIntentWitness {},
        data,
        intent_witness,
    );
}

/// Create and add a council execute optimistic intent action to an intent
public fun new_council_execute_optimistic_intent<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    dao_id: ID,
    intent_id: ID,
    intent_witness: IW,
) {
    // Serialize action data
    let mut data = vector[];
    data.append(bcs::to_bytes(&object::id_to_address(&dao_id)));
    data.append(bcs::to_bytes(&object::id_to_address(&intent_id)));

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        CouncilExecuteOptimisticIntentWitness {},
        data,
        intent_witness,
    );
}

/// Create and add a council cancel optimistic intent action to an intent
public fun new_council_cancel_optimistic_intent<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    dao_id: ID,
    intent_id: ID,
    reason: String,
    intent_witness: IW,
) {
    // Serialize action data
    let mut data = vector[];
    data.append(bcs::to_bytes(&object::id_to_address(&dao_id)));
    data.append(bcs::to_bytes(&object::id_to_address(&intent_id)));
    data.append(bcs::to_bytes(reason.as_bytes()));

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        CouncilCancelOptimisticIntentWitness {},
        data,
        intent_witness,
    );
}

/// Create and add a council approve intent spec action to an intent
/// This creates a shared ApprovedIntentSpec object that users can reference
public fun new_council_approve_intent_spec<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    intent_spec: futarchy_types::init_action_specs::InitActionSpecs,
    dao_id: ID,
    expiration_period_ms: u64,
    metadata: String,
    intent_witness: IW,
) {
    // Serialize the entire CouncilApproveIntentSpecAction struct at once
    let action = CouncilApproveIntentSpecAction {
        intent_spec,
        dao_id,
        expiration_period_ms,
        metadata,
    };

    let data = bcs::to_bytes(&action);

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        CouncilApproveIntentSpecWitness {},
        data,
        intent_witness,
    );
}

// === Legacy Constructors (deprecated - use new_* functions above) ===

// Optimistic Intent Constructors
public fun new_council_create_optimistic_intent_action(
    dao_id: ID,
    intent_key: String,
    title: String,
    description: String,
): CouncilCreateOptimisticIntentAction {
    CouncilCreateOptimisticIntentAction { dao_id, intent_key, title, description }
}

public fun get_council_create_optimistic_intent_params(
    action: &CouncilCreateOptimisticIntentAction
): (ID, &String, &String, &String) {
    (action.dao_id, &action.intent_key, &action.title, &action.description)
}

public fun delete_council_create_optimistic_intent(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

public fun new_council_execute_optimistic_intent_action(
    dao_id: ID,
    intent_id: ID,
): CouncilExecuteOptimisticIntentAction {
    CouncilExecuteOptimisticIntentAction { dao_id, intent_id }
}

public fun get_council_execute_optimistic_intent_params(
    action: &CouncilExecuteOptimisticIntentAction
): (ID, ID) {
    (action.dao_id, action.intent_id)
}

public fun delete_council_execute_optimistic_intent(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

public fun new_council_cancel_optimistic_intent_action(
    dao_id: ID,
    intent_id: ID,
    reason: String,
): CouncilCancelOptimisticIntentAction {
    CouncilCancelOptimisticIntentAction { dao_id, intent_id, reason }
}

public fun get_council_cancel_optimistic_intent_params(
    action: &CouncilCancelOptimisticIntentAction
): (ID, ID, &String) {
    (action.dao_id, action.intent_id, &action.reason)
}

public fun delete_council_cancel_optimistic_intent(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

public fun new_council_approve_intent_spec_action(
    intent_spec: futarchy_types::init_action_specs::InitActionSpecs,
    dao_id: ID,
    expiration_period_ms: u64,
    metadata: String,
): CouncilApproveIntentSpecAction {
    CouncilApproveIntentSpecAction { intent_spec, dao_id, expiration_period_ms, metadata }
}

public fun get_council_approve_intent_spec_params(
    action: &CouncilApproveIntentSpecAction
): (&futarchy_types::init_action_specs::InitActionSpecs, ID, u64, &String) {
    (&action.intent_spec, action.dao_id, action.expiration_period_ms, &action.metadata)
}

public fun delete_council_approve_intent_spec(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

public fun destroy_council_approve_intent_spec(action: CouncilApproveIntentSpecAction) {
    let CouncilApproveIntentSpecAction { intent_spec: _, dao_id: _, expiration_period_ms: _, metadata: _ } = action;
}

// Other Constructors
// UpdateUpgradeRulesAction is handled through the new_ function above

public fun new_update_council_membership_action(
    new_members: vector<address>,
    new_weights: vector<u64>,
    new_threshold: u64,
): UpdateCouncilMembershipAction {
    UpdateCouncilMembershipAction { new_members, new_weights, new_threshold }
}

public fun get_update_council_membership_params(
    action: &UpdateCouncilMembershipAction
): (&vector<address>, &vector<u64>, u64) {
    (&action.new_members, &action.new_weights, action.new_threshold)
}

public fun new_unlock_and_return_cap_action(package_name: String, return_vault_name: String): UnlockAndReturnUpgradeCapAction {
    UnlockAndReturnUpgradeCapAction { package_name, return_vault_name }
}

public fun get_unlock_and_return_cap_params(action: &UnlockAndReturnUpgradeCapAction): (&String, &String) {
    (&action.package_name, &action.return_vault_name)
}

public fun delete_update_upgrade_rules(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

public fun delete_update_council_membership(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

public fun delete_update_time_lock(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

public fun delete_unlock_and_return_cap(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

// --- Generic Approval Functions ---

public fun new_approve_generic_action(
    dao_id: ID,
    action_type: String,
    resource_key: String,
    metadata: vector<String>,
    expires_at: u64,
): ApproveGenericAction {
    ApproveGenericAction {
        dao_id,
        action_type,
        resource_key,
        metadata,
        expires_at,
    }
}

public fun get_approve_generic_params(
    action: &ApproveGenericAction
): (ID, &String, &String, &vector<String>, u64) {
    (
        action.dao_id,
        &action.action_type,
        &action.resource_key,
        &action.metadata,
        action.expires_at,
    )
}

public fun delete_approve_generic(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

// --- Sweep Intents Functions ---

public fun new_sweep_intents_action(intent_keys: vector<String>): SweepIntentsAction {
    SweepIntentsAction { intent_keys }
}

public fun get_sweep_keys(action: &SweepIntentsAction): &vector<String> {
    &action.intent_keys
}

public fun delete_sweep_intents(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

// === Destruction Functions ===

/// Destroy an UpdateCouncilMembershipAction
public fun destroy_update_council_membership(action: UpdateCouncilMembershipAction) {
    let UpdateCouncilMembershipAction { new_members: _, new_weights: _, new_threshold: _ } = action;
}

/// Destroy an UnlockAndReturnUpgradeCapAction
public fun destroy_unlock_and_return_upgrade_cap(action: UnlockAndReturnUpgradeCapAction) {
    let UnlockAndReturnUpgradeCapAction { package_name: _, return_vault_name: _ } = action;
}

/// Destroy an ApproveGenericAction
public fun destroy_approve_generic(action: ApproveGenericAction) {
    let ApproveGenericAction { dao_id: _, action_type: _, resource_key: _, metadata: _, expires_at: _ } = action;
}

/// Destroy a SweepIntentsAction
public fun destroy_sweep_intents(action: SweepIntentsAction) {
    let SweepIntentsAction { intent_keys: _ } = action;
}

/// Destroy a CouncilCreateOptimisticIntentAction
public fun destroy_council_create_optimistic_intent(action: CouncilCreateOptimisticIntentAction) {
    let CouncilCreateOptimisticIntentAction { dao_id: _, intent_key: _, title: _, description: _ } = action;
}

/// Destroy a CouncilExecuteOptimisticIntentAction
public fun destroy_council_execute_optimistic_intent(action: CouncilExecuteOptimisticIntentAction) {
    let CouncilExecuteOptimisticIntentAction { dao_id: _, intent_id: _ } = action;
}

/// Destroy a CouncilCancelOptimisticIntentAction
public fun destroy_council_cancel_optimistic_intent(action: CouncilCancelOptimisticIntentAction) {
    let CouncilCancelOptimisticIntentAction { dao_id: _, intent_id: _, reason: _ } = action;
}


