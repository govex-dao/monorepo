// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// DAO Dissolution and Redemption System
///
/// Enables terminated DAOs to distribute assets proportionally to token holders
/// without transferring assets out of the Account.
///
/// Flow:
/// 1. DAO passes proposal to create DissolutionCapability (with time delay)
/// 2. After unlock time, anyone can redeem asset tokens for pro-rata vault balances
/// 3. Redemption burns asset tokens and withdraws proportionally from vaults
///
/// Safety:
/// - Capability is immutable once created
/// - Time-locked to allow auctions/settlements
/// - Only works on TERMINATED DAOs
/// - Pro-rata calculation prevents draining
/// - Each redemption is atomic and proportional

module futarchy_actions::dissolution_actions;

use account_actions::currency;
use account_actions::vault;
use account_protocol::account::{Self, Account};
use account_protocol::bcs_validation;
use account_protocol::executable::{Self, Executable};
use account_protocol::intents;
use account_protocol::action_validation;
use account_protocol::package_registry::PackageRegistry;
use account_protocol::version_witness::VersionWitness;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_core::version;
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::clock::Clock;
use sui::coin::Coin;
use sui::event;
use sui::object::{Self, ID, UID};
use sui::transfer;

// === Errors ===

const ENotTerminated: u64 = 0;
const EWrongAccount: u64 = 1;
const ETooEarly: u64 = 2;
const ECapabilityAlreadyExists: u64 = 3;
const EInvalidUnlockDelay: u64 = 4;
const EZeroSupply: u64 = 5;
const EWrongAssetType: u64 = 6;

// === Action Type Markers ===

public struct CreateDissolutionCapability has drop {}

// === Structs ===

/// Shared capability proving a DAO is dissolved and ready for redemption
/// Created via governance proposal, becomes active after time delay
public struct DissolutionCapability has key {
    id: UID,
    /// Address of the dissolved DAO Account
    dao_address: address,
    /// When the capability was created (for audit trail)
    created_at_ms: u64,
    /// When redemption becomes available (time-locked)
    unlock_at_ms: u64,
    /// Total asset supply at dissolution (for pro-rata calculation)
    /// Captured from TreasuryCap.total_supply() at creation
    total_asset_supply: u64,
}

// === Events ===

/// Emitted when a dissolution capability is created
public struct DissolutionCapabilityCreated has copy, drop {
    capability_id: ID,
    dao_address: address,
    created_at_ms: u64,
    unlock_at_ms: u64,
    total_asset_supply: u64,
}

/// Emitted when a user redeems tokens
public struct Redemption has copy, drop {
    capability_id: ID,
    user: address,
    asset_amount_burned: u64,
    coin_type_redeemed: String,
    coin_amount_received: u64,
    vault_name: String,
}

// === Public Functions ===

/// Permissionless creation of dissolution capability
/// Anyone can call this after DAO is terminated
/// Reads dissolution parameters from DAO config (set during termination)
///
/// SAFETY:
/// - Only works on terminated DAOs
/// - Validates AssetType matches DAO's configured asset
/// - Parameters come from DAO governance decision (can't be manipulated)
/// - Creates immutable capability with time lock
/// - Can only be called once (prevents multiple capability creation)
public fun create_capability_if_terminated<AssetType>(
    account: &mut Account,
    registry: &PackageRegistry,
    ctx: &mut TxContext,
) {
    // Extract all data we need and validate
    let (unlock_at_ms, terminated_at_ms) = {
        let dao_state = futarchy_config::state_mut_from_account(account, registry);

        // Verify DAO is terminated
        assert!(
            futarchy_config::operational_state(dao_state) == futarchy_config::state_terminated(),
            ENotTerminated
        );

        // Check that capability hasn't been created yet (prevent duplicate creation)
        assert!(
            !futarchy_config::dissolution_capability_created(dao_state),
            ECapabilityAlreadyExists
        );

        // Get dissolution unlock time from config (set during termination)
        let unlock_time_option = futarchy_config::dissolution_unlock_time(dao_state);
        assert!(unlock_time_option.is_some(), ENotTerminated); // Should have been set during termination

        let unlock_ms = *unlock_time_option.borrow();
        let terminated_ms = *futarchy_config::terminated_at(dao_state).borrow();

        // Mark that capability has been created (prevents future calls)
        futarchy_config::mark_dissolution_capability_created(dao_state);

        (unlock_ms, terminated_ms)
    }; // dao_state borrow dropped here

    // CRITICAL: Validate AssetType matches DAO's configured asset type
    // This prevents attackers from creating capabilities with arbitrary token types
    let config = account::config<FutarchyConfig>(account);
    let expected_asset_type = futarchy_config::asset_type(config);
    let actual_asset_type = type_name::with_defining_ids<AssetType>().into_string().to_string();
    assert!(expected_asset_type == &actual_asset_type, EWrongAssetType);

    // Get total asset supply from TreasuryCap
    let total_supply = currency::coin_type_supply<AssetType>(account, registry);
    assert!(total_supply > 0, EZeroSupply);

    // Create capability with parameters from DAO config
    let capability = DissolutionCapability {
        id: object::new(ctx),
        dao_address: account.addr(),
        created_at_ms: terminated_at_ms,  // Use termination time, not creation time
        unlock_at_ms,
        total_asset_supply: total_supply,
    };

    let capability_id = object::id(&capability);

    // Emit creation event
    event::emit(DissolutionCapabilityCreated {
        capability_id,
        dao_address: account.addr(),
        created_at_ms: terminated_at_ms,
        unlock_at_ms,
        total_asset_supply: total_supply,
    });

    // Share the capability so anyone can use it for redemption
    transfer::share_object(capability);
}

/// Check if a dissolution capability exists for a DAO
public fun has_capability(dao_address: address): bool {
    // Note: This would require a registry or dynamic field
    // For now, caller must track capability ID
    // Alternative: store capability ID in DAO config
    false // Placeholder - implement registry if needed
}

/// Get capability info for display/verification
public fun capability_info(cap: &DissolutionCapability): (address, u64, u64, u64) {
    (cap.dao_address, cap.created_at_ms, cap.unlock_at_ms, cap.total_asset_supply)
}

/// Check if capability is unlocked and ready for redemption
public fun is_unlocked(cap: &DissolutionCapability, clock: &Clock): bool {
    clock.timestamp_ms() >= cap.unlock_at_ms
}

/// Redeem asset tokens for a specific coin type from a specific vault
///
/// This is the core permissionless redemption function.
/// Users call this to burn their asset tokens and receive pro-rata share
/// of any coin type held in the DAO's vaults.
///
/// Safety:
/// - Verifies capability matches DAO
/// - Checks time lock has passed
/// - Confirms DAO still terminated
/// - Burns asset tokens before withdrawal
/// - Calculates exact pro-rata share
///
/// Note: Users can call this multiple times for different coin types
public fun redeem<Config: store, AssetType, RedeemCoinType: drop>(
    capability: &DissolutionCapability,
    account: &mut Account,
    registry: &PackageRegistry,
    asset_coins: Coin<AssetType>,
    vault_name: String,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<RedeemCoinType> {
    // === Safety Checks ===

    // 1. Verify capability matches this DAO account
    assert!(capability.dao_address == account.addr(), EWrongAccount);

    // 2. Verify time lock has passed
    assert!(clock.timestamp_ms() >= capability.unlock_at_ms, ETooEarly);

    // 3. Verify DAO is still terminated (can't be reactivated)
    verify_terminated(account, registry);

    // 4. Verify non-zero supply (safety check)
    assert!(capability.total_asset_supply > 0, EZeroSupply);

    // === Calculate Pro-Rata Share ===

    let asset_amount = asset_coins.value();

    // Get current vault balance for this coin type
    let vault_balance = vault::balance<Config, RedeemCoinType>(account, registry, vault_name);

    // Calculate user's proportional share using u128 to prevent overflow
    let share_numerator = (asset_amount as u128);
    let share_denominator = (capability.total_asset_supply as u128);
    let vault_balance_u128 = (vault_balance as u128);

    let redeem_amount = (vault_balance_u128 * share_numerator / share_denominator) as u64;

    // === Burn Asset Tokens ===

    // Burn user's asset tokens using permissionless public_burn
    currency::public_burn<Config, AssetType>(account, registry, asset_coins);

    // === Withdraw Pro-Rata Share ===

    // Withdraw from vault using permissionless withdrawal (no Auth required)
    // Pass DAO address for verification
    let redeemed_coin = vault::withdraw_permissionless<Config, RedeemCoinType>(
        account,
        registry,
        capability.dao_address,
        vault_name,
        redeem_amount,
        ctx,
    );

    // === Emit Event ===

    event::emit(Redemption {
        capability_id: object::id(capability),
        user: ctx.sender(),
        asset_amount_burned: asset_amount,
        coin_type_redeemed: type_name::with_defining_ids<RedeemCoinType>().into_string().to_string(),
        coin_amount_received: redeem_amount,
        vault_name,
    });

    redeemed_coin
}

// === Helper Functions ===

/// Verify DAO is in TERMINATED state
/// Aborts if not terminated
fun verify_terminated(account: &Account, registry: &PackageRegistry) {
    let dao_state = account::borrow_managed_data(
        account,
        registry,
        futarchy_config::new_dao_state_key(),
        version::current()
    );
    let operational_state = futarchy_config::operational_state(dao_state);
    let terminated_state = futarchy_config::state_terminated();
    assert!(operational_state == terminated_state, ENotTerminated);
}

// === Action Structs for Proposal System ===

/// Action data for creating a dissolution capability
/// Note: This is typically called permissionlessly AFTER termination,
/// but can also be included in the termination proposal itself
public struct CreateDissolutionCapabilityAction<phantom AssetType> has store, drop, copy {
    // Empty - all parameters come from DAO config set during termination
}

// === Action Constructors ===

/// Create action for proposal system
public fun new_create_dissolution_capability<AssetType>(): CreateDissolutionCapabilityAction<AssetType> {
    CreateDissolutionCapabilityAction {}
}

// === Execution Functions (for Proposal System) ===

/// Execute create dissolution capability action from proposal
/// This allows dissolution capability creation to be bundled with termination proposal
public fun do_create_dissolution_capability<AssetType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _version: VersionWitness,
    _witness: IW,
    ctx: &mut TxContext,
) {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<CreateDissolutionCapability>(spec);

    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);

    // No fields to deserialize - empty action
    bcs_validation::validate_all_bytes_consumed(reader);

    // Execute capability creation (permissionless function)
    create_capability_if_terminated<AssetType>(
        account,
        registry,
        ctx,
    );

    executable::increment_action_idx(executable);
}

// === Garbage Collection (Delete Functions for Expired Intents) ===

/// Delete create dissolution capability action from expired intent
public fun delete_create_dissolution_capability<AssetType>(expired: &mut intents::Expired) {
    let action_spec = intents::remove_action_spec(expired);
    let action_data = intents::action_spec_action_data(action_spec);
    let mut reader = bcs::new(action_data);

    // No fields to consume - empty action
    let _ = reader.into_remainder_bytes();
}
