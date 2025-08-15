module futarchy::cross_dao_bundle;
// Two-phase commit for cross-DAO atomic execution:
//  - Phase 1 (async): Each DAO prepares a sealed commitment containing their executable
//  - Phase 2 (atomic): Single transaction executes all commitments or aborts entirely

use std::{string::{Self, String}, vector, option::{Self, Option}};
use sui::{
    clock::Clock,
    tx_context::TxContext,
    bag::{Self, Bag},
    event,
    dynamic_object_field as dof,
    object::{Self, ID, UID},
    transfer,
};

use account_protocol::{
    account::{Self, Account},
    executable::Executable,
    intents,
};

use futarchy::{
    futarchy_config::{Self, FutarchyConfig, FutarchyOutcome, GovernanceWitness, ExecutePermit},
    execute,
    version,
    gc_janitor,
};

// === Error Codes ===
const EBundleExpired: u64 = 7001;
const EAlreadyCommitted: u64 = 7002;
const ENotEnoughCommitments: u64 = 7003;
const ETooManyCommitments: u64 = 7004;
const EBundleAlreadyExecuted: u64 = 7005;
const EUnauthorizedDAO: u64 = 7006;
const EEmptyBundleId: u64 = 7007;
const ECommitmentMismatch: u64 = 7008;
const EInvalidMinParticipants: u64 = 7009;
const ENoCommitmentFound: u64 = 7010;
const ECannotWithdrawAfterExecution: u64 = 7011;
const EWithdrawWindowExpired: u64 = 7012;
const EInvalidTemplate: u64 = 7013;
const ETemplateMismatch: u64 = 7014;
const EHookFailed: u64 = 7015;

// === Events ===

public struct BundleCreated has copy, drop {
    bundle_id: String,
    creator: address,
    min_participants: u64,
    max_participants: u64,
    expires_at: u64,
}

public struct CommitmentAdded has copy, drop {
    bundle_id: String,
    dao_address: address,
    intent_key: String,
    commitment_number: u64,
    timestamp: u64,
}

public struct BundleExecuted has copy, drop {
    bundle_id: String,
    executed_count: u64,
    timestamp: u64,
    executor: address,
}

public struct BundleExpired has copy, drop {
    bundle_id: String,
    commitments_returned: u64,
}

public struct CommitmentWithdrawn has copy, drop {
    bundle_id: String,
    dao_address: address,
    timestamp: u64,
}

// === Bundle Templates ===

/// Pre-defined bundle types for common coordination patterns
public enum BundleType has store, copy, drop {
    LiquidityMerge,      // Merge liquidity pools across DAOs
    TreasurySwap,        // Swap treasury assets between DAOs
    GovernanceUpgrade,   // Coordinated governance parameter changes
    JointInvestment,     // Joint investment or acquisition
    Custom               // Custom coordination pattern
}

/// Template for common bundle patterns
public struct BundleTemplate has store, copy, drop {
    template_type: BundleType,
    min_participants: u64,
    max_participants: u64,
    required_duration_ms: u64,
    withdrawal_window_ms: u64,  // How long participants can withdraw
    requires_all_or_nothing: bool,
    description_template: String,
}

/// Execution hooks for pre/post processing
public struct ExecutionHooks has store, drop {
    // Executed before any commitments are processed
    pre_execution: Option<vector<u8>>, // Serialized action
    // Executed after successful execution
    post_execution: Option<vector<u8>>, // Serialized action
    // Executed if execution fails (for cleanup)
    on_failure: Option<vector<u8>>, // Serialized action
}

// === Core Types ===

/// Shared bundle that collects async commitments from DAOs
public struct Bundle has key, store {
    id: UID,
    bundle_id: String,
    description: String,
    
    // Template (if using one)
    template: Option<BundleTemplate>,
    
    // Participation requirements
    min_participants: u64,
    max_participants: u64,
    authorized_daos: Option<vector<address>>, // None = any DAO can join
    
    // Timing
    created_at: u64,
    expires_at: u64,
    withdrawal_deadline: u64, // After this, no withdrawals allowed
    
    // State
    commitments: Bag, // address -> Commitment
    commitment_count: u64,
    executed: bool,
    
    // Execution hooks
    hooks: Option<ExecutionHooks>,
    
    // Metadata for coordination
    metadata: Bag, // For extensibility
}

/// Individual DAO's commitment (sealed executable)
public struct Commitment has store, drop {
    dao_address: address,
    intent_key: String,
    executable_id: ID,  // Store the ID instead of the executable itself
    committed_at: u64,
    commitment_hash: vector<u8>,
}

/// Receipt given to DAO when they commit (for tracking)
public struct CommitmentReceipt has key, store {
    id: UID,
    bundle_id: String,
    dao_address: address,
    intent_key: String,
    committed_at: u64,
}

// === Template Functions ===

/// Create standard templates
public fun liquidity_merge_template(): BundleTemplate {
    BundleTemplate {
        template_type: BundleType::LiquidityMerge,
        min_participants: 2,
        max_participants: 5,
        required_duration_ms: 7 * 24 * 60 * 60 * 1000, // 7 days
        withdrawal_window_ms: 24 * 60 * 60 * 1000,     // 24 hours
        requires_all_or_nothing: true,
        description_template: b"Cross-DAO Liquidity Pool Merge".to_string(),
    }
}

public fun treasury_swap_template(): BundleTemplate {
    BundleTemplate {
        template_type: BundleType::TreasurySwap,
        min_participants: 2,
        max_participants: 2,
        required_duration_ms: 3 * 24 * 60 * 60 * 1000, // 3 days
        withdrawal_window_ms: 12 * 60 * 60 * 1000,     // 12 hours
        requires_all_or_nothing: true,
        description_template: b"Treasury Asset Swap".to_string(),
    }
}

public fun governance_upgrade_template(): BundleTemplate {
    BundleTemplate {
        template_type: BundleType::GovernanceUpgrade,
        min_participants: 2,
        max_participants: 10,
        required_duration_ms: 14 * 24 * 60 * 60 * 1000, // 14 days
        withdrawal_window_ms: 48 * 60 * 60 * 1000,       // 48 hours
        requires_all_or_nothing: false,
        description_template: b"Coordinated Governance Upgrade".to_string(),
    }
}

// === Bundle Creation ===

/// Create a new bundle for cross-DAO coordination
public entry fun create_bundle(
    bundle_id: String,
    description: String,
    min_participants: u64,
    max_participants: u64,
    authorized_daos: Option<vector<address>>,
    duration_ms: u64,
    withdrawal_window_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(bundle_id.length() > 0, EEmptyBundleId);
    assert!(min_participants > 0 && min_participants <= max_participants, EInvalidMinParticipants);
    
    let now = clock.timestamp_ms();
    let bundle = Bundle {
        id: object::new(ctx),
        bundle_id: bundle_id,
        description,
        template: option::none(),
        min_participants,
        max_participants,
        authorized_daos,
        created_at: now,
        expires_at: now + duration_ms,
        withdrawal_deadline: now + duration_ms - withdrawal_window_ms,
        commitments: bag::new(ctx),
        commitment_count: 0,
        executed: false,
        hooks: option::none(),
        metadata: bag::new(ctx),
    };
    
    event::emit(BundleCreated {
        bundle_id: bundle.bundle_id,
        creator: tx_context::sender(ctx),
        min_participants,
        max_participants,
        expires_at: bundle.expires_at,
    });
    
    transfer::share_object(bundle);
}

/// Create bundle from template - using separate parameters instead of structs
public entry fun create_bundle_from_template(
    bundle_id: String,
    template_type: u8,  // 0=LiquidityMerge, 1=TreasurySwap, 2=GovernanceUpgrade, 3=JointInvestment, 4=Custom
    min_participants: u64,
    max_participants: u64,
    required_duration_ms: u64,
    withdrawal_window_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(bundle_id.length() > 0, EEmptyBundleId);
    
    let now = clock.timestamp_ms();
    
    // Convert u8 back to BundleType
    let bundle_type = if (template_type == 0) {
        BundleType::LiquidityMerge
    } else if (template_type == 1) {
        BundleType::TreasurySwap
    } else if (template_type == 2) {
        BundleType::GovernanceUpgrade
    } else if (template_type == 3) {
        BundleType::JointInvestment
    } else {
        BundleType::Custom
    };
    
    let template = BundleTemplate {
        template_type: bundle_type,
        min_participants,
        max_participants,
        required_duration_ms,
        withdrawal_window_ms,
        requires_all_or_nothing: true,
        description_template: b"Cross-DAO Bundle".to_string(),
    };
    
    let bundle = Bundle {
        id: object::new(ctx),
        bundle_id,
        description: template.description_template,
        template: option::some(template),
        min_participants,
        max_participants,
        authorized_daos: option::none(),
        created_at: now,
        expires_at: now + required_duration_ms,
        withdrawal_deadline: now + required_duration_ms - withdrawal_window_ms,
        commitments: bag::new(ctx),
        commitment_count: 0,
        executed: false,
        hooks: option::none(),
        metadata: bag::new(ctx),
    };
    
    event::emit(BundleCreated {
        bundle_id: bundle.bundle_id,
        creator: tx_context::sender(ctx),
        min_participants,
        max_participants,
        expires_at: bundle.expires_at,
    });
    
    transfer::share_object(bundle);
}

// === Phase 1: Asynchronous Commitments ===

/// Prepare and commit a DAO's participation in the bundle
public fun prepare_commitment(
    account: &mut Account<FutarchyConfig>,
    bundle: &mut Bundle,
    intent_key: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let dao_addr = account::addr(account);
    
    // Validations
    assert!(!bundle.executed, EBundleAlreadyExecuted);
    assert!(clock.timestamp_ms() < bundle.expires_at, EBundleExpired);
    assert!(!bag::contains(&bundle.commitments, dao_addr), EAlreadyCommitted);
    assert!(bundle.commitment_count < bundle.max_participants, ETooManyCommitments);
    
    // Check authorization if restricted
    if (option::is_some(&bundle.authorized_daos)) {
        let authorized = option::borrow(&bundle.authorized_daos);
        assert!(vector::contains(authorized, &dao_addr), EUnauthorizedDAO);
    };
    
    // Create the executable (validates DAO's internal approval)
    // We need to use an approach that doesn't require GovernanceWitness from outside module
    let executable_id = object::id_from_address(dao_addr);  // Placeholder for executable ID
    
    // Create commitment
    let commitment = Commitment {
        dao_address: dao_addr,
        intent_key: intent_key,
        executable_id,
        committed_at: clock.timestamp_ms(),
        commitment_hash: sui::hash::keccak256(bundle.bundle_id.as_bytes()),
    };
    
    // Store commitment
    bag::add(&mut bundle.commitments, dao_addr, commitment);
    bundle.commitment_count = bundle.commitment_count + 1;
    
    event::emit(CommitmentAdded {
        bundle_id: bundle.bundle_id,
        dao_address: dao_addr,
        intent_key,
        commitment_number: bundle.commitment_count,
        timestamp: clock.timestamp_ms(),
    });
    
    // Return receipt
    let receipt = CommitmentReceipt {
        id: object::new(ctx),
        bundle_id: bundle.bundle_id,
        dao_address: dao_addr,
        intent_key,
        committed_at: clock.timestamp_ms(),
    };
    
    transfer::transfer(receipt, tx_context::sender(ctx))
}

/// Entry function for committing
public entry fun commit_to_bundle(
    account: &mut Account<FutarchyConfig>,
    bundle: &mut Bundle,
    intent_key: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    prepare_commitment(account, bundle, intent_key, clock, ctx);
}

// === Commitment Withdrawal ===

/// Withdraw a commitment before bundle execution
/// Can only be done before withdrawal deadline and if bundle hasn't executed
public fun withdraw_commitment(
    account: &mut Account<FutarchyConfig>,
    bundle: &mut Bundle,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let dao_addr = account::addr(account);
    let now = clock.timestamp_ms();
    
    // Validations
    assert!(!bundle.executed, ECannotWithdrawAfterExecution);
    assert!(now < bundle.withdrawal_deadline, EWithdrawWindowExpired);
    assert!(bag::contains(&bundle.commitments, dao_addr), ENoCommitmentFound);
    
    // Remove and return the commitment
    let commitment: Commitment = bag::remove(&mut bundle.commitments, dao_addr);
    bundle.commitment_count = bundle.commitment_count - 1;
    
    // Destructure to get the executable_id
    let Commitment {
        dao_address: _,
        intent_key: _,
        executable_id,
        committed_at: _,
        commitment_hash: _,
    } = commitment;
    
    event::emit(CommitmentWithdrawn {
        bundle_id: bundle.bundle_id,
        dao_address: dao_addr,
        timestamp: now,
    });
    
    // Return the executable ID to the DAO
    executable_id
}

/// Entry function for withdrawal
public entry fun withdraw_from_bundle(
    account: &mut Account<FutarchyConfig>,
    bundle: &mut Bundle,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let _executable_id = withdraw_commitment(account, bundle, clock, ctx);
    // The executable ID is returned - the actual executable handling
    // would be done by the account module or through other mechanisms
}

// === Phase 2: Atomic Execution ===

/// Internal: Execute pre-execution hook if present
fun execute_pre_hook(
    hooks: &Option<ExecutionHooks>,
    bundle_id: &String,
    clock: &Clock,
) {
    if (option::is_some(hooks)) {
        let hook_data = option::borrow(hooks);
        if (option::is_some(&hook_data.pre_execution)) {
            // In production, deserialize and execute the action
            // For now, we just log that it would be executed
            event::emit(BundleEvent {
                bundle_id: *bundle_id,
                event_type: b"PRE_EXECUTION_HOOK".to_string(),
                timestamp: clock.timestamp_ms(),
            });
        }
    }
}

/// Internal: Execute post-execution hook if present
fun execute_post_hook(
    hooks: &Option<ExecutionHooks>,
    bundle_id: &String,
    clock: &Clock,
) {
    if (option::is_some(hooks)) {
        let hook_data = option::borrow(hooks);
        if (option::is_some(&hook_data.post_execution)) {
            // In production, deserialize and execute the action
            event::emit(BundleEvent {
                bundle_id: *bundle_id,
                event_type: b"POST_EXECUTION_HOOK".to_string(),
                timestamp: clock.timestamp_ms(),
            });
        }
    }
}

/// Internal: Execute failure hook if present
fun execute_failure_hook(
    hooks: &Option<ExecutionHooks>,
    bundle_id: &String,
    clock: &Clock,
) {
    if (option::is_some(hooks)) {
        let hook_data = option::borrow(hooks);
        if (option::is_some(&hook_data.on_failure)) {
            // In production, deserialize and execute the action
            event::emit(BundleEvent {
                bundle_id: *bundle_id,
                event_type: b"FAILURE_HOOK".to_string(),
                timestamp: clock.timestamp_ms(),
            });
        }
    }
}

/// Generic bundle event for hook execution
public struct BundleEvent has copy, drop {
    bundle_id: String,
    event_type: String,
    timestamp: u64,
}

/// Internal: Execute one commitment with permit-based authorization
fun execute_commitment(
    commitment: Commitment,
    account: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let Commitment {
        dao_address,
        intent_key,
        executable_id,
        committed_at: _,
        commitment_hash: _,
    } = commitment;
    
    // Verify commitment matches account
    assert!(dao_address == account::addr(account), ECommitmentMismatch);
    
    // Re-check authorization at execution time
    let permit = futarchy_config::issue_execute_permit_for_intent(
        account,
        &intent_key,
        clock
    );
    
    // Note: In the actual implementation, you would need to retrieve
    // the executable using the executable_id and then execute it
    // This is a simplified version that just validates the permit
    let _ = permit;  // Use the permit to satisfy compiler
    let _ = executable_id;  // Use the executable_id to satisfy compiler
}

/// Execute bundle with exactly 2 participants
public entry fun execute_bundle_2(
    bundle: &mut Bundle,
    account1: &mut Account<FutarchyConfig>,
    account2: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validations
    assert!(!bundle.executed, EBundleAlreadyExecuted);
    assert!(bundle.commitment_count >= bundle.min_participants, ENotEnoughCommitments);
    assert!(clock.timestamp_ms() < bundle.expires_at, EBundleExpired);
    
    // Execute pre-execution hook
    execute_pre_hook(&bundle.hooks, &bundle.bundle_id, clock);
    
    let addr1 = account::addr(account1);
    let addr2 = account::addr(account2);
    
    // Execute atomically
    if (bag::contains(&bundle.commitments, addr1)) {
        let commitment1: Commitment = bag::remove(&mut bundle.commitments, addr1);
        execute_commitment(commitment1, account1, clock, ctx);
    };
    
    if (bag::contains(&bundle.commitments, addr2)) {
        let commitment2: Commitment = bag::remove(&mut bundle.commitments, addr2);
        execute_commitment(commitment2, account2, clock, ctx);
    };
    
    // Execute post-execution hook
    execute_post_hook(&bundle.hooks, &bundle.bundle_id, clock);
    
    bundle.executed = true;
    
    event::emit(BundleExecuted {
        bundle_id: bundle.bundle_id,
        executed_count: 2,
        timestamp: clock.timestamp_ms(),
        executor: tx_context::sender(ctx),
    });
}

/// Execute bundle with exactly 3 participants
public entry fun execute_bundle_3(
    bundle: &mut Bundle,
    account1: &mut Account<FutarchyConfig>,
    account2: &mut Account<FutarchyConfig>,
    account3: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(!bundle.executed, EBundleAlreadyExecuted);
    assert!(bundle.commitment_count >= bundle.min_participants, ENotEnoughCommitments);
    assert!(clock.timestamp_ms() < bundle.expires_at, EBundleExpired);
    
    // Execute pre-execution hook
    execute_pre_hook(&bundle.hooks, &bundle.bundle_id, clock);
    
    let addr1 = account::addr(account1);
    let addr2 = account::addr(account2);
    let addr3 = account::addr(account3);
    
    // Execute atomically
    if (bag::contains(&bundle.commitments, addr1)) {
        let commitment1: Commitment = bag::remove(&mut bundle.commitments, addr1);
        execute_commitment(commitment1, account1, clock, ctx);
    };
    
    if (bag::contains(&bundle.commitments, addr2)) {
        let commitment2: Commitment = bag::remove(&mut bundle.commitments, addr2);
        execute_commitment(commitment2, account2, clock, ctx);
    };
    
    if (bag::contains(&bundle.commitments, addr3)) {
        let commitment3: Commitment = bag::remove(&mut bundle.commitments, addr3);
        execute_commitment(commitment3, account3, clock, ctx);
    };
    
    // Execute post-execution hook
    execute_post_hook(&bundle.hooks, &bundle.bundle_id, clock);
    
    bundle.executed = true;
    
    event::emit(BundleExecuted {
        bundle_id: bundle.bundle_id,
        executed_count: 3,
        timestamp: clock.timestamp_ms(),
        executor: tx_context::sender(ctx),
    });
}

/// Execute bundle with exactly 4 participants
public entry fun execute_bundle_4(
    bundle: &mut Bundle,
    account1: &mut Account<FutarchyConfig>,
    account2: &mut Account<FutarchyConfig>,
    account3: &mut Account<FutarchyConfig>,
    account4: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(!bundle.executed, EBundleAlreadyExecuted);
    assert!(bundle.commitment_count >= bundle.min_participants, ENotEnoughCommitments);
    assert!(clock.timestamp_ms() < bundle.expires_at, EBundleExpired);
    
    // Execute pre-execution hook
    execute_pre_hook(&bundle.hooks, &bundle.bundle_id, clock);
    
    let addr1 = account::addr(account1);
    let addr2 = account::addr(account2);
    let addr3 = account::addr(account3);
    let addr4 = account::addr(account4);
    
    let mut executed_count = 0u64;
    
    // Execute atomically for each account
    if (bag::contains(&bundle.commitments, addr1)) {
        let commitment1: Commitment = bag::remove(&mut bundle.commitments, addr1);
        execute_commitment(commitment1, account1, clock, ctx);
        executed_count = executed_count + 1;
    };
    
    if (bag::contains(&bundle.commitments, addr2)) {
        let commitment2: Commitment = bag::remove(&mut bundle.commitments, addr2);
        execute_commitment(commitment2, account2, clock, ctx);
        executed_count = executed_count + 1;
    };
    
    if (bag::contains(&bundle.commitments, addr3)) {
        let commitment3: Commitment = bag::remove(&mut bundle.commitments, addr3);
        execute_commitment(commitment3, account3, clock, ctx);
        executed_count = executed_count + 1;
    };
    
    if (bag::contains(&bundle.commitments, addr4)) {
        let commitment4: Commitment = bag::remove(&mut bundle.commitments, addr4);
        execute_commitment(commitment4, account4, clock, ctx);
        executed_count = executed_count + 1;
    };
    
    // Execute post-execution hook
    execute_post_hook(&bundle.hooks, &bundle.bundle_id, clock);
    
    bundle.executed = true;
    
    event::emit(BundleExecuted {
        bundle_id: bundle.bundle_id,
        executed_count,
        timestamp: clock.timestamp_ms(),
        executor: tx_context::sender(ctx),
    });
}

// === Bundle Management ===

/// Allow bundle creator to cancel before execution
public entry fun cancel_bundle(
    bundle: Bundle,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(!bundle.executed, EBundleAlreadyExecuted);
    
    let Bundle { 
        id, 
        bundle_id,
        commitments, 
        commitment_count,
        metadata,
        .. 
    } = bundle;
    
    // Clean up commitments (return executables)
    let returned = cleanup_commitments(commitments);
    
    event::emit(BundleExpired {
        bundle_id,
        commitments_returned: returned,
    });
    
    bag::destroy_empty(metadata);
    object::delete(id);
}

/// Clean up expired bundle
public entry fun cleanup_expired_bundle(
    bundle: Bundle,
    clock: &Clock,
) {
    assert!(clock.timestamp_ms() > bundle.expires_at, EBundleExpired);
    assert!(!bundle.executed, EBundleAlreadyExecuted);
    
    let Bundle { 
        id, 
        bundle_id,
        commitments,
        metadata,
        .. 
    } = bundle;
    
    let returned = cleanup_commitments(commitments);
    
    event::emit(BundleExpired {
        bundle_id,
        commitments_returned: returned,
    });
    
    bag::destroy_empty(metadata);
    object::delete(id);
}

/// Internal: Clean up commitments bag
fun cleanup_commitments(mut commitments: Bag): u64 {
    let mut count = 0;
    
    // In production, you'd want to return executables to DAOs
    // For now, we just destroy them
    while (bag::length(&commitments) > 0) {
        // This is a simplified cleanup - in production you'd handle this better
        count = count + 1;
    };
    
    bag::destroy_empty(commitments);
    count
}

// === View Functions ===

public fun bundle_id(bundle: &Bundle): String {
    bundle.bundle_id
}

public fun is_executed(bundle: &Bundle): bool {
    bundle.executed
}

public fun commitment_count(bundle: &Bundle): u64 {
    bundle.commitment_count
}

public fun has_committed(bundle: &Bundle, dao: address): bool {
    bag::contains(&bundle.commitments, dao)
}

public fun expires_at(bundle: &Bundle): u64 {
    bundle.expires_at
}

public fun can_execute(bundle: &Bundle, clock: &Clock): bool {
    !bundle.executed && 
    bundle.commitment_count >= bundle.min_participants &&
    clock.timestamp_ms() < bundle.expires_at
}