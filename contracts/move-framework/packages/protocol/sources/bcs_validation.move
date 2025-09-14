// ============================================================================
// FORK MODIFICATION NOTICE - BCS Validation Security Module
// ============================================================================
// NEW FILE: Added to support type-based action system with proper validation.
//
// PURPOSE:
// - Ensures all BCS bytes are consumed when deserializing actions
// - Prevents attacks where extra data is appended to action payloads
// - Critical for security of the typed Intent system
//
// SECURITY CONSIDERATIONS:
// Without this validation, attackers could append extra bytes to actions that
// would be ignored during deserialization but could potentially affect
// execution if the bytes were passed to other functions.
//
// USAGE:
// Called after deserializing any action from BCS to ensure no trailing data.
// Example: After bcs::peel_vec_u8(&mut reader), call validate_all_bytes_consumed(reader)
// ============================================================================
/// BCS validation helpers to ensure complete consumption of serialized data
module account_protocol::bcs_validation;

// === Imports ===

use sui::bcs::BCS;

// === Errors ===

const ETrailingActionData: u64 = 0;

// === Public Functions ===

/// Validates that all bytes in the BCS reader have been consumed
/// This prevents attacks where extra data is appended to actions
public fun validate_all_bytes_consumed(reader: BCS) {
    // Check if there are any remaining bytes
    let remaining = reader.into_remainder_bytes();
    assert!(remaining.is_empty(), ETrailingActionData);
}