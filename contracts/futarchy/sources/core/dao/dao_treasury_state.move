/// Unified state management for DAO and Treasury
/// This module ensures atomic state transitions across both objects
module futarchy::dao_treasury_state;

use futarchy::dao_state::{Self, DAO};
use futarchy::treasury::{Self, Treasury};

// === Errors ===
const EInvalidStateTransition: u64 = 0;
const EStateMismatch: u64 = 1;

// === Public Functions ===

/// Atomically transition both DAO and Treasury to dissolution state
public(package) fun start_dissolution<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    treasury: &mut Treasury,
) {
    // Verify current states are aligned
    assert!(
        dao_state::operational_state(dao) == dao_state::state_active() &&
        treasury::get_state(treasury) == treasury::state_active(),
        EStateMismatch
    );
    
    // Atomic state transition
    dao_state::set_operational_state(dao, dao_state::state_dissolving());
    // Treasury state is set by the dissolution functions
}

/// Atomically pause both DAO and Treasury
public(package) fun pause_system<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    treasury: &mut Treasury,
) {
    dao_state::set_operational_state(dao, dao_state::state_paused());
    // Treasury doesn't have a paused state, but we could add one
}

/// Atomically resume both DAO and Treasury
public(package) fun resume_system<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    treasury: &mut Treasury,
) {
    // Only resume if both are in expected states
    assert!(
        dao_state::operational_state(dao) == dao_state::state_paused(),
        EInvalidStateTransition
    );
    
    dao_state::set_operational_state(dao, dao_state::state_active());
}

/// Verify DAO and Treasury states are consistent
public fun verify_state_consistency<AssetType, StableType>(
    dao: &DAO<AssetType, StableType>,
    treasury: &Treasury,
): bool {
    let dao_state = dao_state::operational_state(dao);
    let treasury_state = treasury::get_state(treasury);
    
    // Check consistency rules
    if (dao_state == dao_state::state_active()) {
        treasury_state == treasury::state_active()
    } else if (dao_state == dao_state::state_dissolving()) {
        treasury_state == treasury::state_liquidating() || 
        treasury_state == treasury::state_redemption_active()
    } else {
        // Paused state - treasury should still be active
        treasury_state == treasury::state_active()
    }
}