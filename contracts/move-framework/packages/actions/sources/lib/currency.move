// ============================================================================
// FORK MODIFICATION NOTICE - Type-Based Currency Management
// ============================================================================
// This module manages TreasuryCap and CoinMetadata operations for Account.
//
// CHANGES IN THIS FORK:
// - Actions use type markers: CurrencyMint, CurrencyBurn, CurrencyUpdate, CurrencyDisable
// - Added 'drop' ability to all action structs for hot potato pattern
// - Integrated BCS validation for action deserialization
// - Actions use typed Intent system with add_typed_action()
// - Enhanced imports for better modularity (string::Self, bcs::Self)
// - Type-safe action validation through ActionSpec comparison
// - Compile-time type safety replaces string-based descriptors
// ============================================================================
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
    coin::{Self, Coin, TreasuryCap, CoinMetadata},
    url::{Self, Url},
    bcs::{Self, BCS},
};
use account_protocol::{
    account::{Self, Account, Auth},
    intents::{Self, Expired, Intent},
    executable::{Self, Executable},
    version_witness::VersionWitness,
};
use account_actions::{
    currency,
    version
};
use account_extensions::framework_action_types::{Self, CurrencyDisable, CurrencyMint, CurrencyBurn, CurrencyUpdate};
// === Use Fun Aliases ===
use fun account_protocol::intents::add_typed_action as Intent.add_typed_action;

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

// === Structs ===    

/// Dynamic Object Field key for the TreasuryCap.
public struct TreasuryCapKey<phantom CoinType>() has copy, drop, store;
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
/// Action updating a CoinMetadata object using a locked TreasuryCap.
public struct UpdateAction<phantom CoinType> has store, drop { 
    symbol: Option<ascii::String>,
    name: Option<String>,
    description: Option<String>,
    icon_url: Option<ascii::String>,
}

// === Public functions ===

/// Authenticated users can lock a TreasuryCap.
public fun lock_cap<Config, CoinType>(
    auth: Auth,
    account: &mut Account<Config>,
    treasury_cap: TreasuryCap<CoinType>,
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
    account.add_managed_data(CurrencyRulesKey<CoinType>(), rules, version::current());
    account.add_managed_asset(TreasuryCapKey<CoinType>(), treasury_cap, version::current());
}

/// Checks if a TreasuryCap exists for a given coin type.
public fun has_cap<Config, CoinType>(
    account: &Account<Config>
): bool {
    account.has_managed_asset(TreasuryCapKey<CoinType>())
}

/// Borrows the CurrencyRules for a given coin type.
public fun borrow_rules<Config, CoinType>(
    account: &Account<Config>
): &CurrencyRules<CoinType> {
    account.borrow_managed_data(CurrencyRulesKey<CoinType>(), version::current())
}

/// Returns the total supply of a given coin type.
public fun coin_type_supply<Config, CoinType>(account: &Account<Config>): u64 {
    let cap: &TreasuryCap<CoinType> = 
        account.borrow_managed_asset(TreasuryCapKey<CoinType>(), version::current());
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

/// Anyone can burn coins they own if enabled.
public fun public_burn<Config, CoinType>(
    account: &mut Account<Config>, 
    coin: Coin<CoinType>
) {
    let rules_mut: &mut CurrencyRules<CoinType> = 
        account.borrow_managed_data_mut(CurrencyRulesKey<CoinType>(), version::current());
    assert!(rules_mut.can_burn, EBurnDisabled);
    rules_mut.total_burned = rules_mut.total_burned + coin.value();

    let cap_mut: &mut TreasuryCap<CoinType> = 
        account.borrow_managed_asset_mut(TreasuryCapKey<CoinType>(), version::current());
    cap_mut.burn(coin);
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
    
    intent.add_typed_action(
        DisableAction<CoinType> { mint, burn, update_symbol, update_name, update_description, update_icon },
        framework_action_types::currency_disable(),
        intent_witness
    );
}

/// Processes a DisableAction and disables the permissions marked as true.
public fun do_disable<Config, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());
    let action_data = intents::action_spec_data(spec);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let mint = bcs::peel_bool(&mut reader);
    let burn = bcs::peel_bool(&mut reader);
    let update_symbol = bcs::peel_bool(&mut reader);
    let update_name = bcs::peel_bool(&mut reader);
    let update_description = bcs::peel_bool(&mut reader);
    let update_icon = bcs::peel_bool(&mut reader);

    let rules_mut: &mut CurrencyRules<CoinType> =
        account.borrow_managed_data_mut(CurrencyRulesKey<CoinType>(), version_witness);

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
    symbol: Option<ascii::String>,
    name: Option<String>,
    description: Option<String>,
    icon_url: Option<ascii::String>,
    intent_witness: IW,
) {
    assert!(symbol.is_some() || name.is_some() || description.is_some() || icon_url.is_some(), ENoChange);

    intent.add_typed_action(
        UpdateAction<CoinType> { symbol, name, description, icon_url },
        framework_action_types::currency_update(),
        intent_witness
    );
}

/// Processes an UpdateAction, updates the CoinMetadata.
public fun do_update<Config, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    metadata: &mut CoinMetadata<CoinType>,
    version_witness: VersionWitness,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());
    let action_data = intents::action_spec_data(spec);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);

    // Deserialize Option fields
    let symbol = if (bcs::peel_bool(&mut reader)) {
        option::some(bcs::peel_vec_u8(&mut reader).to_ascii_string())
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
        option::some(bcs::peel_vec_u8(&mut reader).to_ascii_string())
    } else {
        option::none()
    };

    let rules_mut: &mut CurrencyRules<CoinType> =
        account.borrow_managed_data_mut(CurrencyRulesKey<CoinType>(), version_witness);

    if (!rules_mut.can_update_symbol) assert!(symbol.is_none(), ECannotUpdateSymbol);
    if (!rules_mut.can_update_name) assert!(name.is_none(), ECannotUpdateName);
    if (!rules_mut.can_update_description) assert!(description.is_none(), ECannotUpdateDescription);
    if (!rules_mut.can_update_icon) assert!(icon_url.is_none(), ECannotUpdateIcon);

    let (default_symbol, default_name, default_description, default_icon_url) =
        (metadata.get_symbol(), metadata.get_name(), metadata.get_description(), metadata.get_icon_url().extract().inner_url());
    let cap: &TreasuryCap<CoinType> =
        account.borrow_managed_asset(TreasuryCapKey<CoinType>(), version_witness);

    cap.update_symbol(metadata, symbol.get_with_default(default_symbol));
    cap.update_name(metadata, name.get_with_default(default_name));
    cap.update_description(metadata, description.get_with_default(default_description));
    cap.update_icon_url(metadata, icon_url.get_with_default(default_icon_url));

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
    intent.add_typed_action(
        MintAction<CoinType> { amount },
        framework_action_types::currency_mint(),
        intent_witness
    );
}

/// Processes a MintAction, mints and returns new coins.
public fun do_mint<Config, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    _intent_witness: IW,
    ctx: &mut TxContext
): Coin<CoinType> {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());
    let action_data = intents::action_spec_data(spec);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let amount = bcs::peel_u64(&mut reader);

    let total_supply = currency::coin_type_supply<_, CoinType>(account);
    let rules_mut: &mut CurrencyRules<CoinType> =
        account.borrow_managed_data_mut(CurrencyRulesKey<CoinType>(), version_witness);

    assert!(rules_mut.can_mint, EMintDisabled);
    if (rules_mut.max_supply.is_some()) assert!(amount + total_supply <= *rules_mut.max_supply.borrow(), EMaxSupply);

    rules_mut.total_minted = rules_mut.total_minted + amount;

    let cap_mut: &mut TreasuryCap<CoinType> =
        account.borrow_managed_asset_mut(TreasuryCapKey<CoinType>(), version_witness);

    // Increment action index
    executable::increment_action_idx(executable);

    cap_mut.mint(amount, ctx)
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
    intent.add_typed_action(
        BurnAction<CoinType> { amount },
        framework_action_types::currency_burn(),
        intent_witness
    );
}

/// Processes a BurnAction, burns coins and returns the amount burned.
public fun do_burn<Config, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    coin: Coin<CoinType>,
    version_witness: VersionWitness,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());
    let action_data = intents::action_spec_data(spec);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let amount = bcs::peel_u64(&mut reader);

    assert!(amount == coin.value(), EWrongValue);

    let rules_mut: &mut CurrencyRules<CoinType> =
        account.borrow_managed_data_mut(CurrencyRulesKey<CoinType>(), version_witness);
    assert!(rules_mut.can_burn, EBurnDisabled);

    rules_mut.total_burned = rules_mut.total_burned + amount;

    let cap_mut: &mut TreasuryCap<CoinType> =
        account.borrow_managed_asset_mut(TreasuryCapKey<CoinType>(), version_witness);

    // Increment action index
    executable::increment_action_idx(executable);

    cap_mut.burn(coin);
}

/// Deletes a BurnAction from an expired intent.
public fun delete_burn<CoinType>(expired: &mut Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, so it's automatically cleaned up
}

// === Test functions ===

#[test_only] 
public fun toggle_can_mint<Config, CoinType>(account: &mut Account<Config>) {
    let rules_mut: &mut CurrencyRules<CoinType> = account.borrow_managed_data_mut(CurrencyRulesKey<CoinType>(), version::current());
    rules_mut.can_mint = !rules_mut.can_mint;
}

#[test_only] 
public fun toggle_can_burn<Config, CoinType>(account: &mut Account<Config>) {
    let rules_mut: &mut CurrencyRules<CoinType> = account.borrow_managed_data_mut(CurrencyRulesKey<CoinType>(), version::current());
    rules_mut.can_burn = !rules_mut.can_burn;
}

#[test_only] 
public fun toggle_can_update_symbol<Config, CoinType>(account: &mut Account<Config>) {
    let rules_mut: &mut CurrencyRules<CoinType> = account.borrow_managed_data_mut(CurrencyRulesKey<CoinType>(), version::current());
    rules_mut.can_update_symbol = !rules_mut.can_update_symbol;
}

#[test_only] 
public fun toggle_can_update_name<Config, CoinType>(account: &mut Account<Config>) {
    let rules_mut: &mut CurrencyRules<CoinType> = account.borrow_managed_data_mut(CurrencyRulesKey<CoinType>(), version::current());
    rules_mut.can_update_name = !rules_mut.can_update_name;
}

#[test_only] 
public fun toggle_can_update_description<Config, CoinType>(account: &mut Account<Config>) {
    let rules_mut: &mut CurrencyRules<CoinType> = account.borrow_managed_data_mut(CurrencyRulesKey<CoinType>(), version::current());
    rules_mut.can_update_description = !rules_mut.can_update_description;
}

#[test_only] 
public fun toggle_can_update_icon<Config, CoinType>(account: &mut Account<Config>) {
    let rules_mut: &mut CurrencyRules<CoinType> = account.borrow_managed_data_mut(CurrencyRulesKey<CoinType>(), version::current());
    rules_mut.can_update_icon = !rules_mut.can_update_icon;
}