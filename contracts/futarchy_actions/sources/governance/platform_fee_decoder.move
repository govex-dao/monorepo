/// Decoder for platform fee actions
module futarchy_actions::platform_fee_decoder;

use std::{string::String, type_name};
use sui::{object::{Self, UID}, dynamic_object_field};
use account_protocol::schema::{Self, ActionDecoderRegistry, HumanReadableField};

// Placeholder - implement when platform_fee_actions module is available
public fun register_decoders(
    _registry: &mut ActionDecoderRegistry,
    _ctx: &mut TxContext,
) {
    // TODO: Implement when platform_fee_actions module is available
}