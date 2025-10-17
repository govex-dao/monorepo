// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Common validation logic for conditional token coin metadata and treasury caps
/// Used by both coin_registry and proposal modules to enforce invariants
module futarchy_one_shot_utils::coin_validation;

use std::ascii;
use std::string;
use sui::coin::{TreasuryCap, CoinMetadata};

// === Errors ===
const ESupplyNotZero: u64 = 0;
const EMetadataMismatch: u64 = 1;
const ETreasuryCapMismatch: u64 = 2;
const ENameNotEmpty: u64 = 3;
const EDescriptionNotEmpty: u64 = 4;
const ESymbolNotEmpty: u64 = 5;
const EIconUrlNotEmpty: u64 = 6;

// === Public Validation Functions ===

/// Validates that a coin's total supply is zero
public fun assert_zero_supply<T>(treasury_cap: &TreasuryCap<T>) {
    assert!(treasury_cap.total_supply() == 0, ESupplyNotZero);
}

/// Validates that metadata and treasury cap match the same coin type
public fun assert_caps_match<T>(treasury_cap: &TreasuryCap<T>, metadata: &CoinMetadata<T>) {
    // Type safety ensures they match at compile time
    // This function exists for explicit validation calls
    let _ = treasury_cap;
    let _ = metadata;
}

/// Validates that coin name is empty (will be set by proposal)
public fun assert_empty_name<T>(metadata: &CoinMetadata<T>) {
    let name = metadata.get_name();
    let name_bytes = string::bytes(&name);
    // Name must be empty - proposal will set it
    assert!(name_bytes.is_empty(), ENameNotEmpty);
}

/// Validates that metadata fields are empty/minimal
public fun assert_empty_metadata<T>(metadata: &CoinMetadata<T>) {
    // Description should be empty
    let description = metadata.get_description();
    assert!(string::bytes(&description).is_empty(), EDescriptionNotEmpty);

    // Symbol should be empty
    let symbol = metadata.get_symbol();
    assert!(ascii::as_bytes(&symbol).is_empty(), ESymbolNotEmpty);

    // Icon URL should be empty
    let icon_url = metadata.get_icon_url();
    assert!(icon_url.is_none(), EIconUrlNotEmpty);
}

/// Complete validation - checks all requirements
public fun validate_conditional_coin<T>(treasury_cap: &TreasuryCap<T>, metadata: &CoinMetadata<T>) {
    assert_zero_supply(treasury_cap);
    assert_caps_match(treasury_cap, metadata);
    assert_empty_name(metadata);
    assert_empty_metadata(metadata);
}

// === View Functions ===

/// Check if supply is zero without aborting
public fun is_supply_zero<T>(treasury_cap: &TreasuryCap<T>): bool {
    treasury_cap.total_supply() == 0
}

/// Check if name is empty without aborting
public fun is_name_empty<T>(metadata: &CoinMetadata<T>): bool {
    let name = metadata.get_name();
    let name_bytes = string::bytes(&name);
    name_bytes.is_empty()
}

/// Check if metadata is empty without aborting
public fun is_metadata_empty<T>(metadata: &CoinMetadata<T>): bool {
    let description = metadata.get_description();
    let symbol = metadata.get_symbol();
    let icon_url = metadata.get_icon_url();

    string::bytes(&description).is_empty() &&
    ascii::as_bytes(&symbol).is_empty() &&
    icon_url.is_none()
}
