// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Basic signed integer helpers for configurations that need negative values.
/// Stores a `u128` magnitude with an explicit sign flag to avoid relying on
/// signed primitives that Move does not provide.
module futarchy_types::signed;

// Comparison return values follow the same conventions as `std::option`:
// 0 = less, 1 = equal, 2 = greater.
const ORDERING_LESS: u8 = 0;
const ORDERING_EQUAL: u8 = 1;
const ORDERING_GREATER: u8 = 2;

/// Signed 128-bit integer encoded as magnitude + sign.
public struct SignedU128 has copy, drop, store {
    magnitude: u128,
    is_negative: bool,
}

/// Construct a new signed value.
public fun new(magnitude: u128, is_negative: bool): SignedU128 {
    SignedU128 { magnitude, is_negative }
}

/// Create a zero value.
public fun zero(): SignedU128 {
    SignedU128 { magnitude: 0, is_negative: false }
}

/// Construct from an unsigned value (positive).
public fun from_u64(value: u64): SignedU128 {
    SignedU128 { magnitude: (value as u128), is_negative: false }
}

/// Construct from an unsigned value (positive).
public fun from_u128(value: u128): SignedU128 {
    SignedU128 { magnitude: value, is_negative: false }
}

/// Return the magnitude.
public fun magnitude(value: &SignedU128): u128 {
    value.magnitude
}

/// True if the value is negative.
public fun is_negative(value: &SignedU128): bool {
    value.is_negative
}

/// Pack the value into a tuple (magnitude, is_negative).
/// Useful for constructing composite structs without exposing internal field
/// names to callers in other packages.
public fun to_parts(value: &SignedU128): (u128, bool) {
    (value.magnitude, value.is_negative)
}

/// Create from tuple parts.
public fun from_parts(magnitude: u128, is_negative: bool): SignedU128 {
    SignedU128 { magnitude, is_negative }
}

/// Convert an unsigned value with an explicit sign flag.
public fun from_signed_parts(magnitude: u128, is_negative: bool): SignedU128 {
    SignedU128 { magnitude, is_negative }
}

/// Compare two signed values.
/// Returns ORDERING_LESS (0), ORDERING_EQUAL (1), or ORDERING_GREATER (2).
public fun compare(lhs: &SignedU128, rhs: &SignedU128): u8 {
    if (lhs.is_negative != rhs.is_negative) {
        if (lhs.is_negative) {
            ORDERING_LESS
        } else {
            ORDERING_GREATER
        }
    } else {
        if (lhs.magnitude == rhs.magnitude) {
            ORDERING_EQUAL
        } else if (lhs.is_negative) {
            // Both negative: larger magnitude => smaller numeric value
            if (lhs.magnitude > rhs.magnitude) {
                ORDERING_LESS
            } else {
                ORDERING_GREATER
            }
        } else {
            // Both non-negative: standard comparison
            if (lhs.magnitude < rhs.magnitude) {
                ORDERING_LESS
            } else {
                ORDERING_GREATER
            }
        }
    }
}

/// Negate a signed value.
public fun negate(value: &SignedU128): SignedU128 {
    SignedU128 {
        magnitude: value.magnitude,
        is_negative: !value.is_negative,
    }
}

/// Convenience helper to treat an unsigned magnitude as signed.
public fun as_signed(is_negative: bool, magnitude: u128): SignedU128 {
    SignedU128 { magnitude, is_negative }
}

/// Serialize helpers for Move's BCS compatibility when callers need direct
/// access to the fields.
public fun magnitude_mut(value: &mut SignedU128): &mut u128 {
    &mut value.magnitude
}

public fun sign_mut(value: &mut SignedU128): &mut bool {
    &mut value.is_negative
}

public fun ordering_less(): u8 { ORDERING_LESS }

public fun ordering_equal(): u8 { ORDERING_EQUAL }

public fun ordering_greater(): u8 { ORDERING_GREATER }
