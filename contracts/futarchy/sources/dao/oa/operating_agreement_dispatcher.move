/// Dispatcher for operating agreement actions
module futarchy::operating_agreement_dispatcher;

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
    operating_agreement,
    operating_agreement_actions,
};

// === Constants ===
const EOARequiresCouncil: u64 = 8;

// === Public(friend) Functions ===

/// Try to execute operating agreement actions
public(package) fun try_execute_operating_agreement_action<IW: drop, Outcome: store + drop + copy>(
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