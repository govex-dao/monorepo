/// === FORK MODIFICATIONS ===
/// This file defines type markers for ALL Move Framework actions.
/// 
/// PURPOSE:
/// - Provides compile-time type safety for action routing
/// - Replaces string-based action identification
/// - Avoids circular dependencies by defining types in extensions layer
/// - Each action in protocol/actions packages has a corresponding type here
///
/// DESIGN:
/// - Empty structs with `drop` ability serve as type tags
/// - Constructor functions enable cross-module instantiation
/// - No logic, just pure type definitions
/// - Used by intents system for type-based action routing
///
/// Pure type definitions for Move Framework action types
/// This module has NO dependencies and defines ONLY types (no logic)
/// Can be imported by both protocol layer and application layer
module account_extensions::framework_action_types {
    // NO IMPORTS - This is critical to avoid circular dependencies
    
    // Note: In Sui Move, empty structs cannot be instantiated from other modules
    // without constructor functions, even if the struct is public.
    // We provide minimal constructors only for cross-module instantiation.
    
    // ======== Vault Actions ========
    
    /// Deposit coins into vault  
    public struct VaultDeposit has drop {}
    
    /// Spend coins from vault
    public struct VaultSpend has drop {}
    
    // ======== Transfer Actions ========

    /// Transfer object ownership
    public struct TransferObject has drop {}

    /// Transfer object to transaction sender (for crank incentives)
    public struct TransferToSender has drop {}
    
    // ======== Currency Actions ========
    
    /// Lock treasury cap (for future intent-based usage)
    public struct CurrencyLockCap has drop {}
    
    /// Disable currency operations
    public struct CurrencyDisable has drop {}
    
    /// Mint new currency
    public struct CurrencyMint has drop {}
    
    /// Burn currency
    public struct CurrencyBurn has drop {}
    
    /// Update currency metadata
    public struct CurrencyUpdate has drop {}
    
    // ======== Access Control Actions ========
    
    /// Store/lock capability (for future intent-based usage)
    public struct AccessControlStore has drop {}
    
    /// Borrow capability
    public struct AccessControlBorrow has drop {}
    
    /// Return borrowed capability
    public struct AccessControlReturn has drop {}
    
    // ======== Package Upgrade Actions ========
    
    /// Upgrade package
    public struct PackageUpgrade has drop {}
    
    /// Commit upgrade
    public struct PackageCommit has drop {}
    
    /// Restrict upgrade policy
    public struct PackageRestrict has drop {}
    
    // ======== Kiosk Actions ========
    
    /// Take item from kiosk
    public struct KioskTake has drop {}
    
    /// List item in kiosk
    public struct KioskList has drop {}
    
    // ======== Vesting Actions ========
    
    /// Create vesting schedule
    public struct VestingCreate has drop {}
    
    /// Cancel vesting schedule
    public struct VestingCancel has drop {}
    
    // ======== Configuration Actions ========
    
    /// Update account dependencies
    public struct ConfigUpdateDeps has drop {}
    
    /// Toggle unverified packages allowed
    public struct ConfigToggleUnverified has drop {}
    
    /// Update account metadata
    public struct ConfigUpdateMetadata has drop {}
    
    /// Configure object deposit settings
    public struct ConfigUpdateDeposits has drop {}
    
    /// Manage type whitelist for deposits
    public struct ConfigManageWhitelist has drop {}
    
    // ======== Owned Actions ========
    
    /// Withdraw owned object
    public struct OwnedWithdraw has drop {}
    
    // ======== Minimal Constructors for Cross-Module Usage ========
    // These are required because Sui Move doesn't allow instantiating
    // empty structs from other modules without constructors.
    
    public fun vault_deposit(): VaultDeposit { VaultDeposit {} }
    public fun vault_spend(): VaultSpend { VaultSpend {} }
    public fun transfer_object(): TransferObject { TransferObject {} }
    public fun currency_lock_cap(): CurrencyLockCap { CurrencyLockCap {} }
    public fun currency_disable(): CurrencyDisable { CurrencyDisable {} }
    public fun currency_mint(): CurrencyMint { CurrencyMint {} }
    public fun currency_burn(): CurrencyBurn { CurrencyBurn {} }
    public fun currency_update(): CurrencyUpdate { CurrencyUpdate {} }
    public fun access_control_store(): AccessControlStore { AccessControlStore {} }
    public fun access_control_borrow(): AccessControlBorrow { AccessControlBorrow {} }
    public fun access_control_return(): AccessControlReturn { AccessControlReturn {} }
    public fun package_upgrade(): PackageUpgrade { PackageUpgrade {} }
    public fun package_commit(): PackageCommit { PackageCommit {} }
    public fun package_restrict(): PackageRestrict { PackageRestrict {} }
    public fun kiosk_take(): KioskTake { KioskTake {} }
    public fun kiosk_list(): KioskList { KioskList {} }
    public fun vesting_create(): VestingCreate { VestingCreate {} }
    public fun vesting_cancel(): VestingCancel { VestingCancel {} }
    public fun config_update_deps(): ConfigUpdateDeps { ConfigUpdateDeps {} }
    public fun config_toggle_unverified(): ConfigToggleUnverified { ConfigToggleUnverified {} }
    public fun config_update_metadata(): ConfigUpdateMetadata { ConfigUpdateMetadata {} }
    public fun config_update_deposits(): ConfigUpdateDeposits { ConfigUpdateDeposits {} }
    public fun config_manage_whitelist(): ConfigManageWhitelist { ConfigManageWhitelist {} }
    public fun owned_withdraw(): OwnedWithdraw { OwnedWithdraw {} }
}