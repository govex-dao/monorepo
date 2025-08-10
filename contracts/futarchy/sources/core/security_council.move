module futarchy::security_council;

// === Imports ===

use std::string::String;
use sui::clock::Clock;
use sui::tx_context::TxContext;

use account_extensions::extensions::Extensions;

use account_protocol::{
    account::{Self, Account, Auth},
    deps,
    executable::Executable,
};

use futarchy::{
    version,                                // VersionWitness for this package
    weighted_multisig::{Self, WeightedMultisig, Approvals},
};

// === Witness ===

/// Unique witness for this config module
public struct Witness has drop {}

public fun witness(): Witness {
    Witness {}
}

// === Security Council factory and governance helpers ===

/// Create a new Weighted Security Council account with the given members/weights/threshold.
/// Includes AccountProtocol, Futarchy, and AccountActions in Deps.
public fun new(
    extensions: &Extensions,
    members: vector<address>,
    weights: vector<u64>,
    threshold: u64,
    ctx: &mut TxContext,
): Account<WeightedMultisig> {
    // build multisig config
    let config = weighted_multisig::new(members, weights, threshold);

    account_protocol::account_interface::create_account!(
        config,
        version::current(),  // VersionWitness for 'futarchy'
        Witness{},           // config witness (this module)
        ctx,
        || deps::new_latest_extensions(
            extensions,
            vector[
                b"AccountProtocol".to_string(),
                b"Futarchy".to_string(),
                b"AccountActions".to_string(),
            ]
        )
    )
}

/// Authenticate a sender as a council member. Returns an Auth usable for gated calls.
public fun authenticate(
    account: &Account<WeightedMultisig>,
    ctx: &TxContext
): Auth {
    account_protocol::account_interface::create_auth!(
        account,
        version::current(),
        Witness{},
        || weighted_multisig::assert_is_member(account.config(), ctx.sender())
    )
}

/// A council member approves a pending intent by adding their approval weight.
/// Avoid borrowing account.config() inside the closure to prevent borrow conflicts.
public fun approve_intent(
    account: &mut Account<WeightedMultisig>,
    key: String,
    ctx: &mut TxContext,
) {
    // Verify membership before the macro (this borrow ends at return)
    weighted_multisig::assert_is_member(account.config(), ctx.sender());

    account_protocol::account_interface::resolve_intent!(
        account,
        key,
        version::current(),
        Witness{},
        |outcome_mut: &mut Approvals| {
            // Insert approver without borrowing config in this closure
            weighted_multisig::approve_sender_unchecked(outcome_mut, ctx.sender());
        }
    );
}

/// Execute an already-approved intent, returning the Executable hot-potato.
public fun execute_intent(
    account: &mut Account<WeightedMultisig>,
    key: String,
    clock: &Clock,
): Executable<Approvals> {
    account_protocol::account_interface::execute_intent!(
        account,
        key,
        clock,
        version::current(),
        Witness{},
        |outcome: Approvals| {
            // final check before allowing execution
            weighted_multisig::validate_outcome(outcome, account.config(), b"".to_string());
        }
    )
}