/// Futarchy vault initialization module
/// The vault itself is managed by account_actions::vault
module futarchy::futarchy_vault_init;

use account_protocol::{
    account::Account,
    version_witness::VersionWitness,
};
use futarchy::futarchy_config::FutarchyConfig;
use futarchy::futarchy_vault;

// === Public Functions ===

/// Initialize vault during DAO creation
public(package) fun initialize(
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    ctx: &mut TxContext
) {
    // Initialize the vault in the futarchy_vault actions module
    futarchy_vault::init_vault(account, version, ctx);
}