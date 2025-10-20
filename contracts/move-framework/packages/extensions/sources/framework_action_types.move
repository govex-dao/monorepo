// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Type markers for Move Framework actions.
module account_extensions::framework_action_types;

// NO IMPORTS - This is critical to avoid circular dependencies

// Note: In Sui Move, empty structs cannot be instantiated from other modules
// without constructor functions, even if the struct is public.
// We provide minimal constructors only for cross-module instantiation.

// ======== Vault Actions ========

/// Deposit coins into vault
public struct VaultDeposit has drop {}

/// Spend coins from vault
public struct VaultSpend has drop {}

/// Approve coin type for permissionless deposits
public struct VaultApproveCoinType has drop {}

/// Remove coin type approval
public struct VaultRemoveApprovedCoinType has drop {}

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

/// Create and transfer commit cap (governance action)
public struct PackageCreateCommitCap has drop {}

// ======== Vesting Actions ========

/// Create vesting schedule
public struct VestingCreate has drop {}

/// Cancel vesting schedule
public struct VestingCancel has drop {}

/// Toggle vesting pause (pause/resume)
public struct ToggleVestingPause has drop {}

/// Toggle vesting emergency freeze
public struct ToggleVestingFreeze has drop {}

/// Toggle stream pause (pause/resume)
public struct ToggleStreamPause has drop {}

/// Toggle stream emergency freeze
public struct ToggleStreamFreeze has drop {}

/// Cancel stream
public struct CancelStream has drop {}

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

/// Withdraw owned object by ID
public struct OwnedWithdrawObject has drop {}

/// Withdraw owned coin by type and amount
public struct OwnedWithdrawCoin has drop {}

// ======== Memo Actions ========

/// Emit a text memo with optional object reference
public struct Memo has drop {}

// ======== Minimal Constructors for Cross-Module Usage ========
// These are required because Sui Move doesn't allow instantiating
// empty structs from other modules without constructors.

public fun vault_deposit(): VaultDeposit { VaultDeposit {} }

public fun vault_spend(): VaultSpend { VaultSpend {} }

public fun vault_approve_coin_type(): VaultApproveCoinType { VaultApproveCoinType {} }

public fun vault_remove_approved_coin_type(): VaultRemoveApprovedCoinType { VaultRemoveApprovedCoinType {} }

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

public fun package_create_commit_cap(): PackageCreateCommitCap { PackageCreateCommitCap {} }

public fun vesting_create(): VestingCreate { VestingCreate {} }

public fun vesting_cancel(): VestingCancel { VestingCancel {} }

public fun toggle_vesting_pause(): ToggleVestingPause { ToggleVestingPause {} }

public fun toggle_vesting_freeze(): ToggleVestingFreeze { ToggleVestingFreeze {} }

public fun toggle_stream_pause(): ToggleStreamPause { ToggleStreamPause {} }

public fun toggle_stream_freeze(): ToggleStreamFreeze { ToggleStreamFreeze {} }

public fun cancel_stream(): CancelStream { CancelStream {} }

public fun config_update_deps(): ConfigUpdateDeps { ConfigUpdateDeps {} }

public fun config_toggle_unverified(): ConfigToggleUnverified { ConfigToggleUnverified {} }

public fun config_update_metadata(): ConfigUpdateMetadata { ConfigUpdateMetadata {} }

public fun config_update_deposits(): ConfigUpdateDeposits { ConfigUpdateDeposits {} }

public fun config_manage_whitelist(): ConfigManageWhitelist { ConfigManageWhitelist {} }

public fun owned_withdraw_object(): OwnedWithdrawObject { OwnedWithdrawObject {} }

public fun owned_withdraw_coin(): OwnedWithdrawCoin { OwnedWithdrawCoin {} }

public fun memo(): Memo { Memo {} }
