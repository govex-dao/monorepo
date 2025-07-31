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
    capability_manager::{Self, CapabilityManager},
    recurring_payments,
    recurring_payment_registry::PaymentStreamRegistry,
    dao::{Self, DAO},
    execution_context::{ProposalExecutionContext},
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
const EInvalidAction: u64 = 12;
const EActionAlreadyExecuted: u64 = 13;
const EUnauthorizedActionAddition: u64 = 14;
const ETooManyActions: u64 = 15;

// === Constants ===
const ACTION_TRANSFER: u8 = 0;
const ACTION_NO_OP: u8 = 3;
const ACTION_RECURRING_PAYMENT: u8 = 4;
const ACTION_MINT: u8 = 5;
const ACTION_BURN: u8 = 6;
const ACTION_CAPABILITY_DEPOSIT: u8 = 7;

// SECURITY FIX: Add maximum actions limit to prevent DOS
const MAX_ACTIONS_PER_OUTCOME: u64 = 100;

// === Structs ===

/// Registry to store treasury actions with proper type mapping
public struct ActionRegistry has key {
    id: UID,
    // Map proposal_id -> ProposalActions
    actions: Table<ID, ProposalActions>,
    // SECURITY FIX: Unified execution tracking to prevent bypass
    // Track executed actions: proposal_id -> outcome -> action_index -> executed
    executed_actions: Table<ID, Table<u64, Table<u64, bool>>>,
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
    // SECURITY FIX: Track proposal creator to ensure only they can add actions
    creator: address,
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

/// Mint action - mints new tokens
public struct MintAction<phantom CoinType> has store {
    amount: u64,
    recipient: address,
    description: String,
}

/// Burn action - burns tokens
public struct BurnAction<phantom CoinType> has store {
    amount: u64,
    from_treasury: bool, // If true, burn from treasury balance; if false, expect external coins
    description: String,
}

/// Capability deposit action - parameters for accepting a TreasuryCap
public struct CapabilityDepositAction<phantom CoinType> has store {
    max_supply: Option<u64>,
    max_mint_per_proposal: Option<u64>,
    mint_cooldown_ms: u64,
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
        executed_actions: table::new(ctx),
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
        creator: ctx.sender(),
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
    ctx: &mut TxContext,
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
    
    // SECURITY FIX: Limit number of actions per outcome to prevent DOS
    assert!(index < MAX_ACTIONS_PER_OUTCOME, ETooManyActions);
    
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
    ctx: &mut TxContext,
) {
    assert!(registry.actions.contains(proposal_id), ENoActionsFound);
    let proposal_actions = &mut registry.actions[proposal_id];
    assert!(proposal_actions.outcome_actions.contains(outcome), EInvalidOutcome);
    
    let action_bag = &mut proposal_actions.outcome_actions[outcome];
    let index = action_bag.length();
    
    // SECURITY FIX: Limit number of actions per outcome to prevent DOS
    assert!(index < MAX_ACTIONS_PER_OUTCOME, ETooManyActions);
    
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
    ctx: &mut TxContext,
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
    
    // SECURITY FIX: Limit number of actions per outcome to prevent DOS
    assert!(index < MAX_ACTIONS_PER_OUTCOME, ETooManyActions);
    
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

/// Add a mint action
public fun add_mint_action<CoinType>(
    registry: &mut ActionRegistry,
    proposal_id: ID,
    outcome: u64,
    amount: u64,
    recipient: address,
    description: String,
    ctx: &mut TxContext,
) {
    assert!(registry.actions.contains(proposal_id), ENoActionsFound);
    let proposal_actions = &mut registry.actions[proposal_id];
    assert!(proposal_actions.outcome_actions.contains(outcome), EInvalidOutcome);
    
    // Validate parameters
    assert!(amount > 0, EInvalidAmount);
    
    let action = MintAction<CoinType> {
        amount,
        recipient,
        description,
    };
    
    let action_bag = &mut proposal_actions.outcome_actions[outcome];
    let index = action_bag.length();
    
    // SECURITY FIX: Limit number of actions per outcome to prevent DOS
    assert!(index < MAX_ACTIONS_PER_OUTCOME, ETooManyActions);
    
    action_bag.add(index, action);
    
    // Add metadata
    let coin_type_str = type_name::get<CoinType>().into_string();
    let metadata = ActionMetadata {
        action_type: ACTION_MINT,
        coin_type: option::some(coin_type_str),
        index,
    };
    proposal_actions.action_metadata[outcome].push_back(metadata);
    
    // Track coin type
    if (!proposal_actions.coin_types.contains(&coin_type_str)) {
        proposal_actions.coin_types.push_back(coin_type_str);
    };
    
    event::emit(ActionAdded {
        proposal_id,
        outcome,
        action_type: ACTION_MINT,
        coin_type: option::some(coin_type_str),
    });
}

/// Add a burn action
public fun add_burn_action<CoinType>(
    registry: &mut ActionRegistry,
    proposal_id: ID,
    outcome: u64,
    amount: u64,
    from_treasury: bool,
    description: String,
    ctx: &mut TxContext,
) {
    assert!(registry.actions.contains(proposal_id), ENoActionsFound);
    let proposal_actions = &mut registry.actions[proposal_id];
    assert!(proposal_actions.outcome_actions.contains(outcome), EInvalidOutcome);
    
    // Validate parameters
    assert!(amount > 0, EInvalidAmount);
    
    let action = BurnAction<CoinType> {
        amount,
        from_treasury,
        description,
    };
    
    let action_bag = &mut proposal_actions.outcome_actions[outcome];
    let index = action_bag.length();
    
    // SECURITY FIX: Limit number of actions per outcome to prevent DOS
    assert!(index < MAX_ACTIONS_PER_OUTCOME, ETooManyActions);
    
    action_bag.add(index, action);
    
    // Add metadata
    let coin_type_str = type_name::get<CoinType>().into_string();
    let metadata = ActionMetadata {
        action_type: ACTION_BURN,
        coin_type: option::some(coin_type_str),
        index,
    };
    proposal_actions.action_metadata[outcome].push_back(metadata);
    
    // Track coin type
    if (!proposal_actions.coin_types.contains(&coin_type_str)) {
        proposal_actions.coin_types.push_back(coin_type_str);
    };
    
    event::emit(ActionAdded {
        proposal_id,
        outcome,
        action_type: ACTION_BURN,
        coin_type: option::some(coin_type_str),
    });
}

/// Add a capability deposit action
public fun add_capability_deposit_action<CoinType>(
    registry: &mut ActionRegistry,
    proposal_id: ID,
    outcome: u64,
    max_supply: Option<u64>,
    max_mint_per_proposal: Option<u64>,
    mint_cooldown_ms: u64,
    ctx: &mut TxContext,
) {
    assert!(registry.actions.contains(proposal_id), ENoActionsFound);
    let proposal_actions = &mut registry.actions[proposal_id];
    assert!(proposal_actions.outcome_actions.contains(outcome), EInvalidOutcome);
    
    let action = CapabilityDepositAction<CoinType> {
        max_supply,
        max_mint_per_proposal,
        mint_cooldown_ms,
    };
    
    let action_bag = &mut proposal_actions.outcome_actions[outcome];
    let index = action_bag.length();
    
    // SECURITY FIX: Limit number of actions per outcome to prevent DOS
    assert!(index < MAX_ACTIONS_PER_OUTCOME, ETooManyActions);
    
    action_bag.add(index, action);
    
    // Add metadata
    let coin_type_str = type_name::get<CoinType>().into_string();
    let metadata = ActionMetadata {
        action_type: ACTION_CAPABILITY_DEPOSIT,
        coin_type: option::some(coin_type_str),
        index,
    };
    proposal_actions.action_metadata[outcome].push_back(metadata);
    
    // Track coin type
    if (!proposal_actions.coin_types.contains(&coin_type_str)) {
        proposal_actions.coin_types.push_back(coin_type_str);
    };
    
    event::emit(ActionAdded {
        proposal_id,
        outcome,
        action_type: ACTION_CAPABILITY_DEPOSIT,
        coin_type: option::some(coin_type_str),
    });
}

// === Execution Functions ===

/// Execute transfer action
fun execute_transfer<AssetType, StableType, CoinType: drop>(
    action_bag: &mut Bag,
    index: u64,
    treasury: &mut Treasury,
    auth: treasury::Auth,
    _dao: &DAO<AssetType, StableType>,
    clock: &Clock,
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
            clock,
            ctx
        );
    } else {
        // If amount is 0, still need to consume auth token
        treasury::consume_auth(auth);
    };
}


/// Execute recurring payment action
fun execute_recurring_payment<AssetType, StableType, CoinType: drop>(
    action_bag: &mut Bag,
    index: u64,
    _treasury: &mut Treasury,
    auth: treasury::Auth,
    dao: &DAO<AssetType, StableType>,
    payment_registry: &mut PaymentStreamRegistry, // Required for creating a stream
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
    
    // With the new model, we don't pre-fund. We just create the stream object
    // which acts as a permission slip for future claims against the treasury.
    let total_amount_cap = amount_per_payment * total_payments;

    recurring_payments::create_payment_stream<CoinType>(
        object::id(dao),
        payment_registry,
        recipient,
        amount_per_payment,
        payment_interval_ms,
        start_timestamp,
        // Set end_timestamp and max_total as caps for safety
        option::some(start_timestamp + (payment_interval_ms * (total_payments + 1))),
        option::some(total_amount_cap),
        description,
        clock,
        ctx,
    );
    
    // Consume auth token to prevent reuse
    treasury::consume_auth(auth);
}

/// Execute no-op action
fun execute_no_op<AssetType, StableType>(
    action_bag: &mut Bag,
    index: u64,
    _treasury: &mut Treasury,
    auth: treasury::Auth,
    _dao: &DAO<AssetType, StableType>,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Remove the action but do nothing
    let _action = bag::remove<u64, NoOpAction>(action_bag, index);
    
    // Consume auth token to prevent reuse
    treasury::consume_auth(auth);
}



/// Execute capability deposit action
fun execute_capability_deposit<AssetType, StableType, CoinType: drop>(
    action_bag: &mut Bag,
    index: u64,
    _treasury: &mut Treasury,
    auth: treasury::Auth,
    _dao: &DAO<AssetType, StableType>,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Just remove the action - the actual deposit happens through
    // the permissionless deposit_treasury_cap function
    let CapabilityDepositAction { max_supply: _, max_mint_per_proposal: _, mint_cooldown_ms: _ } = 
        bag::remove<u64, CapabilityDepositAction<CoinType>>(action_bag, index);
    
    // Consume auth token to prevent reuse
    treasury::consume_auth(auth);
}

// === Private Helper Functions ===

/// Process a single action based on its type
fun process_action<AssetType, StableType, CoinType: drop>(
    action_type: u8,
    action_bag: &mut Bag,
    index: u64,
    treasury: &mut Treasury,
    auth: treasury::Auth,
    dao: &DAO<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
    cap_manager: &mut CapabilityManager,
    execution_context: &ProposalExecutionContext,
): bool {
    if (action_type == ACTION_TRANSFER) {
        execute_transfer<AssetType, StableType, CoinType>(
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
        execute_no_op<AssetType, StableType>(
            action_bag,
            index,
            treasury,
            auth,
            dao,
            clock,
            ctx
        );
        true
    } else if (action_type == ACTION_MINT) {
        // Handle mint action directly
        let MintAction { amount, recipient, description: _ } = 
            bag::remove<u64, MintAction<CoinType>>(action_bag, index);
        
        // Consume auth token (mint doesn't need treasury auth)
        treasury::consume_auth(auth);
        
        capability_manager::mint_tokens<CoinType>(
            cap_manager,
            execution_context,
            amount,
            recipient,
            clock,
            ctx
        );
        true
    } else if (action_type == ACTION_BURN) {
        // Handle burn action directly
        let BurnAction { amount, from_treasury, description: _ } = 
            bag::remove<u64, BurnAction<CoinType>>(action_bag, index);
        
        if (from_treasury) {
            // Withdraw coins from treasury and burn them
            let coins_to_burn = treasury::withdraw<CoinType>(
                auth,
                treasury,
                amount,
                clock,
                ctx
            );
            capability_manager::burn_tokens<CoinType>(
                cap_manager,
                execution_context,
                coins_to_burn,
                clock,
                ctx
            );
        } else {
            // For burning from other sources, we would need additional logic
            // For now, only treasury burns are supported
            treasury::consume_auth(auth);
            abort EInvalidAction
        };
        true
    } else if (action_type == ACTION_CAPABILITY_DEPOSIT) {
        execute_capability_deposit<AssetType, StableType, CoinType>(
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
        // Unknown action type - consume auth and return false
        treasury::consume_auth(auth);
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
public fun execute_outcome_actions<AssetType, StableType, CoinType: drop>(
    registry: &mut ActionRegistry,
    treasury: &mut Treasury,
    dao: &DAO<AssetType, StableType>,
    clock: &Clock,
    proposal_id: ID,
    outcome: u64,
    ctx: &mut TxContext,
    cap_manager: &mut CapabilityManager,
    execution_context: &ProposalExecutionContext,
) {
    assert!(registry.actions.contains(proposal_id), ENoActionsFound);
    
    // First, check and mark as executed to prevent replay
    {
        let proposal_actions = &mut registry.actions[proposal_id];
        assert!(proposal_actions.outcome_actions.contains(outcome), EInvalidOutcome);
        assert!(!proposal_actions.executed[outcome], EAlreadyExecuted);
        // CRITICAL: Mark as executed BEFORE processing to prevent replay attacks
        *&mut proposal_actions.executed[outcome] = true;
    };
    
    // Count actions for this coin type
    let mut action_count = 0u64;
    let coin_type_str = type_name::get<CoinType>().into_string();
    
    // Execute each action
    let mut i = 0;
    let metadata_vec_length = {
        let proposal_actions = &registry.actions[proposal_id];
        proposal_actions.action_metadata[outcome].length()
    };
    
    while (i < metadata_vec_length) {
        let (action_type, coin_type_opt, index) = {
            let proposal_actions = &registry.actions[proposal_id];
            let metadata = &proposal_actions.action_metadata[outcome][i];
            (metadata.action_type, metadata.coin_type, metadata.index)
        };
        
        // Only execute actions for this coin type
        if (coin_type_opt.is_some() && 
            *coin_type_opt.borrow() == coin_type_str) {
            
            if (action_type == ACTION_RECURRING_PAYMENT) {
                // Recurring payments need a registry - abort with error
                abort ERecurringPaymentRegistryRequired
            };
            
            // Get mutable reference to action bag for this specific action
            let proposal_actions_mut = &mut registry.actions[proposal_id];
            let action_bag = &mut proposal_actions_mut.outcome_actions[outcome];
            
            // Create auth for each action (auth is consumed)
            let auth = treasury::create_auth_for_proposal(treasury, execution_context);
            
            let executed = process_action<AssetType, StableType, CoinType>(
                action_type,
                action_bag,
                index,
                treasury,
                auth,
                dao,
                clock,
                ctx,
                cap_manager,
                execution_context
            );
            
            if (executed) {
                action_count = action_count + 1;
            };
        };
        i = i + 1;
    };
    
    // Check if all actions are done and emit event
    let is_empty = {
        let proposal_actions = &registry.actions[proposal_id];
        proposal_actions.outcome_actions[outcome].is_empty()
    };
    let should_mark_executed = finish_execution(
        is_empty,
        proposal_id,
        outcome,
        action_count,
        coin_type_str
    );
    
    // Mark as executed if all actions for all coin types are done
    if (should_mark_executed) {
        let proposal_actions_final = &mut registry.actions[proposal_id];
        proposal_actions_final.executed.remove(outcome);
        proposal_actions_final.executed.add(outcome, true);
    };
}

/// Execute actions for a specific outcome and coin type with payment stream support
public fun execute_outcome_actions_with_payments<AssetType, StableType, CoinType: drop>(
    registry: &mut ActionRegistry,
    treasury: &mut Treasury,
    payment_stream_registry: &mut PaymentStreamRegistry,
    dao: &DAO<AssetType, StableType>,
    clock: &Clock,
    proposal_id: ID,
    outcome: u64,
    ctx: &mut TxContext,
    cap_manager: &mut CapabilityManager,
    execution_context: &ProposalExecutionContext,
) {
    assert!(registry.actions.contains(proposal_id), ENoActionsFound);
    
    // First, check and mark as executed to prevent replay
    {
        let proposal_actions = &mut registry.actions[proposal_id];
        assert!(proposal_actions.outcome_actions.contains(outcome), EInvalidOutcome);
        assert!(!proposal_actions.executed[outcome], EAlreadyExecuted);
        // Mark as executed BEFORE processing to prevent replay attacks
        *&mut proposal_actions.executed[outcome] = true;
    };
    
    // Count actions for this coin type
    let mut action_count = 0u64;
    let coin_type_str = type_name::get<CoinType>().into_string();
    
    // Execute each action
    let mut i = 0;
    let metadata_vec_length = {
        let proposal_actions = &registry.actions[proposal_id];
        proposal_actions.action_metadata[outcome].length()
    };
    
    while (i < metadata_vec_length) {
        let (action_type, coin_type_opt, index) = {
            let proposal_actions = &registry.actions[proposal_id];
            let metadata = &proposal_actions.action_metadata[outcome][i];
            (metadata.action_type, metadata.coin_type, metadata.index)
        };
        
        // Only execute actions for this coin type
        if (coin_type_opt.is_some() && 
            *coin_type_opt.borrow() == coin_type_str) {
            
            // Create auth for each action (auth is consumed)
            let auth = treasury::create_auth_for_proposal(treasury, execution_context);
            
            if (action_type == ACTION_RECURRING_PAYMENT) {
                // Get mutable reference to action bag for this specific action
                let proposal_actions_mut = &mut registry.actions[proposal_id];
                let action_bag = &mut proposal_actions_mut.outcome_actions[outcome];
                
                execute_recurring_payment<AssetType, StableType, CoinType>(
                    action_bag,
                    index,
                    treasury,
                    auth,
                    dao,
                    payment_stream_registry,
                    clock,
                    ctx
                );
                action_count = action_count + 1;
            } else {
                // Get mutable reference to action bag for this specific action
                let proposal_actions_mut = &mut registry.actions[proposal_id];
                let action_bag = &mut proposal_actions_mut.outcome_actions[outcome];
                
                if (process_action<AssetType, StableType, CoinType>(
                    action_type,
                    action_bag,
                    index,
                    treasury,
                    auth,
                    dao,
                    clock,
                    ctx,
                    cap_manager,
                    execution_context
                )) {
                    action_count = action_count + 1;
                };
            };
        };
        i = i + 1;
    };
    
    // Check if all actions are done and emit event
    let is_empty = {
        let proposal_actions = &registry.actions[proposal_id];
        proposal_actions.outcome_actions[outcome].is_empty()
    };
    let should_mark_executed = finish_execution(
        is_empty,
        proposal_id,
        outcome,
        action_count,
        coin_type_str
    );
    
    // Mark as executed if all actions for all coin types are done
    if (should_mark_executed) {
        let proposal_actions_final = &mut registry.actions[proposal_id];
        proposal_actions_final.executed.remove(outcome);
        proposal_actions_final.executed.add(outcome, true);
    };
}

/// Execute SUI-specific actions without payment stream registry
public entry fun execute_outcome_actions_sui<AssetType, StableType>(
    registry: &mut ActionRegistry,
    treasury: &mut Treasury,
    dao: &DAO<AssetType, StableType>,
    cap_manager: &mut CapabilityManager,
    clock: &Clock,
    proposal_id: ID,
    outcome: u64,
    ctx: &mut TxContext,
) {
    // Verify proposal has been resolved
    let info = dao::get_proposal_info(dao, proposal_id);
    assert!(dao::get_result(info).is_some(), ENoActionsFound);
    
    // Create execution context
    let execution_context = dao::create_proposal_execution_context(
        dao,
        proposal_id,
        outcome
    );
    
    execute_outcome_actions<AssetType, StableType, SUI>(
        registry,
        treasury,
        dao,
        clock,
        proposal_id,
        outcome,
        ctx,
        cap_manager,
        &execution_context
    );
}

/// Execute SUI-specific actions with payment stream registry
public entry fun execute_outcome_actions_sui_with_payments<AssetType, StableType>(
    registry: &mut ActionRegistry,
    treasury: &mut Treasury,
    payment_stream_registry: &mut PaymentStreamRegistry,
    dao: &DAO<AssetType, StableType>,
    cap_manager: &mut CapabilityManager,
    clock: &Clock,
    proposal_id: ID,
    outcome: u64,
    ctx: &mut TxContext,
) {
    // Verify proposal has been resolved
    let info = dao::get_proposal_info(dao, proposal_id);
    assert!(dao::get_result(info).is_some(), ENoActionsFound);
    
    // Create execution context
    let execution_context = dao::create_proposal_execution_context(
        dao,
        proposal_id,
        outcome
    );
    
    execute_outcome_actions_with_payments<AssetType, StableType, SUI>(
        registry,
        treasury,
        payment_stream_registry,
        dao,
        clock,
        proposal_id,
        outcome,
        ctx,
        cap_manager,
        &execution_context
    );
}


/// Execute USDC-specific actions (for tests)
#[test_only]
public fun execute_outcome_actions_usdc<AssetType, StableType, USDC: drop>(
    registry: &mut ActionRegistry,
    treasury: &mut Treasury,
    dao: &DAO<AssetType, StableType>,
    clock: &Clock,
    proposal_id: ID,
    outcome: u64,
    ctx: &mut TxContext,
    cap_manager: &mut CapabilityManager,
    execution_context: &ProposalExecutionContext,
) {
    execute_outcome_actions<AssetType, StableType, USDC>(
        registry,
        treasury,
        dao,
        clock,
        proposal_id,
        outcome,
        ctx,
        cap_manager,
        execution_context
    );
}



// === Test Functions ===

#[test_only]
public fun destroy_for_testing(registry: ActionRegistry) {
    // For testing purposes, transfer ownership to a black hole address
    // This avoids the need to properly clean up nested tables
    transfer::transfer(registry, @0x0);
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