/// Decoder validation helper module
/// Provides functions to check if decoders exist for action types
module account_protocol::decoder_validation;

use account_protocol::schema;
use std::type_name::TypeName;

// === Imports ===

// === Public Functions ===

/// Check if a decoder exists for the given action type in the registry
/// This is a wrapper around schema::has_decoder for convenience
public fun has_decoder(registry: &schema::ActionDecoderRegistry, action_type: TypeName): bool {
    schema::has_decoder(registry, action_type)
}

/// Validate that a decoder exists, aborting if not found
/// Use this when you want to enforce decoder existence
public fun assert_decoder_exists(registry: &schema::ActionDecoderRegistry, action_type: TypeName) {
    assert!(has_decoder(registry, action_type), EDecoderNotFound);
}

// === Errors ===

const EDecoderNotFound: u64 = 0;
