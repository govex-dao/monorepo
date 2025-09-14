// ============================================================================
// FORK MODIFICATION NOTICE - Hot Potato Action Results
// ============================================================================
// Zero-cost result passing between actions using hot potato pattern.
//
// PURPOSE:
// - Replace ExecutionContext with compile-time safe result chaining
// - Eliminate Table storage costs (~200 gas per operation)
// - Enforce explicit data dependencies between actions
//
// NEW IN THIS DIFF:
// - Added consumption functions for all result types
// - consume_mint_result, consume_spend_result, etc.
// - Enables proper cleanup of hot potato results in intent modules
// ============================================================================

module account_protocol::action_results;

use sui::object::ID;
use std::string::String;

// Generic result wrapper for any action that creates objects
public struct ActionResult<phantom T> {
    object_id: ID,
    // Additional fields can be added per action type
}

// Specific result types for common patterns
public struct TransferResult {
    transferred_id: ID,
    recipient: address,
}

public struct MintResult {
    coin_id: ID,
    amount: u64,
}

public struct CreateStreamResult {
    stream_id: ID,
    beneficiary: address,
}

public struct CreateProposalResult {
    proposal_id: ID,
    proposal_number: u64,
}

public struct SpendResult {
    coin_id: ID,
    amount: u64,
    vault_name: String,
}

public struct VestingResult {
    vesting_id: ID,
    recipient: address,
    amount: u64,
}

public struct KioskResult {
    item_id: ID,
    kiosk_id: ID,
}

public struct UpgradeResult {
    package_id: ID,
    version: u64,
}

// Result chain for complex multi-step operations
public struct ResultChain {
    // Can hold multiple results in sequence
    results: vector<ID>,
}

// Constructor functions
public fun new_action_result<T>(object_id: ID): ActionResult<T> {
    ActionResult { object_id }
}

public fun new_transfer_result(id: ID, recipient: address): TransferResult {
    TransferResult { transferred_id: id, recipient }
}

public fun new_mint_result(coin_id: ID, amount: u64): MintResult {
    MintResult { coin_id, amount }
}

public fun new_spend_result(coin_id: ID, amount: u64, vault_name: String): SpendResult {
    SpendResult { coin_id, amount, vault_name }
}

public fun new_vesting_result(vesting_id: ID, recipient: address, amount: u64): VestingResult {
    VestingResult { vesting_id, recipient, amount }
}

public fun new_kiosk_result(item_id: ID, kiosk_id: ID): KioskResult {
    KioskResult { item_id, kiosk_id }
}

public fun new_upgrade_result(package_id: ID, version: u64): UpgradeResult {
    UpgradeResult { package_id, version }
}

// Consumption functions to destroy hot potatoes
public fun consume_mint_result(result: MintResult) {
    let MintResult { coin_id: _, amount: _ } = result;
}

public fun consume_spend_result(result: SpendResult) {
    let SpendResult { coin_id: _, amount: _, vault_name: _ } = result;
}

public fun consume_transfer_result(result: TransferResult) {
    let TransferResult { transferred_id: _, recipient: _ } = result;
}

public fun consume_vesting_result(result: VestingResult) {
    let VestingResult { vesting_id: _, recipient: _, amount: _ } = result;
}

public fun consume_kiosk_result(result: KioskResult) {
    let KioskResult { item_id: _, kiosk_id: _ } = result;
}

public fun consume_upgrade_result(result: UpgradeResult) {
    let UpgradeResult { package_id: _, version: _ } = result;
}

public fun consume_create_stream_result(result: CreateStreamResult) {
    let CreateStreamResult { stream_id: _, beneficiary: _ } = result;
}

public fun consume_create_proposal_result(result: CreateProposalResult) {
    let CreateProposalResult { proposal_id: _, proposal_number: _ } = result;
}

public fun consume_action_result<T>(result: ActionResult<T>) {
    let ActionResult { object_id: _ } = result;
}

public fun new_result_chain(): ResultChain {
    ResultChain { results: vector::empty() }
}

public fun add_to_chain(chain: &mut ResultChain, id: ID) {
    vector::push_back(&mut chain.results, id);
}

// Destructor functions to extract data
public fun destroy_action_result<T>(result: ActionResult<T>): ID {
    let ActionResult { object_id } = result;
    object_id
}

public fun destroy_transfer_result(result: TransferResult): (ID, address) {
    let TransferResult { transferred_id, recipient } = result;
    (transferred_id, recipient)
}

public fun destroy_mint_result(result: MintResult): (ID, u64) {
    let MintResult { coin_id, amount } = result;
    (coin_id, amount)
}

public fun destroy_spend_result(result: SpendResult): (ID, u64, String) {
    let SpendResult { coin_id, amount, vault_name } = result;
    (coin_id, amount, vault_name)
}

public fun destroy_vesting_result(result: VestingResult): (ID, address, u64) {
    let VestingResult { vesting_id, recipient, amount } = result;
    (vesting_id, recipient, amount)
}

public fun destroy_kiosk_result(result: KioskResult): (ID, ID) {
    let KioskResult { item_id, kiosk_id } = result;
    (item_id, kiosk_id)
}

public fun destroy_upgrade_result(result: UpgradeResult): (ID, u64) {
    let UpgradeResult { package_id, version } = result;
    (package_id, version)
}

public fun destroy_result_chain(chain: ResultChain): vector<ID> {
    let ResultChain { results } = chain;
    results
}

// Accessors for reading without consuming
public fun result_object_id<T>(result: &ActionResult<T>): ID {
    result.object_id
}

public fun transfer_result_id(result: &TransferResult): ID {
    result.transferred_id
}

public fun transfer_result_recipient(result: &TransferResult): address {
    result.recipient
}

public fun mint_result_id(result: &MintResult): ID {
    result.coin_id
}

public fun mint_result_amount(result: &MintResult): u64 {
    result.amount
}

public fun spend_result_id(result: &SpendResult): ID {
    result.coin_id
}

public fun spend_result_amount(result: &SpendResult): u64 {
    result.amount
}

public fun spend_result_vault_name(result: &SpendResult): &String {
    &result.vault_name
}

public fun chain_results(chain: &ResultChain): &vector<ID> {
    &chain.results
}