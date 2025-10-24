// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Utilities for conditional tokens:
/// - Validation (treasury cap, supply checks)
/// - Metadata generation and updates for conditional coins
/// - Helper functions for building coin names/symbols
module futarchy_markets_core::conditional_coin_utils;

use futarchy_core::dao_config::ConditionalCoinConfig;
use std::ascii::{Self, String as AsciiString};
use std::string::{Self, String};
use std::vector;
use sui::coin::TreasuryCap;
use sui::coin_registry::{Self, Currency, MetadataCap};

// === Errors ===
const ESupplyNotZero: u64 = 0;

// === Validation Functions ===

/// Validates that a coin's total supply is zero
public fun assert_zero_supply<T>(treasury_cap: &TreasuryCap<T>) {
    assert!(treasury_cap.total_supply() == 0, ESupplyNotZero);
}

/// Check if supply is zero without aborting
public fun is_supply_zero<T>(treasury_cap: &TreasuryCap<T>): bool {
    treasury_cap.total_supply() == 0
}

// === Metadata Update Functions ===

/// Update conditional Currency in CoinRegistry with DAO naming pattern
/// Pattern: c_<outcome_index>_<BASE_SYMBOL>
/// Uses MetadataCap to update the shared Currency object
/// Also copies the icon_url from the base currency
public fun update_conditional_currency<ConditionalCoinType>(
    currency: &mut Currency<ConditionalCoinType>,
    metadata_cap: &MetadataCap<ConditionalCoinType>,
    coin_config: &ConditionalCoinConfig,
    outcome_index: u64,
    base_coin_name: &String,
    base_coin_symbol: &String,
    base_icon_url: &String,
) {
    // Build conditional coin symbol: prefix + outcome_index + _ + base_symbol
    // Example: "c_0_SUI", "c_1_USDC"
    let symbol_str = build_conditional_symbol(coin_config, outcome_index, base_coin_symbol);

    // Build conditional coin name (human-readable)
    // Example: "Conditional 0: Sui", "Conditional 1: USD Coin"
    let name_str = build_conditional_name(outcome_index, base_coin_name);

    // Build description
    let description_str = build_conditional_description(outcome_index, base_coin_name);

    // Update Currency in CoinRegistry using MetadataCap
    coin_registry::set_symbol(currency, metadata_cap, symbol_str);
    coin_registry::set_name(currency, metadata_cap, name_str);
    coin_registry::set_description(currency, metadata_cap, description_str);

    // Copy icon URL from base currency to conditional coin
    // This ensures conditional coins visually match their base asset/stable
    if (!string::is_empty(base_icon_url)) {
        coin_registry::set_icon_url(currency, metadata_cap, *base_icon_url);
    };
}

// === Helper Functions ===

/// Build conditional coin symbol: prefix + outcome_index + _ + base_symbol
/// Example: "c_0_SUI", "c_1_USDC"
public fun build_conditional_symbol(
    coin_config: &ConditionalCoinConfig,
    outcome_index: u64,
    base_coin_symbol: &String,
): String {
    use futarchy_core::dao_config;

    let mut symbol_str = string::utf8(b"");

    // Add prefix (e.g., "c_") if configured
    let prefix_opt = dao_config::coin_name_prefix(coin_config);
    if (prefix_opt.is_some()) {
        let prefix = prefix_opt.destroy_some();
        let prefix_bytes = ascii::as_bytes(&prefix);
        string::append_utf8(&mut symbol_str, *prefix_bytes);
    } else {
        prefix_opt.destroy_none();
    };

    // Add outcome index if configured
    if (dao_config::use_outcome_index(coin_config)) {
        string::append_utf8(&mut symbol_str, u64_to_string(outcome_index));
        string::append_utf8(&mut symbol_str, b"_");
    };

    // Add base coin symbol (e.g., "SUI", "USDC")
    string::append(&mut symbol_str, *base_coin_symbol);

    symbol_str
}

/// Build conditional coin name (human-readable)
/// Example: "Conditional 0: Sui", "Conditional 1: USD Coin"
public fun build_conditional_name(outcome_index: u64, base_coin_name: &String): String {
    let mut name_str = string::utf8(b"Conditional ");
    string::append_utf8(&mut name_str, u64_to_string(outcome_index));
    string::append_utf8(&mut name_str, b": ");
    string::append(&mut name_str, *base_coin_name);
    name_str
}

/// Build conditional coin description
/// Example: "Conditional token for outcome 0 backed by Sui"
public fun build_conditional_description(outcome_index: u64, base_coin_name: &String): String {
    let mut description_str = string::utf8(b"Conditional token for outcome ");
    string::append_utf8(&mut description_str, u64_to_string(outcome_index));
    string::append_utf8(&mut description_str, b" backed by ");
    string::append(&mut description_str, *base_coin_name);
    description_str
}

/// Convert u64 to UTF-8 string (for use in names/descriptions)
public fun u64_to_string(mut num: u64): vector<u8> {
    if (num == 0) {
        return b"0"
    };

    let mut digits = vector::empty<u8>();
    while (num > 0) {
        let digit = ((num % 10) as u8) + 48; // ASCII '0' = 48
        vector::push_back(&mut digits, digit);
        num = num / 10;
    };

    // Reverse digits
    vector::reverse(&mut digits);
    digits
}

/// Convert u64 to ASCII string
public fun u64_to_ascii(mut num: u64): AsciiString {
    if (num == 0) {
        return ascii::string(b"0")
    };

    let mut digits = vector::empty<u8>();
    while (num > 0) {
        let digit = ((num % 10) as u8) + 48; // ASCII '0' = 48
        vector::push_back(&mut digits, digit);
        num = num / 10;
    };

    // Reverse digits
    vector::reverse(&mut digits);
    ascii::string(digits)
}
