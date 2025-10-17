// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// BCS validation helpers to ensure complete consumption of serialized data.
module account_protocol::bcs_validation;

use sui::bcs::BCS;

// === Imports ===

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
