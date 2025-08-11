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
    executable::Executable,
};
use futarchy::{
    version,
    operating_agreement,
    operating_agreement_actions::{Self, BatchOperatingAgreementAction, OperatingAgreementAction},
    coexec_common,
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome},
    weighted_multisig::{Self, WeightedMultisig, Approvals},
    security_council_actions,
};

const ENoBatch: u64 = 1;

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
/// - Council executable must contain ApproveOAChangeAction whose digest matches
/// Both executables are confirmed atomically.
public fun execute_with_council(
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
    let actions = operating_agreement_actions::get_batch_actions(batch);
    let digest = digest_batch(actions);

    // Extract council approval action
    let approval: &security_council_actions::ApproveOAChangeAction = 
        coexec_common::extract_action(&mut council_exec, version::current());
    let (dao_id, cdigest, expires_at) = security_council_actions::get_approve_oa_change_params(approval);
    
    // Validate all co-execution requirements using the standard pattern
    coexec_common::validate_coexec_standard(
        dao,
        council,
        b"OA:Custodian".to_string(),
        dao_id,
        expires_at,
        cdigest,
        &digest,
        clock
    );

    // Apply actions to OA
    let agreement = operating_agreement::get_agreement_mut(dao, version::current());
    operating_agreement::apply_actions(agreement, actions, clock, ctx);

    // Confirm both executables atomically
    coexec_common::confirm_both_executables(dao, council, futarchy_exec, council_exec);
}