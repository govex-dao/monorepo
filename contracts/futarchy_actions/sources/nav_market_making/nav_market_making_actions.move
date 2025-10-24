// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// NAV Market Making System for DAOs
///
/// Enables ongoing mint/redeem operations with caps and time limits.
/// Two modes:
/// 1. BUY-BACK: Users deposit stable coin → DAO mints asset tokens
/// 2. SELL: Users burn asset tokens → DAO releases stable coin
///
/// Flow:
/// 1. DAO passes proposal to create NAV market making capability
/// 2. Capability defines exchange rate, max caps, and expiry
/// 3. Users can buy-back or sell (based on enabled flags)
/// 4. After expiry, capability can be cleaned up
///
/// Safety:
/// - Max caps prevent unlimited drain
/// - Time-locked expiry
/// - Can disable buy-back or sell independently
/// - Exchange rate is immutable once set
/// - Provides liquidity around NAV (Net Asset Value)

module futarchy_actions::nav_market_making_actions;

use account_actions::currency;
use account_actions::vault;
use account_protocol::account::{Self, Account};
use account_protocol::bcs_validation;
use account_protocol::executable::{Self, Executable};
use account_protocol::intents;
use account_protocol::action_validation;
use account_protocol::package_registry::PackageRegistry;
use account_protocol::version_witness::VersionWitness;
use futarchy_core::futarchy_config::{Self, FutarchyConfig, DaoState};
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

const ENotActive: u64 = 0;
const EWrongAccount: u64 = 1;
const EExpired: u64 = 2;
const EWrongAssetType: u64 = 4;
const EWrongStableType: u64 = 5;
const EBuyBackDisabled: u64 = 6;
const ESellDisabled: u64 = 7;
const EMaxBuyBackCapReached: u64 = 8;
const EMaxSellCapReached: u64 = 9;
const EInvalidExchangeRate: u64 = 10;
const EInvalidExpiry: u64 = 11;
const ENotExpired: u64 = 12;
const EInsufficientVaultBalance: u64 = 13;
const EWrongCapabilityId: u64 = 14;

// === Action Type Markers ===

public struct CreateNavMarketMaking has drop {}
public struct CancelNavMarketMaking has drop {}

// === Structs ===

/// Shared capability for NAV market making operations
/// Supports BOTH buy-back and sell strategies simultaneously
/// Created via governance proposal with fixed exchange rates and time limit
public struct NavMarketMakingCapability has key {
    id: object::UID,
    /// Address of the DAO Account
    dao_address: address,
    /// Type name of the asset token (to be minted/burned)
    asset_type: String,
    /// Type name of the stable coin (to be deposited/withdrawn)
    stable_type: String,

    // === PRICING (FIXED RATES) ===
    /// Fixed NAV per token set by governance (immutable)
    /// Uses 6 decimals precision (e.g., 1_000_000 = $1.00 per token)
    nav_per_token: u64,

    /// Vault name for stable coin deposits/withdrawals
    vault_name: String,

    // === BUY-BACK STRATEGY (Fund: Users deposit stable → DAO mints asset) ===
    /// Discount from NAV for buy-back in basis points (e.g., 500 = 5% discount)
    /// Buy-back price = NAV * (10000 - buyback_discount_bps) / 10000
    buyback_discount_bps: u64,
    /// Enable/disable buy-back (deposit stable → mint asset)
    buyback_enabled: bool,
    /// Max total stable coins that can be deposited (buy-back cap)
    max_buyback_stable: u64,
    /// Current total stable coins deposited via buy-back
    current_buyback_stable: u64,

    // === SELL STRATEGY (Redeem: Users burn asset → DAO releases stable) ===
    /// Premium over NAV for sell in basis points (e.g., 1000 = 10% premium)
    /// Sell price = NAV * (10000 + sell_premium_bps) / 10000
    sell_premium_bps: u64,
    /// Enable/disable sell (burn asset → withdraw stable)
    sell_enabled: bool,
    /// Max total stable coins that can be withdrawn (sell cap)
    max_sell_stable: u64,
    /// Current total stable coins withdrawn via sell
    current_sell_stable: u64,

    /// When the capability expires (ms)
    expiry_time_ms: u64,
    /// When capability was created (ms)
    created_at_ms: u64,
}

/// Owned capability to cancel a NavMarketMakingCapability
/// Minted when capability is created and sent to a specified address
/// Holder can cancel the capability at any time (emergency stop)
public struct CancelCap has key, store {
    id: object::UID,
    /// ID of the NavMarketMakingCapability this can cancel
    capability_id: ID,
}

// === Events ===

/// Emitted when a NAV market making capability is created
public struct NavMarketMakingCapabilityCreated has copy, drop {
    capability_id: ID,
    dao_address: address,
    asset_type: String,
    stable_type: String,
    vault_name: String,
    buyback_stable_per_asset: u64,
    buyback_enabled: bool,
    max_buyback_stable: u64,
    sell_stable_per_asset: u64,
    sell_enabled: bool,
    max_sell_stable: u64,
    expiry_time_ms: u64,
}

/// Emitted when a user buys back (deposits stable, mints asset via buy-back)
public struct BuyBack has copy, drop {
    capability_id: ID,
    user: address,
    stable_deposited: u64,
    asset_minted: u64,
}

/// Emitted when a user sells (burns asset, withdraws stable via sell)
public struct Sell has copy, drop {
    capability_id: ID,
    user: address,
    asset_burned: u64,
    stable_withdrawn: u64,
}

/// Emitted when capability is cleaned up after expiry
public struct NavMarketMakingCapabilityDeleted has copy, drop {
    capability_id: ID,
}

/// Emitted when capability is cancelled early using CancelCap
public struct NavMarketMakingCapabilityCancelled has copy, drop {
    capability_id: ID,
    cancelled_by: address,
}


// === Public Functions ===

/// Create a NAV market making capability with BOTH buy-back and sell strategies
/// Called after DAO passes a proposal
///
/// Creates a CancelCap and sends it to cancel_cap_recipient
/// The holder of CancelCap can cancel the capability at any time
///
/// Example: "Allow buyback at $0.95 and sell at $1.10, expires in 7 days"
/// - Governance sets fixed NAV (e.g., $1.00 per token)
/// - Buyback discount of 500 bps = users pay $0.95
/// - Sell premium of 1000 bps = users receive $1.10
/// - After 7 days, capability expires and governance can create a new one with updated rates
///
/// This is SAFER than dynamic NAV calculation because:
/// - No oracle manipulation
/// - No frontrunning
/// - No MEV attacks
/// - Simple and predictable
public fun create_capability<AssetType, StableType>(
    account: &mut Account,
    registry: &PackageRegistry,
    nav_per_token: u64,
    vault_name: String,
    buyback_discount_bps: u64,
    buyback_enabled: bool,
    max_buyback_stable: u64,
    sell_premium_bps: u64,
    sell_enabled: bool,
    max_sell_stable: u64,
    expiry_time_ms: u64,
    cancel_cap_recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate DAO is ACTIVE (not terminated)
    verify_active(account, registry);

    // Validate discount/premium are reasonable (max 50% = 5000 bps)
    if (buyback_enabled) assert!(buyback_discount_bps <= 5000, EInvalidExchangeRate);
    if (sell_enabled) assert!(sell_premium_bps <= 5000, EInvalidExchangeRate);

    // Validate expiry is in the future
    let current_time = clock.timestamp_ms();
    assert!(expiry_time_ms > current_time, EInvalidExpiry);

    // Validate AssetType matches DAO's configured asset type
    let config = account::config<FutarchyConfig>(account);
    let expected_asset_type = futarchy_config::asset_type(config);
    let actual_asset_type = type_name::with_defining_ids<AssetType>().into_string().to_string();
    assert!(expected_asset_type == &actual_asset_type, EWrongAssetType);

    // Validate vault exists
    assert!(vault::has_vault(account, vault_name), EInsufficientVaultBalance);

    // Create capability with BOTH strategies and fixed rates
    let capability = NavMarketMakingCapability {
        id: object::new(ctx),
        dao_address: account.addr(),
        asset_type: actual_asset_type,
        stable_type: type_name::with_defining_ids<StableType>().into_string().to_string(),
        nav_per_token,
        vault_name,
        buyback_discount_bps,
        buyback_enabled,
        max_buyback_stable,
        current_buyback_stable: 0,
        sell_premium_bps,
        sell_enabled,
        max_sell_stable,
        current_sell_stable: 0,
        expiry_time_ms,
        created_at_ms: current_time,
    };

    let capability_id = object::id(&capability);

    // Emit creation event
    event::emit(NavMarketMakingCapabilityCreated {
        capability_id,
        dao_address: account.addr(),
        asset_type: capability.asset_type,
        stable_type: capability.stable_type,
        vault_name,
        buyback_stable_per_asset: buyback_discount_bps, // Repurpose for discount_bps
        buyback_enabled,
        max_buyback_stable,
        sell_stable_per_asset: sell_premium_bps, // Repurpose for premium_bps
        sell_enabled,
        max_sell_stable,
        expiry_time_ms,
    });

    // Create and send CancelCap to recipient
    let cancel_cap = CancelCap {
        id: object::new(ctx),
        capability_id,
    };
    transfer::transfer(cancel_cap, cancel_cap_recipient);

    // Share the capability so anyone can use it
    transfer::share_object(capability);
}

/// Buy-Back: User deposits stable → DAO mints and gives asset tokens
/// DAO "buys back" its tokens by accepting stable and issuing new tokens
/// Anyone can call this if buy-back is enabled
/// Stable coins are deposited to the DAO vault (increases treasury)
/// Price is fixed rate set by governance with a discount
public fun buyback<Config: store, AssetType, StableType: drop>(
    capability: &mut NavMarketMakingCapability,
    account: &mut Account,
    registry: &PackageRegistry,
    stable_coins: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    // === Safety Checks ===

    // 1. Verify capability matches this DAO account
    assert!(capability.dao_address == account.addr(), EWrongAccount);

    // 2. Verify not expired
    assert!(clock.timestamp_ms() < capability.expiry_time_ms, EExpired);

    // 3. Verify buy-back is enabled
    assert!(capability.buyback_enabled, EBuyBackDisabled);

    // 4. Verify stable type matches
    let actual_stable_type = type_name::with_defining_ids<StableType>().into_string().to_string();
    assert!(capability.stable_type == actual_stable_type, EWrongStableType);

    // === Calculate Amounts ===

    let stable_amount = stable_coins.value();

    // Check buy-back cap
    assert!(
        capability.current_buyback_stable + stable_amount <= capability.max_buyback_stable,
        EMaxBuyBackCapReached
    );

    // === Calculate Price (Fixed Rate) ===
    // Apply discount: buyback_price = nav * (10000 - discount_bps) / 10000
    let buyback_price = ((capability.nav_per_token as u128) * ((10000 - capability.buyback_discount_bps) as u128) / 10000u128) as u64;

    // Calculate asset tokens to mint: stable_amount / buyback_price * 1_000_000
    // Using u128 to prevent overflow
    let asset_amount = ((stable_amount as u128) * 1_000_000u128 / (buyback_price as u128)) as u64;

    // === Deposit Stable Coins to Vault ===
    // IMPORTANT: Stable coins go into the DAO vault (increases treasury)
    // This uses permissionless deposit since the stable type should be approved
    vault::deposit_approved<Config, StableType>(account, registry, capability.vault_name, stable_coins);

    // === Mint Asset Tokens ===

    // Mint asset tokens using the TreasuryCap
    let treasury_cap = currency::borrow_treasury_cap_mut<AssetType>(account, registry);
    let asset_coins = treasury_cap.mint(asset_amount, ctx);

    // Update buy-back total
    capability.current_buyback_stable = capability.current_buyback_stable + stable_amount;

    // === Emit Event ===

    event::emit(BuyBack {
        capability_id: object::id(capability),
        user: ctx.sender(),
        stable_deposited: stable_amount,
        asset_minted: asset_amount,
    });

    asset_coins
}

/// Sell: User burns asset → DAO releases stable coins
/// DAO "sells" tokens by accepting burned tokens and releasing stable
/// Anyone can call this if sell is enabled
/// Price is fixed rate set by governance with a premium
public fun sell<Config: store, AssetType, StableType: drop>(
    capability: &mut NavMarketMakingCapability,
    account: &mut Account,
    registry: &PackageRegistry,
    asset_coins: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StableType> {
    // === Safety Checks ===

    // 1. Verify capability matches this DAO account
    assert!(capability.dao_address == account.addr(), EWrongAccount);

    // 2. Verify not expired
    assert!(clock.timestamp_ms() < capability.expiry_time_ms, EExpired);

    // 3. Verify sell is enabled
    assert!(capability.sell_enabled, ESellDisabled);

    // 4. Verify asset type matches
    let actual_asset_type = type_name::with_defining_ids<AssetType>().into_string().to_string();
    assert!(capability.asset_type == actual_asset_type, EWrongAssetType);

    // === Calculate Amounts ===

    let asset_amount = asset_coins.value();

    // === Calculate Price (Fixed Rate) ===
    // Apply premium: sell_price = nav * (10000 + premium_bps) / 10000
    let sell_price = ((capability.nav_per_token as u128) * ((10000 + capability.sell_premium_bps) as u128) / 10000u128) as u64;

    // Calculate stable coins to withdraw: asset_amount * sell_price / 1_000_000
    // Using u128 to prevent overflow
    let stable_amount = ((asset_amount as u128) * (sell_price as u128) / 1_000_000u128) as u64;

    // Check sell cap
    assert!(
        capability.current_sell_stable + stable_amount <= capability.max_sell_stable,
        EMaxSellCapReached
    );

    // Check vault has sufficient balance
    let vault_balance = vault::balance<Config, StableType>(account, registry, capability.vault_name);
    assert!(vault_balance >= stable_amount, EInsufficientVaultBalance);

    // === Burn Asset Tokens ===

    currency::public_burn<Config, AssetType>(account, registry, asset_coins);

    // === Withdraw Stable Coins from Vault ===

    // Use permissionless withdrawal (no Auth required)
    // Safety is enforced by the capability checks above
    let stable_coins = vault::withdraw_permissionless<Config, StableType>(
        account,
        registry,
        capability.dao_address,
        capability.vault_name,
        stable_amount,
        ctx,
    );

    // Update sell total
    capability.current_sell_stable = capability.current_sell_stable + stable_amount;

    // === Emit Event ===

    event::emit(Sell {
        capability_id: object::id(capability),
        user: ctx.sender(),
        asset_burned: asset_amount,
        stable_withdrawn: stable_amount,
    });

    stable_coins
}

/// Cancel capability early using CancelCap (emergency stop)
/// Holder of CancelCap can cancel at any time, even before expiry
/// Consumes the CancelCap and deletes the capability
public fun cancel(
    capability: NavMarketMakingCapability,
    cancel_cap: CancelCap,
    ctx: &TxContext,
) {
    let capability_id = object::id(&capability);

    // Verify CancelCap matches this capability
    assert!(cancel_cap.capability_id == capability_id, EWrongCapabilityId);

    // Emit cancellation event
    event::emit(NavMarketMakingCapabilityCancelled {
        capability_id,
        cancelled_by: ctx.sender(),
    });

    // Destroy capability
    let NavMarketMakingCapability {
        id,
        dao_address: _,
        asset_type: _,
        stable_type: _,
        nav_per_token: _,
        vault_name: _,
        buyback_discount_bps: _,
        buyback_enabled: _,
        max_buyback_stable: _,
        current_buyback_stable: _,
        sell_premium_bps: _,
        sell_enabled: _,
        max_sell_stable: _,
        current_sell_stable: _,
        expiry_time_ms: _,
        created_at_ms: _,
    } = capability;

    object::delete(id);

    // Destroy CancelCap
    let CancelCap { id: cancel_cap_id, capability_id: _ } = cancel_cap;
    object::delete(cancel_cap_id);
}

/// Cleanup expired capability
/// Anyone can call this after expiry to delete the capability
/// Does NOT require CancelCap (permissionless cleanup after expiry)
public fun cleanup_expired(
    capability: NavMarketMakingCapability,
    clock: &Clock,
) {
    // Verify capability is expired
    assert!(clock.timestamp_ms() >= capability.expiry_time_ms, ENotExpired);

    let capability_id = object::id(&capability);

    // Emit deletion event
    event::emit(NavMarketMakingCapabilityDeleted {
        capability_id,
    });

    // Destroy capability
    let NavMarketMakingCapability {
        id,
        dao_address: _,
        asset_type: _,
        stable_type: _,
        nav_per_token: _,
        vault_name: _,
        buyback_discount_bps: _,
        buyback_enabled: _,
        max_buyback_stable: _,
        current_buyback_stable: _,
        sell_premium_bps: _,
        sell_enabled: _,
        max_sell_stable: _,
        current_sell_stable: _,
        expiry_time_ms: _,
        created_at_ms: _,
    } = capability;

    object::delete(id);
}

// === View Functions ===

/// Get capability info for display/verification
/// Returns: (dao_address, asset_type, stable_type, nav_per_token, vault_name, expiry_time_ms)
public fun capability_info(cap: &NavMarketMakingCapability): (
    address,
    String,
    String,
    u64,
    String,
    u64,
) {
    (
        cap.dao_address,
        cap.asset_type,
        cap.stable_type,
        cap.nav_per_token,
        cap.vault_name,
        cap.expiry_time_ms,
    )
}

/// Get buy-back strategy info
/// Returns: (discount_bps, enabled, max_cap, current_total, remaining_capacity)
public fun buyback_info(cap: &NavMarketMakingCapability): (u64, bool, u64, u64, u64) {
    let remaining = cap.max_buyback_stable - cap.current_buyback_stable;
    (
        cap.buyback_discount_bps,
        cap.buyback_enabled,
        cap.max_buyback_stable,
        cap.current_buyback_stable,
        remaining,
    )
}

/// Get sell strategy info
/// Returns: (premium_bps, enabled, max_cap, current_total, remaining_capacity)
public fun sell_info(cap: &NavMarketMakingCapability): (u64, bool, u64, u64, u64) {
    let remaining = cap.max_sell_stable - cap.current_sell_stable;
    (
        cap.sell_premium_bps,
        cap.sell_enabled,
        cap.max_sell_stable,
        cap.current_sell_stable,
        remaining,
    )
}

/// Check if capability is expired
public fun is_expired(cap: &NavMarketMakingCapability, clock: &Clock): bool {
    clock.timestamp_ms() >= cap.expiry_time_ms
}

/// Check if buy-back is available (enabled and under cap)
public fun can_buyback(cap: &NavMarketMakingCapability, stable_amount: u64, clock: &Clock): bool {
    cap.buyback_enabled
        && clock.timestamp_ms() < cap.expiry_time_ms
        && cap.current_buyback_stable + stable_amount <= cap.max_buyback_stable
}

/// Check if sell is available (enabled and not expired)
/// Note: Cannot check cap without calculating NAV (requires Account and pool access)
public fun can_sell(cap: &NavMarketMakingCapability, clock: &Clock): bool {
    cap.sell_enabled && clock.timestamp_ms() < cap.expiry_time_ms
}

/// Get remaining buy-back capacity (in stable coins)
public fun remaining_buyback_capacity(cap: &NavMarketMakingCapability): u64 {
    cap.max_buyback_stable - cap.current_buyback_stable
}

/// Get remaining sell capacity (in stable coins)
public fun remaining_sell_capacity(cap: &NavMarketMakingCapability): u64 {
    cap.max_sell_stable - cap.current_sell_stable
}

// === Action Structs for Proposal System ===

/// Action data for creating a NAV market making capability
public struct CreateNavMarketMakingAction<phantom AssetType, phantom StableType> has store, drop, copy {
    nav_per_token: u64,
    vault_name: String,
    buyback_discount_bps: u64,
    buyback_enabled: bool,
    max_buyback_stable: u64,
    sell_premium_bps: u64,
    sell_enabled: bool,
    max_sell_stable: u64,
    expiry_time_ms: u64,
    cancel_cap_recipient: address,
}

/// Action data for cancelling a NAV market making capability
public struct CancelNavMarketMakingAction has store, drop, copy {
    capability_id: ID,
}

// === Action Constructors ===

/// Create action for proposal system
public fun new_create_nav_market_making<AssetType, StableType>(
    nav_per_token: u64,
    vault_name: String,
    buyback_discount_bps: u64,
    buyback_enabled: bool,
    max_buyback_stable: u64,
    sell_premium_bps: u64,
    sell_enabled: bool,
    max_sell_stable: u64,
    expiry_time_ms: u64,
    cancel_cap_recipient: address,
): CreateNavMarketMakingAction<AssetType, StableType> {
    CreateNavMarketMakingAction {
        nav_per_token,
        vault_name,
        buyback_discount_bps,
        buyback_enabled,
        max_buyback_stable,
        sell_premium_bps,
        sell_enabled,
        max_sell_stable,
        expiry_time_ms,
        cancel_cap_recipient,
    }
}

/// Create cancel action for proposal system
public fun new_cancel_nav_market_making(capability_id: ID): CancelNavMarketMakingAction {
    CancelNavMarketMakingAction { capability_id }
}

// === Execution Functions (for Proposal System) ===

/// Execute create capability action from proposal
public fun do_create_nav_market_making<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    version: VersionWitness,
    _witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<CreateNavMarketMaking>(spec);

    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);

    // Deserialize action data
    let nav_per_token = bcs::peel_u64(&mut reader);
    let vault_name_bytes = bcs::peel_vec_u8(&mut reader);
    let vault_name = std::string::utf8(vault_name_bytes);
    let buyback_discount_bps = bcs::peel_u64(&mut reader);
    let buyback_enabled = bcs::peel_bool(&mut reader);
    let max_buyback_stable = bcs::peel_u64(&mut reader);
    let sell_premium_bps = bcs::peel_u64(&mut reader);
    let sell_enabled = bcs::peel_bool(&mut reader);
    let max_sell_stable = bcs::peel_u64(&mut reader);
    let expiry_time_ms = bcs::peel_u64(&mut reader);
    let cancel_cap_recipient = bcs::peel_address(&mut reader);

    bcs_validation::validate_all_bytes_consumed(reader);

    // Execute capability creation
    create_capability<AssetType, StableType>(
        account,
        registry,
        nav_per_token,
        vault_name,
        buyback_discount_bps,
        buyback_enabled,
        max_buyback_stable,
        sell_premium_bps,
        sell_enabled,
        max_sell_stable,
        expiry_time_ms,
        cancel_cap_recipient,
        clock,
        ctx,
    );

    executable::increment_action_idx(executable);
}

/// Execute cancel action from proposal
public fun do_cancel_nav_market_making<AssetType, StableType, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account,
    _registry: &PackageRegistry,
    _version: VersionWitness,
    _witness: IW,
    capability: NavMarketMakingCapability,
    cancel_cap: CancelCap,
    ctx: &TxContext,
) {
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<CancelNavMarketMaking>(spec);

    // Call the cancel function
    cancel(capability, cancel_cap, ctx);

    executable::increment_action_idx(executable);
}

// === Garbage Collection (Delete Functions for Expired Intents) ===

/// Delete create action from expired intent
public fun delete_create_nav_market_making<AssetType, StableType>(expired: &mut intents::Expired) {
    let action_spec = intents::remove_action_spec(expired);
    let action_data = intents::action_spec_action_data(action_spec);
    let mut reader = bcs::new(action_data);

    // Consume all fields
    reader.peel_u64(); // nav_per_token
    reader.peel_vec_u8(); // vault_name
    reader.peel_u64(); // buyback_discount_bps
    reader.peel_bool(); // buyback_enabled
    reader.peel_u64(); // max_buyback_stable
    reader.peel_u64(); // sell_premium_bps
    reader.peel_bool(); // sell_enabled
    reader.peel_u64(); // max_sell_stable
    reader.peel_u64(); // expiry_time_ms
    reader.peel_address(); // cancel_cap_recipient

    let _ = reader.into_remainder_bytes();
}

/// Delete cancel action from expired intent
public fun delete_cancel_nav_market_making(expired: &mut intents::Expired) {
    let action_spec = intents::remove_action_spec(expired);
    let action_data = intents::action_spec_action_data(action_spec);
    let mut reader = bcs::new(action_data);

    reader.peel_address(); // capability_id as ID

    let _ = reader.into_remainder_bytes();
}

// === Helper Functions ===

/// Verify DAO is in ACTIVE state (not terminated)
fun verify_active(account: &Account, registry: &PackageRegistry) {
    let dao_state: &DaoState = account::borrow_managed_data(
        account,
        registry,
        futarchy_config::new_dao_state_key(),
        version::current()
    );
    assert!(
        futarchy_config::operational_state(dao_state) == futarchy_config::state_active(),
        ENotActive
    );
}
