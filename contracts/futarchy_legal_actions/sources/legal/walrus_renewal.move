/// Intent-based Walrus blob renewal system for Operating Agreements
/// Uses Account Protocol recurring intents for governance-approved renewals
/// DAO pays WAL from treasury, keeper pays SUI gas and gets reward
///
/// Architecture:
/// 1. DAO creates recurring intent via governance (approved spending cap)
/// 2. Anyone can execute intent when blob needs renewal
/// 3. Intent enforces max spending cap while withdrawing sensible amounts
/// 4. Keeper gets percentage-based reward for executing
///
/// Walrus Integration: Uses official Walrus Move contracts for blob storage extension
/// - walrus::blob::Blob - Represents stored blobs on Sui
/// - walrus::storage_resource::Storage - Manages storage capacity and duration
module futarchy_legal_actions::walrus_renewal;

// === Imports ===
use std::{
    string::String,
    type_name::{Self, TypeName},
};
use sui::{
    balance::Balance,
    clock::{Self, Clock},
    coin::{Self, Coin},
    event,
    object::{Self, ID},
    tx_context::{Self, TxContext},
    bcs,
};
use account_protocol::{
    bcs_validation,
    account::{Self, Account},
    executable::{Self, Executable},
    version_witness::VersionWitness,
    intents::{Self, Intent},
};
use account_actions::vault;
use futarchy_core::{
    action_validation,
    action_types,
    version,
    futarchy_config::FutarchyConfig,
};
use futarchy_legal_actions::dao_file_registry::{Self, File};

// === Walrus Integration (External Modules) ===
use walrus::{system, blob};
use wal::wal::WAL;

// === Errors ===
const EUnauthorizedDocument: u64 = 0;
const EBlobMismatch: u64 = 1;
const EExceedsApprovedMax: u64 = 2;
const EInvalidKeeperReward: u64 = 3;

// === Constants ===

/// Duration to extend Walrus storage (in epochs, ~1 year)
public fun default_extend_epochs(): u64 { 52 }

// === Structs ===

/// Action for intent-based Walrus blob renewal
/// This action is added to a recurring intent approved by governance
public struct WalrusRenewalAction has store, drop, copy {
    vault_name: String,           // Which vault stores WAL tokens
    max_wal_per_blob: u64,       // Maximum WAL to spend per renewal (hard cap)
    keeper_reward_bps: u64,      // Keeper reward in basis points (e.g., 50 = 0.5%)
    min_keeper_reward_wal: u64,  // Minimum keeper reward in WAL
}

// === Events ===

public struct WalrusBlobRenewed has copy, drop {
    dao_id: ID,
    blob_id: ID,
    wal_spent: u64,
    keeper_reward_wal: u64,
    old_expiry: u64,
    new_expiry: u64,
    keeper: address,
    timestamp_ms: u64,
}

// === Intent Construction ===

/// Add Walrus renewal action to an intent
/// Called during intent creation (typically via governance proposal)
public fun new_walrus_renewal<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    vault_name: String,
    max_wal_per_blob: u64,
    keeper_reward_bps: u64,
    min_keeper_reward_wal: u64,
    intent_witness: IW,
) {
    assert!(keeper_reward_bps <= 10000, EInvalidKeeperReward); // Max 100%

    let action = WalrusRenewalAction {
        vault_name,
        max_wal_per_blob,
        keeper_reward_bps,
        min_keeper_reward_wal,
    };

    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        action_types::walrus_renewal(),
        action_data,
        intent_witness
    );
}

// === Intent Execution ===

/// Execute approved Walrus renewal intent
/// Called by intent execution system after governance approval
///
/// This function validates the document/blob and extends Walrus storage.
/// The caller must provide WAL tokens (from vault via separate vault_spend action).
///
/// Security:
/// - Document/blob ownership verified
/// - Returns unused WAL + keeper reward for caller to handle
public fun do_walrus_renewal<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    // External resources provided by caller:
    mut wal_payment: Coin<WAL>,       // WAL payment from vault (via separate action)
    walrus_system: &mut system::System,
    blob: &mut blob::Blob,
    doc: &mut File,
    chunk_id: ID,
    _version_witness: VersionWitness,
    _intent_witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<WAL>, Coin<WAL>) {  // Returns (unused_wal, keeper_reward)
    // 1. Verify document ownership (prevents cross-DAO attack)
    let doc_dao_id = dao_file_registry::get_document_dao_id(doc);
    executable.intent().assert_is_account(account.addr());
    assert!(doc_dao_id == object::id(account), EUnauthorizedDocument);

    // 2. CRITICAL: Verify blob belongs to this chunk (prevents treasury drain exploit)
    let chunk = dao_file_registry::get_chunk(doc, chunk_id);
    let expected_blob_id = dao_file_registry::get_chunk_blob_id(chunk);
    let provided_blob_id = blob::blob_id(blob);
    assert!(expected_blob_id == provided_blob_id, EBlobMismatch);

    let old_expiry = blob::end_epoch(blob) as u64;
    let keeper = tx_context::sender(ctx);

    // 3. Deserialize APPROVED limits from intent
    let specs = executable.intent().action_specs();
    let spec = specs.borrow(executable.action_idx());
    action_validation::assert_action_type<action_types::WalrusRenewal>(spec);

    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    let _vault_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let max_wal_per_blob = bcs::peel_u64(&mut reader);
    let keeper_reward_bps = bcs::peel_u64(&mut reader);
    let min_keeper_reward_wal = bcs::peel_u64(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    // 4. Validate payment amount doesn't exceed approved limit
    assert!(wal_payment.value() <= max_wal_per_blob, EExceedsApprovedMax);

    let initial_value = wal_payment.value();

    // 5. Extend blob storage using Walrus (Walrus takes what it needs)
    system::extend_blob(
        walrus_system,
        blob,
        default_extend_epochs() as u32,
        &mut wal_payment,
    );

    let actual_spent = initial_value - wal_payment.value();

    // 6. Calculate keeper reward based on what was actually spent
    let percentage_reward = (actual_spent * keeper_reward_bps) / 10000;
    let keeper_reward_amount = if (percentage_reward > min_keeper_reward_wal) {
        percentage_reward
    } else {
        min_keeper_reward_wal
    };

    // 7. Split keeper reward from remaining coins
    let keeper_reward = if (wal_payment.value() >= keeper_reward_amount) {
        coin::split(&mut wal_payment, keeper_reward_amount, ctx)
    } else {
        // If not enough left for keeper reward, give what's left
        let remaining = wal_payment.value();
        coin::split(&mut wal_payment, remaining, ctx)
    };

    // 8. Update chunk metadata
    let new_expiry = blob::end_epoch(blob) as u64;
    dao_file_registry::update_chunk_walrus_expiry(doc, chunk_id, new_expiry);

    // 9. Emit event
    event::emit(WalrusBlobRenewed {
        dao_id: doc_dao_id,
        blob_id: object::id(blob),
        wal_spent: actual_spent,
        keeper_reward_wal: keeper_reward.value(),
        old_expiry,
        new_expiry,
        keeper,
        timestamp_ms: clock::timestamp_ms(clock),
    });

    // 10. Increment action index
    executable::increment_action_idx(executable);

    // Return unused WAL and keeper reward for caller to handle
    (wal_payment, keeper_reward)
}

// === Deletion Handler ===

/// Delete Walrus renewal action from expired intent
/// Called when intent expires or is cancelled
public fun delete_walrus_renewal(expired: &mut intents::Expired) {
    let _spec = intents::remove_action_spec(expired);
    // ActionSpec has drop, so it's automatically cleaned up
}
