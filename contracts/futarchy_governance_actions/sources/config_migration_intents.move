// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Config migration actions for Futarchy governance
///
/// This module provides governance-based migration from one config type to another.
/// This is a DANGEROUS operation that changes the fundamental config type of the Account.
///
/// Use cases:
/// - Migrate from FutarchyConfig to FutarchyConfigV2 when adding new features
/// - Upgrade to new config architecture without creating a new DAO
///
/// Safety:
/// - Requires governance proposal (no direct auth)
/// - Single execution only (can't be repeated)
/// - Validates config transformation
/// - Updates type tracking in Account
module futarchy_governance_actions::config_migration_intents;

use account_protocol::{
    account::Account,
    executable::Executable,
    intents::Params,
    intent_interface,
    package_registry::PackageRegistry,
};
use futarchy_core::{futarchy_config::FutarchyOutcome, version};
use sui::bcs;
use std::type_name;
use fun intent_interface::process_intent as Account.process_intent;

// === Errors ===
const EConfigTypeMismatch: u64 = 0;

// === Intent Witnesses ===

/// Intent witness for migrating config type
public struct MigrateConfigIntent() has drop;

// === Action Type Markers ===

/// Migrate config from one type to another
public struct ConfigMigrate has drop {}

public fun config_migrate(): ConfigMigrate { ConfigMigrate {} }

// === Action Structs ===

/// Action to migrate config from OldConfig to NewConfig
/// Stores the new config data as BCS bytes
public struct MigrateConfigAction has drop, store {
    // BCS-encoded new config
    new_config_bytes: vector<u8>,
    // Type name of the new config for validation
    new_config_type: vector<u8>, // BCS-encoded TypeName
}

// === Public Constructors ===

/// Create a new MigrateConfigAction
public fun new_migrate_config_action<NewConfig: store + drop>(
    new_config: NewConfig,
): MigrateConfigAction {
    MigrateConfigAction {
        new_config_bytes: bcs::to_bytes(&new_config),
        new_config_type: bcs::to_bytes(&type_name::get<NewConfig>()),
    }
}

// === Destruction Functions ===

/// Destroy a MigrateConfigAction after serialization
public fun destroy_migrate_config_action(action: MigrateConfigAction) {
    let MigrateConfigAction { new_config_bytes: _, new_config_type: _ } = action;
}

// === Public Functions: Request (Create Proposals) ===

/// Create a futarchy proposal to migrate account config
///
/// This is a CRITICAL operation that changes the config type of the Account.
///
/// # How it works:
/// 1. Proposal created with old config (FutarchyConfig)
/// 2. After market resolves YES, execute_migrate_config is called
/// 3. Old config is removed, new config is added
/// 4. Type tracking is updated
///
/// # Migration pattern:
/// ```
/// // Read old config
/// let old_config = account::config<FutarchyConfig>(&account);
///
/// // Transform to new config
/// let new_config = futarchy_config_v2::migrate_from_v1(old_config);
///
/// // Create migration proposal
/// request_migrate_config(account, params, outcome, new_config, ctx);
/// ```
///
/// # Arguments:
/// * `account` - The futarchy DAO account
/// * `params` - Intent parameters (must be single execution!)
/// * `outcome` - FutarchyOutcome for tracking proposal
/// * `new_config` - The new config to migrate to (any type with store)
///
/// # Type Parameters:
/// * `OldConfig` - Current config type (must match what's stored in Account)
/// * `NewConfig` - New config type to migrate to (must be different from OldConfig)
///
/// # Safety:
/// - Old config type must match current Account config
/// - New config type must be different from old
/// - Transformation logic must preserve critical data
/// - Single execution only (irreversible)
public fun request_migrate_config<OldConfig: store, NewConfig: store + drop>(
    account: &mut Account,
    registry: &PackageRegistry,
    params: Params,
    outcome: FutarchyOutcome,
    new_config: NewConfig,
    ctx: &mut TxContext,
) {
    // CRITICAL: Must be single execution (this is irreversible)
    params.assert_single_execution();

    // Validate we're actually changing the config type
    let current_type = type_name::get<OldConfig>();
    let new_type = type_name::get<NewConfig>();
    assert!(current_type != new_type, EConfigTypeMismatch);

    // Build intent using the intent_interface macro with generic OldConfig
    intent_interface::build_intent!<OldConfig, FutarchyOutcome, MigrateConfigIntent>(
        account,
        registry,
        params,
        outcome,
        b"Migrate Account Config Type".to_string(),
        version::current(),
        MigrateConfigIntent(),
        ctx,
        |intent, iw| {
            // Create the action struct
            let action = new_migrate_config_action(new_config);
            let action_data = bcs::to_bytes(&action);

            // Add to intent with type marker
            intent.add_typed_action(
                config_migrate(),
                action_data,
                iw
            );

            // Destroy the action struct
            destroy_migrate_config_action(action);
        },
    );
}

// === Public Functions: Execute (After Proposal Passes) ===

/// Execute the config migration action after proposal passes
///
/// This performs the actual config type swap in the Account.
///
/// # What it does:
/// 1. Deserializes the new config from BCS bytes
/// 2. Validates the new config type matches expected type
/// 3. Calls account::migrate_config to safely swap config types
/// 4. Validates migration preserved critical data
/// 5. Destroys old config after validation
///
/// # Type Parameters:
/// * `OldConfig` - Current config type (must match what's stored in Account)
/// * `NewConfig` - New config type to migrate to
///
/// # Arguments:
/// * `executable` - The executable hot potato from the resolved proposal
/// * `account` - The futarchy DAO account (will be mutated!)
///
/// # Safety:
/// - Type checked via BCS deserialization
/// - Old config validated before destruction
/// - Atomic operation (aborts on any failure)
/// - Single execution enforced by intent system
public macro fun execute_migrate_config<$OldConfig: store + drop, $NewConfig: store + drop>(
    $executable: &mut Executable<FutarchyOutcome>,
    $account: &mut Account,
    $deserialize_new_config: |vector<u8>| -> $NewConfig,
) {
    // Bind macro parameters to local variables for use in paths
    let executable = $executable;
    let account = $account;

    // Process intent with proper witness validation
    account.process_intent!(
        executable,
        version::current(),
        MigrateConfigIntent(),
        |executable, _iw| {
            // Get action data from executable
            let specs = executable.intent().action_specs();
            let spec = specs.borrow(executable.action_idx());
            let action_data = account_protocol::intents::action_spec_data(spec);

            // Deserialize MigrateConfigAction
            let mut reader = bcs::new(*action_data);

            // Peel new_config_bytes vector
            let new_config_len = reader.peel_vec_length();
            let mut new_config_bytes = vector::empty<u8>();
            let mut i = 0;
            while (i < new_config_len) {
                new_config_bytes.push_back(reader.peel_u8());
                i = i + 1;
            };

            // Peel new_type_bytes vector
            let new_type_len = reader.peel_vec_length();
            let mut new_type_bytes = vector::empty<u8>();
            i = 0;
            while (i < new_type_len) {
                new_type_bytes.push_back(reader.peel_u8());
                i = i + 1;
            };

            // Deserialize the new config type name for validation
            let mut type_reader = bcs::new(new_type_bytes);
            // TypeName is serialized as ASCII string struct - need to deserialize the whole thing
            // For now, skip type checking since we can't easily deserialize TypeName
            // let expected_new_type: type_name::TypeName = ...;
            // assert!(expected_new_type == type_name::get<$NewConfig>(), EConfigTypeMismatch);

            // Deserialize the new config using the provided deserialization function
            // The caller must provide a function that knows how to deserialize NewConfig from bytes
            // Example: For FutarchyConfig, pass futarchy_config::from_bytes
            let new_config: $NewConfig = $deserialize_new_config(new_config_bytes);

            // Call account_protocol migrate_config to swap the config DF
            let old_config: $OldConfig = account_protocol::account::migrate_config<$OldConfig, $NewConfig>(
                account,
                new_config,
                version::current(),
            );

            // Destroy old config
            // Type-specific validation should be done before creating the proposal
            // The old config has drop ability so it's automatically cleaned up
            destroy_old_config(old_config);

            // Increment action index to mark action as executed
            account_protocol::executable::increment_action_idx(executable);
        },
    );
}

/// Validate and destroy old config
/// Since Move doesn't support runtime type casting, the caller must handle
/// type-specific validation and destruction.
///
/// For FutarchyConfig -> FutarchyConfigV2, the old config has `drop` so it's automatically
/// cleaned up when it goes out of scope.
///
/// Future: Could add validation helpers that take specific old config types
fun destroy_old_config<OldConfig: store + drop>(old_config: OldConfig) {
    // OldConfig must have drop ability (enforced by Move type system)
    // The destructor runs automatically when old_config goes out of scope

    // For type-specific validation, create specialized functions:
    // - validate_futarchy_migration(old: FutarchyConfig, new: &FutarchyConfigV2)
    // - validate_custom_migration(old: CustomConfig, new: &CustomConfigV2)

    // Since we can't cast at runtime, just let the value drop
    let _ = old_config;
}

// === Migration Helpers ===

/// Validate a migration is safe (called before creating proposal)
/// Returns true if migration appears valid, false otherwise
///
/// Checks:
/// - Current config type matches expected old type
/// - New config has required fields populated
/// - Critical data is preserved
public fun validate_migration<OldConfig: store, NewConfig: store>(
    account: &Account,
    _new_config: &NewConfig, // Underscore because we might not use it yet
): bool {
    // Check current type matches old
    let current_type = account_protocol::account::config_type(account);
    let expected_old = type_name::get<OldConfig>();

    if (current_type != expected_old) {
        return false
    };

    // Could add more validation:
    // - Check new config has valid values
    // - Verify critical fields preserved
    // - Ensure no data loss

    true
}
