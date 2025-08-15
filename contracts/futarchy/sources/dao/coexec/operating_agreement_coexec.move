module futarchy::operating_agreement_coexec;

use std::{
    vector,
    string::{Self, String},
    hash,
};
use sui::{
    clock::Clock,
    object::{Self, ID},
    address,
    tx_context::TxContext,
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
};
use futarchy::{
    version,
    operating_agreement,
    operating_agreement_actions::{Self, BatchOperatingAgreementAction, OperatingAgreementAction},
    coexec_common,
    futarchy_config::{Self, FutarchyConfig, OAApproval, CouncilApproval},
    weighted_multisig::{Self, WeightedMultisig, Approvals},
    security_council_actions,
    policy_registry,
};

const ENoBatch: u64 = 1;
const EDAOMismatch: u64 = 2;
const EBatchMismatch: u64 = 3;
const EExpired: u64 = 4;
const ENoCustodian: u64 = 5;
const EWrongCustodian: u64 = 6;

/// Deterministically hash a batch OA action into a digest
fun digest_batch(actions: &vector<OperatingAgreementAction>): vector<u8> {
    // Build a simple canonical byte stream and sha3 it
    let mut bytes = vector::empty<u8>();
    let mut i = 0;
    while (i < actions.length()) {
        let (t, lid_opt, text_opt, diff_opt) = operating_agreement_actions::get_operating_agreement_action_params(actions.borrow(i));
        // action_type
        bytes.push_back((t as u8));
        // line_id if any
        if (lid_opt.is_some()) {
            let id = *lid_opt.borrow();
            let addr = object::id_to_address(&id);
            let id_bytes = address::to_bytes(addr);
            let mut j = 0;
            while (j < id_bytes.length()) {
                bytes.push_back(*id_bytes.borrow(j));
                j = j + 1;
            };
        };
        // text if any
        if (text_opt.is_some()) {
            let s = *text_opt.borrow();
            let sb = string::as_bytes(&s);
            let mut k = 0;
            while (k < sb.length()) {
                bytes.push_back(*sb.borrow(k));
                k = k + 1;
            };
        };
        // difficulty if any
        if (diff_opt.is_some()) {
            let d = *diff_opt.borrow();
            // serialize u64 as 8 bytes (big endian-ish)
            let mut shift = 56;
            loop {
                let b: u8 = (((d >> shift) & 0xFF) as u8);
                bytes.push_back(b);
                if (shift == 0) { break };
                shift = shift - 8;
            };
        };
        i = i + 1;
    };
    hash::sha3_256(bytes)
}

/// Execute OA changes requiring 2-of-2: futarchy + council.
/// - DAO must have OA:Custodian policy set to council_id
/// - Futarchy executable must contain BatchOperatingAgreementAction
/// - Council executable must contain ApproveOAChangeAction with matching batch_id
/// Both executables are confirmed atomically.
public fun execute_with_council<FutarchyOutcome: store + drop + copy>(
    dao: &mut Account<FutarchyConfig>,
    council: &mut Account<WeightedMultisig>,
    mut futarchy_exec: Executable<FutarchyOutcome>,
    mut council_exec: Executable<Approvals>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Extract futarchy batch OA action
    let batch: &BatchOperatingAgreementAction = 
        coexec_common::extract_action_with_check(&mut futarchy_exec, version::current(), ENoBatch);
    let batch_id = operating_agreement_actions::get_batch_id(batch);
    let actions = operating_agreement_actions::get_batch_actions(batch);

    // Extract council approval action
    let approval: &security_council_actions::ApproveOAChangeAction = 
        coexec_common::extract_action(&mut council_exec, version::current());
    let (dao_id, approved_batch_id, expires_at) = security_council_actions::get_approve_oa_change_params(approval);
    
    // Validate all co-execution requirements
    assert!(dao_id == object::id(dao), EDAOMismatch);
    assert!(approved_batch_id == batch_id, EBatchMismatch);
    assert!(clock.timestamp_ms() < expires_at, EExpired);
    
    // Verify council is the OA custodian
    let registry = policy_registry::borrow_registry(dao, version::current());
    assert!(policy_registry::has_policy(registry, b"OA:Custodian".to_string()), ENoCustodian);
    let policy = policy_registry::get_policy(registry, b"OA:Custodian".to_string());
    assert!(policy_registry::policy_account_id(policy) == object::id(council), EWrongCustodian);

    // Apply actions to OA
    let agreement = operating_agreement::get_agreement_mut(dao, version::current());
    operating_agreement::apply_actions(agreement, actions, clock, ctx);
    
    // Record the council approval for this intent
    let intent_key = executable::intent(&futarchy_exec).key();
    let oa_approval = futarchy_config::new_oa_approval(
        object::id(dao),
        batch_id,
        expires_at
    );
    futarchy_config::record_council_approval_oa(
        dao,
        intent_key,
        oa_approval,
        ctx
    );

    // Confirm both executables atomically
    coexec_common::confirm_both_executables(dao, council, futarchy_exec, council_exec);
}