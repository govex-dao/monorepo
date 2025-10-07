/// Vault operations for futarchy accounts with controlled coin type access
/// Allows permissionless deposits of existing coin types but requires governance for new types
module futarchy_vault::futarchy_vault;

// === Imports ===
use std::{
    string::{Self, String},
    type_name::{Self, TypeName},
};
use sui::{
    coin::Coin,
    event,
    vec_set::{Self, VecSet},
    object::{Self, ID},
    tx_context::{Self, TxContext},
};
use account_protocol::{
    account::{Self, Account, Auth},
    executable::{Self, Executable},
    intents::{Self, Expired},
    version_witness::VersionWitness,
};
use account_actions::vault;
use futarchy_core::version;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_core::{action_types, action_validation};
use sui::bcs;
use futarchy_markets::{
};

// === Errors ===
const ECoinTypeNotAllowed: u64 = 1;
const EVaultNotInitialized: u64 = 2;
const ECoinTypeDoesNotExist: u64 = 3;

// Public error code accessors for testing
public fun e_coin_type_not_allowed(): u64 { ECoinTypeNotAllowed }
public fun e_vault_not_initialized(): u64 { EVaultNotInitialized }
public fun e_coin_type_does_not_exist(): u64 { ECoinTypeDoesNotExist }

// === Constants ===
const ALLOWED_COINS_KEY: vector<u8> = b"allowed_coin_types";
const DEFAULT_VAULT_NAME: vector<u8> = b"treasury";

/// Get the default vault name (treasury) - the source of truth for the DAO's main vault
public fun default_vault_name(): vector<u8> {
    DEFAULT_VAULT_NAME
}

// === Structs ===

/// Witness for FutarchyConfig authorization
public struct FutarchyConfigWitness has drop {}

/// Event emitted when revenue is deposited to a DAO
public struct RevenueDeposited has copy, drop {
    dao_id: ID,
    depositor: address,
    coin_type: TypeName,
    amount: u64,
    vault_name: String,
}

/// Tracks which coin types are allowed in the vault
public struct AllowedCoinTypes has store {
    types: VecSet<TypeName>,
}

/// Action to add a new coin type to the allowed list (requires governance)
public struct AddCoinTypeAction<phantom CoinType> has store {
    vault_name: String,
}

/// Action to remove a coin type from the allowed list (requires governance)
public struct RemoveCoinTypeAction<phantom CoinType> has store {
    vault_name: String,
}

// === Public Functions ===

/// Initialize vault for a futarchy account
public fun init_vault<Config>(
    account: &mut Account<Config>,
    version: VersionWitness,
    ctx: &mut TxContext
) {
    // Don't store our own vault - rely on account_actions::vault
    // We only need to track allowed coin types for governance control
    
    // Initialize allowed coin types set
    let allowed = AllowedCoinTypes {
        types: vec_set::empty(),
    };
    
    account::add_managed_data(
        account,
        ALLOWED_COINS_KEY,
        allowed,
        version,
    );
    
    // The actual vault opening is handled by account_actions::vault module
    // through proper Auth when needed
}

/// Check if a coin type is allowed in the vault
public fun is_coin_type_allowed<Config, CoinType>(
    account: &Account<Config>,
): bool {
    // Check if the allowed coins list exists
    if (!account::has_managed_data(account, ALLOWED_COINS_KEY)) {
        return false
    };
    
    let allowed: &AllowedCoinTypes = account::borrow_managed_data(
        account,
        ALLOWED_COINS_KEY,
        version::current()
    );
    allowed.types.contains(&type_name::with_defining_ids<CoinType>())
}

/// PERMISSIONLESS: Deposit coins of a type that already exists in the vault
/// Anyone can deposit if the DAO already holds this coin type
/// This bypasses auth requirements since it's just adding to existing balances
public fun deposit_existing_coin_type<CoinType: drop>(
    account: &mut Account<FutarchyConfig>,
    coin: Coin<CoinType>,
    vault_name: String,
    _ctx: &mut TxContext,
) {
    // Check if the vault exists and has this coin type
    assert!(vault::has_vault(account, vault_name), EVaultNotInitialized);
    let vault_ref = vault::borrow_vault(account, vault_name);
    assert!(vault::coin_type_exists<CoinType>(vault_ref), ECoinTypeDoesNotExist);
    
    // Use the permissionless deposit function from vault module
    // This is safe because:
    // 1. We're only adding to existing coin types
    // 2. Deposits don't reduce DAO assets
    // 3. This enables permissionless revenue/donations
    vault::deposit_permissionless(account, vault_name, coin);
}

/// ENTRY: Public entry function for depositing revenue/donations to a DAO
/// Anyone can send coins of a type the DAO already holds
public entry fun deposit_revenue<CoinType: drop>(
    account: &mut Account<FutarchyConfig>,
    coin: Coin<CoinType>,
    ctx: &mut TxContext,
) {
    // Use treasury vault name for revenue deposits
    let vault_name = string::utf8(default_vault_name());
    let amount = coin.value();
    let dao_id = object::id(account);
    
    // Deposit only if DAO already has this coin type
    deposit_existing_coin_type<CoinType>(account, coin, vault_name, ctx);
    
    // Emit event for transparency
    event::emit(RevenueDeposited {
        dao_id,
        depositor: tx_context::sender(ctx),
        coin_type: type_name::with_defining_ids<CoinType>(),
        amount,
        vault_name,
    });
}

// TODO: Fix deposit_new_coin_type - vault::deposit signature changed

/// GOVERNANCE ONLY: Add a new coin type to the allowed list
/// This should only be called through a governance proposal
public fun do_add_coin_type<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    _ctx: &mut TxContext,
) {
    // Get action spec and deserialize
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Assert action type
    action_validation::assert_action_type<action_types::AddCoinType>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let vault_name = bcs::peel_vec_u8(&mut bcs).to_string();

    // Increment action index
    executable::increment_action_idx(executable);
    
    // Add coin type to allowed list
    let allowed: &mut AllowedCoinTypes = account::borrow_managed_data_mut(
        account,
        ALLOWED_COINS_KEY,
        version
    );
    
    let type_name = type_name::with_defining_ids<CoinType>();
    if (!allowed.types.contains(&type_name)) {
        allowed.types.insert(type_name);
    };
    
    // Note: The vault itself will automatically create storage for this type
    // when the first deposit happens
    let _ = vault_name;
}

/// GOVERNANCE ONLY: Remove a coin type from the allowed list
public fun do_remove_coin_type<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    _ctx: &mut TxContext,
) {
    // Get action spec and deserialize
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Assert action type
    action_validation::assert_action_type<action_types::RemoveCoinType>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut bcs = bcs::new(*action_data);
    let vault_name = bcs::peel_vec_u8(&mut bcs).to_string();

    // Increment action index
    executable::increment_action_idx(executable);
    
    // Remove coin type from allowed list
    let allowed: &mut AllowedCoinTypes = account::borrow_managed_data_mut(
        account,
        ALLOWED_COINS_KEY,
        version
    );
    
    let type_name = type_name::with_defining_ids<CoinType>();
    if (allowed.types.contains(&type_name)) {
        allowed.types.remove(&type_name);
    };
    
    // Note: This doesn't remove existing coins of this type from the vault,
    // it just prevents future deposits
    let _ = vault_name;
}

// === Helper Functions ===

/// Create a new add coin type action
public fun new_add_coin_type_action<CoinType>(
    vault_name: String,
): AddCoinTypeAction<CoinType> {
    AddCoinTypeAction { vault_name }
}

/// Create a new remove coin type action
public fun new_remove_coin_type_action<CoinType>(
    vault_name: String,
): RemoveCoinTypeAction<CoinType> {
    RemoveCoinTypeAction { vault_name }
}

// === Cleanup Functions ===

/// Delete an add coin type action from an expired intent
public fun delete_add_coin_type<CoinType>(expired: &mut Expired) {
    let spec = expired.remove_action_spec();
    let action_data = intents::action_spec_data(&spec);
    let mut bcs = bcs::new(*action_data);
    let vault_name = bcs::peel_vec_u8(&mut bcs);
    let _ = vault_name;
}

/// Delete a remove coin type action from an expired intent
public fun delete_remove_coin_type<CoinType>(expired: &mut Expired) {
    let spec = expired.remove_action_spec();
    let action_data = intents::action_spec_data(&spec);
    let mut bcs = bcs::new(*action_data);
    let vault_name = bcs::peel_vec_u8(&mut bcs);
    let _ = vault_name;
}