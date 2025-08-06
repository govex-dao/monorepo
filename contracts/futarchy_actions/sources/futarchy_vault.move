/// Minimal vault initialization wrapper for futarchy accounts
/// All actual vault operations should use account_actions::vault directly
module futarchy_actions::futarchy_vault;

// === Imports ===
use sui::bag::{Self, Bag};
use account_protocol::{
    account::{Self, Account},
    version_witness::VersionWitness,
};

// === Constants ===
const VAULT_KEY: vector<u8> = b"futarchy_vault";

// === Structs ===

/// Minimal vault storage for initialization only
public struct Vault has store {
    balances: Bag,
    treasury_caps: Bag,
}

// === Public Functions ===

/// Initialize vault for a futarchy account
/// This is the ONLY function we keep - just for initialization during DAO creation
public fun init_vault<Config>(
    account: &mut Account<Config>,
    version: VersionWitness,
    ctx: &mut TxContext
) {
    let vault = Vault {
        balances: bag::new(ctx),
        treasury_caps: bag::new(ctx),
    };
    
    // Store vault in account managed data
    account::add_managed_data(
        account,
        VAULT_KEY,
        vault,
        version,
    );
}

// For ALL other vault operations (deposit, withdraw, transfer, etc.):
// Use account_actions::vault directly
// Example:
//   - Deposits: account_actions::vault::deposit()
//   - Withdraws: account_actions::vault::withdraw()
//   - Transfers: account_actions::vault_intents::request_spend_and_transfer()
//   - Minting: account_actions::currency_intents::request_mint_and_transfer()