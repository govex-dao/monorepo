/// Deposit Escrow Intents - Intent builders for accepting deposits
module futarchy_vault::deposit_escrow_intents;

use std::string::String;
use std::type_name;
use sui::{clock::Clock, object::ID, bcs, tx_context::TxContext};
use account_protocol::{
    account::Account,
    intents::{Self, Intent, Params},
    intent_interface,
    schema::{Self, ActionDecoderRegistry},
};
use futarchy_core::{futarchy_config::FutarchyConfig, action_types, version};
use futarchy_vault::deposit_escrow_actions;

// === Aliases ===
use fun intent_interface::build_intent as Account.build_intent;

// === Witness ===
public struct DepositEscrowIntent has copy, drop {}

// === Intent Creation ===

/// Create intent to accept deposit into vault
/// User must provide deposit coins via ResourceRequest when this intent is created
public fun create_accept_deposit_intent<Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    registry: &ActionDecoderRegistry,
    params: Params,
    outcome: Outcome,
    escrow_id: ID,
    vault_name: String,
    ctx: &mut TxContext
) {
    // Enforce decoder exists
    schema::assert_decoder_exists(
        registry,
        type_name::with_defining_ids<deposit_escrow_actions::AcceptDepositAction>()
    );

    account.build_intent!(
        params,
        outcome,
        b"deposit_escrow_accept".to_string(),
        version::current(),
        DepositEscrowIntent {},
        ctx,
        |intent, iw| {
            let action = deposit_escrow_actions::new_accept_deposit_action(
                escrow_id,
                vault_name,
            );
            let action_bytes = bcs::to_bytes(&action);
            intent.add_typed_action(
                action_types::accept_deposit(),
                action_bytes,
                iw
            );
        }
    );
}

// === Helper for Adding to Existing Intents ===

/// Add accept deposit action to existing intent
public fun add_accept_deposit<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    escrow_id: ID,
    vault_name: String,
    intent_witness: IW,
) {
    let action = deposit_escrow_actions::new_accept_deposit_action(escrow_id, vault_name);
    let action_bytes = bcs::to_bytes(&action);
    intents::add_typed_action(intent, action_types::accept_deposit(), action_bytes, intent_witness);
}

/// Create unique key for deposit escrow intent
public fun create_deposit_escrow_key(
    operation: String,
    clock: &Clock,
): String {
    let mut key = b"deposit_escrow_".to_string();
    key.append(operation);
    key.append(b"_".to_string());
    key.append(clock.timestamp_ms().to_string());
    key
}
