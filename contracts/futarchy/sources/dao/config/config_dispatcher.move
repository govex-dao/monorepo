/// Dispatcher for configuration-related actions
module futarchy::config_dispatcher;

// === Imports ===
use sui::clock::Clock;
use account_protocol::{
    account::Account,
    executable::{Self, Executable},
};
use futarchy::{
    futarchy_config::FutarchyConfig,
    config_actions,
    version,
};

// === Public Functions ===

/// Try to execute configuration actions
public(package) fun try_execute_config_action<IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    // Check for basic config actions
    if (executable::contains_action<Outcome, config_actions::SetProposalsEnabledAction>(executable)) {
        config_actions::do_set_proposals_enabled<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, config_actions::UpdateNameAction>(executable)) {
        config_actions::do_update_name<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    // Check for advanced config actions
    if (executable::contains_action<Outcome, config_actions::TradingParamsUpdateAction>(executable)) {
        config_actions::do_update_trading_params<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, config_actions::MetadataUpdateAction>(executable)) {
        config_actions::do_update_metadata<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, config_actions::TwapConfigUpdateAction>(executable)) {
        config_actions::do_update_twap_config<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, config_actions::GovernanceUpdateAction>(executable)) {
        config_actions::do_update_governance<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, config_actions::MetadataTableUpdateAction>(executable)) {
        config_actions::do_update_metadata_table<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, config_actions::QueueParamsUpdateAction>(executable)) {
        config_actions::do_update_queue_params<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (executable::contains_action<Outcome, config_actions::SlashDistributionUpdateAction>(executable)) {
        config_actions::do_update_slash_distribution<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    // Try to execute ConfigAction (batch wrapper)
    if (executable::contains_action<Outcome, config_actions::ConfigAction>(executable)) {
        config_actions::do_batch_config<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    false
}