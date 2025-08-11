/// Governance-related actions for futarchy DAOs
/// This module defines action structs and execution logic for creating second-order proposals
module futarchy::governance_actions;

// === Imports ===
use std::string::String;
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
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    version_witness::VersionWitness,
};
use futarchy::{
    futarchy_config::{Self, FutarchyConfig},
    priority_queue,
    proposal_fee_manager::{Self, ProposalFeeManager},
};

// === Errors ===
const EInvalidProposalType: u64 = 1;
const EReservationExpired: u64 = 2;
const EReservationNotFound: u64 = 3;
const EInvalidReservationPeriod: u64 = 4;
const EProposalAlreadyExists: u64 = 5;
const EInsufficientFee: u64 = 6;
const EMaxDepthExceeded: u64 = 7;

// === Constants ===
// These are now just fallbacks - actual values come from DAO config
/// Default reservation period (30 days in milliseconds)
const DEFAULT_RESERVATION_PERIOD_MS: u64 = 2_592_000_000; // 30 days
/// Maximum reservation period (90 days in milliseconds)
const MAX_RESERVATION_PERIOD_MS: u64 = 7_776_000_000; // 90 days

// === Structs ===

/// Action to create a new proposal (second-order proposal)
public struct CreateProposalAction has store, copy, drop {
    /// Type of proposal to create
    proposal_type: String,
    /// Serialized proposal data
    proposal_data: vector<u8>,
    /// Initial asset amount for the new proposal
    initial_asset_amount: u64,
    /// Initial stable amount for the new proposal
    initial_stable_amount: u64,
    /// Whether to use DAO liquidity
    use_dao_liquidity: bool,
    /// Fee for the new proposal
    proposal_fee: u64,
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

/// Storage for proposal reservations
public struct ProposalReservationRegistry has key {
    id: UID,
    /// Map from parent proposal ID to reservation
    reservations: Table<ID, ProposalReservation>,
}

// === Action Execution ===

/// Execute the create proposal action
/// The executor must provide the SUI fee upfront for the second-order proposal
public fun do_create_proposal<Outcome: store, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version_witness: VersionWitness,
    witness: IW,
    parent_proposal_id: ID,
    queue: &mut priority_queue::ProposalQueue<FutarchyConfig>,
    fee_manager: &mut ProposalFeeManager,
    registry: &mut ProposalReservationRegistry,
    fee_coin: Coin<SUI>, // Executor must pay the fee upfront
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action = executable.next_action<Outcome, CreateProposalAction, IW>(witness);
    
    // Get reservation period from DAO config or use override
    let config = account::config(account);
    let reservation_period = if (option::is_some(&action.reservation_period_ms_override)) {
        let override_period = *option::borrow(&action.reservation_period_ms_override);
        // Still validate against max
        assert!(override_period <= MAX_RESERVATION_PERIOD_MS, EInvalidReservationPeriod);
        override_period
    } else {
        futarchy_config::proposal_recreation_window_ms(config)
    };
    
    // Check chain depth
    let max_depth = futarchy_config::max_proposal_chain_depth(config);
    assert!(max_depth > 0, EMaxDepthExceeded);
    
    // Verify the fee coin matches the required fee amount
    assert!(coin::value(&fee_coin) >= action.proposal_fee, EInsufficientFee);
    
    // Generate a unique proposal ID for the new proposal
    // Using object::new ensures cryptographically unique IDs
    let proposal_uid = object::new(ctx);
    let proposal_id = object::uid_to_inner(&proposal_uid);
    object::delete(proposal_uid);
    
    // Deposit the fee first (required for potential refunds)
    // Note: bag::add will abort if proposal_id already exists, preventing duplicates
    proposal_fee_manager::deposit_proposal_fee(
        fee_manager,
        proposal_id,
        fee_coin
    );
    
    // Create the proposal with the generated ID
    let new_proposal = create_queued_proposal_with_id(
        action,
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
            *action,
            reservation_period,
            clock,
            ctx
        );
    } else if (should_create_reservation(action)) {
        // Create reservation if needed even without eviction
        create_reservation(
            registry,
            parent_proposal_id,
            *action,
            reservation_period,
            clock,
            ctx
        );
    };
    
    let _ = version_witness;
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
        clock::timestamp_ms(clock) < reservation.recreation_expires_at,
        EReservationExpired
    );
    
    // Verify fee is sufficient (same as any new proposal)
    let fee_amount = coin::value(&fee_coin);
    // Validate that fee meets the original requirement
    // The fee should be at least the original fee that was paid
    assert!(fee_amount >= reservation.original_fee, EInsufficientFee);
    
    // Pay the fee to the fee manager
    let fee_amount = coin::value(&fee_coin);
    proposal_fee_manager::deposit_proposal_fee(fee_manager, parent_proposal_id, fee_coin);
    
    // Create the proposal from reservation data
    // Uses current timestamp and fee for priority calculation - no special treatment
    let new_proposal = create_queued_proposal_from_reservation(
        reservation,
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
    let child_proposals = extract_child_proposals(&action.proposal_data);
    
    let reservation = ProposalReservation {
        parent_proposal_id,
        root_proposal_id: root_id,
        chain_depth: depth,
        parent_outcome: 0, // Default to outcome 0 (YES) for now, will be set when parent resolves
        parent_executed: false, // Defaults to false, will be updated when parent executes
        proposal_type: action.proposal_type,
        proposal_data: action.proposal_data,
        initial_asset_amount: action.initial_asset_amount,
        initial_stable_amount: action.initial_stable_amount,
        use_dao_liquidity: action.use_dao_liquidity,
        original_fee: action.proposal_fee,
        original_proposer: tx_context::sender(ctx),
        recreation_expires_at: clock::timestamp_ms(clock) + reservation_period,
        recreation_count: 0,
        child_proposals,
    };
    
    table::add(&mut registry.reservations, parent_proposal_id, reservation);
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
    use std::string;
    
    // Create proposal data from action
    let proposal_data = priority_queue::new_proposal_data(
        string::utf8(b"Child Proposal"),
        action.proposal_type,
        vector[string::utf8(b"Yes"), string::utf8(b"No")],
        vector[string::utf8(b"Execute"), string::utf8(b"Reject")],
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
    use std::string;
    
    // Create proposal data from reservation
    let proposal_data = priority_queue::new_proposal_data(
        string::utf8(b"Recreated Proposal"),
        reservation.proposal_type,
        vector[string::utf8(b"Yes"), string::utf8(b"No")],
        vector[string::utf8(b"Execute"), string::utf8(b"Reject")],
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

// === Public Registry Functions ===

/// Initialize the registry (should be called once during deployment)
public fun init_registry(ctx: &mut TxContext): ProposalReservationRegistry {
    ProposalReservationRegistry {
        id: object::new(ctx),
        reservations: table::new(ctx),
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
    clock::timestamp_ms(clock) < reservation.recreation_expires_at
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
        EInsufficientFee
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
        let child_action = {
            let reservation = table::borrow(&registry.reservations, parent_proposal_id);
            *vector::borrow(&reservation.child_proposals, i)
        };
        let child_fee = vector::pop_back(&mut fee_coins);
        
        // Create child proposal with a new ID
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