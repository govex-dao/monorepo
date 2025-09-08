/// Futarchy vault initialization module
/// The vault itself is managed by account_actions::vault
module futarchy_vault::futarchy_vault_init;

use std::string;
use account_protocol::{
    account::{Self, Account},
    version_witness::VersionWitness,
};
use account_actions::vault;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_vault::futarchy_vault;

// === Public Functions ===

/// Initialize vault during DAO creation
public fun initialize(
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    ctx: &mut TxContext
) {
    // Initialize the futarchy_vault allowed coin types tracking
    futarchy_vault::init_vault(account, version, ctx);
    
    // Open the default treasury vault using account_actions::vault
    // We need to create an Auth for this
    let auth = futarchy_config::authenticate(account, ctx);
    vault::open(auth, account, string::utf8(futarchy_vault::default_vault_name()), ctx);
}