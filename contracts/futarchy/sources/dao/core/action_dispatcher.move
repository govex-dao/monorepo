/// Main action dispatcher - Entry points for composable atomic batch execution
/// Delegates to specialized dispatchers in each category folder
module futarchy::action_dispatcher;

// === Imports ===
use std::option::{Self, Option};
use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
    object::ID,
    transfer,
    tx_context::{Self, TxContext},
    event,
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents::Intent,
};
use account_actions::{
    vault_intents,
};
use futarchy::{
    futarchy_config::{Self, FutarchyConfig},
    version,
    priority_queue,
    proposal,
    proposal_fee_manager::{Self, ProposalFeeManager},
    spot_amm::SpotAMM,
    conditional_amm,
};

// Import all specialized dispatchers
use futarchy::{
    config_dispatcher,
    governance_dispatcher,
    oracle_mint_actions,
    dissolution_dispatcher,
    liquidity_dispatcher,
    stream_dispatcher,
    vault_dispatcher,
    memo_dispatcher,
    operating_agreement_dispatcher,
    governance_actions::{Self, ProposalReservationRegistry},
};

// === Constants ===
const EProposalCreationSkipped: u64 = 14;

// === Events ===
public struct ProposalCreationSkipped has copy, drop {
    parent_proposal_id: ID,
    timestamp: u64,
    reason: vector<u8>,
}

// === Entry Functions for Composable Execution ===

/// Execute standard futarchy actions that don't require special resources
/// Includes: config updates, governance settings, memos, etc.
public(package) fun execute_standard_actions<IW: copy + drop, Outcome: store + drop + copy>(
    executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<Outcome> {
    let mut executable = executable;
    
    // Process all standard actions
    while (executable.action_idx() < executable.intent().actions().length()) {
        let processed = 
            config_dispatcher::try_execute_config_action(&mut executable, account, witness, clock, ctx) ||
            governance_dispatcher::try_execute_governance_actions(&mut executable, account, witness, clock, ctx) ||
            memo_dispatcher::try_execute_memo_action(&mut executable, account, witness, clock, ctx) ||
            operating_agreement_dispatcher::try_execute_operating_agreement_action(&mut executable, account, witness, clock, ctx);
            
        if (!processed) break  // Unknown action type
    };
    
    executable
}

/// Execute vault spend and transfer actions
public(package) fun execute_vault_spend<Outcome: store + drop + copy, CoinType: drop>(
    executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    ctx: &mut TxContext,
): Executable<Outcome> {
    let mut executable = executable;
    
    // Use Move framework's vault intent execution for spend/transfer
    vault_intents::execute_spend_and_transfer<FutarchyConfig, Outcome, CoinType>(
        &mut executable,
        account,
        ctx
    );
    
    executable
}

/// Execute vault coin type management actions (add/remove allowed coin types)
public(package) fun execute_vault_management<Outcome: store + drop + copy, CoinType: drop, IW: copy + drop>(
    mut executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): Executable<Outcome> {
    // Process vault coin type management actions
    while (executable.action_idx() < executable.intent().actions().length()) {
        if (vault_dispatcher::try_execute_typed_vault_action<CoinType, IW, Outcome>(&mut executable, account, witness, ctx)) {
            continue
        };
        
        break // Unknown action type
    };
    
    executable
}

/// Execute oracle mint actions (conditional or ratio-based)
public(package) fun execute_oracle_mint<Outcome: store + drop + copy, AssetType>(
    executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    amm_pool: &mut conditional_amm::LiquidityPool,
    ctx: &mut TxContext,
): Executable<Outcome> {
    let mut executable = executable;
    
    oracle_mint_actions::execute_all_oracle_mint_actions<Outcome, AssetType>(
        &mut executable,
        account,
        amm_pool,
        ctx
    );
    
    executable
}

/// Execute liquidity operations (pool creation, parameter updates, etc.)
public(package) fun execute_liquidity_operations<
    Outcome: store + drop + copy,
    AssetType: drop + store,
    StableType: drop + store,
    IW: copy + drop
>(
    mut executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
): Executable<Outcome> {
    // Process all liquidity actions
    while (executable.action_idx() < executable.intent().actions().length()) {
        if (liquidity_dispatcher::try_execute_liquidity_action(&mut executable, account, witness, ctx)) {
            continue
        };
        
        if (liquidity_dispatcher::try_execute_typed_liquidity_action<AssetType, StableType, IW, Outcome>(
            &mut executable, account, witness, ctx
        )) {
            continue
        };
        
        break // Unknown action type
    };
    
    executable
}

/// Execute stream/recurring payment operations
public(package) fun execute_stream_operations<
    Outcome: store + drop + copy,
    CoinType: drop,
    IW: copy + drop
>(
    mut executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<Outcome> {
    // Process all stream actions
    while (executable.action_idx() < executable.intent().actions().length()) {
        if (stream_dispatcher::try_execute_stream_action(&mut executable, account, witness, clock, ctx)) {
            continue
        };
        
        if (stream_dispatcher::try_execute_typed_stream_action<CoinType, IW, Outcome>(
            &mut executable, account, witness, clock, ctx
        )) {
            continue
        };
        
        break // Unknown action type
    };
    
    executable
}

/// Execute dissolution operations (initiate, finalize, distribute, etc.)
public(package) fun execute_dissolution_operations<
    Outcome: store + drop + copy,
    AssetType: drop + store,
    StableType: drop + store,
    CoinType: drop,
    IW: copy + drop
>(
    mut executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<Outcome> {
    // Process all dissolution actions sequentially
    while (executable.action_idx() < executable.intent().actions().length()) {
        if (dissolution_dispatcher::try_execute_dissolution_action(&mut executable, account, witness, ctx)) {
            continue
        };
        
        if (dissolution_dispatcher::try_execute_typed_dissolution_action<CoinType, IW, Outcome>(
            &mut executable, account, witness, clock, ctx
        )) {
            continue
        };
        
        // Try liquidity actions (needed for withdrawing AMM liquidity)
        if (liquidity_dispatcher::try_execute_typed_liquidity_action<AssetType, StableType, IW, Outcome>(
            &mut executable, account, witness, ctx
        )) {
            continue
        };
        
        break // Unknown action type
    };
    
    executable
}

/// Execute governance operations (create second-order proposals)
public(package) fun execute_governance_operations<
    Outcome: store + drop + copy,
    IW: copy + drop
>(
    mut executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    queue: &mut priority_queue::ProposalQueue<FutarchyConfig>,
    fee_manager: &mut ProposalFeeManager,
    registry: &mut ProposalReservationRegistry,
    parent_proposal_id: ID,
    fee_coin: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<Outcome> {
    // Process governance actions that require special resources
    while (executable.action_idx() < executable.intent().actions().length()) {
        // Check if this is a create proposal action
        if (executable::contains_action<Outcome, governance_actions::CreateProposalAction>(&mut executable)) {
            // Create the resource request
            let request = governance_actions::do_create_proposal<Outcome, IW>(
                &mut executable,
                account,
                version::current(),
                witness,
                parent_proposal_id,
                clock,
                ctx
            );
            
            // Fulfill the request with resources
            // The fee coin is passed directly to fulfill function which handles validation
            let _receipt = governance_actions::fulfill_create_proposal(
                request,
                queue,
                fee_manager,
                registry,
                fee_coin,
                clock,
                ctx
            );
            
            // Receipt has drop ability, so it's automatically cleaned up
            // Note: fee_coin is consumed by fulfill_create_proposal, so we return here
            return executable
        } else {
            break // No more governance actions
        }
    };
    
    // If no governance actions were processed, return the fee coin to sender
    if (coin::value(&fee_coin) > 0) {
        transfer::public_transfer(fee_coin, tx_context::sender(ctx));
    } else {
        coin::destroy_zero(fee_coin);
    };
    
    executable
}