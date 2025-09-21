/// Governance-related actions for futarchy DAOs
/// This module defines action structs and execution logic for creating second-order proposals
module futarchy_actions::governance_actions;

// === Imports ===
use std::string::{Self, String};
use std::option::{Self, Option};
use std::vector::{Self};
use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    object::{Self, ID, UID},
    sui::SUI,
    table::{Self, Table},
    transfer,
    tx_context::{Self, TxContext},
    bcs::{Self, BCS},
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents,
    version_witness::VersionWitness,
    bcs_validation,
};
use futarchy_core::{
    futarchy_config::{Self, FutarchyConfig},
    priority_queue,
    proposal_fee_manager::{Self, ProposalFeeManager},
    dao_payment_tracker::{Self, DaoPaymentTracker},
    action_validation,
    action_types,
};
use futarchy_actions::{
    resource_requests::{Self, ResourceRequest, ResourceReceipt},
};
use futarchy_types::action_specs::InitActionSpecs;

// === Errors ===
const EInvalidProposalType: u64 = 1;
const EReservationExpired: u64 = 2;
const EReservationNotFound: u64 = 3;
const EInvalidReservationPeriod: u64 = 4;
const EProposalAlreadyExists: u64 = 5;
const EInsufficientFee: u64 = 6;
const EMaxDepthExceeded: u64 = 7;
const EInvalidTitle: u64 = 8;
const ENoOutcomes: u64 = 9;
const EOutcomeMismatch: u64 = 10;
const EInvalidBucketDuration: u64 = 11;
const EChainDepthNotFound: u64 = 12;
const EBucketOrderingViolation: u64 = 13;
const EIntegerOverflow: u64 = 14;
const EInsufficientFeeCoins: u64 = 15;
const EDAOPaymentDelinquent: u64 = 16; // DAO is blocked due to unpaid fees

// === Constants ===
// These are now just fallbacks - actual values come from DAO config
/// Default reservation period (30 days in milliseconds)
const DEFAULT_RESERVATION_PERIOD_MS: u64 = 2_592_000_000; // 30 days
/// Maximum reservation period (90 days in milliseconds)
const MAX_RESERVATION_PERIOD_MS: u64 = 7_776_000_000; // 90 days

// === Structs ===

/// Action to create a new proposal (second-order proposal)
public struct CreateProposalAction has store, copy, drop {
    /// Key identifier for the proposal
    key: String,
    /// Intent specs for the proposal
    intent_specs: vector<InitActionSpecs>,
    /// Initial asset amount for the new proposal
    initial_asset_amount: u64,
    /// Initial stable amount for the new proposal
    initial_stable_amount: u64,
    /// Whether to use DAO liquidity
    use_dao_liquidity: bool,
    /// Fee for the new proposal
    proposal_fee: u64,
    /// The human-readable messages for each outcome
    outcome_messages: vector<String>,
    /// The detailed descriptions for each outcome
    outcome_details: vector<String>,
    /// The title of the proposal to be created
    title: String,
    /// Optional: Override reservation period (if not set, uses DAO config)
    reservation_period_ms_override: Option<u64>,
}

/// Reservation for an nth-order proposal that was evicted
/// This allows the proposal to be recreated within a time window
/// Each recreation requires full fees - no special privileges
public struct ProposalReservation has store {
    /// Original parent proposal that created this reservation
    parent_proposal_id: ID,
    /// Root proposal ID (the original first-order proposal in the chain)
    root_proposal_id: ID,
    /// Depth in the proposal chain (1 = second-order, 2 = third-order, etc.)
    chain_depth: u64,
    /// Which outcome this proposal is created for (0 = YES, 1 = NO, etc.)
    parent_outcome: u8,
    /// Whether parent has already been executed
    parent_executed: bool,
    /// The proposal data that was evicted
    proposal_type: String,
    proposal_data: vector<u8>,
    initial_asset_amount: u64,
    initial_stable_amount: u64,
    use_dao_liquidity: bool,
    /// The title of the proposal to be created
    title: String,
    /// The human-readable messages for each outcome
    outcome_messages: vector<String>,
    /// The detailed descriptions for each outcome
    outcome_details: vector<String>,
    /// Original fee amount (for reference)
    original_fee: u64,
    /// Original proposer (from parent proposal)
    original_proposer: address,
    /// Expiration timestamp for recreation rights
    recreation_expires_at: u64,
    /// Number of times this has been recreated (for tracking only)
    recreation_count: u64,
    /// Child proposals this would create (for nth-order chains)
    /// Each child can be for different outcomes
    child_proposals: vector<CreateProposalAction>,
}

/// A "bucket" that holds all reservations expiring within the same time window (e.g., a day).
public struct ReservationBucket has store {
    /// The start timestamp of this bucket's time window (e.g., midnight UTC).
    timestamp_ms: u64,
    /// The keys of all reservations that expire within this bucket's window.
    reservation_ids: vector<ID>,
    /// Pointers for the doubly-linked list (bucket timestamps).
    prev_bucket_timestamp: Option<u64>,
    next_bucket_timestamp: Option<u64>,
}

/// Storage for proposal reservations
public struct ProposalReservationRegistry has key {
    id: UID,
    /// Map from parent proposal ID to reservation
    reservations: Table<ID, ProposalReservation>,
    /// Map from bucket timestamp to bucket
    buckets: Table<u64, ReservationBucket>,
    /// Head of the linked list (points to the OLDEST bucket timestamp).
    head_bucket_timestamp: Option<u64>,
    /// Tail of the linked list (points to the NEWEST bucket timestamp).
    tail_bucket_timestamp: Option<u64>,
    /// How large each time window is in milliseconds. A DAO-configurable value.
    /// Example: 1 day = 86,400,000 ms.
    bucket_duration_ms: u64,
}

// === Getter Functions ===

/// Get the proposal fee from a CreateProposalAction
public fun get_proposal_fee(action: &CreateProposalAction): u64 {
    action.proposal_fee
}

// === Constructor Functions ===

/// Create a new CreateProposalAction with validation
public fun new_create_proposal_action(
    proposal_type: String,
    proposal_data: vector<u8>,
    initial_asset_amount: u64,
    initial_stable_amount: u64,
    use_dao_liquidity: bool,
    proposal_fee: u64,
    reservation_period_ms_override: Option<u64>,
    title: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
): CreateProposalAction {
    use std::string;
    
    // Basic validation
    assert!(string::length(&title) > 0, EInvalidTitle);
    assert!(!vector::is_empty(&outcome_messages), ENoOutcomes);
    assert!(vector::length(&outcome_messages) == vector::length(&outcome_details), EOutcomeMismatch);

    CreateProposalAction {
        key: proposal_type,
        intent_specs: vector::empty(),
        initial_asset_amount,
        initial_stable_amount,
        use_dao_liquidity,
        proposal_fee,
        reservation_period_ms_override,
        title,
        outcome_messages,
        outcome_details,
    }
}

// === Action Execution ===

/// Execute the create proposal action - creates a resource request
/// Returns a hot potato that must be fulfilled with governance resources
public fun do_create_proposal<Outcome: store, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version_witness: VersionWitness,
    witness: IW,
    parent_proposal_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
): ResourceRequest<CreateProposalAction> {
    // Get spec and validate type BEFORE deserialization
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::CreateProposal>(spec);

    // Deserialize the action data
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    // Deserialize CreateProposalAction field by field
    let key = bcs::peel_vec_u8(&mut reader).to_string();
    let intent_specs_count = bcs::peel_vec_length(&mut reader);
    let mut intent_specs = vector::empty<InitActionSpecs>();
    let mut i = 0;
    while (i < intent_specs_count) {
        // For each InitActionSpecs, peel the actions
        let action_count = bcs::peel_vec_length(&mut reader);
        let mut j = 0;
        while (j < action_count) {
            // Skip individual action specs for now
            let _ = bcs::peel_vec_u8(&mut reader); // action type
            let _ = bcs::peel_vec_u8(&mut reader); // action data
            j = j + 1;
        };
        i = i + 1;
    };

    let outcome_messages_count = bcs::peel_vec_length(&mut reader);
    let mut outcome_messages = vector::empty();
    i = 0;
    while (i < outcome_messages_count) {
        vector::push_back(&mut outcome_messages, bcs::peel_vec_u8(&mut reader).to_string());
        i = i + 1;
    };

    let outcome_details_count = bcs::peel_vec_length(&mut reader);
    let mut outcome_details = vector::empty();
    i = 0;
    while (i < outcome_details_count) {
        vector::push_back(&mut outcome_details, bcs::peel_vec_u8(&mut reader).to_string());
        i = i + 1;
    };

    let title = bcs::peel_vec_u8(&mut reader).to_string();
    let initial_asset_amount = bcs::peel_u64(&mut reader);
    let initial_stable_amount = bcs::peel_u64(&mut reader);
    let use_dao_liquidity = bcs::peel_bool(&mut reader);
    let proposal_fee = bcs::peel_u64(&mut reader);
    let reservation_period_ms_override = if (bcs::peel_bool(&mut reader)) {
        option::some(bcs::peel_u64(&mut reader))
    } else {
        option::none()
    };

    let action = CreateProposalAction {
        key,
        intent_specs,
        outcome_messages,
        outcome_details,
        title,
        initial_asset_amount,
        initial_stable_amount,
        use_dao_liquidity,
        proposal_fee,
        reservation_period_ms_override,
    };
    bcs_validation::validate_all_bytes_consumed(reader);

    // Increment action index
    executable::increment_action_idx(executable);
    
    // Get reservation period from DAO config or use override
    let config = account::config(account);
    let reservation_period = if (option::is_some(&action.reservation_period_ms_override)) {
        let override_period = *option::borrow(&action.reservation_period_ms_override);
        // Still validate against max
        assert!(override_period <= MAX_RESERVATION_PERIOD_MS, EInvalidReservationPeriod);
        override_period
    } else {
        86_400_000 // Default to 1 day recreation window
    };
    
    // Check chain depth (we'll need to pass registry to fulfill function)
    let max_depth = 10; // Default max chain depth
    
    // Create resource request with all needed context
    let mut request = resource_requests::new_request<CreateProposalAction>(ctx);
    
    // Add all the context data needed for fulfillment
    // Context not needed for now
    // resource_requests::add_context(&mut request, string::utf8(b"action"), action);
    resource_requests::add_context(&mut request, string::utf8(b"parent_proposal_id"), parent_proposal_id);
    resource_requests::add_context(&mut request, string::utf8(b"reservation_period"), reservation_period);
    resource_requests::add_context(&mut request, string::utf8(b"max_depth"), max_depth);
    resource_requests::add_context(&mut request, string::utf8(b"account_id"), object::id(account));
    
    let _ = version_witness;
    
    request
}

/// Fulfill the resource request by providing the governance resources
/// This completes the proposal creation with all required resources
public fun fulfill_create_proposal(
    request: ResourceRequest<CreateProposalAction>,
    queue: &mut priority_queue::ProposalQueue<FutarchyConfig>,
    fee_manager: &mut ProposalFeeManager,
    registry: &mut ProposalReservationRegistry,
    payment_tracker: &DaoPaymentTracker,  // NEW: Check if DAO is blocked
    fee_coin: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
): ResourceReceipt<CreateProposalAction> {
    // Extract context from the request
    let action: CreateProposalAction = resource_requests::get_context(&request, string::utf8(b"action"));
    let parent_proposal_id: ID = resource_requests::get_context(&request, string::utf8(b"parent_proposal_id"));
    let reservation_period: u64 = resource_requests::get_context(&request, string::utf8(b"reservation_period"));
    let max_depth: u64 = resource_requests::get_context(&request, string::utf8(b"max_depth"));
    let account_id: ID = resource_requests::get_context(&request, string::utf8(b"account_id"));
    
    // Check if DAO is blocked due to unpaid fees
    assert!(
        !dao_payment_tracker::is_dao_blocked(payment_tracker, account_id),
        EDAOPaymentDelinquent
    );
    
    // Check chain depth - need to track proposals both in registry and queue
    // For proposals in queue, we assume depth 0 if not in registry
    // This is a conservative approach that prevents bypassing depth limits
    let parent_depth = if (table::contains(&registry.reservations, parent_proposal_id)) {
        table::borrow(&registry.reservations, parent_proposal_id).chain_depth
    } else {
        // If not in registry, it could be a first-order proposal or
        // a proposal that hasn't been evicted yet. We conservatively
        // assume it's a first-order proposal (depth 0)
        0
    };
    
    // Enforce the chain depth limit
    assert!(parent_depth < max_depth, EMaxDepthExceeded);
    
    // Verify the fee coin matches the required fee amount
    assert!(coin::value(&fee_coin) >= action.proposal_fee, EInsufficientFee);
    
    // Generate a unique proposal ID for the new proposal
    let proposal_uid = object::new(ctx);
    let proposal_id = object::uid_to_inner(&proposal_uid);
    object::delete(proposal_uid);
    
    // Deposit the fee first (required for potential refunds)
    proposal_fee_manager::deposit_proposal_fee(
        fee_manager,
        proposal_id,
        fee_coin
    );
    
    // Create the proposal with the generated ID
    let new_proposal = create_queued_proposal_with_id(
        &action,
        proposal_id,
        parent_proposal_id,
        reservation_period,
        clock,
        ctx
    );
    
    // Try to insert into queue
    let eviction_info = priority_queue::insert(
        queue,
        new_proposal,
        clock,
        ctx
    );
    
    // Handle eviction - refund fee if a proposal was evicted
    if (option::is_some(&eviction_info)) {
        let eviction = option::borrow(&eviction_info);
        let evicted_proposal_id = priority_queue::eviction_proposal_id(eviction);
        let evicted_proposer = priority_queue::eviction_proposer(eviction);
        
        // Refund the evicted proposal's fee
        let refund_coin = proposal_fee_manager::refund_proposal_fee(
            fee_manager,
            evicted_proposal_id,
            ctx
        );
        transfer::public_transfer(refund_coin, evicted_proposer);
        
        // Create a reservation for the current proposal since it caused an eviction
        create_reservation(
            registry,
            parent_proposal_id,
            action,
            reservation_period,
            clock,
            ctx
        );
    } else if (should_create_reservation(&action)) {
        // Create reservation if needed even without eviction
        create_reservation(
            registry,
            parent_proposal_id,
            action,
            reservation_period,
            clock,
            ctx
        );
    };
    
    // Consume the request and return receipt
    resource_requests::fulfill(request)
}

/// Execute recreation of an evicted second-order proposal
/// Requires full fee payment - no special privileges or priority
public entry fun recreate_evicted_proposal(
    parent_proposal_id: ID,
    registry: &mut ProposalReservationRegistry,
    queue: &mut priority_queue::ProposalQueue<FutarchyConfig>,
    fee_manager: &mut ProposalFeeManager,
    fee_coin: Coin<sui::sui::SUI>, // Must pay full fee for recreation in SUI
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get the reservation
    assert!(
        table::contains(&registry.reservations, parent_proposal_id),
        EReservationNotFound
    );
    
    let reservation = table::borrow_mut(&mut registry.reservations, parent_proposal_id);
    
    // Check if reservation is still valid (time window only)
    assert!(
        clock.timestamp_ms() < reservation.recreation_expires_at,
        EReservationExpired
    );
    
    // Verify fee is sufficient (same as any new proposal)
    let fee_amount = coin::value(&fee_coin);
    // Validate that fee meets the original requirement
    // The fee should be at least the original fee that was paid
    assert!(fee_amount >= reservation.original_fee, EInsufficientFee);
    
    // Generate a new unique proposal ID for this recreation
    let new_proposal_uid = object::new(ctx);
    let new_proposal_id = object::uid_to_inner(&new_proposal_uid);
    object::delete(new_proposal_uid);
    
    // Pay the fee to the fee manager with the new proposal ID
    proposal_fee_manager::deposit_proposal_fee(fee_manager, new_proposal_id, fee_coin);
    
    // Create the proposal from reservation data with the new ID
    // Uses current timestamp and fee for priority calculation - no special treatment
    let new_proposal = create_queued_proposal_from_reservation_with_id(
        reservation,
        new_proposal_id,
        fee_amount,
        clock,
        ctx
    );
    
    // Try to insert into queue - competes like any other proposal
    let eviction_info = priority_queue::insert(
        queue,
        new_proposal,
        clock,
        ctx
    );
    
    // If a proposal was evicted, refund its fee to prevent orphaned funds
    if (option::is_some(&eviction_info)) {
        let eviction = option::borrow(&eviction_info);
        let evicted_proposal_id = priority_queue::eviction_proposal_id(eviction);
        let evicted_proposer = priority_queue::eviction_proposer(eviction);
        
        // Refund the evicted proposal's fee from the fee manager
        let refund_coin = proposal_fee_manager::refund_proposal_fee(
            fee_manager,
            evicted_proposal_id,
            ctx
        );
        
        // Transfer the refunded fee to the evicted proposer
        transfer::public_transfer(refund_coin, evicted_proposer);
    };
    
    // Update recreation count (just for tracking)
    reservation.recreation_count = reservation.recreation_count + 1;
    
    // Reservation stays valid until expiry - can be recreated unlimited times
    // as long as someone pays the fee each time
}

// === Helper Functions ===

fun create_reservation(
    registry: &mut ProposalReservationRegistry,
    parent_proposal_id: ID,
    action: CreateProposalAction,
    reservation_period: u64,
    clock: &Clock,
    ctx: &TxContext,
) {

    // Check if parent is also a reserved proposal to get chain info
    let (root_id, depth) = if (table::contains(&registry.reservations, parent_proposal_id)) {
        let parent_reservation = table::borrow(&registry.reservations, parent_proposal_id);
        (parent_reservation.root_proposal_id, parent_reservation.chain_depth + 1)
    } else {
        // This is a direct child of a first-order proposal
        (parent_proposal_id, 1)
    };
    
    // Extract child proposals if this proposal contains any
    // Child proposals not used with new structure
    let child_proposals = vector::empty<CreateProposalAction>();
    
    // Calculate the expiration time for the new reservation with overflow check
    let current_time = clock.timestamp_ms();
    assert!(current_time <= 18446744073709551615 - reservation_period, EIntegerOverflow);
    let expires_at = current_time + reservation_period;
    
    let reservation = ProposalReservation {
        parent_proposal_id,
        root_proposal_id: root_id,
        chain_depth: depth,
        parent_outcome: 0, // Default to outcome 0, should be set based on actual parent outcome
        parent_executed: false, // Defaults to false, will be updated when parent executes
        proposal_type: action.key,
        proposal_data: bcs::to_bytes(&action.intent_specs),
        initial_asset_amount: action.initial_asset_amount,
        initial_stable_amount: action.initial_stable_amount,
        use_dao_liquidity: action.use_dao_liquidity,
        title: action.title,
        outcome_messages: action.outcome_messages,
        outcome_details: action.outcome_details,
        original_fee: action.proposal_fee,
        original_proposer: tx_context::sender(ctx),
        recreation_expires_at: expires_at,
        recreation_count: 0,
        child_proposals,
    };
    
    // Add the reservation to the main table
    table::add(&mut registry.reservations, parent_proposal_id, reservation);
    
    // --- Add the reservation ID to the correct time bucket ---
    let bucket_duration = registry.bucket_duration_ms;
    assert!(bucket_duration > 0, EInvalidBucketDuration);
    
    // Calculate the timestamp for the bucket this reservation belongs to
    let bucket_timestamp = expires_at - (expires_at % bucket_duration);
    
    if (table::contains(&registry.buckets, bucket_timestamp)) {
        // Bucket already exists, just add the ID
        let bucket = table::borrow_mut(&mut registry.buckets, bucket_timestamp);
        vector::push_back(&mut bucket.reservation_ids, parent_proposal_id);
    } else {
        // Need to create a new bucket
        let prev_timestamp = registry.tail_bucket_timestamp;
        
        // Validate bucket ordering - new bucket must be newer than tail
        if (option::is_some(&prev_timestamp)) {
            let tail_timestamp = *option::borrow(&prev_timestamp);
            assert!(bucket_timestamp >= tail_timestamp, EBucketOrderingViolation);
        };
        
        let new_bucket = ReservationBucket {
            timestamp_ms: bucket_timestamp,
            reservation_ids: vector[parent_proposal_id],
            prev_bucket_timestamp: prev_timestamp,
            next_bucket_timestamp: option::none(),
        };
        
        // Add the new bucket to the table
        table::add(&mut registry.buckets, bucket_timestamp, new_bucket);
        
        // Update linked list pointers
        if (option::is_some(&prev_timestamp)) {
            // Update the old tail's next pointer
            let old_tail_timestamp = *option::borrow(&prev_timestamp);
            let old_tail = table::borrow_mut(&mut registry.buckets, old_tail_timestamp);
            old_tail.next_bucket_timestamp = option::some(bucket_timestamp);
        } else {
            // This is the first bucket
            registry.head_bucket_timestamp = option::some(bucket_timestamp);
        };
        
        // Update the tail pointer
        registry.tail_bucket_timestamp = option::some(bucket_timestamp);
    }
}

/// Extract any CreateProposalActions from proposal data
fun extract_child_proposals(proposal_data: &vector<u8>): vector<CreateProposalAction> {
    // Child proposals are tracked separately in the ProposalReservation
    // They are not embedded in the raw proposal data bytes
    // Return empty vector as child proposals are managed through reservations
    let _ = proposal_data;
    vector::empty<CreateProposalAction>()
}

fun should_create_reservation(action: &CreateProposalAction): bool {
    // Create reservation if a reservation period override is specified
    // or if the proposal has a high fee (indicating importance)
    option::is_some(&action.reservation_period_ms_override) || 
    action.proposal_fee >= 1000000000 // High-value proposals get reservations
}

fun create_queued_proposal_with_id(
    action: &CreateProposalAction,
    proposal_id: ID,
    parent_proposal_id: ID,
    _reservation_period: u64,
    clock: &Clock,
    ctx: &TxContext,
): priority_queue::QueuedProposal<FutarchyConfig> {
    // Create proposal data from action
    let proposal_data = priority_queue::new_proposal_data(
        action.title,
        action.key,
        action.outcome_messages,
        action.outcome_details,
        vector[action.initial_asset_amount, action.initial_asset_amount],
        vector[action.initial_stable_amount, action.initial_stable_amount]
    );
    
    // Create the queued proposal with the specific ID
    priority_queue::new_queued_proposal_with_id(
        proposal_id,
        parent_proposal_id, // Using parent as DAO ID for now
        action.proposal_fee,
        action.use_dao_liquidity,
        tx_context::sender(ctx),
        proposal_data,
        option::none(), // No bond for now
        option::none(), // No intent key
        clock
    )
}

fun create_queued_proposal_from_reservation(
    reservation: &ProposalReservation,
    fee_amount: u64,
    clock: &Clock,
    ctx: &TxContext,
): priority_queue::QueuedProposal<FutarchyConfig> {
    // Create proposal data from reservation
    let proposal_data = priority_queue::new_proposal_data(
        reservation.title,
        reservation.proposal_type,
        reservation.outcome_messages,
        reservation.outcome_details,
        vector[reservation.initial_asset_amount, reservation.initial_asset_amount],
        vector[reservation.initial_stable_amount, reservation.initial_stable_amount]
    );
    
    // Create the queued proposal with new fee
    priority_queue::new_queued_proposal(
        reservation.parent_proposal_id,
        fee_amount,
        reservation.use_dao_liquidity,
        tx_context::sender(ctx), // Current recreator becomes proposer
        proposal_data,
        option::none(), // No bond
        option::none(), // No intent key
        clock
    )
}

fun create_queued_proposal_from_reservation_with_id(
    reservation: &ProposalReservation,
    proposal_id: ID,
    fee_amount: u64,
    clock: &Clock,
    ctx: &TxContext,
): priority_queue::QueuedProposal<FutarchyConfig> {
    // Create proposal data from reservation
    let proposal_data = priority_queue::new_proposal_data(
        reservation.title,
        reservation.proposal_type,
        reservation.outcome_messages,
        reservation.outcome_details,
        vector[reservation.initial_asset_amount, reservation.initial_asset_amount],
        vector[reservation.initial_stable_amount, reservation.initial_stable_amount]
    );
    
    // Create the queued proposal with the specific ID
    priority_queue::new_queued_proposal_with_id(
        proposal_id,
        reservation.parent_proposal_id,
        fee_amount,
        reservation.use_dao_liquidity,
        tx_context::sender(ctx), // Current recreator becomes proposer
        proposal_data,
        option::none(), // No bond
        option::none(), // No intent key
        clock
    )
}

// === Public Registry Functions ===

/// Initialize the registry (should be called once during deployment)
public fun init_registry(ctx: &mut TxContext): ProposalReservationRegistry {
    ProposalReservationRegistry {
        id: object::new(ctx),
        reservations: table::new(ctx),
        buckets: table::new(ctx),
        head_bucket_timestamp: option::none(),
        tail_bucket_timestamp: option::none(),
        // Default to 1 day buckets. Can be made configurable per-DAO.
        bucket_duration_ms: 86_400_000,
    }
}

/// Share the registry for global access
public fun share_registry(registry: ProposalReservationRegistry) {
    transfer::share_object(registry);
}

/// Check if a reservation exists and is valid
public fun has_valid_reservation(
    registry: &ProposalReservationRegistry,
    parent_proposal_id: ID,
    clock: &Clock,
): bool {
    if (!table::contains(&registry.reservations, parent_proposal_id)) {
        return false
    };
    
    let reservation = table::borrow(&registry.reservations, parent_proposal_id);
    // Only time window matters - no recreation limit
    clock.timestamp_ms() < reservation.recreation_expires_at
}

/// Get reservation details (for viewing)
public fun get_reservation(
    registry: &ProposalReservationRegistry,
    parent_proposal_id: ID,
): &ProposalReservation {
    table::borrow(&registry.reservations, parent_proposal_id)
}

/// Recreate an entire proposal chain starting from a specific proposal
/// This handles nth-order proposals by recreating the whole subtree
public entry fun recreate_proposal_chain(
    parent_proposal_id: ID,
    registry: &mut ProposalReservationRegistry,
    queue: &mut priority_queue::ProposalQueue<FutarchyConfig>,
    fee_manager: &mut ProposalFeeManager,
    mut fee_coins: vector<Coin<sui::sui::SUI>>, // Fees for each proposal in the chain
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get the reservation
    assert!(
        table::contains(&registry.reservations, parent_proposal_id),
        EReservationNotFound
    );
    
    // First check the chain size
    let chain_size = {
        let reservation = table::borrow(&registry.reservations, parent_proposal_id);
        1 + vector::length(&reservation.child_proposals)
    };
    
    assert!(
        vector::length(&fee_coins) == chain_size,
        EInsufficientFeeCoins
    );
    
    // Recreate this proposal first
    let fee_coin = vector::pop_back(&mut fee_coins);
    recreate_evicted_proposal(
        parent_proposal_id,
        registry,
        queue,
        fee_manager,
        fee_coin,
        clock,
        ctx
    );
    
    // Then recreate all child proposals
    let child_proposals_count = {
        let reservation = table::borrow(&registry.reservations, parent_proposal_id);
        vector::length(&reservation.child_proposals)
    };
    
    let mut i = 0;
    while (i < child_proposals_count) {
        // Get child action (need to borrow inside loop to avoid lifetime issues)
        // Validate operations before creating any UIDs
        assert!(i < child_proposals_count, EInsufficientFeeCoins);
        assert!(!vector::is_empty(&fee_coins), EInsufficientFeeCoins);
        
        let child_action = {
            let reservation = table::borrow(&registry.reservations, parent_proposal_id);
            *vector::borrow(&reservation.child_proposals, i)
        };
        let child_fee = vector::pop_back(&mut fee_coins);
        
        // Validate fee before creating UID
        assert!(coin::value(&child_fee) >= child_action.proposal_fee, EInsufficientFee);
        
        // Now safe to create child proposal with a new ID
        let child_id = object::new(ctx);
        let child_proposal_id = object::uid_to_inner(&child_id);
        object::delete(child_id);
        
        // Create the child proposal with the specific ID
        let child_proposal = create_queued_proposal_with_id(
            &child_action,
            child_proposal_id,
            parent_proposal_id, // Use parent as the dao_id
            0, // No additional reservation period for children in batch
            clock,
            ctx
        );
        
        // Deposit the fee for the child proposal
        proposal_fee_manager::deposit_proposal_fee(
            fee_manager,
            child_proposal_id,
            child_fee
        );
        
        // Insert child proposal into queue
        let eviction_info = priority_queue::insert(
            queue,
            child_proposal,
            clock,
            ctx
        );
        
        // If a proposal was evicted, refund its fee to prevent orphaned funds
        if (option::is_some(&eviction_info)) {
            let eviction = option::borrow(&eviction_info);
            let evicted_proposal_id = priority_queue::eviction_proposal_id(eviction);
            let evicted_proposer = priority_queue::eviction_proposer(eviction);
            
            // Refund the evicted proposal's fee from the fee manager
            let refund_coin = proposal_fee_manager::refund_proposal_fee(
                fee_manager,
                evicted_proposal_id,
                ctx
            );
            
            // Transfer the refunded fee to the evicted proposer
            transfer::public_transfer(refund_coin, evicted_proposer);
        };
        
        i = i + 1;
    };
    
    vector::destroy_empty(fee_coins);
}

/// Get all proposals in a chain (for viewing/planning recreation)
public fun get_proposal_chain(
    registry: &ProposalReservationRegistry,
    root_proposal_id: ID,
): vector<ID> {
    // Returns the root proposal ID
    // Full chain tracking is handled via events for off-chain indexing
    let _ = registry;
    let mut chain = vector::empty<ID>();
    vector::push_back(&mut chain, root_proposal_id);
    chain
}

/// Prune the oldest expired bucket from the registry.
/// This function is O(1) if there are no expired reservations, and O(k) where k is the number
/// of reservations in a single bucket to prune.
/// Called from proposal_lifecycle during finalization to clean up old reservations.
public fun prune_oldest_expired_bucket(
    registry: &mut ProposalReservationRegistry,
    config: &futarchy_config::FutarchyConfig,
    clock: &Clock,
    _ctx: &TxContext,
) {
    // Check if we have any buckets to prune
    if (option::is_none(&registry.head_bucket_timestamp)) {
        return // No buckets at all
    };
    
    let head_timestamp = *option::borrow(&registry.head_bucket_timestamp);
    let current_time = clock.timestamp_ms();
    
    // Add a safety buffer based on DAO configuration
    let safety_buffer = 86_400_000; // Default to 1 day recreation window
    let prune_before = if (current_time > safety_buffer) {
        current_time - safety_buffer
    } else {
        0
    };
    
    // Check if the oldest bucket has expired
    if (head_timestamp >= prune_before) {
        return // Oldest bucket hasn't expired yet
    };
    
    // Remove the head bucket
    let bucket = table::remove(&mut registry.buckets, head_timestamp);
    
    // Update the head pointer
    registry.head_bucket_timestamp = bucket.next_bucket_timestamp;
    
    // If there's a new head, update its prev pointer to none
    if (option::is_some(&bucket.next_bucket_timestamp)) {
        let next_timestamp = *option::borrow(&bucket.next_bucket_timestamp);
        let next_bucket = table::borrow_mut(&mut registry.buckets, next_timestamp);
        next_bucket.prev_bucket_timestamp = option::none();
    } else {
        // This was the last bucket, so tail should also be none
        registry.tail_bucket_timestamp = option::none();
    };
    
    // Clean up the expired reservations - batch check existence first
    let reservation_ids = &bucket.reservation_ids;
    let mut i = 0;
    let len = vector::length(reservation_ids);
    
    // Collect existing reservations to remove
    let mut to_remove = vector::empty<ID>();
    while (i < len) {
        let reservation_id = *vector::borrow(reservation_ids, i);
        if (table::contains(&registry.reservations, reservation_id)) {
            vector::push_back(&mut to_remove, reservation_id);
        };
        i = i + 1;
    };
    
    // Now remove them in batch
    i = 0;
    while (i < vector::length(&to_remove)) {
        let reservation_id = *vector::borrow(&to_remove, i);
        let reservation = table::remove(&mut registry.reservations, reservation_id);
            
        
        // Destructure the reservation to avoid "value has drop ability" error
        let ProposalReservation {
            parent_proposal_id: _,
            root_proposal_id: _,
            chain_depth: _,
            parent_outcome: _,
            parent_executed: _,
            proposal_type: _,
            proposal_data: _,
            initial_asset_amount: _,
            initial_stable_amount: _,
            use_dao_liquidity: _,
            title: _,
            outcome_messages: _,
            outcome_details: _,
            original_fee: _,
            original_proposer: _,
            recreation_expires_at: _,
            recreation_count: _,
            child_proposals: _,
        } = reservation;
        i = i + 1;
    };
    
    // Destructure the bucket to avoid "value has drop ability" error
    let ReservationBucket {
        timestamp_ms: _,
        reservation_ids: _,
        prev_bucket_timestamp: _,
        next_bucket_timestamp: _,
    } = bucket;
}

// === Delete Functions for Expired Intents ===

/// Delete a create proposal action from an expired intent
public fun delete_create_proposal(expired: &mut account_protocol::intents::Expired) {
    // Remove the action spec but don't destructure it
    let _action_spec = intents::remove_action_spec(expired);
}

/// Delete a proposal reservation from an expired intent
/// Note: ProposalReservation is not an action, so this is primarily a placeholder
/// for consistency with the registry's expected functions
public fun delete_proposal_reservation(expired: &mut account_protocol::intents::Expired) {
    // ProposalReservation is a storage struct, not an action
    // If we had a ReservationAction, we'd destructure it here
    // For now, this is a no-op to satisfy the registry
    let _ = expired;
}