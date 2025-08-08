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
use futarchy::{
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome},
    operating_agreement,
    version,
    account_spot_pool::{Self, AccountSpotPool, LPToken},
    lp_token_custody,
};
// Import action modules from local package
use futarchy::{
    config_actions,
    advanced_config_actions,
    operating_agreement_actions,
    liquidity_actions,
    dissolution_actions,
    stream_actions,
};

// === Constants ===

// === Errors ===
const EInvalidAmount: u64 = 4;
const ENoSpotPool: u64 = 5;
const EInvalidPoolId: u64 = 6;
// Note: ESlippageExceeded, EUnknownActionType, ENoActionsToExecute, and EExecutionFailed
// were removed as they're no longer used after simplifying the liquidity action handling

// === Public Functions ===

/// Main dispatcher function that executes all actions in an executable
/// This function inspects the action types and routes them to appropriate handlers
/// Note: This function consumes the executable (hot potato pattern)
/// Note: Witness requires copy because it's used multiple times in the loop
public fun execute_all_actions<IW: copy + drop>(
    executable: Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
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
        if (try_execute_config_action(&mut executable, account, witness, ctx)) {
            continue
        };
        
        if (try_execute_dissolution_action(&mut executable, account, witness, ctx)) {
            continue
        };
        
        if (try_execute_operating_agreement_action(&mut executable, account, witness, clock, ctx)) {
            continue
        };
        
        if (try_execute_liquidity_action(&mut executable, account, witness, ctx)) {
            continue
        };
        
        if (try_execute_stream_action(&mut executable, account, witness, clock, ctx)) {
            continue
        };
        
        // Additional action types can be added here
        
        // If no action was executed, we're done
        break
    };
    
    // Confirm execution
    account::confirm_execution(account, executable);
}

// === Config Action Handlers ===

fun try_execute_config_action<IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): bool {
    // Check for basic config actions
    if (executable::contains_action<FutarchyOutcome, config_actions::SetProposalsEnabledAction>(executable)) {
        // Call the action module implementation
        config_actions::do_set_proposals_enabled<FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, config_actions::UpdateNameAction>(executable)) {
        // Call the action module implementation
        config_actions::do_update_name<FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    // Check for advanced config actions
    if (executable::contains_action<FutarchyOutcome, advanced_config_actions::TradingParamsUpdateAction>(executable)) {
        // Call the action module implementation
        advanced_config_actions::do_update_trading_params<FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, advanced_config_actions::MetadataUpdateAction>(executable)) {
        // Call the action module implementation
        advanced_config_actions::do_update_metadata<FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, advanced_config_actions::TwapConfigUpdateAction>(executable)) {
        advanced_config_actions::do_update_twap_config<FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, advanced_config_actions::GovernanceUpdateAction>(executable)) {
        // Call the action module implementation
        advanced_config_actions::do_update_governance<FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, advanced_config_actions::MetadataTableUpdateAction>(executable)) {
        advanced_config_actions::do_update_metadata_table<FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, advanced_config_actions::QueueParamsUpdateAction>(executable)) {
        advanced_config_actions::do_update_queue_params<FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, advanced_config_actions::SlashDistributionUpdateAction>(executable)) {
        // Call the action module implementation
        advanced_config_actions::do_update_slash_distribution<FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    false
}

// === Dissolution Action Handlers ===

fun try_execute_dissolution_action<IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): bool {
    if (executable::contains_action<FutarchyOutcome, dissolution_actions::InitiateDissolutionAction>(executable)) {
        dissolution_actions::do_initiate_dissolution<FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, dissolution_actions::FinalizeDissolutionAction>(executable)) {
        dissolution_actions::do_finalize_dissolution<FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, dissolution_actions::CancelDissolutionAction>(executable)) {
        dissolution_actions::do_cancel_dissolution<FutarchyOutcome, IW>(
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

fun try_execute_liquidity_action<IW: drop>(
    _executable: &mut Executable<FutarchyOutcome>,
    _account: &mut Account<FutarchyConfig>,
    _witness: IW,
    _ctx: &mut TxContext,
): bool {
    // Liquidity actions require specific coin types - cannot be executed generically
    // Users should call execute_typed_actions with known types for validation
    // or execute_add_liquidity_with_pool/execute_remove_liquidity_with_pool for actual execution
    false
}

// === Operating Agreement Action Handlers ===

fun try_execute_operating_agreement_action<IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    if (executable::contains_action<FutarchyOutcome, operating_agreement_actions::UpdateLineAction>(executable)) {
        let agreement = operating_agreement::get_agreement_mut(account, version::current());
        operating_agreement::execute_update_line<IW>(
            executable,
            agreement,
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, operating_agreement_actions::InsertLineAfterAction>(executable)) {
        let agreement = operating_agreement::get_agreement_mut(account, version::current());
        operating_agreement::execute_insert_line_after<IW>(
            executable,
            agreement,
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, operating_agreement_actions::InsertLineAtBeginningAction>(executable)) {
        let agreement = operating_agreement::get_agreement_mut(account, version::current());
        operating_agreement::execute_insert_line_at_beginning<IW>(
            executable,
            agreement,
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, operating_agreement_actions::RemoveLineAction>(executable)) {
        let agreement = operating_agreement::get_agreement_mut(account, version::current());
        operating_agreement::execute_remove_line<IW>(
            executable,
            agreement,
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, operating_agreement_actions::BatchOperatingAgreementAction>(executable)) {
        let agreement = operating_agreement::get_agreement_mut(account, version::current());
        operating_agreement::execute_batch_operating_agreement<IW>(
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

// === Stream/Recurring Payment Action Handlers ===

fun try_execute_stream_action<IW: drop>(
    _executable: &mut Executable<FutarchyOutcome>,
    _account: &mut Account<FutarchyConfig>,
    _witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
): bool {
    // Stream actions require specific coin types - cannot be executed generically
    // Users should call execute_typed_actions with known types
    false
}

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
public fun execute_typed_actions_with_pool<AssetType: drop, StableType: drop, IW: copy + drop>(
    executable: Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    _pool: &mut AccountSpotPool<AssetType, StableType>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Just use the regular typed actions since we can't automate pool operations
    // The pool parameter is kept for API compatibility
    execute_typed_actions<AssetType, StableType, IW>(
        executable,
        account,
        witness,
        clock,
        ctx
    );
}

/// Execute actions with known coin types (without pool)
/// This version can handle liquidity and stream actions that require specific types
/// Note: Witness requires copy because it's used multiple times in the loop
public fun execute_typed_actions<AssetType: drop, StableType: drop, IW: copy + drop>(
    executable: Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut executable = executable;
    
    loop {
        // Try config actions
        if (try_execute_config_action(&mut executable, account, witness, ctx)) {
            continue
        };
        
        // Try dissolution actions (including typed distribute actions)
        if (try_execute_dissolution_action(&mut executable, account, witness, ctx)) {
            continue
        };
        
        if (try_execute_typed_dissolution_action<AssetType, IW>(&mut executable, account, witness, ctx)) {
            continue
        };
        
        // Try operating agreement actions
        if (try_execute_operating_agreement_action(&mut executable, account, witness, clock, ctx)) {
            continue
        };
        
        // Try typed liquidity actions
        if (try_execute_typed_liquidity_action<AssetType, StableType, IW>(&mut executable, account, witness, ctx)) {
            continue
        };
        
        // Try typed stream actions (using AssetType as the coin type)
        if (try_execute_typed_stream_action<AssetType, IW>(&mut executable, account, witness, clock, ctx)) {
            continue
        };
        
        // No more actions
        break
    };
    
    account::confirm_execution(account, executable);
}

// Note: try_execute_typed_liquidity_action_with_pool has been removed
// and execute_remove_liquidity_with_pool directly for actual execution.

/// Execute liquidity actions with known types (without pool)
/// only handles validation now
/// Actual execution requires execute_add_liquidity_with_pool or execute_remove_liquidity_with_pool
fun try_execute_typed_liquidity_action<AssetType: drop, StableType: drop, IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
    account: &Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): bool {
    // For add liquidity actions, validate and document execution requirements
    if (executable::contains_action<FutarchyOutcome, liquidity_actions::AddLiquidityAction<AssetType, StableType>>(executable)) {
        validate_add_liquidity_action<AssetType, StableType, IW>(
            executable,
            account,
            witness,
            ctx
        );
        return true
    };
    
    // For remove liquidity actions, validate and document execution requirements  
    if (executable::contains_action<FutarchyOutcome, liquidity_actions::RemoveLiquidityAction<AssetType, StableType>>(executable)) {
        validate_remove_liquidity_action<AssetType, StableType, IW>(
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
public fun execute_add_liquidity_with_pool<AssetType: drop, StableType: drop, IW: copy + drop>(
    executable: &mut Executable<FutarchyOutcome>,
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
fun validate_add_liquidity_action<AssetType, StableType, IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
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
/// Note: Refactored to not require copy on witness - uses single auth pattern
public fun execute_remove_liquidity_with_pool<AssetType: drop, StableType: drop, IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
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
    
    // Store coins temporarily (to avoid multiple auth creation)
    // In production, these should be deposited to vault through Move framework vault intents
    transfer::public_transfer(asset_coin, object::id_address(account));
    transfer::public_transfer(stable_coin, object::id_address(account));
    
    // Recommended Move framework integration pattern:
    // 1. Create a batch deposit intent with vault_intents::new_deposit()
    // 2. Add both asset_coin and stable_coin to the deposit intent
    // 3. Execute the batch deposit with vault_intents::execute_deposit()
    // This avoids needing multiple auth objects and follows framework patterns
}

/// Validate remove liquidity action parameters
/// Replaces the old execute_remove_liquidity validation-only function
fun validate_remove_liquidity_action<AssetType, StableType, IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
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
fun try_execute_typed_dissolution_action<CoinType, IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): bool {
    if (executable::contains_action<FutarchyOutcome, dissolution_actions::DistributeAssetAction<CoinType>>(executable)) {
        dissolution_actions::do_distribute_asset<FutarchyOutcome, CoinType, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    false
}

// === Helper Functions ===
// Note: Full liquidity pool execution helpers have been removed
// They will need to be properly implemented with actual pool integration

/// Execute stream actions with known coin type
fun try_execute_typed_stream_action<CoinType, IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    if (executable::contains_action<FutarchyOutcome, stream_actions::CreatePaymentAction<CoinType>>(executable)) {
        stream_actions::do_create_payment<FutarchyOutcome, CoinType, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, stream_actions::CancelPaymentAction<CoinType>>(executable)) {
        stream_actions::do_cancel_payment<FutarchyOutcome, CoinType, IW>(
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