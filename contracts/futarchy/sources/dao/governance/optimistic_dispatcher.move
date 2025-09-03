/// Dispatcher for optimistic intent actions
module futarchy::optimistic_dispatcher;

// === Imports ===
use sui::{
    clock::Clock,
    tx_context::TxContext,
};
use account_protocol::{
    account::Account,
    executable::{Self, Executable},
};
use futarchy::{
    futarchy_config::FutarchyConfig,
    version,
    optimistic_intents,
};

// === Public(friend) Functions ===

/// Try to execute optimistic intent actions
public(package) fun try_execute_optimistic_action<IW: drop, Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    // Check for create optimistic intent action
    if (executable::contains_action<Outcome, optimistic_intents::CreateOptimisticIntentAction>(executable)) {
        optimistic_intents::do_create_optimistic_intent<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    // Check for challenge optimistic intents action (cancels them)
    if (executable::contains_action<Outcome, optimistic_intents::ChallengeOptimisticIntentsAction>(executable)) {
        optimistic_intents::do_challenge_optimistic_intents<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    // Check for cancel optimistic intent action
    if (executable::contains_action<Outcome, optimistic_intents::CancelOptimisticIntentAction>(executable)) {
        optimistic_intents::do_cancel_optimistic_intent<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    // Check for execute optimistic intent action
    if (executable::contains_action<Outcome, optimistic_intents::ExecuteOptimisticIntentAction>(executable)) {
        let intent_key = optimistic_intents::do_execute_optimistic_intent<Outcome, IW>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        
        // Execute the intent from the Account Protocol
        // The security council account should have this intent stored
        // We use the intent_key to identify which intent to execute
        // Note: The actual execution happens through the Account Protocol's intent system
        // The optimistic intent just acts as a time-locked wrapper around the real intent
        
        // For now, we mark it as executed in our tracking but the actual execution
        // would need to be done through the appropriate Account Protocol functions
        // based on the intent_key. This would typically be done by calling
        // account::execute_intent_by_key or similar, which would need to be
        // implemented in the Account Protocol integration.
        let _ = intent_key;
        
        return true
    };
    
    // Check for cleanup expired intents action
    if (executable::contains_action<Outcome, optimistic_intents::CleanupExpiredIntentsAction>(executable)) {
        optimistic_intents::do_cleanup_expired_intents<Outcome, IW>(
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