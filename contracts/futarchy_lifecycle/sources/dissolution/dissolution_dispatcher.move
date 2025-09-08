/// Dispatcher for dissolution-related actions
module futarchy_lifecycle::dissolution_dispatcher;

// === Imports ===
use sui::clock::Clock;
use account_protocol::{
    account::Account,
    executable::{Self, Executable},
};
use futarchy_core::version;
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_lifecycle::dissolution_actions;

// === Public Functions ===

/// Try to execute basic dissolution actions
public fun try_execute_dissolution_action<IW: drop + copy, Outcome: store + drop + copy>(
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
    
    // Try to execute BatchDistributeAction
    if (executable::contains_action<Outcome, dissolution_actions::BatchDistributeAction>(executable)) {
        dissolution_actions::do_batch_distribute<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    // Try to execute CalculateProRataSharesAction
    if (executable::contains_action<Outcome, dissolution_actions::CalculateProRataSharesAction>(executable)) {
        dissolution_actions::do_calculate_pro_rata_shares<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            ctx
        );
        return true
    };
    
    // Note: DistributeAssetsAction and CancelAllStreamsAction require specific coin types
    // They are handled in the typed execution functions
    
    false
}

/// Execute typed dissolution actions that require coins
public fun try_execute_typed_dissolution_action<CoinType: drop, IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    // Note: DistributeAssetsAction requires coins but we can't withdraw mid-execution
    // The frontend should:
    // 1. Create a vault SpendAction first to withdraw the distribution amount
    // 2. Create the DistributeAssetsAction 
    // 3. Use a different entry function that can pass coins between actions
    // For now, this is not implemented here
    
    // Try to execute CancelAllStreamsAction (no type parameter on the action)
    if (executable::contains_action<Outcome, dissolution_actions::CancelAllStreamsAction>(executable)) {
        // This action cancels streams and refunds coins
        dissolution_actions::do_cancel_all_streams<Outcome, CoinType, IW>(
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

/// Try to execute typed dissolution actions requiring both AssetType and StableType
public fun try_execute_typed_dissolution_action_dual<AssetType, StableType, IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext
): bool {
    // Try to execute WithdrawAmmLiquidityAction
    if (executable::contains_action<Outcome, dissolution_actions::WithdrawAmmLiquidityAction<AssetType, StableType>>(executable)) {
        dissolution_actions::do_withdraw_amm_liquidity<Outcome, AssetType, StableType, IW>(
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