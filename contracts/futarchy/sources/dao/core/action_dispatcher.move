/// Dispatcher for routing and executing different types of futarchy actions
/// This module acts as the central hub for executing approved proposal actions
module futarchy::action_dispatcher;

// === Imports ===
use sui::{
    clock::Clock,
    object::{Self, ID},
    coin::{Self, Coin},
    transfer,
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
};
use account_actions::vault;
use futarchy::{
    futarchy_config::{Self, FutarchyConfig},
    operating_agreement,
    version,
    account_spot_pool::{Self, AccountSpotPool, LPToken},
    lp_token_custody,
    policy_registry_coexec,
};
// Import action modules from local package
use futarchy::{
    config_actions,
    operating_agreement_actions,
    liquidity_actions,
    dissolution_actions,
    stream_actions,
    policy_actions,
    policy_registry,
};

// === Constants ===

// === Errors ===
const EInvalidAmount: u64 = 4;
const ENoSpotPool: u64 = 5;
const EInvalidPoolId: u64 = 6;
const EOARequiresCouncil: u64 = 8;
const ECriticalPolicyRequiresCouncil: u64 = 9;
const ECannotRemoveOACustodian: u64 = 10;

// === Public Functions ===

/// Main dispatcher function that executes all actions in an executable
/// This function inspects the action types and routes them to appropriate handlers
/// Note: This function returns the executable for the caller to confirm
/// Note: Witness requires copy because it's used multiple times in the loop
public fun execute_all_actions<IW: copy + drop, Outcome: store + drop + copy>(
    executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<Outcome> {
    let mut executable = executable;
    
    // Process all actions in the executable
    // Process actions until executable is empty
    // Note: Account Protocol doesn't expose action_count, so we try each action type
    loop {
        // For transfers and vault operations, users should use Account Protocol directly:
        // - vault_intents::execute_spend_and_transfer() for transfers
        // - currency_intents::execute_mint_and_transfer() for minting
        // - currency_intents::execute_withdraw_and_burn() for burning
        // 
        // For liquidity operations, the typical flow is:
        // 1. Validate liquidity actions via execute_typed_actions
        // 2. Execute vault intents to withdraw/deposit coins
        // 3. Execute actual liquidity operations with execute_add_liquidity_with_pool
        
        // Execute futarchy-specific actions
        if (try_execute_config_action(&mut executable, account, witness, clock, ctx)) {
            continue
        };
        
        if (try_execute_dissolution_action(&mut executable, account, witness, ctx)) {
            continue
        };
        
        if (try_execute_operating_agreement_action(&mut executable, account, witness, clock, ctx)) {
            continue
        };
        
        if (try_execute_policy_action(&mut executable, account, witness, ctx)) {
            continue
        };
        
        // Liquidity and stream actions require specific coin types - use execute_typed_actions instead
        
        // Additional action types can be added here
        
        // If no action was executed, all actions have been processed
        break
    };
    
    // Do NOT confirm here; the centralized runner (execute::run_*) owns confirmation.
    // Return the executable for the caller to handle
    executable
}

// === Config Action Handlers ===

fun try_execute_config_action<IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    // Check for basic config actions
    if (executable::contains_action<Outcome, config_actions::SetProposalsEnabledAction>(executable)) {
        // Call the action module implementation
        config_actions::do_set_proposals_enabled<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, config_actions::UpdateNameAction>(executable)) {
        // Call the action module implementation
        config_actions::do_update_name<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    // Check for advanced config actions
    if (executable::contains_action<Outcome, config_actions::TradingParamsUpdateAction>(executable)) {
        // Call the action module implementation
        config_actions::do_update_trading_params<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, config_actions::MetadataUpdateAction>(executable)) {
        // Call the action module implementation
        config_actions::do_update_metadata<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, config_actions::TwapConfigUpdateAction>(executable)) {
        config_actions::do_update_twap_config<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, config_actions::GovernanceUpdateAction>(executable)) {
        // Call the action module implementation
        config_actions::do_update_governance<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, config_actions::MetadataTableUpdateAction>(executable)) {
        config_actions::do_update_metadata_table<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, config_actions::QueueParamsUpdateAction>(executable)) {
        config_actions::do_update_queue_params<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, config_actions::SlashDistributionUpdateAction>(executable)) {
        // Call the action module implementation
        config_actions::do_update_slash_distribution<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    false
}

// === Dissolution Action Handlers ===

fun try_execute_dissolution_action<IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): bool {
    if (executable::contains_action<Outcome, dissolution_actions::InitiateDissolutionAction>(executable)) {
        dissolution_actions::do_initiate_dissolution<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, dissolution_actions::FinalizeDissolutionAction>(executable)) {
        dissolution_actions::do_finalize_dissolution<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, dissolution_actions::CancelDissolutionAction>(executable)) {
        dissolution_actions::do_cancel_dissolution<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    // Note: DistributeAssetAction and BatchDistributeAction require specific coin types
    // They need to be handled in the typed execution functions
    
    false
}

// === Liquidity Action Handlers ===
// Note: Liquidity actions require specific coin types and are handled by execute_typed_actions

// === Operating Agreement Action Handlers ===

fun try_execute_operating_agreement_action<IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    // Enforce 2-of-2 if OA has a council custodian policy set.
    // Skip this check for CreateOperatingAgreementAction since OA doesn't exist yet
    if (!executable::contains_action<Outcome, operating_agreement_actions::CreateOperatingAgreementAction>(executable)) {
        if (operating_agreement::has_agreement(account) && operating_agreement::requires_council_coapproval(account)) {
            // Disallow direct OA changes. Must use operating_agreement_coexec::execute_with_council
            abort EOARequiresCouncil
        };
    };
    
    // Create OA if it doesn't exist yet
    if (executable::contains_action<Outcome, operating_agreement_actions::CreateOperatingAgreementAction>(executable)) {
        operating_agreement::execute_create_agreement<IW, FutarchyConfig, Outcome>(
            executable,
            account,
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, operating_agreement_actions::UpdateLineAction>(executable)) {
        let agreement = operating_agreement::get_agreement_mut(account, version::current());
        operating_agreement::execute_update_line<IW, Outcome>(
            executable,
            agreement,
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, operating_agreement_actions::InsertLineAfterAction>(executable)) {
        let agreement = operating_agreement::get_agreement_mut(account, version::current());
        operating_agreement::execute_insert_line_after<IW, Outcome>(
            executable,
            agreement,
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, operating_agreement_actions::InsertLineAtBeginningAction>(executable)) {
        let agreement = operating_agreement::get_agreement_mut(account, version::current());
        operating_agreement::execute_insert_line_at_beginning<IW, Outcome>(
            executable,
            agreement,
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, operating_agreement_actions::RemoveLineAction>(executable)) {
        let agreement = operating_agreement::get_agreement_mut(account, version::current());
        operating_agreement::execute_remove_line<IW, Outcome>(
            executable,
            agreement,
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, operating_agreement_actions::BatchOperatingAgreementAction>(executable)) {
        let agreement = operating_agreement::get_agreement_mut(account, version::current());
        operating_agreement::execute_batch_operating_agreement<IW, Outcome>(
            executable,
            agreement,
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, operating_agreement_actions::SetLineImmutableAction>(executable)) {
        let agreement = operating_agreement::get_agreement_mut(account, version::current());
        operating_agreement::execute_set_line_immutable<IW, Outcome>(
            executable,
            agreement,
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, operating_agreement_actions::SetInsertAllowedAction>(executable)) {
        let agreement = operating_agreement::get_agreement_mut(account, version::current());
        operating_agreement::execute_set_insert_allowed<IW, Outcome>(
            executable,
            agreement,
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, operating_agreement_actions::SetRemoveAllowedAction>(executable)) {
        let agreement = operating_agreement::get_agreement_mut(account, version::current());
        operating_agreement::execute_set_remove_allowed<IW, Outcome>(
            executable,
            agreement,
            witness,
            clock,
            ctx
        );
        return true
    };
    
    false
}

// === Policy Registry Action Handlers ===

fun try_execute_policy_action<IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): bool {
    // Check for set policy action
    if (executable::contains_action<Outcome, policy_actions::SetPolicyAction>(executable)) {
        let action: &policy_actions::SetPolicyAction = executable.next_action(witness);
        let account_id = object::id(account);
        let (key, id, prefix) = policy_actions::get_set_policy_params(action);
        
        // Check if this is a critical policy that requires council co-approval
        if (policy_registry_coexec::is_critical_policy(key)) {
            // Critical policies must use policy_registry_coexec::execute_set_policy_with_council
            abort ECriticalPolicyRequiresCouncil
        };
        
        let registry = policy_registry::borrow_registry_mut(account, version::current());
        policy_registry::set_policy(registry, account_id, *key, id, *prefix);
        return true
    };

    // Check for remove policy action
    if (executable::contains_action<Outcome, policy_actions::RemovePolicyAction>(executable)) {
        let action: &policy_actions::RemovePolicyAction = executable.next_action(witness);
        let account_id = object::id(account);
        let key = policy_actions::get_remove_policy_key(action);
        
        // CRITICAL: DAO can NEVER remove OA:Custodian through futarchy
        // Security council can give up control via coexec path, but DAO cannot
        if (*key == b"OA:Custodian".to_string()) {
            abort ECannotRemoveOACustodian
        };
        
        // Check if this is a critical policy that requires council co-approval
        if (policy_registry_coexec::is_critical_policy(key)) {
            // Critical policies must use policy_registry_coexec::execute_remove_policy_with_council
            abort ECriticalPolicyRequiresCouncil
        };
        
        let registry = policy_registry::borrow_registry_mut(account, version::current());
        policy_registry::remove_policy(registry, account_id, *key);
        return true
    };

    false
}

// === Stream/Recurring Payment Action Handlers ===
// Note: Stream actions require specific coin types and are handled by execute_typed_actions

// === Move Framework Integration ===
// For transfer operations, users should use Account Protocol directly:
// - vault_intents::execute_spend_and_transfer() for coin transfers
// - currency_intents::execute_mint_and_transfer() for minting
// - currency_intents::execute_withdraw_and_burn() for burning
//
// For liquidity operations, the integration pattern is:
// 1. Create liquidity action intents (AddLiquidityAction, RemoveLiquidityAction)
// 2. Execute with execute_typed_actions for validation
// 3. Use vault intents to manage coin flows:
//    - vault_intents::execute_spend() to withdraw coins for adding liquidity
//    - vault_intents::execute_deposit() to store received assets/LP tokens
// 4. Execute actual pool operations with execute_add_liquidity_with_pool
//
// These are not wrapped in the dispatcher as they should be called directly
// in the appropriate sequence for your use case.

// === Typed Action Execution ===

/// Execute actions with known coin types and pool
/// This version validates liquidity actions but requires manual coin handling
/// Note: Witness requires copy because it's used in the loop
public fun execute_typed_actions_with_pool<AssetType: drop, StableType: drop, IW: copy + drop, Outcome: store + drop + copy>(
    executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _pool: &mut AccountSpotPool<AssetType, StableType>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<Outcome> {
    // Just use the regular typed actions since we can't automate pool operations
    // The pool parameter is kept for API compatibility
    execute_typed_actions<AssetType, StableType, IW, Outcome>(
        executable,
        account,
        witness,
        clock,
        ctx
    )
}

/// Execute actions with known coin types (without pool)
/// This version can handle liquidity and stream actions that require specific types
/// Note: Witness requires copy because it's used multiple times in the loop
public fun execute_typed_actions<AssetType: drop, StableType: drop, IW: copy + drop, Outcome: store + drop + copy>(
    executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<Outcome> {
    let mut executable = executable;
    
    loop {
        // Try config actions
        if (try_execute_config_action(&mut executable, account, witness, clock, ctx)) {
            continue
        };
        
        // Try dissolution actions (including typed distribute actions)
        if (try_execute_dissolution_action(&mut executable, account, witness, ctx)) {
            continue
        };
        
        if (try_execute_typed_dissolution_action<AssetType, IW, Outcome>(&mut executable, account, witness, ctx)) {
            continue
        };
        
        // Try operating agreement actions
        if (try_execute_operating_agreement_action(&mut executable, account, witness, clock, ctx)) {
            continue
        };
        
        // Try typed liquidity actions
        if (try_execute_typed_liquidity_action<AssetType, StableType, IW, Outcome>(&mut executable, account, witness, ctx)) {
            continue
        };
        
        // Try typed stream actions (using AssetType as the coin type)
        if (try_execute_typed_stream_action<AssetType, IW, Outcome>(&mut executable, account, witness, clock, ctx)) {
            continue
        };
        
        // If no action was executed, all actions have been processed
        break
    };
    
    // Do NOT confirm here; the centralized runner (execute::run_*) owns confirmation.
    // Return the executable for the caller to handle
    executable
}

// Note: try_execute_typed_liquidity_action_with_pool has been removed
// and execute_remove_liquidity_with_pool directly for actual execution.

/// Execute liquidity actions with known types (without pool)
/// only handles validation now
/// Actual execution requires execute_add_liquidity_with_pool or execute_remove_liquidity_with_pool
fun try_execute_typed_liquidity_action<AssetType: drop, StableType: drop, IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): bool {
    // For add liquidity actions, validate and document execution requirements
    if (executable::contains_action<Outcome, liquidity_actions::AddLiquidityAction<AssetType, StableType>>(executable)) {
        validate_add_liquidity_action<AssetType, StableType, IW, Outcome>(
            executable,
            account,
            witness,
            ctx
        );
        return true
    };
    
    // For remove liquidity actions, validate and document execution requirements  
    if (executable::contains_action<Outcome, liquidity_actions::RemoveLiquidityAction<AssetType, StableType>>(executable)) {
        validate_remove_liquidity_action<AssetType, StableType, IW, Outcome>(
            executable,
            account,
            witness,
            ctx
        );
        return true
    };
    
    false
}


/// Execute add liquidity action with pool and coins
/// Coins must be provided by the caller (e.g., from Move framework vault operations)
/// 
/// Move framework integration:
/// - Use vault_intents::execute_spend() to obtain coins
/// - This function performs the actual pool operation
/// - LP tokens are deposited to the custody registry automatically
/// 
/// Note: Requires copy on witness to create auth after using it for action
public fun execute_add_liquidity_with_pool<AssetType: drop, StableType: drop, IW: copy + drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    pool: &mut AccountSpotPool<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    witness: IW,
    ctx: &mut TxContext,
) {
    // Extract and validate the action
    let action: &liquidity_actions::AddLiquidityAction<AssetType, StableType> = 
        executable::next_action(executable, witness);
    
    // Get action parameters
    let pool_id = liquidity_actions::get_pool_id(action);
    let asset_amount = liquidity_actions::get_asset_amount(action);
    let stable_amount = liquidity_actions::get_stable_amount(action);
    let min_lp_amount = liquidity_actions::get_min_lp_amount(action);
    
    // Validate amounts
    assert!(asset_amount > 0 && stable_amount > 0, EInvalidAmount);
    
    // Verify pool ID matches config
    let config = account::config(account);
    let stored_pool_id = futarchy_config::spot_pool_id(config);
    assert!(stored_pool_id.is_some(), ENoSpotPool);
    assert!(pool_id == *stored_pool_id.borrow(), EInvalidPoolId);
    assert!(pool_id == object::id(pool), EInvalidPoolId);
    
    // Verify amounts match what we expect
    assert!(asset_coin.value() == asset_amount, EInvalidAmount);
    assert!(stable_coin.value() == stable_amount, EInvalidAmount);
    
    // Add liquidity to the pool and get LP token
    let lp_token = account_spot_pool::add_liquidity_and_return(
        pool,
        asset_coin,
        stable_coin,
        min_lp_amount,
        ctx
    );
    
    // Store LP token in custody system
    let auth = account::new_auth(account, version::current(), witness);
    lp_token_custody::deposit_lp_token(
        auth,
        account,
        pool_id,
        lp_token,
        ctx
    );
}

/// Validate add liquidity action parameters
/// Replaces the old execute_add_liquidity validation-only function
fun validate_add_liquidity_action<AssetType, StableType, IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &Account<FutarchyConfig>,
    witness: IW,
    _ctx: &mut TxContext,
) {
    // Extract and validate the action
    let action: &liquidity_actions::AddLiquidityAction<AssetType, StableType> = 
        executable::next_action(executable, witness);
    
    // Get action parameters
    let pool_id = liquidity_actions::get_pool_id(action);
    let asset_amount = liquidity_actions::get_asset_amount(action);
    let stable_amount = liquidity_actions::get_stable_amount(action);
    let _min_lp_amount = liquidity_actions::get_min_lp_amount(action);
    
    // Validate the action
    assert!(asset_amount > 0, EInvalidAmount);
    assert!(stable_amount > 0, EInvalidAmount);
    
    // Verify pool ID matches config
    let config = account::config(account);
    let stored_pool_id = futarchy_config::spot_pool_id(config);
    assert!(stored_pool_id.is_some(), ENoSpotPool);
    assert!(pool_id == *stored_pool_id.borrow(), EInvalidPoolId);
    
    // Action validated - actual execution requires execute_add_liquidity_with_pool
    // with coins obtained from vault operations using Move framework vault intents:
    //
    // Example integration pattern:
    // 1. This function validates the AddLiquidityAction
    // 2. Use vault_intents::execute_spend() to withdraw asset_amount and stable_amount
    // 3. Call execute_add_liquidity_with_pool with the withdrawn coins
    // 4. LP tokens are automatically deposited to the custody registry
}

// Use execute_add_liquidity_with_pool directly for actual liquidity operations.
// For validation only, the dispatcher now uses validate_add_liquidity_action.

/// Execute remove liquidity action - full implementation  
/// Removes liquidity from pool and provides coins for vault deposit
/// 
/// Move framework integration:
/// - LP token should be obtained via lp_token_custody::withdraw_lp_token()
/// - This function performs the actual pool operation
/// - Resulting coins should be deposited via vault_intents::execute_deposit()
/// 
/// Note: Requires copy on witness to create multiple auth objects for vault deposits
public fun execute_remove_liquidity_with_pool<AssetType: drop, StableType: drop, IW: copy + drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    pool: &mut AccountSpotPool<AssetType, StableType>,
    lp_token: LPToken<AssetType, StableType>,
    witness: IW,
    ctx: &mut TxContext,
) {
    // Extract and validate the action
    let action: &liquidity_actions::RemoveLiquidityAction<AssetType, StableType> = 
        executable::next_action(executable, witness);
    
    // Get action parameters
    let pool_id = liquidity_actions::get_remove_pool_id(action);
    let lp_amount = liquidity_actions::get_lp_amount(action);
    let min_asset_amount = liquidity_actions::get_min_asset_amount(action);
    let min_stable_amount = liquidity_actions::get_min_stable_amount(action);
    
    // Validate the action
    assert!(lp_amount > 0, EInvalidAmount);
    assert!(account_spot_pool::lp_token_amount(&lp_token) == lp_amount, EInvalidAmount);
    
    // Verify pool ID matches
    let config = account::config(account);
    let stored_pool_id = futarchy_config::spot_pool_id(config);
    assert!(stored_pool_id.is_some(), ENoSpotPool);
    assert!(pool_id == *stored_pool_id.borrow(), EInvalidPoolId);
    assert!(pool_id == object::id(pool), EInvalidPoolId);
    
    // Remove liquidity from pool
    let (asset_coin, stable_coin) = account_spot_pool::remove_liquidity_and_return(
        pool,
        lp_token,
        min_asset_amount,
        min_stable_amount,
        ctx
    );
    
    // Deposit coins directly into the DAO vault (treasury)
    let auth = account::new_auth(account, version::current(), witness);
    vault::deposit(auth, account, b"treasury".to_string(), asset_coin);
    // Create a new auth for the second deposit
    let auth2 = account::new_auth(account, version::current(), witness);
    vault::deposit(auth2, account, b"treasury".to_string(), stable_coin);
}

/// Validate remove liquidity action parameters
/// Replaces the old execute_remove_liquidity validation-only function
fun validate_remove_liquidity_action<AssetType, StableType, IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &Account<FutarchyConfig>,
    witness: IW,
    _ctx: &mut TxContext,
) {
    // Extract and validate the action
    let action: &liquidity_actions::RemoveLiquidityAction<AssetType, StableType> = 
        executable::next_action(executable, witness);
    
    // Get action parameters
    let pool_id = liquidity_actions::get_remove_pool_id(action);
    let lp_amount = liquidity_actions::get_lp_amount(action);
    let _min_asset_amount = liquidity_actions::get_min_asset_amount(action);
    let _min_stable_amount = liquidity_actions::get_min_stable_amount(action);
    
    // Validate the action
    assert!(lp_amount > 0, EInvalidAmount);
    
    // Verify pool ID matches config
    let config = account::config(account);
    let stored_pool_id = futarchy_config::spot_pool_id(config);
    assert!(stored_pool_id.is_some(), ENoSpotPool);
    assert!(pool_id == *stored_pool_id.borrow(), EInvalidPoolId);
    
    // Action validated - actual execution requires execute_remove_liquidity_with_pool
    // with LP tokens obtained from the custody system using Move framework patterns:
    //
    // Example integration pattern:
    // 1. This function validates the RemoveLiquidityAction
    // 2. Retrieve LP tokens from custody using lp_token_custody::withdraw_lp_token()
    // 3. Call execute_remove_liquidity_with_pool with the LP tokens
    // 4. Resulting coins can be deposited back to vault via vault_intents::execute_deposit()
}

/// Execute typed dissolution actions with known coin type
/// Note: DistributeAssetAction now requires a Coin<CoinType> parameter to be passed
/// This prevents automatic execution in the dispatcher until proper coin handling is added
fun try_execute_typed_dissolution_action<CoinType, IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): bool {
    // Removed automatic execution of DistributeAssetAction
    // This action now requires a Coin<CoinType> to be provided
    // Use a dedicated executor that pairs vault::spend with dissolution::distribute
    false
}

// === Helper Functions ===
// Note: Full liquidity pool execution helpers have been removed
// They will need to be properly implemented with actual pool integration

/// Execute stream actions with known coin type
fun try_execute_typed_stream_action<CoinType, IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    if (executable::contains_action<Outcome, stream_actions::CreatePaymentAction<CoinType>>(executable)) {
        stream_actions::do_create_payment<Outcome, CoinType, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, stream_actions::CancelPaymentAction<CoinType>>(executable)) {
        stream_actions::do_cancel_payment<Outcome, CoinType, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    false
}