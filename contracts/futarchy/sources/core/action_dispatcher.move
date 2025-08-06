/// Dispatcher for routing and executing different types of futarchy actions
/// This module acts as the central hub for executing approved proposal actions
module futarchy::action_dispatcher;

// === Imports ===
use sui::{
    clock::Clock,
    coin::Coin,
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
};
use futarchy::{
    futarchy_config::{FutarchyConfig, FutarchyOutcome},
    version,
};
use futarchy_actions::{
    config_actions,
    advanced_config_actions,
    operating_agreement_actions,
    liquidity_actions,
    dissolution_actions,
    stream_actions,
};
use account_actions::{
    currency,
    vault,
    currency_intents,
    vault_intents,
};

// === Errors ===
const EUnknownActionType: u64 = 1;
const ENoActionsToExecute: u64 = 2;
const EExecutionFailed: u64 = 3;

// === Public Functions ===

/// Main dispatcher function that executes all actions in an executable
/// This function inspects the action types and routes them to appropriate handlers
/// Note: This function consumes the executable (hot potato pattern)
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
        
        // Execute futarchy-specific actions
        if (try_execute_config_action(&mut executable, account, witness, ctx)) {
            continue
        };
        
        if (try_execute_dissolution_action(&mut executable, account, witness, ctx)) {
            continue
        };
        
        if (try_execute_operating_agreement_action(&mut executable, account, witness, ctx)) {
            continue
        };
        
        if (try_execute_liquidity_action(&mut executable, account, witness, ctx)) {
            continue
        };
        
        if (try_execute_stream_action(&mut executable, account, witness, clock, ctx)) {
            continue
        };
        
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
        config_actions::do_set_proposals_enabled<FutarchyConfig, FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, config_actions::UpdateNameAction>(executable)) {
        config_actions::do_update_name<FutarchyConfig, FutarchyOutcome, IW>(
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
        advanced_config_actions::do_update_trading_params<FutarchyConfig, FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, advanced_config_actions::MetadataUpdateAction>(executable)) {
        advanced_config_actions::do_update_metadata<FutarchyConfig, FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, advanced_config_actions::TwapConfigUpdateAction>(executable)) {
        advanced_config_actions::do_update_twap_config<FutarchyConfig, FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, advanced_config_actions::GovernanceUpdateAction>(executable)) {
        advanced_config_actions::do_update_governance<FutarchyConfig, FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, advanced_config_actions::MetadataTableUpdateAction>(executable)) {
        advanced_config_actions::do_update_metadata_table<FutarchyConfig, FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, advanced_config_actions::QueueParamsUpdateAction>(executable)) {
        advanced_config_actions::do_update_queue_params<FutarchyConfig, FutarchyOutcome, IW>(
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
        dissolution_actions::do_initiate_dissolution<FutarchyConfig, FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, dissolution_actions::FinalizeDissolutionAction>(executable)) {
        dissolution_actions::do_finalize_dissolution<FutarchyConfig, FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, dissolution_actions::CancelDissolutionAction>(executable)) {
        dissolution_actions::do_cancel_dissolution<FutarchyConfig, FutarchyOutcome, IW>(
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
    executable: &mut Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): bool {
    // Liquidity actions require specific coin types - cannot be executed generically
    // Users should call execute_actions_for_asset with known types
    false
}

// === Operating Agreement Action Handlers ===

fun try_execute_operating_agreement_action<IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): bool {
    if (executable::contains_action<FutarchyOutcome, operating_agreement_actions::UpdateLineAction>(executable)) {
        operating_agreement_actions::do_update_line<FutarchyConfig, FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, operating_agreement_actions::InsertLineAfterAction>(executable)) {
        operating_agreement_actions::do_insert_line_after<FutarchyConfig, FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, operating_agreement_actions::InsertLineAtBeginningAction>(executable)) {
        operating_agreement_actions::do_insert_line_at_beginning<FutarchyConfig, FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, operating_agreement_actions::RemoveLineAction>(executable)) {
        operating_agreement_actions::do_remove_line<FutarchyConfig, FutarchyOutcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, operating_agreement_actions::BatchOperatingAgreementAction>(executable)) {
        operating_agreement_actions::do_batch_operating_agreement<FutarchyConfig, FutarchyOutcome, IW>(
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

// === Stream/Recurring Payment Action Handlers ===

fun try_execute_stream_action<IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    // Stream actions require specific coin types - cannot be executed generically
    // Users should call execute_typed_actions with known types
    false
}

// For transfer operations, users should use Account Protocol directly:
// - vault_intents::execute_spend_and_transfer() for coin transfers
// - currency_intents::execute_mint_and_transfer() for minting
// - currency_intents::execute_withdraw_and_burn() for burning
// These are not wrapped in the dispatcher as they should be called directly

// === Typed Action Execution ===

/// Execute actions with known coin types
/// This version can handle liquidity and stream actions that require specific types
public fun execute_typed_actions<AssetType, StableType, IW: copy + drop>(
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
        if (try_execute_operating_agreement_action(&mut executable, account, witness, ctx)) {
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

/// Execute liquidity actions with known types
fun try_execute_typed_liquidity_action<AssetType, StableType, IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): bool {
    if (executable::contains_action<FutarchyOutcome, liquidity_actions::AddLiquidityAction<AssetType, StableType>>(executable)) {
        liquidity_actions::do_add_liquidity<FutarchyConfig, FutarchyOutcome, AssetType, StableType, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<FutarchyOutcome, liquidity_actions::RemoveLiquidityAction<AssetType, StableType>>(executable)) {
        liquidity_actions::do_remove_liquidity<FutarchyConfig, FutarchyOutcome, AssetType, StableType, IW>(
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

/// Execute typed dissolution actions with known coin type
fun try_execute_typed_dissolution_action<CoinType, IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): bool {
    if (executable::contains_action<FutarchyOutcome, dissolution_actions::DistributeAssetAction<CoinType>>(executable)) {
        dissolution_actions::do_distribute_asset<FutarchyConfig, FutarchyOutcome, CoinType, IW>(
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

/// Execute stream actions with known coin type
fun try_execute_typed_stream_action<CoinType, IW: drop>(
    executable: &mut Executable<FutarchyOutcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    if (executable::contains_action<FutarchyOutcome, stream_actions::CreatePaymentAction<CoinType>>(executable)) {
        stream_actions::do_create_payment<FutarchyConfig, FutarchyOutcome, CoinType, IW>(
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
        stream_actions::do_cancel_payment<FutarchyConfig, FutarchyOutcome, CoinType, IW>(
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