// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// PTB execution helpers for Futarchy proposals.
///
/// The frontend composes a programmable transaction that:
/// 1. Calls `begin_execution` to receive the governance executable hot potato.
/// 2. Invokes the relevant `do_*` action functions in order (routing is handled client-side).
/// 3. Calls `finalize_execution` to confirm the intent, perform cleanup, and emit events.
///
/// This keeps execution logic flexible while guaranteeing on-chain sequencing with the
/// executable's action counter.
module futarchy_governance::ptb_executor;

use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents,
    package_registry::PackageRegistry,
};
use futarchy_governance_actions::intent_janitor;
use futarchy_core::{
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome},
    proposal_fee_manager::{Self, ProposalFeeManager},
};
use futarchy_governance::proposal_lifecycle;
use futarchy_governance_actions::governance_intents;
use futarchy_markets_core::proposal::{Self, Proposal};
use futarchy_markets_primitives::market_state::{Self, MarketState};
use std::option;
use std::string::String;
use sui::{clock::Clock, coin::Coin, event, object::ID, tx_context::TxContext};

// === Errors ===
const EMarketNotFinalized: u64 = 0;
const EProposalNotApproved: u64 = 1;
const EIntentMissing: u64 = 2;

// YES/ACCEPTED outcome index used across governance flow.
const OUTCOME_ACCEPTED: u64 = 0;

// === Events ===
/// Event emitted when a proposal intent is executed
public struct ProposalIntentExecuted has copy, drop {
    proposal_id: ID,
    dao_id: ID,
    intent_key: String,
    timestamp: u64,
}

/// Begin execution for an approved proposal by creating the governance executable.
/// - Verifies market finalization and approval.
/// - Deposits the execution fee.
/// - Synthesizes the intent from the stored InitActionSpecs.
/// Returns the executable hot potato and intent key for cleanup.
public fun begin_execution<AssetType, StableType>(
    account: &mut Account,
    registry: &PackageRegistry,
    proposal: &mut Proposal<AssetType, StableType>,
    market: &MarketState,
    fee_manager: &mut ProposalFeeManager<StableType>,
    fee_coin: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Executable<FutarchyOutcome>, String) {
    assert!(market_state::is_finalized(market), EMarketNotFinalized);

    let winning_outcome = market_state::get_winning_outcome(market);
    assert!(winning_outcome == OUTCOME_ACCEPTED, EProposalNotApproved);
    assert!(
        proposal::has_intent_spec(proposal, winning_outcome),
        EIntentMissing
    );

    proposal_fee_manager::deposit_proposal_fee(
        fee_manager,
        proposal::get_id(proposal),
        fee_coin,
    );

    let outcome = futarchy_config::new_futarchy_outcome_full(
        build_intent_key_hint(proposal, clock),
        option::some(proposal::get_id(proposal)),
        option::some(proposal::market_state_id(proposal)),
        true,
        clock.timestamp_ms(),
    );

    governance_intents::execute_proposal_intent(
        account,
        registry,
        proposal,
        market,
        winning_outcome,
        outcome,
        clock,
        ctx,
    )
}

/// Finalize execution after all actions have been processed.
/// Confirms the executable, performs janitorial cleanup, and emits the execution event.
/// Note: Cannot be `entry` because Executable<FutarchyOutcome> is not a valid entry parameter type
public fun finalize_execution<AssetType, StableType>(
    account: &mut Account,
    registry: &PackageRegistry,
    proposal: &mut Proposal<AssetType, StableType>,
    executable: Executable<FutarchyOutcome>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let intent_key = intents::key(account_protocol::executable::intent(&executable));

    account::confirm_execution(account, executable);

    intent_janitor::cleanup_all_expired_intents(account, registry, clock, ctx);

    event::emit(ProposalIntentExecuted {
        proposal_id: proposal::get_id(proposal),
        dao_id: proposal::get_dao_id(proposal),
        intent_key,
        timestamp: clock.timestamp_ms(),
    });
}

/// Build a human-readable hint for the temporary outcome metadata.
fun build_intent_key_hint<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    clock: &Clock,
): String {
    let mut key = b"ptb_execution_".to_string();
    let proposal_id = proposal::get_id(proposal);
    key.append(proposal_id.id_to_address().to_string());
    key.append(b"_".to_string());
    key.append(clock.timestamp_ms().to_string());
    key
}
