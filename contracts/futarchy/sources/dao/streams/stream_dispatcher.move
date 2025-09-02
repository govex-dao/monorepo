/// Dispatcher for stream/recurring payment actions
module futarchy::stream_dispatcher;

// === Imports ===
use sui::{
    clock::Clock,
    tx_context::TxContext,
};
use account_protocol::{
    account::Account,
    executable::{Self, Executable},
};
use futarchy::{
    futarchy_config::FutarchyConfig,
    version,
    stream_actions,
};

// === Public(friend) Functions ===

/// Try to execute stream actions (non-typed actions)
public(package) fun try_execute_stream_action<IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext
): bool {
    // Try to execute UpdatePaymentRecipientAction
    if (executable::contains_action<Outcome, stream_actions::UpdatePaymentRecipientAction>(executable)) {
        stream_actions::do_update_payment_recipient<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    // Try to execute AddWithdrawerAction
    if (executable::contains_action<Outcome, stream_actions::AddWithdrawerAction>(executable)) {
        stream_actions::do_add_withdrawer<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    // Try to execute RemoveWithdrawersAction
    if (executable::contains_action<Outcome, stream_actions::RemoveWithdrawersAction>(executable)) {
        stream_actions::do_remove_withdrawers<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    // Try to execute TogglePaymentAction
    if (executable::contains_action<Outcome, stream_actions::TogglePaymentAction>(executable)) {
        stream_actions::do_toggle_payment<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    // Try to execute ChallengeWithdrawalsAction
    if (executable::contains_action<Outcome, stream_actions::ChallengeWithdrawalsAction>(executable)) {
        stream_actions::do_challenge_withdrawals<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    // Try to execute CancelChallengedWithdrawalsAction
    if (executable::contains_action<Outcome, stream_actions::CancelChallengedWithdrawalsAction>(executable)) {
        stream_actions::do_cancel_challenged_withdrawals<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    // Note: Typed stream actions (CreatePayment, CancelPayment, etc.) require coin type
    
    false
}

/// Execute stream actions with known coin type
public(package) fun try_execute_typed_stream_action<CoinType, IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    // Try to execute CreatePaymentAction
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
    
    // Try to execute CancelPaymentAction
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
    
    // Try to execute CreateBudgetStreamAction
    if (executable::contains_action<Outcome, stream_actions::CreateBudgetStreamAction<CoinType>>(executable)) {
        stream_actions::do_create_budget_stream<Outcome, CoinType, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    // Try to execute ExecutePaymentAction
    if (executable::contains_action<Outcome, stream_actions::ExecutePaymentAction<CoinType>>(executable)) {
        stream_actions::do_execute_payment<Outcome, CoinType, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    // Try to execute RequestWithdrawalAction
    if (executable::contains_action<Outcome, stream_actions::RequestWithdrawalAction<CoinType>>(executable)) {
        stream_actions::do_request_withdrawal<Outcome, CoinType, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    // Try to execute ProcessPendingWithdrawalAction
    if (executable::contains_action<Outcome, stream_actions::ProcessPendingWithdrawalAction<CoinType>>(executable)) {
        stream_actions::do_process_pending_withdrawal<Outcome, CoinType, IW>(
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