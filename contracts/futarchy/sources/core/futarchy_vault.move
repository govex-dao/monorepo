/// Futarchy vault module - minimal wrapper for initialization only
/// For all vault operations, use account_actions::vault directly
module futarchy::futarchy_vault;

use account_protocol::account::Account;
use futarchy::futarchy_config::FutarchyConfig;
use futarchy_actions::futarchy_vault as vault_impl;

// === Public Functions ===

/// Initialize vault during DAO creation
/// This delegates to futarchy_actions for the actual implementation
public(package) fun init_vault(
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext
) {
    // Delegate to the futarchy_actions vault for initialization
    // This creates a custom Vault struct with bags for balances and treasury caps
    vault_impl::init_vault(
        account,
        futarchy::version::current(),
        ctx
    );
}

// For ALL other vault operations, users should use account_actions directly:
// - Deposits: account_actions::vault::deposit() with proper Auth
// - Withdrawals: account_actions::vault::withdraw() with proper Auth  
// - Transfers: account_actions::vault_intents::request_spend_and_transfer()
// - Checking balance: account_actions::vault::get_balance()

#[test_only]
/// Initialize vault during DAO creation (test version)
public(package) fun init_vault_test(
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext
) {
    use account_protocol::version_witness;
    // Delegate to the futarchy_actions vault for initialization with test version
    vault_impl::init_vault(
        account,
        version_witness::new_for_testing(@account_protocol),
        ctx
    );
}
// - Closing vault: account_actions::vault::close() with proper Auth

// Note: Auth objects must be created by the config module that has access
// to create them. Regular modules cannot create Auth objects directly.