/// Main action dispatcher - Entry points for composable atomic batch execution
/// Delegates to specialized dispatchers in each category folder
module futarchy_actions::action_dispatcher;

// === Imports ===
use std::option;
use sui::{
    clock::Clock,
    coin::{Self, Coin},
    sui::SUI,
    transfer,
    tx_context::TxContext,
};
use account_protocol::{
    account::Account,
    executable::{Self, Executable},
    intents::Intent,
};
use account_actions::{
    vault_intents,
};
use futarchy_core::version;
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_core::{
    priority_queue,
    proposal_fee_manager::ProposalFeeManager,
};
use futarchy_markets::{
    proposal,
    spot_amm::SpotAMM,
};

// Import all specialized dispatchers
use futarchy_actions::{
    config_dispatcher,
    liquidity_dispatcher,
    vault_governance_dispatcher,
    memo_dispatcher,
    optimistic_dispatcher,
    protocol_admin_actions,
    governance_dispatcher,
    governance_actions::{Self, ProposalReservationRegistry},
};
use futarchy_specialized_actions::{
    operating_agreement_dispatcher,
};
use futarchy_lifecycle::{
    factory::Factory,
    dissolution_dispatcher,
    oracle_actions,
    stream_dispatcher,
};
use futarchy_markets::fee::{FeeManager};

// === Entry Functions for Composable Execution ===

/// Execute standard futarchy actions that don't require special resources
/// Includes: config updates, governance settings, memos, etc.
public fun execute_standard_actions<IW: copy + drop, Outcome: store + drop + copy>(
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
            operating_agreement_dispatcher::try_execute_operating_agreement_action(&mut executable, account, witness, clock, ctx) ||
            optimistic_dispatcher::try_execute_optimistic_action(&mut executable, account, witness, clock, ctx);
            
        if (!processed) break  // Unknown action type
    };
    
    executable
}

/// Execute vault spend and transfer actions
public fun execute_vault_spend<Outcome: store + drop + copy, CoinType: drop>(
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
public fun execute_vault_management<Outcome: store + drop + copy, CoinType: drop, IW: copy + drop>(
    mut executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    ctx: &mut TxContext,
): Executable<Outcome> {
    // Process vault coin type management actions
    while (executable.action_idx() < executable.intent().actions().length()) {
        if (vault_governance_dispatcher::try_execute_typed_vault_action<CoinType, IW, Outcome>(&mut executable, account, witness, ctx)) {
            continue
        };
        
        break // Unknown action type
    };
    
    executable
}

/// Execute oracle mint actions using stored TreasuryCap
/// Handles conditional mints and tiered mints for founder rewards
public fun execute_oracle_mint<
    Outcome: store + drop + copy,
    AssetType: drop + store,
    StableType: drop + store,
    IW: copy + drop
>(
    mut executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    spot_pool: &mut SpotAMM<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<Outcome> {
    // Process all oracle actions using stored TreasuryCap
    while (executable.action_idx() < executable.intent().actions().length()) {
        // Check for read oracle price action
        if (executable::contains_action<Outcome, oracle_actions::ReadOraclePriceAction<AssetType, StableType>>(&mut executable)) {
            oracle_actions::do_read_oracle_price<AssetType, StableType, Outcome, IW>(
                &mut executable,
                account,
                version::current(),
                witness,
                spot_pool,
                clock,
                ctx
            );
            continue
        };
        
        // Check for conditional mint action
        if (executable::contains_action<Outcome, oracle_actions::ConditionalMintAction<AssetType>>(&mut executable)) {
            oracle_actions::do_conditional_mint<AssetType, StableType, Outcome, IW>(
                &mut executable,
                account,
                version::current(),
                witness,
                spot_pool,
                clock,
                ctx
            );
            continue
        };
        
        // Check for tiered mint action
        if (executable::contains_action<Outcome, oracle_actions::TieredMintAction<AssetType>>(&mut executable)) {
            oracle_actions::do_tiered_mint<AssetType, StableType, Outcome, IW>(
                &mut executable,
                account,
                version::current(),
                witness,
                spot_pool,
                clock,
                ctx
            );
            continue
        };
        
        break // Unknown action type
    };
    
    executable
}

/// Execute liquidity operations (pool creation, parameter updates, etc.)
public fun execute_liquidity_operations<
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
        
        let (handled, resource_request) = liquidity_dispatcher::try_execute_typed_liquidity_action<AssetType, StableType, IW, Outcome>(
            &mut executable, account, witness, ctx
        );
        // Properly handle the resource request option
        option::destroy_none(resource_request);
        if (handled) {
            continue
        };
        
        break // Unknown action type
    };
    
    executable
}

/// Execute stream/recurring payment operations
public fun execute_stream_operations<
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
public fun execute_dissolution_operations<
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
        let (handled, resource_request) = liquidity_dispatcher::try_execute_typed_liquidity_action<AssetType, StableType, IW, Outcome>(
            &mut executable, account, witness, ctx
        );
        // Properly handle the resource request option
        option::destroy_none(resource_request);
        if (handled) {
            continue
        };
        
        break // Unknown action type
    };
    
    executable
}

/// Execute governance operations (create second-order proposals)
public fun execute_governance_operations<
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

/// Execute protocol admin operations (factory, fee, validator management)
/// This enables dogfooding - the protocol being governed by its own DAO
public fun execute_protocol_admin_operations<
    Outcome: store + drop + copy,
    IW: copy + drop
>(
    mut executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    factory: &mut Factory,
    fee_manager: &mut FeeManager,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<Outcome> {
    // Process all protocol admin actions
    while (executable.action_idx() < executable.intent().actions().length()) {
        // Factory admin actions
        if (executable::contains_action<Outcome, protocol_admin_actions::SetFactoryPausedAction>(&mut executable)) {
            protocol_admin_actions::do_set_factory_paused(
                &mut executable,
                account,
                version::current(),
                witness,
                factory,
                ctx
            );
            continue
        };
        
        // Fee admin actions
        if (executable::contains_action<Outcome, protocol_admin_actions::UpdateDaoCreationFeeAction>(&mut executable)) {
            protocol_admin_actions::do_update_dao_creation_fee(
                &mut executable,
                account,
                version::current(),
                witness,
                fee_manager,
                clock,
                ctx
            );
            continue
        };
        
        if (executable::contains_action<Outcome, protocol_admin_actions::UpdateProposalFeeAction>(&mut executable)) {
            protocol_admin_actions::do_update_proposal_fee(
                &mut executable,
                account,
                version::current(),
                witness,
                fee_manager,
                clock,
                ctx
            );
            continue
        };
        
        if (executable::contains_action<Outcome, protocol_admin_actions::UpdateMonthlyDaoFeeAction>(&mut executable)) {
            protocol_admin_actions::do_update_monthly_dao_fee(
                &mut executable,
                account,
                version::current(),
                witness,
                fee_manager,
                clock,
                ctx
            );
            continue
        };
        
        if (executable::contains_action<Outcome, protocol_admin_actions::UpdateVerificationFeeAction>(&mut executable)) {
            protocol_admin_actions::do_update_verification_fee(
                &mut executable,
                account,
                version::current(),
                witness,
                fee_manager,
                clock,
                ctx
            );
            continue
        };
        
        if (executable::contains_action<Outcome, protocol_admin_actions::AddVerificationLevelAction>(&mut executable)) {
            protocol_admin_actions::do_add_verification_level(
                &mut executable,
                account,
                version::current(),
                witness,
                fee_manager,
                clock,
                ctx
            );
            continue
        };
        
        if (executable::contains_action<Outcome, protocol_admin_actions::RemoveVerificationLevelAction>(&mut executable)) {
            protocol_admin_actions::do_remove_verification_level(
                &mut executable,
                account,
                version::current(),
                witness,
                fee_manager,
                clock,
                ctx
            );
            continue
        };
        
        if (executable::contains_action<Outcome, protocol_admin_actions::UpdateRecoveryFeeAction>(&mut executable)) {
            protocol_admin_actions::do_update_recovery_fee(
                &mut executable,
                account,
                version::current(),
                witness,
                fee_manager,
                clock,
                ctx
            );
            continue
        };
        
        if (executable::contains_action<Outcome, protocol_admin_actions::ApplyDaoFeeDiscountAction>(&mut executable)) {
            protocol_admin_actions::do_apply_dao_fee_discount(
                &mut executable,
                account,
                version::current(),
                witness,
                fee_manager,
                clock,
                ctx
            );
            continue
        };
        
        if (executable::contains_action<Outcome, protocol_admin_actions::WithdrawFeesToTreasuryAction>(&mut executable)) {
            protocol_admin_actions::do_withdraw_fees_to_treasury(
                &mut executable,
                account,
                version::current(),
                witness,
                fee_manager,
                clock,
                ctx
            );
            continue
        };
        
        break // Unknown action type
    };
    
    executable
}

/// Execute commitment creation with coins
public fun execute_commitment_creation<
    AssetType,
    StableType,
    Outcome: store + drop + copy,
    IW: copy + drop
>(
    mut executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    committed_coin: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<Outcome> {
    use futarchy_actions::commitment_dispatcher;
    
    // Process only create commitment action
    if (executable.action_idx() < executable.intent().actions().length()) {
        let mut new_commitment = commitment_dispatcher::try_execute_create_commitment<AssetType, StableType, Outcome, IW>(
            &mut executable,
            account,
            witness,
            committed_coin,
            clock,
            ctx,
        );
        
        if (option::is_some(&new_commitment)) {
            transfer::public_share_object(option::extract(&mut new_commitment));
            option::destroy_none(new_commitment);
            return executable
        };
        
        // The coins have already been handled by try_execute_create_commitment
        option::destroy_none(new_commitment);
    } else {
        // If the executable is complete, the coin should already be zero
        if (coin::value(&committed_coin) == 0) {
            coin::destroy_zero(committed_coin);
        } else {
            // Return non-zero coins to sender
            transfer::public_transfer(committed_coin, tx_context::sender(ctx));
        };
    };
    
    executable
}

/// Execute commitment operations (no coin needed)
public fun execute_commitment_operations<
    AssetType,
    StableType,
    Outcome: store + drop + copy,
    IW: copy + drop
>(
    mut executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    commitment: &mut futarchy_actions::commitment_proposal::CommitmentProposal<AssetType, StableType>,
    proposal: &proposal::Proposal<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<Outcome> {
    use futarchy_actions::{commitment_dispatcher, commitment_actions};
    
    while (executable.action_idx() < executable.intent().actions().length()) {
        let mut request_opt = commitment_dispatcher::try_execute_commitment<AssetType, StableType, Outcome, IW>(
            &mut executable,
            account,
            witness,
            ctx,
        );
        if (option::is_some(&request_opt)) {
            let request = option::extract(&mut request_opt);
            option::destroy_none(request_opt); // Destroy the now-empty option
            // Properly fulfill the request with required resources
            let _receipt = commitment_actions::fulfill_execute_commitment(
                request,
                commitment,
                proposal,
                clock,
                ctx,
            );
            continue
        };
        option::destroy_none(request_opt);
        
        let mut update_request = commitment_dispatcher::try_execute_update_recipient<AssetType, StableType, Outcome, IW>(
            &mut executable,
            account,
            witness,
            ctx,
        );
        if (option::is_some(&update_request)) {
            let request = option::extract(&mut update_request);
            option::destroy_none(update_request); // Destroy the now-empty option
            // Properly fulfill the update recipient request
            let _receipt = commitment_actions::fulfill_update_commitment_recipient(
                request,
                commitment,
                ctx,
            );
            continue
        };
        option::destroy_none(update_request);
        
        let mut withdraw_request = commitment_dispatcher::try_execute_withdraw_tokens<AssetType, StableType, Outcome, IW>(
            &mut executable,
            account,
            witness,
            ctx,
        );
        if (option::is_some(&withdraw_request)) {
            let request = option::extract(&mut withdraw_request);
            option::destroy_none(withdraw_request); // Destroy the now-empty option
            // Properly fulfill the withdraw request
            let _receipt = commitment_actions::fulfill_withdraw_unlocked_tokens(
                request,
                commitment,
                clock,
                ctx,
            );
            continue
        };
        option::destroy_none(withdraw_request);
        
        break
    };
    
    executable
}