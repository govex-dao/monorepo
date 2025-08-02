/// Treasury initialization module
/// Allows DAOs to add treasury functionality after creation
#[test_only]
module futarchy::treasury_initialization;

// === Imports ===
use futarchy::{
    dao,
    dao_state::{DAO},
    treasury,
};
use sui::object;

// === Errors ===
const ETreasuryAlreadyInitialized: u64 = 0;
const EUnauthorized: u64 = 1;

// === Public Functions ===

/// Initialize treasury for a DAO
/// This can be called after DAO creation to add treasury functionality
/// NOTE: This function is deprecated as treasury is now initialized during DAO creation
#[test_only]
public entry fun initialize_treasury<AssetType, StableType>(
    _dao: &mut DAO<AssetType, StableType>,
    _admin: address,
    _ctx: &mut TxContext,
) {
    // This function is deprecated - treasury is now initialized during DAO creation
    abort ETreasuryAlreadyInitialized
}

/// Initialize treasury with the sender as admin
/// NOTE: This function is deprecated as treasury is now initialized during DAO creation
#[test_only]
public entry fun initialize_treasury_self<AssetType, StableType>(
    dao: &mut DAO<AssetType, StableType>,
    ctx: &mut TxContext,
) {
    initialize_treasury(dao, ctx.sender(), ctx);
}