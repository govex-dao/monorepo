/// Treasury initialization module
/// Allows DAOs to add treasury functionality after creation
#[test_only]
module futarchy::treasury_initialization;

// === Imports ===
use futarchy::{
    dao::{Self, DAO},
    treasury,
};

// === Errors ===
const ETreasuryAlreadyInitialized: u64 = 0;
const EUnauthorized: u64 = 1;

// === Public Functions ===

/// Initialize treasury for a DAO
/// This can be called after DAO creation to add treasury functionality
#[test_only]
public entry fun initialize_treasury(
    dao: &mut DAO,
    admin: address,
    ctx: &mut TxContext,
) {
    // Check that treasury isn't already initialized
    assert!(!dao.has_treasury(), ETreasuryAlreadyInitialized);
    
    // Initialize the treasury
    let treasury_id = treasury::initialize(
        object::id(dao),
        admin,
        ctx
    );
    
    // Set the treasury ID in the DAO
    dao::set_treasury_id(dao, treasury_id);
}

/// Initialize treasury with the sender as admin
#[test_only]
public entry fun initialize_treasury_self(
    dao: &mut DAO,
    ctx: &mut TxContext,
) {
    initialize_treasury(dao, ctx.sender(), ctx);
}