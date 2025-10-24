// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// Authenticated users can lock a TreasuryCap in the Account to restrict minting and burning operations,
/// as well as modifying the CoinMetadata.

module account_actions::currency;

// === Imports ===

use std::{
    string::{Self, String},
    ascii,
    option,

};
use sui::{
    coin::{Self, Coin, TreasuryCap},
    coin_registry::{Self, MetadataCap, Currency},
    url::{Self, Url},
    bcs,
    object,
};
use account_protocol::{
    action_validation,
    account::{Self, Account, Auth},
    intents::{Self, Expired, Intent},
    executable::{Self, Executable},
    version_witness::VersionWitness,
    bcs_validation,
    package_registry::PackageRegistry,
};
use account_actions::{
    currency,
    version,
};
// === Use Fun Aliases ===

// === Errors ===

const ENoChange: u64 = 0;
const EWrongValue: u64 = 1;
const EMintDisabled: u64 = 2;
const EBurnDisabled: u64 = 3;
const ECannotUpdateName: u64 = 4;
const ECannotUpdateSymbol: u64 = 5;
const ECannotUpdateDescription: u64 = 6;
const ECannotUpdateIcon: u64 = 7;
const EMaxSupply: u64 = 8;
const EUnsupportedActionVersion: u64 = 9;
const ENoMetadataCap: u64 = 10;

// === Action Type Markers ===

/// Lock treasury cap
public struct CurrencyLockCap has drop {}
/// Disable currency operations
public struct CurrencyDisable has drop {}
/// Mint new currency
public struct CurrencyMint has drop {}
/// Burn currency
public struct CurrencyBurn has drop {}
/// Update currency metadata
public struct CurrencyUpdate has drop {}

public fun currency_lock_cap(): CurrencyLockCap { CurrencyLockCap {} }
public fun currency_disable(): CurrencyDisable { CurrencyDisable {} }
public fun currency_mint(): CurrencyMint { CurrencyMint {} }
public fun currency_burn(): CurrencyBurn { CurrencyBurn {} }
public fun currency_update(): CurrencyUpdate { CurrencyUpdate {} }

// === Structs ===

/// Dynamic Object Field key for the TreasuryCap.
public struct TreasuryCapKey<phantom CoinType>() has copy, drop, store;
/// Dynamic Object Field key for the MetadataCap.
public struct MetadataCapKey<phantom CoinType>() has copy, drop, store;
/// Dynamic Field key for the CurrencyRules.
public struct CurrencyRulesKey<phantom CoinType>() has copy, drop, store;
/// Dynamic Field wrapper restricting access to a TreasuryCap, permissions are disabled forever if set.
public struct CurrencyRules<phantom CoinType> has store {
    // coin can have a fixed supply, can_mint must be true to be able to mint more
    max_supply: Option<u64>,
    // total amount minted
    total_minted: u64,
    // total amount burned
    total_burned: u64,
    // permissions
    can_mint: bool,
    can_burn: bool,
    can_update_symbol: bool,
    can_update_name: bool,
    can_update_description: bool,
    can_update_icon: bool,
}

/// Action disabling permissions marked as true, cannot be reenabled.
public struct DisableAction<phantom CoinType> has store, drop {
    mint: bool,
    burn: bool,
    update_symbol: bool,
    update_name: bool,
    update_description: bool,
    update_icon: bool,
}
/// Action minting new coins.
public struct MintAction<phantom CoinType> has store, drop {
    amount: u64,
}
/// Action burning coins.
public struct BurnAction<phantom CoinType> has store, drop {
    amount: u64,
}
/// Action updating a Currency object in CoinRegistry using MetadataCap.
public struct UpdateAction<phantom CoinType> has store, drop {
    symbol: Option<String>,
    name: Option<String>,
    description: Option<String>,
    icon_url: Option<String>,
}

// === Public functions ===

/// Authenticated users can lock a TreasuryCap and optionally MetadataCap.
public fun lock_cap<CoinType>(
    auth: Auth,
    account: &mut Account,
    registry: &PackageRegistry,
    treasury_cap: TreasuryCap<CoinType>,
    metadata_cap: Option<MetadataCap<CoinType>>,
    max_supply: Option<u64>,
) {
    account.verify(auth);

    let rules = CurrencyRules<CoinType> {
        max_supply,
        total_minted: 0,
        total_burned: 0,
        can_mint: true,
        can_burn: true,
        can_update_symbol: true,
        can_update_name: true,
        can_update_description: true,
        can_update_icon: true,
    };
    account.add_managed_data(registry, CurrencyRulesKey<CoinType>(), rules, version::current());
    account.add_managed_asset(registry, TreasuryCapKey<CoinType>(), treasury_cap, version::current());

    // Store MetadataCap if provided
    if (metadata_cap.is_some()) {
        account.add_managed_asset(registry, MetadataCapKey<CoinType>(), metadata_cap.destroy_some(), version::current());
    } else {
        metadata_cap.destroy_none();
    };
}

/// Lock treasury cap and optionally metadata cap during initialization - works on unshared Accounts
/// This function is for use during account creation, before the account is shared.
/// SAFETY: This function MUST only be called on unshared Accounts.
/// Calling this on a shared Account bypasses Auth checks.
public(package) fun do_lock_cap_unshared<CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    treasury_cap: TreasuryCap<CoinType>,
    metadata_cap: Option<MetadataCap<CoinType>>,
) {
    // SAFETY REQUIREMENT: Account must be unshared
    // Default rules with no max supply
    let rules = CurrencyRules<CoinType> {
        max_supply: option::none(),
        total_minted: 0,
        total_burned: 0,
        can_mint: true,
        can_burn: true,
        can_update_symbol: true,
        can_update_name: true,
        can_update_description: true,
        can_update_icon: true,
    };
    account.add_managed_data(registry, CurrencyRulesKey<CoinType>(), rules, version::current());
    account.add_managed_asset(registry, TreasuryCapKey<CoinType>(), treasury_cap, version::current());

    // Store MetadataCap if provided
    if (metadata_cap.is_some()) {
        account.add_managed_asset(registry, MetadataCapKey<CoinType>(), metadata_cap.destroy_some(), version::current());
    } else {
        metadata_cap.destroy_none();
    };
}

/// Mint coins during initialization - works on unshared Accounts
/// Transfers minted coins directly to recipient
/// SAFETY: This function MUST only be called on unshared Accounts.
/// Calling this on a shared Account bypasses Auth checks.
public(package) fun do_mint_unshared< CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    // SAFETY REQUIREMENT: Account must be unshared
    let rules: &mut CurrencyRules<CoinType> =
        account.borrow_managed_data_mut(registry, CurrencyRulesKey<CoinType>(), version::current());

    assert!(rules.can_mint, EMintDisabled);
    if (rules.max_supply.is_some()) {
        let total_supply = rules.total_minted - rules.total_burned;
        assert!(amount + total_supply <= *rules.max_supply.borrow(), EMaxSupply);
    };

    rules.total_minted = rules.total_minted + amount;

    let cap: &mut TreasuryCap<CoinType> =
        account.borrow_managed_asset_mut(registry, TreasuryCapKey<CoinType>(), version::current());

    let coin = cap.mint(amount, ctx);
    transfer::public_transfer(coin, recipient);
}

/// Mint coins to Coin object during initialization - works on unshared Accounts
/// Returns Coin for further use in the same transaction
public(package) fun do_mint_to_coin_unshared< CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    amount: u64,
    ctx: &mut TxContext,
): Coin<CoinType> {
    let rules: &mut CurrencyRules<CoinType> =
        account.borrow_managed_data_mut(registry, CurrencyRulesKey<CoinType>(), version::current());

    assert!(rules.can_mint, EMintDisabled);
    if (rules.max_supply.is_some()) {
        let total_supply = rules.total_minted - rules.total_burned;
        assert!(amount + total_supply <= *rules.max_supply.borrow(), EMaxSupply);
    };

    rules.total_minted = rules.total_minted + amount;

    let cap: &mut TreasuryCap<CoinType> =
        account.borrow_managed_asset_mut(registry, TreasuryCapKey<CoinType>(), version::current());

    cap.mint(amount, ctx)
}

/// Checks if a TreasuryCap exists for a given coin type.
public fun has_cap<CoinType>(
    account: &Account
): bool {
    account.has_managed_asset(TreasuryCapKey<CoinType>())
}

/// Checks if a MetadataCap exists for a given coin type.
public fun has_metadata_cap<CoinType>(
    account: &Account
): bool {
    account.has_managed_asset(MetadataCapKey<CoinType>())
}

/// Borrows a mutable reference to the TreasuryCap for a given coin type.
/// This is used by oracle mints and other patterns that need direct cap access
/// to bypass object-level policies (only Account access matters).
public fun borrow_treasury_cap_mut<CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
): &mut TreasuryCap<CoinType> {
    account.borrow_managed_asset_mut(registry, TreasuryCapKey<CoinType>(), version::current())
}

/// Borrows the CurrencyRules for a given coin type.
public fun borrow_rules<CoinType>(
    account: &Account,
    registry: &PackageRegistry
): &CurrencyRules<CoinType> {
    account.borrow_managed_data(registry, CurrencyRulesKey<CoinType>(), version::current())
}

/// Returns the total supply of a given coin type.
public fun coin_type_supply<CoinType>(account: &Account, registry: &PackageRegistry): u64 {
    let cap: &TreasuryCap<CoinType> =
        account.borrow_managed_asset(registry, TreasuryCapKey<CoinType>(), version::current());
    cap.total_supply()
}

/// Returns the maximum supply of a given coin type.
public fun max_supply<CoinType>(lock: &CurrencyRules<CoinType>): Option<u64> {
    lock.max_supply
}

/// Returns the total amount minted of a given coin type.
public fun total_minted<CoinType>(lock: &CurrencyRules<CoinType>): u64 {
    lock.total_minted
}

/// Returns the total amount burned of a given coin type.
public fun total_burned<CoinType>(lock: &CurrencyRules<CoinType>): u64 {
    lock.total_burned
}

/// Returns true if the coin type can mint.
public fun can_mint<CoinType>(lock: &CurrencyRules<CoinType>): bool {
    lock.can_mint
}

/// Returns true if the coin type can burn.
public fun can_burn<CoinType>(lock: &CurrencyRules<CoinType>): bool {
    lock.can_burn
}

/// Returns true if the coin type can update the symbol.
public fun can_update_symbol<CoinType>(lock: &CurrencyRules<CoinType>): bool {
    lock.can_update_symbol
}

/// Returns true if the coin type can update the name.
public fun can_update_name<CoinType>(lock: &CurrencyRules<CoinType>): bool {
    lock.can_update_name
}

/// Returns true if the coin type can update the description.
public fun can_update_description<CoinType>(lock: &CurrencyRules<CoinType>): bool {
    lock.can_update_description
}

/// Returns true if the coin type can update the icon.
public fun can_update_icon<CoinType>(lock: &CurrencyRules<CoinType>): bool {
    lock.can_update_icon
}

/// Read metadata from Currency in CoinRegistry
/// Simple helper to extract all metadata fields in one call
/// Returns: (decimals, symbol, name, description, icon_url)
public fun read_currency_metadata<CoinType>(
    currency: &Currency<CoinType>,
): (u8, String, String, String, String) {
    (
        coin_registry::decimals(currency),
        coin_registry::symbol(currency),
        coin_registry::name(currency),
        coin_registry::description(currency),
        coin_registry::icon_url(currency)
    )
}

/// Anyone can burn coins they own if enabled.
public fun public_burn<Config: store, CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    coin: Coin<CoinType>
) {
    let rules_mut: &mut CurrencyRules<CoinType> =
        account.borrow_managed_data_mut(registry, CurrencyRulesKey<CoinType>(), version::current());
    assert!(rules_mut.can_burn, EBurnDisabled);
    rules_mut.total_burned = rules_mut.total_burned + coin.value();

    let cap_mut: &mut TreasuryCap<CoinType> =
        account.borrow_managed_asset_mut(registry, TreasuryCapKey<CoinType>(), version::current());
    cap_mut.burn(coin);
}

// === Destruction Functions ===

/// Destroy a MintAction after serialization
public fun destroy_mint_action<CoinType>(action: MintAction<CoinType>) {
    let MintAction { amount: _ } = action;
}

/// Destroy a BurnAction after serialization
public fun destroy_burn_action<CoinType>(action: BurnAction<CoinType>) {
    let BurnAction { amount: _ } = action;
}

// Intent functions

/// Creates a DisableAction and adds it to an intent.
public fun new_disable<Outcome, CoinType, IW: drop>(
    intent: &mut Intent<Outcome>,
    mint: bool,
    burn: bool,
    update_symbol: bool,
    update_name: bool,
    update_description: bool,
    update_icon: bool,
    intent_witness: IW,
) {
    assert!(mint || burn || update_symbol || update_name || update_description || update_icon, ENoChange);

    // Create the action struct with drop ability
    let action = DisableAction<CoinType> { mint, burn, update_symbol, update_name, update_description, update_icon };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with type marker (not action struct)
    intent.add_typed_action(
        currency_disable(),  // Type marker
        action_data,
        intent_witness
    );
}

/// Processes a DisableAction and disables the permissions marked as true.
public fun do_disable<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    version_witness: VersionWitness,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<CurrencyDisable>(spec);


    let action_data = intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let mint = bcs::peel_bool(&mut reader);
    let burn = bcs::peel_bool(&mut reader);
    let update_symbol = bcs::peel_bool(&mut reader);
    let update_name = bcs::peel_bool(&mut reader);
    let update_description = bcs::peel_bool(&mut reader);
    let update_icon = bcs::peel_bool(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    let rules_mut: &mut CurrencyRules<CoinType> =
        account.borrow_managed_data_mut(registry, CurrencyRulesKey<CoinType>(), version_witness);

    // if disabled, can be true or false, it has no effect
    if (mint) rules_mut.can_mint = false;
    if (burn) rules_mut.can_burn = false;
    if (update_symbol) rules_mut.can_update_symbol = false;
    if (update_name) rules_mut.can_update_name = false;
    if (update_description) rules_mut.can_update_description = false;
    if (update_icon) rules_mut.can_update_icon = false;

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Deletes a DisableAction from an expired intent.
public fun delete_disable<CoinType>(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, so it's automatically cleaned up
}

/// Creates an UpdateAction and adds it to an intent.
public fun new_update<Outcome, CoinType, IW: drop>(
    intent: &mut Intent<Outcome>,
    symbol: Option<String>,
    name: Option<String>,
    description: Option<String>,
    icon_url: Option<String>,
    intent_witness: IW,
) {
    assert!(symbol.is_some() || name.is_some() || description.is_some() || icon_url.is_some(), ENoChange);

    // Create the action struct with drop ability
    let action = UpdateAction<CoinType> { symbol, name, description, icon_url };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with type marker (not action struct)
    intent.add_typed_action(
        currency_update(),  // Type marker
        action_data,
        intent_witness
    );
}

/// Processes an UpdateAction, updates the Currency in CoinRegistry.
public fun do_update<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    currency: &mut Currency<CoinType>,
    version_witness: VersionWitness,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<CurrencyUpdate>(spec);


    let action_data = intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);

    // Deserialize Option fields
    let symbol = if (bcs::peel_bool(&mut reader)) {
        option::some(bcs::peel_vec_u8(&mut reader).to_string())
    } else {
        option::none()
    };

    let name = if (bcs::peel_bool(&mut reader)) {
        option::some(bcs::peel_vec_u8(&mut reader).to_string())
    } else {
        option::none()
    };

    let description = if (bcs::peel_bool(&mut reader)) {
        option::some(bcs::peel_vec_u8(&mut reader).to_string())
    } else {
        option::none()
    };

    let icon_url = if (bcs::peel_bool(&mut reader)) {
        option::some(bcs::peel_vec_u8(&mut reader).to_string())
    } else {
        option::none()
    };

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    let rules_mut: &mut CurrencyRules<CoinType> =
        account.borrow_managed_data_mut(registry, CurrencyRulesKey<CoinType>(), version_witness);

    if (!rules_mut.can_update_symbol) assert!(symbol.is_none(), ECannotUpdateSymbol);
    if (!rules_mut.can_update_name) assert!(name.is_none(), ECannotUpdateName);
    if (!rules_mut.can_update_description) assert!(description.is_none(), ECannotUpdateDescription);
    if (!rules_mut.can_update_icon) assert!(icon_url.is_none(), ECannotUpdateIcon);

    // Verify MetadataCap exists (required for updating Currency in CoinRegistry)
    assert!(account.has_managed_asset(MetadataCapKey<CoinType>()), ENoMetadataCap);

    // Get MetadataCap from account
    let metadata_cap: &MetadataCap<CoinType> =
        account.borrow_managed_asset(registry, MetadataCapKey<CoinType>(), version_witness);

    // Update Currency using MetadataCap
    if (symbol.is_some()) {
        coin_registry::set_symbol(currency, metadata_cap, symbol.destroy_some());
    } else {
        symbol.destroy_none();
    };

    if (name.is_some()) {
        coin_registry::set_name(currency, metadata_cap, name.destroy_some());
    } else {
        name.destroy_none();
    };

    if (description.is_some()) {
        coin_registry::set_description(currency, metadata_cap, description.destroy_some());
    } else {
        description.destroy_none();
    };

    if (icon_url.is_some()) {
        coin_registry::set_icon_url(currency, metadata_cap, icon_url.destroy_some());
    } else {
        icon_url.destroy_none();
    };

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Deletes an UpdateAction from an expired intent.
public fun delete_update<CoinType>(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, so it's automatically cleaned up
}

/// Creates a MintAction and adds it to an intent with descriptor.
public fun new_mint<Outcome, CoinType, IW: drop>(
    intent: &mut Intent<Outcome>,
    amount: u64,
    intent_witness: IW,
) {
    // Create the action struct (no drop)
    let action = MintAction<CoinType> { amount };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with type marker (not action struct)
    // Use CurrencyMint marker so validation matches in do_mint
    intent.add_typed_action(
        currency_mint(),  // Type marker
        action_data,
        intent_witness
    );
}

/// Processes a MintAction, mints and returns new coins.
public fun do_mint<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    version_witness: VersionWitness,
    _intent_witness: IW,
    ctx: &mut TxContext
): Coin<CoinType> {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<CurrencyMint>(spec);


    let action_data = intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let amount = bcs::peel_u64(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    let total_supply = currency::coin_type_supply<CoinType>(account, registry);
    let rules_mut: &mut CurrencyRules<CoinType> =
        account.borrow_managed_data_mut(registry, CurrencyRulesKey<CoinType>(), version_witness);

    assert!(rules_mut.can_mint, EMintDisabled);
    if (rules_mut.max_supply.is_some()) assert!(amount + total_supply <= *rules_mut.max_supply.borrow(), EMaxSupply);

    rules_mut.total_minted = rules_mut.total_minted + amount;

    let cap_mut: &mut TreasuryCap<CoinType> =
        account.borrow_managed_asset_mut(registry, TreasuryCapKey<CoinType>(), version_witness);

    // Mint the coin
    let coin = cap_mut.mint(amount, ctx);

    // Store coin info in context for potential use by later actions
    // PTBs handle object flow naturally - no context storage needed

    // Increment action index
    executable::increment_action_idx(executable);

    coin
}

/// Deletes a MintAction from an expired intent.
public fun delete_mint<CoinType>(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, so it's automatically cleaned up
}

/// Creates a BurnAction and adds it to an intent with descriptor.
public fun new_burn<Outcome, CoinType, IW: drop>(
    intent: &mut Intent<Outcome>,
    amount: u64,
    intent_witness: IW,
) {
    // Create the action struct
    let action = BurnAction<CoinType> { amount };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with type marker (not action struct)
    // Use CurrencyBurn marker so validation matches in do_burn
    intent.add_typed_action(
        currency_burn(),  // Type marker
        action_data,
        intent_witness
    );
}

/// Processes a BurnAction, burns coins and returns the amount burned.
public fun do_burn<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    coin: Coin<CoinType>,
    version_witness: VersionWitness,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());

    // CRITICAL: Assert that the action type is what we expect
    action_validation::assert_action_type<CurrencyBurn>(spec);


    let action_data = intents::action_spec_data(spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let amount = bcs::peel_u64(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    assert!(amount == coin.value(), EWrongValue);

    let rules_mut: &mut CurrencyRules<CoinType> =
        account.borrow_managed_data_mut(registry, CurrencyRulesKey<CoinType>(), version_witness);
    assert!(rules_mut.can_burn, EBurnDisabled);

    rules_mut.total_burned = rules_mut.total_burned + amount;

    let cap_mut: &mut TreasuryCap<CoinType> =
        account.borrow_managed_asset_mut(registry, TreasuryCapKey<CoinType>(), version_witness);

    // Increment action index
    executable::increment_action_idx(executable);

    cap_mut.burn(coin);
}

/// Deletes a BurnAction from an expired intent.
public fun delete_burn<CoinType>(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, so it's automatically cleaned up
}
