/// Decoder for governance actions in futarchy DAOs
module futarchy_actions::governance_decoder;

// === Imports ===

use std::{string::String, type_name};
use sui::{object::{Self, UID}, dynamic_object_field, bcs};
use account_protocol::bcs_validation;
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};
use futarchy_actions::governance_actions::{
    CreateProposalAction,
    ProposalReservationAction,
};

// === Decoder Objects ===

/// Decoder for CreateProposalAction
public struct CreateProposalActionDecoder has key, store {
    id: UID,
}

/// Decoder for ProposalReservationAction
public struct ProposalReservationActionDecoder has key, store {
    id: UID,
}

// === Decoder Functions ===

/// Decode a CreateProposalAction
public fun decode_create_proposal_action(
    _decoder: &CreateProposalActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let title = bcs::peel_vec_u8(&mut bcs_data).to_string();
    let description = bcs::peel_vec_u8(&mut bcs_data).to_string();

    // Read outcome messages vector
    let outcomes_count = bcs::peel_vec_length(&mut bcs_data);
    let mut i = 0;
    while (i < outcomes_count) {
        bcs::peel_vec_u8(&mut bcs_data); // Just consume the data
        i = i + 1;
    };

    // Read outcome details vector
    let details_count = bcs::peel_vec_length(&mut bcs_data);
    let mut j = 0;
    while (j < details_count) {
        bcs::peel_vec_u8(&mut bcs_data); // Just consume the data
        j = j + 1;
    };

    let metadata_url = bcs::peel_vec_u8(&mut bcs_data).to_string();

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"title".to_string(),
            title,
            b"String".to_string(),
        ),
        schema::new_field(
            b"description".to_string(),
            description,
            b"String".to_string(),
        ),
        schema::new_field(
            b"outcomes_count".to_string(),
            outcomes_count.to_string(),
            b"u64".to_string(),
        ),
        schema::new_field(
            b"metadata_url".to_string(),
            metadata_url,
            b"String".to_string(),
        ),
    ]
}

/// Decode a ProposalReservationAction
public fun decode_proposal_reservation_action(
    _decoder: &ProposalReservationActionDecoder,
    action_data: vector<u8>,
): vector<HumanReadableField> {
    let mut bcs_data = bcs::new(action_data);

    let reservation_id = bcs::peel_address(&mut bcs_data);

    // Security: ensure all bytes are consumed to prevent trailing data attacks
    bcs_validation::validate_all_bytes_consumed(bcs_data);

    vector[
        schema::new_field(
            b"reservation_id".to_string(),
            reservation_id.to_string(),
            b"ID".to_string(),
        ),
    ]
}

// === Registration Functions ===

/// Register all governance decoders
public fun register_decoders(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    register_create_proposal_decoder(registry, ctx);
    register_proposal_reservation_decoder(registry, ctx);
}

fun register_create_proposal_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = CreateProposalActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<CreateProposalAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}

fun register_proposal_reservation_decoder(
    registry: &mut ActionDecoderRegistry,
    ctx: &mut TxContext,
) {
    let decoder = ProposalReservationActionDecoder { id: object::new(ctx) };
    let type_key = type_name::with_defining_ids<ProposalReservationAction>();
    dynamic_object_field::add(schema::registry_id_mut(registry), type_key, decoder);
}