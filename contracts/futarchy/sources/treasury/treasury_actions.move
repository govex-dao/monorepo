/// Simplified treasury action management for single-vault treasury
module futarchy::treasury_actions;

// === Imports ===
use std::string::String;
use std::ascii::String as AsciiString;
use std::type_name;
use sui::{
    table::{Self, Table},
    bag::{Self, Bag},
    event,
    sui::SUI,
    clock::Clock,
};
use futarchy::{
    treasury::{Self, Treasury},
    recurring_payments,
    recurring_payment_registry::PaymentStreamRegistry,
    dao::DAO,
};

// === Errors ===
const EActionsAlreadyStored: u64 = 2;
const ENoActionsFound: u64 = 3;
const EAlreadyExecuted: u64 = 4;
const EInsufficientBalance: u64 = 5;
const EInvalidOutcome: u64 = 7;
const EInvalidAmount: u64 = 9;
const EInvalidVestingSchedule: u64 = 10;
const ERecurringPaymentRegistryRequired: u64 = 11;

// === Constants ===
const ACTION_TRANSFER: u8 = 0;
const ACTION_NO_OP: u8 = 3;
const ACTION_RECURRING_PAYMENT: u8 = 4;

// === Structs ===

/// Registry to store treasury actions with proper type mapping
public struct ActionRegistry has key {
    id: UID,
    // Map proposal_id -> ProposalActions
    actions: Table<ID, ProposalActions>,
}

/// Actions for a proposal, stored by outcome using Bags for type safety
public struct ProposalActions has store {
    // Map outcome -> Bag of typed actions
    outcome_actions: Table<u64, Bag>,
    // Track execution status per outcome
    executed: Table<u64, bool>,
    // Track action metadata for execution
    action_metadata: Table<u64, vector<ActionMetadata>>,
    // Track unique coin types that have actions
    coin_types: vector<AsciiString>,
}

/// Metadata to track action type and coin type for execution
public struct ActionMetadata has store, drop, copy {
    action_type: u8,  // 0=Transfer, 1=Vesting, 3=NoOp, 4=RecurringPayment
    coin_type: Option<AsciiString>,  // None for NoOp actions
    index: u64,
}

// === Typed Action Structs ===

/// Transfer action - transfers coins to recipient
public struct TransferAction<phantom CoinType> has store {
    recipient: address,
    amount: u64,
}


/// No-op action for reject outcomes
public struct NoOpAction has store, drop {}

/// Recurring payment action
public struct RecurringPaymentAction<phantom CoinType> has store {
    recipient: address,
    amount_per_payment: u64,
    payment_interval_ms: u64, // Time between payments in milliseconds
    total_payments: u64, // Total number of payments
    start_timestamp: u64, // When first payment should occur
    description: String, // Description of the recurring payment
}


// === Events ===

public struct ActionsInitialized has copy, drop {
    proposal_id: ID,
    outcome_count: u64,
}

public struct ActionAdded has copy, drop {
    proposal_id: ID,
    outcome: u64,
    action_type: u8,
    coin_type: Option<AsciiString>,
}

public struct ActionsExecuted has copy, drop {
    proposal_id: ID,
    outcome: u64,
    action_count: u64,
    coin_type: AsciiString,
}

// === Public Functions ===

/// Create the action registry (called once at package init)
public fun create_for_testing(ctx: &mut TxContext) {
    let registry = ActionRegistry {
        id: object::new(ctx),
        actions: table::new(ctx),
    };
    transfer::share_object(registry);
}

/// Initialize actions for a proposal
public fun init_proposal_actions(
    registry: &mut ActionRegistry,
    proposal_id: ID,
    outcome_count: u64,
    ctx: &mut TxContext,
) {
    assert!(!registry.actions.contains(proposal_id), EActionsAlreadyStored);
    
    let mut outcome_actions = table::new<u64, Bag>(ctx);
    let mut executed = table::new<u64, bool>(ctx);
    let mut action_metadata = table::new<u64, vector<ActionMetadata>>(ctx);
    
    let mut i = 0;
    while (i < outcome_count) {
        outcome_actions.add(i, bag::new(ctx));
        executed.add(i, false);
        action_metadata.add(i, vector[]);
        i = i + 1;
    };
    
    let proposal_actions = ProposalActions {
        outcome_actions,
        executed,
        action_metadata,
        coin_types: vector[],
    };
    
    registry.actions.add(proposal_id, proposal_actions);
    
    event::emit(ActionsInitialized {
        proposal_id,
        outcome_count,
    });
}

// === Add Action Functions ===

/// Add a transfer action
public fun add_transfer_action<CoinType>(
    registry: &mut ActionRegistry,
    proposal_id: ID,
    outcome: u64,
    recipient: address,
    amount: u64,
    _ctx: &mut TxContext,
) {
    assert!(registry.actions.contains(proposal_id), ENoActionsFound);
    let proposal_actions = &mut registry.actions[proposal_id];
    assert!(proposal_actions.outcome_actions.contains(outcome), EInvalidOutcome);
    
    // Validate parameters
    assert!(amount > 0, EInvalidAmount);
    
    let action = TransferAction<CoinType> {
        recipient,
        amount,
    };
    
    let action_bag = &mut proposal_actions.outcome_actions[outcome];
    let index = action_bag.length();
    action_bag.add(index, action);
    
    // Add metadata
    let metadata = ActionMetadata {
        action_type: ACTION_TRANSFER,
        coin_type: option::some(type_name::get<CoinType>().into_string()),
        index,
    };
    proposal_actions.action_metadata[outcome].push_back(metadata);
    
    // Track coin type
    let coin_type_str = type_name::get<CoinType>().into_string();
    if (!proposal_actions.coin_types.contains(&coin_type_str)) {
        proposal_actions.coin_types.push_back(coin_type_str);
    };
    
    event::emit(ActionAdded {
        proposal_id,
        outcome,
        action_type: ACTION_TRANSFER,
        coin_type: option::some(coin_type_str),
    });
}



/// Add a no-op action (for reject outcomes)
public fun add_no_op_action(
    registry: &mut ActionRegistry,
    proposal_id: ID,
    outcome: u64,
    _ctx: &mut TxContext,
) {
    assert!(registry.actions.contains(proposal_id), ENoActionsFound);
    let proposal_actions = &mut registry.actions[proposal_id];
    assert!(proposal_actions.outcome_actions.contains(outcome), EInvalidOutcome);
    
    let action_bag = &mut proposal_actions.outcome_actions[outcome];
    let index = action_bag.length();
    action_bag.add(index, NoOpAction {});
    
    // Add metadata
    let metadata = ActionMetadata {
        action_type: ACTION_NO_OP,
        coin_type: option::none(),
        index,
    };
    proposal_actions.action_metadata[outcome].push_back(metadata);
    
    event::emit(ActionAdded {
        proposal_id,
        outcome,
        action_type: ACTION_NO_OP,
        coin_type: option::none(),
    });
}

/// Add recurring payment action
public fun add_recurring_payment_action<CoinType>(
    registry: &mut ActionRegistry,
    proposal_id: ID,
    outcome: u64,
    recipient: address,
    amount_per_payment: u64,
    payment_interval_ms: u64,
    total_payments: u64,
    start_timestamp: u64,
    description: String,
    _ctx: &mut TxContext,
) {
    assert!(registry.actions.contains(proposal_id), ENoActionsFound);
    let proposal_actions = &mut registry.actions[proposal_id];
    assert!(proposal_actions.outcome_actions.contains(outcome), EInvalidOutcome);
    
    // Validate parameters
    assert!(amount_per_payment > 0, EInvalidAmount);
    assert!(payment_interval_ms > 0, EInvalidAmount);
    assert!(total_payments > 0, EInvalidAmount);
    
    let action_bag = &mut proposal_actions.outcome_actions[outcome];
    let index = action_bag.length();
    
    let action = RecurringPaymentAction<CoinType> {
        recipient,
        amount_per_payment,
        payment_interval_ms,
        total_payments,
        start_timestamp,
        description,
    };
    action_bag.add(index, action);
    
    // Add metadata
    let coin_type_str = type_name::get<CoinType>().into_string();
    let metadata = ActionMetadata {
        action_type: ACTION_RECURRING_PAYMENT,
        coin_type: option::some(coin_type_str),
        index,
    };
    proposal_actions.action_metadata[outcome].push_back(metadata);
    
    event::emit(ActionAdded {
        proposal_id,
        outcome,
        action_type: ACTION_RECURRING_PAYMENT,
        coin_type: option::some(coin_type_str),
    });
}

// === Execution Functions ===

/// Execute transfer action
fun execute_transfer<CoinType: drop>(
    action_bag: &mut Bag,
    index: u64,
    treasury: &mut Treasury,
    auth: treasury::Auth,
    _dao: &DAO,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    let TransferAction { recipient, amount } = 
        bag::remove<u64, TransferAction<CoinType>>(action_bag, index);
    
    if (amount > 0) {
        // Check treasury has funds
        assert!(
            treasury::coin_type_value<CoinType>(treasury) >= amount,
            EInsufficientBalance
        );
        
        // Withdraw and transfer
        treasury::withdraw_to<CoinType>(
            auth,
            treasury,
            amount,
            recipient,
            ctx
        );
    }
}


/// Execute recurring payment action
fun execute_recurring_payment<CoinType: drop>(
    action_bag: &mut Bag,
    index: u64,
    treasury: &mut Treasury,
    auth: treasury::Auth,
    dao: &DAO,
    registry: &mut PaymentStreamRegistry, // Required for creating a stream
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let RecurringPaymentAction { 
        recipient, 
        amount_per_payment,
        payment_interval_ms,
        total_payments,
        start_timestamp,
        description 
    } = bag::remove<u64, RecurringPaymentAction<CoinType>>(action_bag, index);
    
    // Validate timing
    assert!(start_timestamp >= clock.timestamp_ms(), EInvalidVestingSchedule);
    
    // Calculate total amount needed
    let total_amount = amount_per_payment * total_payments;
    
    // Check treasury has sufficient funds for all payments
    assert!(
        treasury::coin_type_value<CoinType>(treasury) >= total_amount,
        EInsufficientBalance
    );
    
    // Withdraw the total amount needed to fund the new PaymentStream object
    let funds = treasury::withdraw<CoinType>(
        auth,
        treasury,
        total_amount,
        ctx
    );
    
    // Create the autonomous PaymentStream object, which now holds the funds
    recurring_payments::create_payment_stream<CoinType>(
        dao,
        registry,
        funds,
        recipient,
        amount_per_payment,
        payment_interval_ms,
        start_timestamp,
        option::some(start_timestamp + (payment_interval_ms * total_payments)), // End time
        option::some(total_amount), // Max total
        description,
        clock,
        ctx,
    );
}

/// Execute no-op action
fun execute_no_op(
    action_bag: &mut Bag,
    index: u64,
    _treasury: &mut Treasury,
    _auth: treasury::Auth,
    _dao: &DAO,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Remove the action but do nothing
    let _action = bag::remove<u64, NoOpAction>(action_bag, index);
}

// === Private Helper Functions ===

/// Process a single action based on its type
fun process_action<CoinType: drop>(
    action_type: u8,
    action_bag: &mut Bag,
    index: u64,
    treasury: &mut Treasury,
    auth: treasury::Auth,
    dao: &DAO,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    if (action_type == ACTION_TRANSFER) {
        execute_transfer<CoinType>(
            action_bag,
            index,
            treasury,
            auth,
            dao,
            clock,
            ctx
        );
        true
    } else if (action_type == ACTION_NO_OP) {
        execute_no_op(
            action_bag,
            index,
            treasury,
            auth,
            dao,
            clock,
            ctx
        );
        true
    } else {
        false
    }
}

/// Check if action bag is empty and emit event
fun finish_execution(
    is_empty: bool,
    proposal_id: ID,
    outcome: u64,
    action_count: u64,
    coin_type_str: AsciiString,
): bool {
    event::emit(ActionsExecuted {
        proposal_id,
        outcome,
        action_count,
        coin_type: coin_type_str,
    });
    
    is_empty
}

// === Public Execution Entry Points ===

/// Execute actions for a specific outcome and coin type
public fun execute_outcome_actions<CoinType: drop>(
    registry: &mut ActionRegistry,
    treasury: &mut Treasury,
    dao: &DAO,
    clock: &Clock,
    proposal_id: ID,
    outcome: u64,
    ctx: &mut TxContext,
) {
    assert!(registry.actions.contains(proposal_id), ENoActionsFound);
    let proposal_actions = &mut registry.actions[proposal_id];
    
    assert!(proposal_actions.outcome_actions.contains(outcome), EInvalidOutcome);
    assert!(!proposal_actions.executed[outcome], EAlreadyExecuted);
    
    let action_bag = &mut proposal_actions.outcome_actions[outcome];
    let metadata_vec = &proposal_actions.action_metadata[outcome];
    
    // Count actions for this coin type
    let mut action_count = 0u64;
    let coin_type_str = type_name::get<CoinType>().into_string();
    
    // Execute each action
    let mut i = 0;
    while (i < metadata_vec.length()) {
        let metadata = &metadata_vec[i];
        
        // Only execute actions for this coin type
        if (metadata.coin_type.is_some() && 
            *metadata.coin_type.borrow() == coin_type_str) {
            
            // Create auth for each action (auth is consumed)
            let auth = treasury::create_auth_for_proposal(treasury);
            
            if (metadata.action_type == ACTION_RECURRING_PAYMENT) {
                // Recurring payments need a registry - abort with error
                abort ERecurringPaymentRegistryRequired
            };
            
            if (process_action<CoinType>(
                metadata.action_type,
                action_bag,
                metadata.index,
                treasury,
                auth,
                dao,
                clock,
                ctx
            )) {
                action_count = action_count + 1;
            };
        };
        i = i + 1;
    };
    
    // Check if all actions are done and emit event
    let is_empty = action_bag.is_empty();
    let should_mark_executed = finish_execution(
        is_empty,
        proposal_id,
        outcome,
        action_count,
        coin_type_str
    );
    
    // Mark as executed if all actions for all coin types are done
    if (should_mark_executed) {
        proposal_actions.executed.remove(outcome);
        proposal_actions.executed.add(outcome, true);
    };
}

/// Execute actions for a specific outcome and coin type with payment stream support
public fun execute_outcome_actions_with_payments<CoinType: drop>(
    registry: &mut ActionRegistry,
    treasury: &mut Treasury,
    payment_stream_registry: &mut PaymentStreamRegistry,
    dao: &DAO,
    clock: &Clock,
    proposal_id: ID,
    outcome: u64,
    ctx: &mut TxContext,
) {
    assert!(registry.actions.contains(proposal_id), ENoActionsFound);
    let proposal_actions = &mut registry.actions[proposal_id];
    
    assert!(proposal_actions.outcome_actions.contains(outcome), EInvalidOutcome);
    assert!(!proposal_actions.executed[outcome], EAlreadyExecuted);
    
    let action_bag = &mut proposal_actions.outcome_actions[outcome];
    let metadata_vec = &proposal_actions.action_metadata[outcome];
    
    // Count actions for this coin type
    let mut action_count = 0u64;
    let coin_type_str = type_name::get<CoinType>().into_string();
    
    // Execute each action
    let mut i = 0;
    while (i < metadata_vec.length()) {
        let metadata = &metadata_vec[i];
        
        // Only execute actions for this coin type
        if (metadata.coin_type.is_some() && 
            *metadata.coin_type.borrow() == coin_type_str) {
            
            // Create auth for each action (auth is consumed)
            let auth = treasury::create_auth_for_proposal(treasury);
            
            if (metadata.action_type == ACTION_RECURRING_PAYMENT) {
                execute_recurring_payment<CoinType>(
                    action_bag,
                    metadata.index,
                    treasury,
                    auth,
                    dao,
                    payment_stream_registry,
                    clock,
                    ctx
                );
                action_count = action_count + 1;
            } else if (process_action<CoinType>(
                metadata.action_type,
                action_bag,
                metadata.index,
                treasury,
                auth,
                dao,
                clock,
                ctx
            )) {
                action_count = action_count + 1;
            };
        };
        i = i + 1;
    };
    
    // Check if all actions are done and emit event
    let is_empty = action_bag.is_empty();
    let should_mark_executed = finish_execution(
        is_empty,
        proposal_id,
        outcome,
        action_count,
        coin_type_str
    );
    
    // Mark as executed if all actions for all coin types are done
    if (should_mark_executed) {
        proposal_actions.executed.remove(outcome);
        proposal_actions.executed.add(outcome, true);
    };
}

/// Execute SUI-specific actions without payment stream registry
public entry fun execute_outcome_actions_sui(
    registry: &mut ActionRegistry,
    treasury: &mut Treasury,
    dao: &DAO,
    clock: &Clock,
    proposal_id: ID,
    outcome: u64,
    ctx: &mut TxContext,
) {
    execute_outcome_actions<SUI>(
        registry,
        treasury,
        dao,
        clock,
        proposal_id,
        outcome,
        ctx
    );
}

/// Execute SUI-specific actions with payment stream registry
public entry fun execute_outcome_actions_sui_with_payments(
    registry: &mut ActionRegistry,
    treasury: &mut Treasury,
    payment_stream_registry: &mut PaymentStreamRegistry,
    dao: &DAO,
    clock: &Clock,
    proposal_id: ID,
    outcome: u64,
    ctx: &mut TxContext,
) {
    execute_outcome_actions_with_payments<SUI>(
        registry,
        treasury,
        payment_stream_registry,
        dao,
        clock,
        proposal_id,
        outcome,
        ctx
    );
}


/// Execute USDC-specific actions (for tests)
#[test_only]
public entry fun execute_outcome_actions_usdc<USDC: drop>(
    registry: &mut ActionRegistry,
    treasury: &mut Treasury,
    dao: &DAO,
    clock: &Clock,
    proposal_id: ID,
    outcome: u64,
    ctx: &mut TxContext,
) {
    execute_outcome_actions<USDC>(
        registry,
        treasury,
        dao,
        clock,
        proposal_id,
        outcome,
        ctx
    );
}

// === View Functions ===

/// Get the number of actions for an outcome
public fun get_action_count(
    registry: &ActionRegistry,
    proposal_id: ID,
    outcome: u64,
): u64 {
    if (!registry.actions.contains(proposal_id)) {
        return 0
    };
    
    let proposal_actions = &registry.actions[proposal_id];
    if (!proposal_actions.outcome_actions.contains(outcome)) {
        return 0
    };
    
    proposal_actions.action_metadata[outcome].length()
}

/// Check if actions for an outcome have been executed
public fun is_executed(
    registry: &ActionRegistry,
    proposal_id: ID,
    outcome: u64,
): bool {
    if (!registry.actions.contains(proposal_id)) {
        return false
    };
    
    let proposal_actions = &registry.actions[proposal_id];
    if (!proposal_actions.executed.contains(outcome)) {
        return false
    };
    
    proposal_actions.executed[outcome]
}

/// Get unique coin types that have actions
public fun get_coin_types(
    registry: &ActionRegistry,
    proposal_id: ID,
): vector<AsciiString> {
    if (!registry.actions.contains(proposal_id)) {
        return vector[]
    };
    
    registry.actions[proposal_id].coin_types
}

/// Check if actions exist for a specific outcome
public fun has_actions_for_outcome(
    registry: &ActionRegistry,
    proposal_id: ID,
    outcome: u64,
): bool {
    if (!registry.actions.contains(proposal_id)) {
        return false
    };
    
    let proposal_actions = &registry.actions[proposal_id];
    proposal_actions.outcome_actions.contains(outcome) && 
    proposal_actions.action_metadata[outcome].length() > 0
}