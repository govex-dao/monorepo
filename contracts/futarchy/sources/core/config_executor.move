module futarchy::config_executor;

use sui::clock::Clock;
use sui::tx_context::TxContext;
use sui::url;

use futarchy::{
    dao::{Self},
    dao_state::{Self, DAO},
    priority_queue::{Self, ProposalQueue},
    metadata,
    oracle,
    action_registry::{Self,
        TradingParamsUpdateAction,
        MetadataUpdateAction,
        TwapConfigUpdateAction,
        GovernanceUpdateAction,
        MetadataTableUpdateAction,
        QueueParamsUpdateAction,
    },
    execution_context::ProposalExecutionContext,
};

// === Errors ===
const E_NO_CHANGES_SPECIFIED: u64 = 0;
const E_INVALID_PARAMETER: u64 = 1;
const E_UNSUPPORTED_OPERATION: u64 = 2;

// === Configuration Action Executors ===

/// Execute trading parameters update
public fun execute_trading_params_update<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    action: TradingParamsUpdateAction,
    _context: &ProposalExecutionContext,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Validate at least one change
    let min_asset_opt = action_registry::get_trading_params_min_asset_amount(&action);
    let min_stable_opt = action_registry::get_trading_params_min_stable_amount(&action);
    let review_opt = action_registry::get_trading_params_review_period_ms(&action);
    let trading_opt = action_registry::get_trading_params_trading_period_ms(&action);
    let amm_fee_opt = action_registry::get_trading_params_amm_total_fee_bps(&action);
    
    assert!(
        option::is_some(min_asset_opt) || 
        option::is_some(min_stable_opt) ||
        option::is_some(review_opt) ||
        option::is_some(trading_opt) ||
        option::is_some(amm_fee_opt),
        E_NO_CHANGES_SPECIFIED
    );

    // Get current values
    let (current_min_asset, current_min_stable) = dao::get_min_amounts(dao);
    let current_review = dao_state::review_period_ms(dao);
    let current_trading = dao_state::trading_period_ms(dao);

    // Apply updates
    dao::update_trading_params(
        dao,
        if (option::is_some(min_asset_opt)) { 
            *option::borrow(min_asset_opt) 
        } else { 
            current_min_asset 
        },
        if (option::is_some(min_stable_opt)) { 
            *option::borrow(min_stable_opt) 
        } else { 
            current_min_stable 
        },
        if (option::is_some(review_opt)) { 
            *option::borrow(review_opt) 
        } else { 
            current_review 
        },
        if (option::is_some(trading_opt)) { 
            *option::borrow(trading_opt) 
        } else { 
            current_trading 
        }
    );

    // Update AMM fee if specified
    if (option::is_some(amm_fee_opt)) {
        dao_state::set_amm_total_fee_bps(dao, *option::borrow(amm_fee_opt));
    };
}

/// Execute metadata update
public fun execute_metadata_update<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    action: MetadataUpdateAction,
    _context: &ProposalExecutionContext,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Validate at least one change
    let dao_name_opt = action_registry::get_metadata_dao_name(&action);
    let icon_url_opt = action_registry::get_metadata_icon_url(&action);
    let description_opt = action_registry::get_metadata_description(&action);
    
    assert!(
        option::is_some(dao_name_opt) || 
        option::is_some(icon_url_opt) ||
        option::is_some(description_opt),
        E_NO_CHANGES_SPECIFIED
    );

    // Get current values
    let current_dao_name = *dao_state::dao_name(dao);
    let current_icon_url = dao_state::icon_url(dao);
    let current_description = *dao_state::description(dao);

    // Apply updates
    dao::update_metadata(
        dao,
        if (option::is_some(dao_name_opt)) { 
            *option::borrow(dao_name_opt) 
        } else { 
            current_dao_name 
        },
        if (option::is_some(icon_url_opt)) { 
            url::inner_url(option::borrow(icon_url_opt))
        } else { 
            url::inner_url(current_icon_url)
        },
        if (option::is_some(description_opt)) { 
            *option::borrow(description_opt) 
        } else { 
            current_description 
        }
    );
}

/// Execute TWAP config update
public fun execute_twap_config_update<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    action: TwapConfigUpdateAction,
    _context: &ProposalExecutionContext,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    let start_delay_opt = action_registry::get_twap_config_start_delay(&action);
    let step_max_opt = action_registry::get_twap_config_step_max(&action);
    let initial_observation_opt = action_registry::get_twap_config_initial_observation(&action);
    let threshold_opt = action_registry::get_twap_config_threshold(&action);
    
    // Apply start delay update
    if (option::is_some(start_delay_opt)) {
        dao_state::set_amm_twap_start_delay(dao, *option::borrow(start_delay_opt));
    };
    
    // Apply step max update
    if (option::is_some(step_max_opt)) {
        dao_state::set_amm_twap_step_max(dao, *option::borrow(step_max_opt));
    };
    
    // Apply initial observation update
    if (option::is_some(initial_observation_opt)) {
        dao_state::set_amm_twap_initial_observation(dao, *option::borrow(initial_observation_opt));
    };
    
    // Apply threshold update
    if (option::is_some(threshold_opt)) {
        dao_state::set_twap_threshold(dao, *option::borrow(threshold_opt));
    };
}

/// Execute governance settings update
public fun execute_governance_update<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    action: GovernanceUpdateAction,
    _context: &ProposalExecutionContext,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    let proposal_creation_enabled_opt = action_registry::get_governance_proposal_creation_enabled(&action);
    let max_outcomes_opt = action_registry::get_governance_max_outcomes(&action);
    let required_bond_amount_opt = action_registry::get_governance_required_bond_amount(&action);

    // Apply proposal creation enabled update
    if (option::is_some(proposal_creation_enabled_opt)) {
        dao_state::set_proposal_creation_enabled(dao, *option::borrow(proposal_creation_enabled_opt));
    };

    // Apply governance params updates if specified
    if (option::is_some(max_outcomes_opt) || option::is_some(required_bond_amount_opt)) {
        let (current_max_outcomes, current_fee, current_max_concurrent, current_bond) = 
            dao::get_governance_params(dao);
        
        dao::update_governance(
            dao,
            if (option::is_some(max_outcomes_opt)) { 
                *option::borrow(max_outcomes_opt) 
            } else { 
                current_max_outcomes 
            },
            current_fee, // Keep current fee
            current_max_concurrent, // Keep current max concurrent
            if (option::is_some(required_bond_amount_opt)) { 
                *option::borrow(required_bond_amount_opt) 
            } else { 
                current_bond 
            }
        );
    };
}

/// Execute metadata table update
public fun execute_metadata_table_update<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    action: MetadataTableUpdateAction,
    _context: &ProposalExecutionContext,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    let keys = action_registry::get_metadata_table_keys(&action);
    let values = action_registry::get_metadata_table_values(&action);
    let keys_to_remove = action_registry::get_metadata_table_keys_to_remove(&action);
    
    // Add/update key-value pairs
    let mut i = 0;
    let keys_len = vector::length(keys);
    assert!(keys_len == vector::length(values), E_INVALID_PARAMETER);
    
    while (i < keys_len) {
        let key = vector::borrow(keys, i);
        let value = vector::borrow(values, i);
        dao::update_metadata_entry(dao, *key, *value);
        i = i + 1;
    };

    // Remove keys
    let mut i = 0;
    let remove_len = vector::length(keys_to_remove);
    while (i < remove_len) {
        let key = vector::borrow(keys_to_remove, i);
        dao::remove_metadata_entry(dao, *key);
        i = i + 1;
    };
}

/// Execute queue parameters update
public fun execute_queue_params_update<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
    action: QueueParamsUpdateAction,
    _context: &ProposalExecutionContext,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    let max_proposer_funded_opt = action_registry::get_queue_params_max_proposer_funded(&action);
    let max_concurrent_proposals_opt = action_registry::get_queue_params_max_concurrent_proposals(&action);
    let max_queue_size_opt = action_registry::get_queue_params_max_queue_size(&action);

    // Apply updates
    if (option::is_some(max_proposer_funded_opt)) {
        priority_queue::update_max_proposer_funded(queue, *option::borrow(max_proposer_funded_opt));
    };
    
    if (option::is_some(max_concurrent_proposals_opt)) {
        priority_queue::update_max_concurrent_proposals(queue, *option::borrow(max_concurrent_proposals_opt));
    };
    
    if (option::is_some(max_queue_size_opt)) {
        priority_queue::update_max_queue_size(queue, *option::borrow(max_queue_size_opt));
    };
}

// === Batch Execution Helpers ===

/// Execute multiple configuration updates in a single transaction
public fun execute_batch_config_updates<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    trading_params_actions: vector<TradingParamsUpdateAction>,
    metadata_actions: vector<MetadataUpdateAction>,
    governance_actions: vector<GovernanceUpdateAction>,
    context: &ProposalExecutionContext,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Execute trading params updates
    let mut i = 0;
    while (i < vector::length(&trading_params_actions)) {
        execute_trading_params_update(
            dao, 
            *vector::borrow(&trading_params_actions, i), 
            context, 
            clock, 
            ctx
        );
        i = i + 1;
    };

    // Execute metadata updates
    let mut i = 0;
    while (i < vector::length(&metadata_actions)) {
        execute_metadata_update(
            dao, 
            *vector::borrow(&metadata_actions, i), 
            context, 
            clock, 
            ctx
        );
        i = i + 1;
    };

    // Execute governance updates
    let mut i = 0;
    while (i < vector::length(&governance_actions)) {
        execute_governance_update(
            dao, 
            *vector::borrow(&governance_actions, i), 
            context, 
            clock, 
            ctx
        );
        i = i + 1;
    };
}