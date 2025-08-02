module futarchy::action_registry;

use std::string::String;
use std::type_name::TypeName;
use std::ascii::String as AsciiString;
use sui::object::{Self, ID, UID};
use sui::table::{Self, Table};
use sui::url::Url;
use sui::transfer;
use sui::tx_context::TxContext;

// === Unified Action Type Constants ===
const ACTION_NO_OP: u8 = 0;
// Treasury Actions
const ACTION_TRANSFER: u8 = 1;
const ACTION_MINT: u8 = 2;
const ACTION_BURN: u8 = 3;
const ACTION_RECURRING_PAYMENT: u8 = 4;
const ACTION_CANCEL_STREAM: u8 = 5;
// Config Actions
const ACTION_UPDATE_TRADING_PARAMS: u8 = 10;
const ACTION_UPDATE_METADATA: u8 = 11;
const ACTION_UPDATE_TWAP_CONFIG: u8 = 12;
const ACTION_UPDATE_GOVERNANCE: u8 = 13;
const ACTION_UPDATE_METADATA_TABLE: u8 = 14;
const ACTION_UPDATE_QUEUE_PARAMS: u8 = 15;
// Dissolution Actions
const ACTION_PARTIAL_DISSOLUTION: u8 = 20;
const ACTION_FULL_DISSOLUTION: u8 = 21;
// Liquidity Actions
const ACTION_ADD_LIQUIDITY: u8 = 30;
const ACTION_REMOVE_LIQUIDITY: u8 = 31;

// === Errors ===
const E_PROPOSAL_NOT_FOUND: u64 = 0;
const E_ALREADY_EXECUTED: u64 = 1;
const E_ACTIONS_ALREADY_STORED: u64 = 2;
const E_INVALID_OUTCOME_INDEX: u64 = 3;

// === Structs ===

/// The single, unified registry for all proposal actions.
public struct ActionRegistry has key {
    id: UID,
    actions_by_proposal: Table<ID, ProposalActions>,
    executed_proposals: Table<ID, bool>,
}

/// Stores the sequenced actions for all outcomes of a single proposal.
public struct ProposalActions has store {
    sequences: Table<u64, vector<Action>>,
}

/// A generic, unified Action struct, designed for extensibility.
public struct Action has store, drop, copy {
    action_type: u8,
    // --- Treasury Actions ---
    transfer_action: Option<TransferAction>,
    mint_action: Option<MintAction>,
    burn_action: Option<BurnAction>,
    recurring_payment_action: Option<RecurringPaymentAction>,
    cancel_stream_action: Option<CancelStreamAction>,
    // --- Config Actions ---
    trading_params_action: Option<TradingParamsUpdateAction>,
    metadata_action: Option<MetadataUpdateAction>,
    twap_config_action: Option<TwapConfigUpdateAction>,
    governance_action: Option<GovernanceUpdateAction>,
    metadata_table_action: Option<MetadataTableUpdateAction>,
    queue_params_action: Option<QueueParamsUpdateAction>,
    // --- Dissolution Actions ---
    partial_dissolution_action: Option<PartialDissolutionAction>,
    full_dissolution_action: Option<FullDissolutionAction>,
    // --- Liquidity Actions ---
    add_liquidity_action: Option<AddLiquidityAction>,
    remove_liquidity_action: Option<RemoveLiquidityAction>,
}

// --- Treasury Action Structs ---
public struct TransferAction has store, drop, copy {
    coin_type: TypeName,
    recipient: address,
    amount: u64,
}

public struct MintAction has store, drop, copy {
    coin_type: TypeName,
    recipient: address,
    amount: u64,
}

public struct BurnAction has store, drop, copy {
    coin_type: TypeName,
    amount: u64,
}

public struct RecurringPaymentAction has store, drop, copy {
    coin_type: TypeName,
    recipient: address,
    amount_per_epoch: u64,
    num_epochs: u64,
    epoch_duration_ms: u64,
    cancellable: bool,
    description: String,
}

public struct CancelStreamAction has store, drop, copy {
    stream_id: ID,
}

// --- Config Action Structs ---
public struct TradingParamsUpdateAction has store, drop, copy {
    min_asset_amount: Option<u64>,
    min_stable_amount: Option<u64>,
    review_period_ms: Option<u64>,
    trading_period_ms: Option<u64>,
    amm_total_fee_bps: Option<u64>,
}

public struct MetadataUpdateAction has store, drop, copy {
    dao_name: Option<AsciiString>,
    icon_url: Option<Url>,
    description: Option<String>,
}

public struct TwapConfigUpdateAction has store, drop, copy {
    start_delay: Option<u64>,
    step_max: Option<u64>,
    initial_observation: Option<u128>,
    threshold: Option<u64>,
}

public struct GovernanceUpdateAction has store, drop, copy {
    proposal_creation_enabled: Option<bool>,
    max_outcomes: Option<u64>,
    required_bond_amount: Option<u64>,
}

public struct MetadataTableUpdateAction has store, drop, copy {
    keys: vector<String>,
    values: vector<String>,
    keys_to_remove: vector<String>,
}

public struct QueueParamsUpdateAction has store, drop, copy {
    max_proposer_funded: Option<u64>,
    max_concurrent_proposals: Option<u64>,
    max_queue_size: Option<u64>,
}

// --- Dissolution Action Structs ---
public struct PartialDissolutionAction has store, drop, copy {
    percentage: u64, // Basis points (10000 = 100%)
}

public struct FullDissolutionAction has store, drop, copy {
    // No parameters needed for full dissolution
}

// --- Liquidity Action Structs ---
public struct AddLiquidityAction has store, drop, copy {
    pool_id: ID,
    coin_type_a: TypeName,
    coin_type_b: TypeName,
    amount_a: u64,
    amount_b: u64,
    min_lp_amount: u64,
}

public struct RemoveLiquidityAction has store, drop, copy {
    pool_id: ID,
    coin_type_a: TypeName,
    coin_type_b: TypeName,
    lp_amount: u64,
    min_amount_a: u64,
    min_amount_b: u64,
}

// === Core Functions ===

public fun new(ctx: &mut TxContext): ActionRegistry {
    ActionRegistry {
        id: object::new(ctx),
        actions_by_proposal: table::new(ctx),
        executed_proposals: table::new(ctx),
    }
}

/// Create and share a new ActionRegistry
public fun create_and_share(ctx: &mut TxContext) {
    let registry = new(ctx);
    transfer::share_object(registry);
}

public fun init_proposal_actions(
    registry: &mut ActionRegistry,
    proposal_id: ID,
    sequences_by_outcome: vector<vector<Action>>,
    ctx: &mut TxContext,
) {
    assert!(!registry.actions_by_proposal.contains(proposal_id), E_ACTIONS_ALREADY_STORED);
    
    let mut outcome_sequences = table::new(ctx);
    let mut i = 0;
    let len = sequences_by_outcome.length();
    while (i < len) {
        outcome_sequences.add(i, *vector::borrow(&sequences_by_outcome, i));
        i = i + 1;
    };

    registry.actions_by_proposal.add(proposal_id, ProposalActions {
        sequences: outcome_sequences,
    });
    registry.executed_proposals.add(proposal_id, false);
}

// === View Functions ===

public fun get_action_sequence(
    registry: &ActionRegistry,
    proposal_id: ID,
    outcome_index: u64,
): &vector<Action> {
    assert!(registry.actions_by_proposal.contains(proposal_id), E_PROPOSAL_NOT_FOUND);
    let proposal_actions = registry.actions_by_proposal.borrow(proposal_id);
    assert!(proposal_actions.sequences.contains(outcome_index), E_INVALID_OUTCOME_INDEX);
    proposal_actions.sequences.borrow(outcome_index)
}

public fun is_executed(registry: &ActionRegistry, proposal_id: ID): bool {
    if (!registry.executed_proposals.contains(proposal_id)) {
        return false
    };
    *registry.executed_proposals.borrow(proposal_id)
}

public fun has_actions(registry: &ActionRegistry, proposal_id: ID): bool {
    registry.actions_by_proposal.contains(proposal_id)
}

// === Package-Private Functions ===

public(package) fun mark_as_executed(registry: &mut ActionRegistry, proposal_id: ID) {
    assert!(registry.executed_proposals.contains(proposal_id), E_PROPOSAL_NOT_FOUND);
    assert!(!*registry.executed_proposals.borrow(proposal_id), E_ALREADY_EXECUTED);
    *registry.executed_proposals.borrow_mut(proposal_id) = true;
}

// === Action Factory Functions ===

public fun create_no_op_action(): Action {
    Action {
        action_type: ACTION_NO_OP,
        transfer_action: option::none(),
        mint_action: option::none(),
        burn_action: option::none(),
        recurring_payment_action: option::none(),
        cancel_stream_action: option::none(),
        trading_params_action: option::none(),
        metadata_action: option::none(),
        twap_config_action: option::none(),
        governance_action: option::none(),
        metadata_table_action: option::none(),
        queue_params_action: option::none(),
        partial_dissolution_action: option::none(),
        full_dissolution_action: option::none(),
        add_liquidity_action: option::none(),
        remove_liquidity_action: option::none(),
    }
}

public fun create_transfer_action(
    coin_type: TypeName,
    recipient: address,
    amount: u64,
): Action {
    let mut action = create_no_op_action();
    action.action_type = ACTION_TRANSFER;
    action.transfer_action = option::some(TransferAction {
        coin_type,
        recipient,
        amount,
    });
    action
}

public fun create_mint_action(
    coin_type: TypeName,
    recipient: address,
    amount: u64,
): Action {
    let mut action = create_no_op_action();
    action.action_type = ACTION_MINT;
    action.mint_action = option::some(MintAction {
        coin_type,
        recipient,
        amount,
    });
    action
}

public fun create_burn_action(
    coin_type: TypeName,
    amount: u64,
): Action {
    let mut action = create_no_op_action();
    action.action_type = ACTION_BURN;
    action.burn_action = option::some(BurnAction {
        coin_type,
        amount,
    });
    action
}

public fun create_recurring_payment_action(
    coin_type: TypeName,
    recipient: address,
    amount_per_epoch: u64,
    num_epochs: u64,
    epoch_duration_ms: u64,
    cancellable: bool,
    description: String,
): Action {
    let mut action = create_no_op_action();
    action.action_type = ACTION_RECURRING_PAYMENT;
    action.recurring_payment_action = option::some(RecurringPaymentAction {
        coin_type,
        recipient,
        amount_per_epoch,
        num_epochs,
        epoch_duration_ms,
        cancellable,
        description,
    });
    action
}

public fun create_cancel_stream_action(stream_id: ID): Action {
    let mut action = create_no_op_action();
    action.action_type = ACTION_CANCEL_STREAM;
    action.cancel_stream_action = option::some(CancelStreamAction { stream_id });
    action
}

public fun create_trading_params_action(
    min_asset_amount: Option<u64>,
    min_stable_amount: Option<u64>,
    review_period_ms: Option<u64>,
    trading_period_ms: Option<u64>,
    amm_total_fee_bps: Option<u64>,
): Action {
    let mut action = create_no_op_action();
    action.action_type = ACTION_UPDATE_TRADING_PARAMS;
    action.trading_params_action = option::some(TradingParamsUpdateAction {
        min_asset_amount,
        min_stable_amount,
        review_period_ms,
        trading_period_ms,
        amm_total_fee_bps,
    });
    action
}

public fun create_metadata_action(
    dao_name: Option<AsciiString>,
    icon_url: Option<Url>,
    description: Option<String>,
): Action {
    let mut action = create_no_op_action();
    action.action_type = ACTION_UPDATE_METADATA;
    action.metadata_action = option::some(MetadataUpdateAction {
        dao_name,
        icon_url,
        description,
    });
    action
}

public fun create_twap_config_action(
    start_delay: Option<u64>,
    step_max: Option<u64>,
    initial_observation: Option<u128>,
    threshold: Option<u64>,
): Action {
    let mut action = create_no_op_action();
    action.action_type = ACTION_UPDATE_TWAP_CONFIG;
    action.twap_config_action = option::some(TwapConfigUpdateAction {
        start_delay,
        step_max,
        initial_observation,
        threshold,
    });
    action
}

public fun create_governance_action(
    proposal_creation_enabled: Option<bool>,
    max_outcomes: Option<u64>,
    required_bond_amount: Option<u64>,
): Action {
    let mut action = create_no_op_action();
    action.action_type = ACTION_UPDATE_GOVERNANCE;
    action.governance_action = option::some(GovernanceUpdateAction {
        proposal_creation_enabled,
        max_outcomes,
        required_bond_amount,
    });
    action
}

public fun create_metadata_table_action(
    keys: vector<String>,
    values: vector<String>,
    keys_to_remove: vector<String>,
): Action {
    let mut action = create_no_op_action();
    action.action_type = ACTION_UPDATE_METADATA_TABLE;
    action.metadata_table_action = option::some(MetadataTableUpdateAction {
        keys,
        values,
        keys_to_remove,
    });
    action
}

public fun create_queue_params_action(
    max_proposer_funded: Option<u64>,
    max_concurrent_proposals: Option<u64>,
    max_queue_size: Option<u64>,
): Action {
    let mut action = create_no_op_action();
    action.action_type = ACTION_UPDATE_QUEUE_PARAMS;
    action.queue_params_action = option::some(QueueParamsUpdateAction {
        max_proposer_funded,
        max_concurrent_proposals,
        max_queue_size,
    });
    action
}

public fun create_partial_dissolution_action(percentage: u64): Action {
    let mut action = create_no_op_action();
    action.action_type = ACTION_PARTIAL_DISSOLUTION;
    action.partial_dissolution_action = option::some(PartialDissolutionAction { percentage });
    action
}

public fun create_full_dissolution_action(): Action {
    let mut action = create_no_op_action();
    action.action_type = ACTION_FULL_DISSOLUTION;
    action.full_dissolution_action = option::some(FullDissolutionAction {});
    action
}

public fun create_add_liquidity_action(
    pool_id: ID,
    coin_type_a: TypeName,
    coin_type_b: TypeName,
    amount_a: u64,
    amount_b: u64,
    min_lp_amount: u64,
): Action {
    let mut action = create_no_op_action();
    action.action_type = ACTION_ADD_LIQUIDITY;
    action.add_liquidity_action = option::some(AddLiquidityAction {
        pool_id,
        coin_type_a,
        coin_type_b,
        amount_a,
        amount_b,
        min_lp_amount,
    });
    action
}

public fun create_remove_liquidity_action(
    pool_id: ID,
    coin_type_a: TypeName,
    coin_type_b: TypeName,
    lp_amount: u64,
    min_amount_a: u64,
    min_amount_b: u64,
): Action {
    let mut action = create_no_op_action();
    action.action_type = ACTION_REMOVE_LIQUIDITY;
    action.remove_liquidity_action = option::some(RemoveLiquidityAction {
        pool_id,
        coin_type_a,
        coin_type_b,
        lp_amount,
        min_amount_a,
        min_amount_b,
    });
    action
}

// === Action Getter Functions ===

public fun get_action_type(action: &Action): u8 {
    action.action_type
}

// === TransferAction Getters ===
public fun get_transfer_coin_type(action: &TransferAction): &TypeName { &action.coin_type }
public fun get_transfer_recipient(action: &TransferAction): address { action.recipient }
public fun get_transfer_amount(action: &TransferAction): u64 { action.amount }

// === MintAction Getters ===
public fun get_mint_coin_type(action: &MintAction): &TypeName { &action.coin_type }
public fun get_mint_recipient(action: &MintAction): address { action.recipient }
public fun get_mint_amount(action: &MintAction): u64 { action.amount }

// === BurnAction Getters ===
public fun get_burn_coin_type(action: &BurnAction): &TypeName { &action.coin_type }
public fun get_burn_amount(action: &BurnAction): u64 { action.amount }

// === RecurringPaymentAction Getters ===
public fun get_recurring_payment_coin_type(action: &RecurringPaymentAction): &TypeName { &action.coin_type }
public fun get_recurring_payment_recipient(action: &RecurringPaymentAction): address { action.recipient }
public fun get_recurring_payment_amount_per_epoch(action: &RecurringPaymentAction): u64 { action.amount_per_epoch }
public fun get_recurring_payment_num_epochs(action: &RecurringPaymentAction): u64 { action.num_epochs }
public fun get_recurring_payment_epoch_duration_ms(action: &RecurringPaymentAction): u64 { action.epoch_duration_ms }
public fun get_recurring_payment_cancellable(action: &RecurringPaymentAction): bool { action.cancellable }
public fun get_recurring_payment_description(action: &RecurringPaymentAction): &String { &action.description }

// === CancelStreamAction Getters ===
public fun get_cancel_stream_id(action: &CancelStreamAction): ID { action.stream_id }

public fun get_transfer_action(action: &Action): &TransferAction {
    option::borrow(&action.transfer_action)
}

public fun get_mint_action(action: &Action): &MintAction {
    option::borrow(&action.mint_action)
}

public fun get_burn_action(action: &Action): &BurnAction {
    option::borrow(&action.burn_action)
}

public fun get_recurring_payment_action(action: &Action): &RecurringPaymentAction {
    option::borrow(&action.recurring_payment_action)
}

public fun get_cancel_stream_action(action: &Action): &CancelStreamAction {
    option::borrow(&action.cancel_stream_action)
}

public fun get_trading_params_action(action: &Action): &TradingParamsUpdateAction {
    option::borrow(&action.trading_params_action)
}

public fun get_metadata_action(action: &Action): &MetadataUpdateAction {
    option::borrow(&action.metadata_action)
}

public fun get_twap_config_action(action: &Action): &TwapConfigUpdateAction {
    option::borrow(&action.twap_config_action)
}

public fun get_governance_action(action: &Action): &GovernanceUpdateAction {
    option::borrow(&action.governance_action)
}

public fun get_metadata_table_action(action: &Action): &MetadataTableUpdateAction {
    option::borrow(&action.metadata_table_action)
}

public fun get_queue_params_action(action: &Action): &QueueParamsUpdateAction {
    option::borrow(&action.queue_params_action)
}

public fun get_partial_dissolution_action(action: &Action): &PartialDissolutionAction {
    option::borrow(&action.partial_dissolution_action)
}

public fun get_full_dissolution_action(action: &Action): &FullDissolutionAction {
    option::borrow(&action.full_dissolution_action)
}

public fun get_add_liquidity_action(action: &Action): &AddLiquidityAction {
    option::borrow(&action.add_liquidity_action)
}

public fun get_remove_liquidity_action(action: &Action): &RemoveLiquidityAction {
    option::borrow(&action.remove_liquidity_action)
}

// === TradingParamsUpdateAction Getters ===
public fun get_trading_params_min_asset_amount(action: &TradingParamsUpdateAction): &Option<u64> { &action.min_asset_amount }
public fun get_trading_params_min_stable_amount(action: &TradingParamsUpdateAction): &Option<u64> { &action.min_stable_amount }
public fun get_trading_params_review_period_ms(action: &TradingParamsUpdateAction): &Option<u64> { &action.review_period_ms }
public fun get_trading_params_trading_period_ms(action: &TradingParamsUpdateAction): &Option<u64> { &action.trading_period_ms }
public fun get_trading_params_amm_total_fee_bps(action: &TradingParamsUpdateAction): &Option<u64> { &action.amm_total_fee_bps }

// === MetadataUpdateAction Getters ===
public fun get_metadata_dao_name(action: &MetadataUpdateAction): &Option<AsciiString> { &action.dao_name }
public fun get_metadata_icon_url(action: &MetadataUpdateAction): &Option<Url> { &action.icon_url }
public fun get_metadata_description(action: &MetadataUpdateAction): &Option<String> { &action.description }

// === TwapConfigUpdateAction Getters ===
public fun get_twap_config_start_delay(action: &TwapConfigUpdateAction): &Option<u64> { &action.start_delay }
public fun get_twap_config_step_max(action: &TwapConfigUpdateAction): &Option<u64> { &action.step_max }
public fun get_twap_config_initial_observation(action: &TwapConfigUpdateAction): &Option<u128> { &action.initial_observation }
public fun get_twap_config_threshold(action: &TwapConfigUpdateAction): &Option<u64> { &action.threshold }

// === GovernanceUpdateAction Getters ===
public fun get_governance_proposal_creation_enabled(action: &GovernanceUpdateAction): &Option<bool> { &action.proposal_creation_enabled }
public fun get_governance_max_outcomes(action: &GovernanceUpdateAction): &Option<u64> { &action.max_outcomes }
public fun get_governance_required_bond_amount(action: &GovernanceUpdateAction): &Option<u64> { &action.required_bond_amount }

// === MetadataTableUpdateAction Getters ===
public fun get_metadata_table_keys(action: &MetadataTableUpdateAction): &vector<String> { &action.keys }
public fun get_metadata_table_values(action: &MetadataTableUpdateAction): &vector<String> { &action.values }
public fun get_metadata_table_keys_to_remove(action: &MetadataTableUpdateAction): &vector<String> { &action.keys_to_remove }

// === QueueParamsUpdateAction Getters ===
public fun get_queue_params_max_proposer_funded(action: &QueueParamsUpdateAction): &Option<u64> { &action.max_proposer_funded }
public fun get_queue_params_max_concurrent_proposals(action: &QueueParamsUpdateAction): &Option<u64> { &action.max_concurrent_proposals }
public fun get_queue_params_max_queue_size(action: &QueueParamsUpdateAction): &Option<u64> { &action.max_queue_size }