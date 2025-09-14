#!/bin/bash

# Fix operating_agreement_actions.move to use simpler pattern without ActionSpec

FILE="futarchy_specialized_actions/sources/legal/operating_agreement_actions.move"

# Fix do_insert_line_after
perl -i -0pe 's/public fun do_insert_line_after<Outcome: store, IW: drop>\(\s*executable: &mut Executable<Outcome>,\s*account: &mut Account<FutarchyConfig>,\s*spec: &ActionSpec,\s*action_data: &vector<u8>,\s*_version_witness: VersionWitness,\s*witness: IW,\s*_clock: &Clock,\s*ctx: &mut TxContext,\s*\) \{[^}]+operating_agreement::insert_line_after\([^)]+\);\s*\/\/ Increment action index\s*executable::increment_action_idx\(executable\);\s*\}/public fun do_insert_line_after<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    \/\/ Get the action from the executable
    let action = executable::next_action<Outcome, InsertLineAfterAction, IW>(executable, witness);

    \/\/ Validate
    assert!(action.text.length() > 0, EEmptyText);

    let agreement: &mut OperatingAgreement = account::borrow_managed_data_mut(
        account,
        AgreementKey {},
        version::current()
    );

    operating_agreement::insert_line_after(
        agreement,
        action.prev_line_id,
        action.text,
        action.difficulty,
        ctx
    );
}/gs' "$FILE"

# Fix do_insert_line_at_beginning
perl -i -0pe 's/public fun do_insert_line_at_beginning<Outcome: store, IW: drop>\(\s*executable: &mut Executable<Outcome>,\s*account: &mut Account<FutarchyConfig>,\s*spec: &ActionSpec,\s*action_data: &vector<u8>,\s*_version_witness: VersionWitness,\s*witness: IW,\s*_clock: &Clock,\s*ctx: &mut TxContext,\s*\) \{[^}]+operating_agreement::insert_line_at_beginning\([^)]+\);\s*\/\/ Increment action index\s*executable::increment_action_idx\(executable\);\s*\}/public fun do_insert_line_at_beginning<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    \/\/ Get the action from the executable
    let action = executable::next_action<Outcome, InsertLineAtBeginningAction, IW>(executable, witness);

    \/\/ Validate
    assert!(action.text.length() > 0, EEmptyText);

    let agreement: &mut OperatingAgreement = account::borrow_managed_data_mut(
        account,
        AgreementKey {},
        version::current()
    );

    operating_agreement::insert_line_at_beginning(
        agreement,
        action.text,
        action.difficulty,
        ctx
    );
}/gs' "$FILE"

# Fix do_remove_line
perl -i -0pe 's/public fun do_remove_line<Outcome: store, IW: drop>\(\s*executable: &mut Executable<Outcome>,\s*account: &mut Account<FutarchyConfig>,\s*spec: &ActionSpec,\s*action_data: &vector<u8>,\s*_version_witness: VersionWitness,\s*witness: IW,\s*_clock: &Clock,\s*_ctx: &mut TxContext,\s*\) \{[^}]+operating_agreement::remove_line\([^)]+\);\s*\/\/ Increment action index\s*executable::increment_action_idx\(executable\);\s*\}/public fun do_remove_line<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    \/\/ Get the action from the executable
    let action = executable::next_action<Outcome, RemoveLineAction, IW>(executable, witness);

    let agreement: &mut OperatingAgreement = account::borrow_managed_data_mut(
        account,
        AgreementKey {},
        version::current()
    );

    operating_agreement::remove_line(agreement, action.line_id);
}/gs' "$FILE"

# Fix do_set_line_immutable
perl -i -0pe 's/public fun do_set_line_immutable<Outcome: store, IW: drop>\(\s*executable: &mut Executable<Outcome>,\s*account: &mut Account<FutarchyConfig>,\s*spec: &ActionSpec,\s*action_data: &vector<u8>,\s*_version_witness: VersionWitness,\s*witness: IW,\s*_clock: &Clock,\s*_ctx: &mut TxContext,\s*\) \{[^}]+operating_agreement::set_line_immutable\([^)]+\);\s*\/\/ Increment action index\s*executable::increment_action_idx\(executable\);\s*\}/public fun do_set_line_immutable<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    \/\/ Get the action from the executable
    let action = executable::next_action<Outcome, SetLineImmutableAction, IW>(executable, witness);

    let agreement: &mut OperatingAgreement = account::borrow_managed_data_mut(
        account,
        AgreementKey {},
        version::current()
    );

    operating_agreement::set_line_immutable(agreement, action.line_id);
}/gs' "$FILE"

# Fix do_set_insert_allowed
perl -i -0pe 's/public fun do_set_insert_allowed<Outcome: store, IW: drop>\(\s*executable: &mut Executable<Outcome>,\s*account: &mut Account<FutarchyConfig>,\s*spec: &ActionSpec,\s*action_data: &vector<u8>,\s*_version_witness: VersionWitness,\s*witness: IW,\s*_clock: &Clock,\s*_ctx: &mut TxContext,\s*\) \{[^}]+operating_agreement::set_insert_allowed\([^)]+\);\s*\/\/ Increment action index\s*executable::increment_action_idx\(executable\);\s*\}/public fun do_set_insert_allowed<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    \/\/ Get the action from the executable
    let action = executable::next_action<Outcome, SetInsertAllowedAction, IW>(executable, witness);

    let agreement: &mut OperatingAgreement = account::borrow_managed_data_mut(
        account,
        AgreementKey {},
        version::current()
    );

    operating_agreement::set_insert_allowed(agreement, action.allowed);
}/gs' "$FILE"

# Fix do_set_remove_allowed
perl -i -0pe 's/public fun do_set_remove_allowed<Outcome: store, IW: drop>\(\s*executable: &mut Executable<Outcome>,\s*account: &mut Account<FutarchyConfig>,\s*spec: &ActionSpec,\s*action_data: &vector<u8>,\s*_version_witness: VersionWitness,\s*witness: IW,\s*_clock: &Clock,\s*_ctx: &mut TxContext,\s*\) \{[^}]+operating_agreement::set_remove_allowed\([^)]+\);\s*\/\/ Increment action index\s*executable::increment_action_idx\(executable\);\s*\}/public fun do_set_remove_allowed<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    \/\/ Get the action from the executable
    let action = executable::next_action<Outcome, SetRemoveAllowedAction, IW>(executable, witness);

    let agreement: &mut OperatingAgreement = account::borrow_managed_data_mut(
        account,
        AgreementKey {},
        version::current()
    );

    operating_agreement::set_remove_allowed(agreement, action.allowed);
}/gs' "$FILE"

# Fix do_set_global_immutable
perl -i -0pe 's/public fun do_set_global_immutable<Outcome: store, IW: drop>\(\s*executable: &mut Executable<Outcome>,\s*account: &mut Account<FutarchyConfig>,\s*spec: &ActionSpec,\s*action_data: &vector<u8>,\s*_version_witness: VersionWitness,\s*witness: IW,\s*_clock: &Clock,\s*_ctx: &mut TxContext,\s*\) \{[^}]+operating_agreement::set_global_immutable\([^)]+\);\s*\/\/ Increment action index\s*executable::increment_action_idx\(executable\);\s*\}/public fun do_set_global_immutable<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    witness: IW,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    \/\/ Get the action from the executable
    let _action = executable::next_action<Outcome, SetGlobalImmutableAction, IW>(executable, witness);

    let agreement: &mut OperatingAgreement = account::borrow_managed_data_mut(
        account,
        AgreementKey {},
        version::current()
    );

    operating_agreement::set_global_immutable(agreement);
}/gs' "$FILE"

echo "Fixed operating_agreement_actions.move"