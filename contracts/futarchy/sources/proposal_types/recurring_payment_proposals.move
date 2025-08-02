/// Proposal creation module for initiating recurring payment streams from a DAO's treasury.
module futarchy::recurring_payment_proposals;

// === Imports ===
use std::string::String;
use sui::{
    coin::Coin,
    clock::Clock,
    sui::SUI,
};
use futarchy::{
    dao::{Self},
    dao_state::{Self, DAO},
    fee,
    treasury_actions::{Self, ActionRegistry},
};

// === Errors ===
const EInvalidParameters: u64 = 0;
const EInvalidPaymentInterval: u64 = 1;
const EInvalidStartTimestamp: u64 = 2;
const EInvalidTotalPayments: u64 = 3;
const EPaymentAmountTooLarge: u64 = 4;
const EArrayIndexOutOfBounds: u64 = 5;

// === Constants ===
const MIN_PAYMENT_INTERVAL_MS: u64 = 86400000; // 1 day minimum
const MAX_PAYMENT_INTERVAL_MS: u64 = 365 * 86400000; // 1 year maximum
const MAX_TOTAL_PAYMENTS: u64 = 1000; // Maximum number of payments in a stream


// === Public Functions ===

/// Creates a multi-outcome proposal where each outcome can optionally create a unique recurring payment stream.
/// This allows for complex proposals such as comparing different grant options.
///
/// # Convention for No-Op Outcomes
/// To specify that an outcome should NOT create a payment stream (e.g., for a "Reject" option),
/// set the `amount_per_payment` for that outcome's index to `0`. All other parameters for that
/// index will be ignored, and a no-op action will be registered instead.
///
/// # Note on Limits
/// This function will fail if the target DAO already has the maximum number
/// of active payment streams (currently 100), as enforced by the
/// `PaymentStreamRegistry`.
///
/// # Arguments
/// * `dao`, `fee_manager`, etc. - Standard proposal creation arguments.
/// * `outcome_messages`, `outcome_descriptions` - Vectors defining the text for each proposal choice.
/// * `initial_outcome_amounts` - Liquidity amounts for the futarchy market.
/// * `recipients` - Vector of recipient addresses, one for each potential payment stream.
/// * `amounts_per_payment` - Vector of amounts for each payment, one for each potential stream. **Use 0 for no-op.**
/// * `payment_intervals_ms` - Vector of payment intervals in milliseconds.
/// * `total_payments_list` - Vector of the total number of payments for each stream.
/// * `start_timestamps` - Vector of start times (unix ms) for each stream.
/// * `stream_descriptions` - Vector of descriptions for each created payment stream.
public entry fun create_recurring_payment_proposal<AssetType, StableType, CoinType: drop>(
    dao: &mut DAO<AssetType, StableType>,
    fee_manager: &mut fee::FeeManager,
    registry: &mut ActionRegistry,
    payment: Coin<SUI>,
    dao_fee_payment: Coin<StableType>,
    title: String,
    metadata: String, 
    outcome_messages: vector<String>,
    outcome_descriptions: vector<String>,
    initial_outcome_amounts: vector<u64>,
    // --- Vectors for Payment Stream Parameters (must all have same length as outcomes) ---
    recipients: vector<address>,
    amounts_per_payment: vector<u64>,
    payment_intervals_ms: vector<u64>,
    total_payments_list: vector<u64>,
    start_timestamps: vector<u64>,
    stream_descriptions: vector<String>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // 1. Validate that all input vectors have a matching length for each outcome.
    let outcome_count = outcome_messages.length();
    assert!(outcome_descriptions.length() == outcome_count, EInvalidParameters);
    assert!(recipients.length() == outcome_count, EInvalidParameters);
    assert!(amounts_per_payment.length() == outcome_count, EInvalidParameters);
    assert!(payment_intervals_ms.length() == outcome_count, EInvalidParameters);
    assert!(total_payments_list.length() == outcome_count, EInvalidParameters);
    assert!(start_timestamps.length() == outcome_count, EInvalidParameters);
    assert!(stream_descriptions.length() == outcome_count, EInvalidParameters);
    assert!(initial_outcome_amounts.length() == outcome_count * 2, EInvalidParameters);
    
    // 2. Split initial_outcome_amounts into asset and stable vectors
    let mut asset_amounts = vector[];
    let mut stable_amounts = vector[];
    let mut i = 0;
    while (i < outcome_count) {
        let asset_idx = i * 2;
        let stable_idx = i * 2 + 1;
        // Ensure indices are within bounds
        assert!(stable_idx < initial_outcome_amounts.length(), EArrayIndexOutOfBounds);
        vector::push_back(&mut asset_amounts, initial_outcome_amounts[asset_idx]);
        vector::push_back(&mut stable_amounts, initial_outcome_amounts[stable_idx]);
        i = i + 1;
    };

    // 3. Create the base futarchy proposal
    let (proposal_id, _, _) = dao::create_proposal_internal<AssetType, StableType>(
        dao,
        fee_manager,
        payment,
        dao_fee_payment,
        title,
        metadata, 
        outcome_messages,
        outcome_descriptions,
        asset_amounts,
        stable_amounts,
        false, // uses_dao_liquidity
        clock,
        ctx
    );

    // 4. Initialize and register actions for each outcome
    treasury_actions::init_proposal_actions(registry, proposal_id, outcome_count, ctx);
    i = 0;
    let current_time = clock.timestamp_ms();
    while (i < outcome_count) {
        if (amounts_per_payment[i] > 0) {
            // Validate payment parameters
            let payment_interval = payment_intervals_ms[i];
            let total_payments = total_payments_list[i];
            let start_timestamp = start_timestamps[i];
            let amount_per_payment = amounts_per_payment[i];
            
            // Validate payment interval
            assert!(payment_interval >= MIN_PAYMENT_INTERVAL_MS, EInvalidPaymentInterval);
            assert!(payment_interval <= MAX_PAYMENT_INTERVAL_MS, EInvalidPaymentInterval);
            
            // Validate total payments
            assert!(total_payments > 0 && total_payments <= MAX_TOTAL_PAYMENTS, EInvalidTotalPayments);
            
            // Validate start timestamp (must be in the future)
            assert!(start_timestamp > current_time, EInvalidStartTimestamp);
            
            // Validate total commitment doesn't overflow
            let total_commitment = amount_per_payment * total_payments;
            assert!(total_commitment / total_payments == amount_per_payment, EPaymentAmountTooLarge);
            
            // This outcome creates a payment stream.
            treasury_actions::add_recurring_payment_action<CoinType>(
                registry, proposal_id, i, recipients[i], amount_per_payment,
                payment_interval, total_payments, start_timestamp,
                stream_descriptions[i], ctx
            );
        } else {
            // This is a no-op outcome (e.g., "Reject").
            treasury_actions::add_no_op_action(registry, proposal_id, i, ctx);
        };
        i = i + 1;
    };
}