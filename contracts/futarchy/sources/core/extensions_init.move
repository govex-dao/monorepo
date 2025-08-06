/// Module for initializing Extensions for the Futarchy protocol
/// This handles the creation and management of Extensions object required by account_protocol
module futarchy::extensions_init;

// === Imports ===
use account_extensions::extensions::{Self, Extensions, AdminCap};
use std::string::String;
use sui::{
    object::{Self, ID, UID},
    transfer,
};

// === Structs ===

/// One-time witness for Extensions initialization
public struct EXTENSIONS_INIT has drop {}

/// Capability for managing Futarchy Extensions
public struct FutarchyExtensionsCap has key, store {
    id: UID,
    extensions_id: ID,
}

// === Errors ===
const ENotAuthorized: u64 = 1;

// === Functions ===

/// Get Extensions and AdminCap from already deployed Extensions
/// Note: Extensions is already deployed and shared, this function doesn't create new ones
public fun get_extensions_info(): String {
    b"Extensions is a shared object - use its object ID in transactions".to_string()
}

/// Note: Extensions initialization is handled by account_extensions package deployment
/// This function is kept for documentation purposes only
public entry fun note_extensions_deployment() {
    // Extensions is initialized when account_extensions package is deployed
    // It creates a shared Extensions object and transfers AdminCap to deployer
    // No additional initialization needed from futarchy package
}

/// Add required packages to Extensions for Futarchy
public entry fun setup_futarchy_packages(
    extensions: &mut Extensions,
    admin_cap: &AdminCap,
    account_protocol_version: u64,
    futarchy_actions_version: u64,
) {
    // Add AccountProtocol package
    extensions::add(
        extensions,
        admin_cap,
        b"AccountProtocol".to_string(),
        @account_protocol,
        account_protocol_version,
    );
    
    // Add FutarchyActions package
    extensions::add(
        extensions,
        admin_cap,
        b"FutarchyActions".to_string(),
        @futarchy_actions,
        futarchy_actions_version,
    );
}

/// Helper function to get Extensions ID from capability
public fun get_extensions_id(cap: &FutarchyExtensionsCap): ID {
    cap.extensions_id
}

/// Verify that Extensions has the required packages
public fun verify_extensions(extensions: &Extensions): bool {
    // Check if AccountProtocol is added
    let has_protocol = extensions::is_extension(
        extensions,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1, // version 1
    );
    
    // Check if FutarchyActions is added
    let has_actions = extensions::is_extension(
        extensions,
        b"FutarchyActions".to_string(),
        @futarchy_actions,
        1, // version 1
    );
    
    has_protocol && has_actions
}

#[test_only]
/// Create test Extensions with required packages
public fun create_test_extensions(ctx: &mut TxContext): Extensions {
    let mut extensions = extensions::new_for_testing(ctx);
    
    // Add required packages
    extensions::add_for_testing(
        &mut extensions,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1, // version 1
    );
    
    extensions::add_for_testing(
        &mut extensions,
        b"FutarchyActions".to_string(),
        @futarchy_actions,
        1, // version 1
    );
    
    extensions
}