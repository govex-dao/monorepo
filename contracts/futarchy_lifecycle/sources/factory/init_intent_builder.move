/// Centralized builder for creating ActionSpec blueprints in a PTB.
/// This module exposes a single entry point, `build_spec`, which acts as a
/// dispatcher. The off-chain SDK calls this function with an `action_id`
/// and BCS-serialized parameters to construct a type-safe `ActionSpec`.
module futarchy_lifecycle::init_intent_builder;

// === Imports ===
use std::type_name;
use sui::bcs;
use account_protocol::intent_spec::{Self, ActionSpec};

// Import all action type markers
use futarchy_one_shot_utils::action_types;

// Import action structs and deserialization functions from shared location
use futarchy_one_shot_utils::action_data_structs::{
    CreateSecurityCouncilAction,
    CreateOperatingAgreementAction,
    AddLiquidityAction,
    CreateCommitmentProposalAction,
    CreatePaymentAction,
    create_security_council_action_from_bytes,
    create_operating_agreement_action_from_bytes,
    add_liquidity_action_from_bytes,
    create_commitment_proposal_action_from_bytes,
    create_payment_action_from_bytes,
};

// === Action IDs for PTB Routing ===
const ACTION_CREATE_COUNCIL: u8 = 1;
const ACTION_CREATE_AGREEMENT: u8 = 2;
const ACTION_ADD_LIQUIDITY: u8 = 3;
const ACTION_CREATE_COMMITMENT: u8 = 4;
const ACTION_CREATE_STREAM: u8 = 5;

// === Errors ===
const EUnknownActionId: u64 = 1;

/// The single, unified entry point for building ANY initialization ActionSpec.
/// The PTB calls this function, providing the ID of the action to create and
/// its parameters serialized as a single byte vector.
public fun build_spec<AssetType, StableType>(
    action_id: u8,
    params_bcs: vector<u8>,
): ActionSpec {
    if (action_id == ACTION_CREATE_COUNCIL) {
        // 1. Deserialize the parameters. THIS IS THE CRITICAL VALIDATION STEP.
        let params = create_security_council_action_from_bytes(params_bcs);
        // 2. Re-serialize to ensure canonical form.
        let action_data = bcs::to_bytes(&params);
        // 3. Create and return the ActionSpec blueprint.
        intent_spec::new_action_spec(
            type_name::get<action_types::CreateSecurityCouncil>(),
            action_data
        )
    } else if (action_id == ACTION_CREATE_AGREEMENT) {
        let params = create_operating_agreement_action_from_bytes(params_bcs);
        let action_data = bcs::to_bytes(&params);
        intent_spec::new_action_spec(
            type_name::get<action_types::CreateOperatingAgreement>(),
            action_data
        )
    } else if (action_id == ACTION_ADD_LIQUIDITY) {
        let params = add_liquidity_action_from_bytes<AssetType, StableType>(params_bcs);
        let action_data = bcs::to_bytes(&params);
        intent_spec::new_action_spec(
            type_name::get<action_types::AddLiquidity>(),
            action_data
        )
    } else if (action_id == ACTION_CREATE_COMMITMENT) {
        let params = create_commitment_proposal_action_from_bytes<AssetType>(params_bcs);
        let action_data = bcs::to_bytes(&params);
        intent_spec::new_action_spec(
            type_name::get<action_types::CreateCommitmentProposal>(),
            action_data
        )
    } else if (action_id == ACTION_CREATE_STREAM) {
        let params = create_payment_action_from_bytes<StableType>(params_bcs);
        let action_data = bcs::to_bytes(&params);
        intent_spec::new_action_spec(
            type_name::get<action_types::CreatePayment>(),
            action_data
        )
    } else {
        abort EUnknownActionId
    }
}

/// Helper function to get the action ID constants for the client SDK.
public fun get_action_ids(): (u8, u8, u8, u8, u8) {
    (
        ACTION_CREATE_COUNCIL,
        ACTION_CREATE_AGREEMENT,
        ACTION_ADD_LIQUIDITY,
        ACTION_CREATE_COMMITMENT,
        ACTION_CREATE_STREAM
    )
}