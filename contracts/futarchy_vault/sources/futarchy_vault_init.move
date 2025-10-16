/// Futarchy vault initialization module
/// The vault itself is managed by account_actions::vault
module futarchy_vault::futarchy_vault_init;

use account_actions::vault;
use account_protocol::account::{Self, Account};
use account_protocol::version_witness::VersionWitness;
use futarchy_core::futarchy_config::{Self, FutarchyConfig};
use futarchy_vault::futarchy_vault;
use std::string;

// === Structs ===

/// Witness for authenticating vault operations during init
public struct FutarchyConfigWitness has drop {}

// === Public Functions ===

/// Initialize vault during DAO creation
public fun initialize(
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    ctx: &mut TxContext,
) {
    // Initialize the futarchy_vault allowed coin types tracking
    futarchy_vault::init_vault(account, version, ctx);

    // Open the default treasury vault using account_actions::vault
    // We need to create an Auth for this
    let auth = account::new_auth(account, version, FutarchyConfigWitness {});
    vault::open(auth, account, string::utf8(futarchy_vault::default_vault_name()), ctx);
}
