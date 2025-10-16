/// Vault access helpers with clear error messages
/// Used by dividend actions to safely access treasury vaults
module futarchy_dividend_actions::vault_access;

use account_actions::vault::{Self, Vault};
use account_protocol::account::Account;
use std::string::String;

// === Errors ===

/// Account does not have a vault with the specified name
const ETreasuryVaultNotFound: u64 = 1;

/// Treasury vault exists but does not have the required coin type
const EInsufficientTreasuryBalance: u64 = 2;

/// Account is missing required "treasury" vault for dividend operations
const ETreasuryVaultRequired: u64 = 3;

// === Helper Functions ===

/// Get treasury vault with clear error message
/// Aborts with ETreasuryVaultRequired if account doesn't have "treasury" vault
public fun get_treasury_vault<Config: store>(account: &Account<Config>): &Vault {
    let vault_name = b"treasury".to_string();

    // Check if vault exists
    assert!(vault::has_vault(account, vault_name), ETreasuryVaultRequired);

    vault::borrow_vault(account, vault_name)
}

/// Get vault balance for a specific coin type
/// Returns 0 if vault doesn't have this coin type
public fun get_treasury_balance<Config: store, CoinType: drop>(account: &Account<Config>): u64 {
    let treasury = get_treasury_vault(account);
    vault::coin_type_value<CoinType>(treasury)
}

/// Assert treasury has sufficient balance for operation
/// Provides clear error message about what's missing
public fun assert_treasury_balance<Config: store, CoinType: drop>(
    account: &Account<Config>,
    required_amount: u64,
) {
    let available = get_treasury_balance<Config, CoinType>(account);
    assert!(available >= required_amount, EInsufficientTreasuryBalance);
}

// === Error Message Helpers ===

/// Get user-friendly error message for a vault access error code
public fun error_message(code: u64): vector<u8> {
    if (code == ETreasuryVaultNotFound) {
        b"Account does not have a vault with the specified name. Ensure vault exists before using dividend actions."
    } else if (code == EInsufficientTreasuryBalance) {
        b"Treasury vault does not have sufficient balance for this operation."
    } else if (code == ETreasuryVaultRequired) {
        b"Account must have a 'treasury' vault to use dividend actions. For FutarchyConfig, this is created automatically. For custom Config types, create a vault named 'treasury' during initialization."
    } else {
        b"Unknown vault access error"
    }
}
