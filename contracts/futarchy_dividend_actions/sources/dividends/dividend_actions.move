// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Generic dividend distribution actions for Account Protocol
/// Works with any Account<Config> type
/// Uses pre-built DividendTree for massive scale (100M recipients)
/// Tree is built off-chain over multiple transactions, then passed to proposal
///
/// ## Config Requirements
///
/// Any Config type using dividend actions MUST satisfy:
///
/// 1. **Managed Data Support**: MUST support storing dividend metadata via:
///    - `DividendStorageKey` - For dividend ID tracking
///    - `DividendTreeKey` - For storing DividendTree objects
///    - `DividendProgressKey` - For cranking progress
///    - `DividendPoolKey` - For coin pool storage
///
/// 2. **No Key Conflicts**: Storage keys MUST NOT conflict with dividend keys
///
/// 3. **ResourceRequest Pattern**: Caller must provide coin via:
///    ```
///    let request = do_create_dividend(...);
///    let coin = vault::withdraw(...); // From any vault
///    fulfill_create_dividend(request, coin, ...);
///    ```
///
/// Example Config implementations:
/// - `FutarchyConfig` - DAO ✅
/// - Custom configs - Just need managed data support ✅
module futarchy_dividend_actions::dividend_actions;

// === Imports ===
use std::{
    string::{Self, String},
    type_name::{Self, TypeName},
    option::{Self, Option},
};
use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    balance::{Self, Balance},
    event,
    object::{Self, ID},
    transfer,
    tx_context::TxContext,
    bcs::{Self, BCS},
    table,
};
use futarchy_types::action_type_markers as action_types;
use futarchy_core::{
    action_validation,
    // action_types moved to futarchy_types
    version,
    futarchy_config::FutarchyConfig,
};
use account_protocol::{
    bcs_validation,
    account::{Self, Account, Auth},
    executable::{Self, Executable},
    version_witness::VersionWitness,
    intents,
};
use account_actions::vault::{Self, Vault};
use futarchy_dividend_actions::dividend_tree::{Self, DividendTree};

// === Errors ===
const ETreeNotFinalized: u64 = 2;
const EAllRecipientsProcessed: u64 = 3;
const EInsufficientFunds: u64 = 4;
const EWrongCoinType: u64 = 5;
const EDistributionAlreadyStarted: u64 = 6;
const EUnauthorizedCancellation: u64 = 7;
const ENotFullyDistributed: u64 = 9;
const EPoolNotEmpty: u64 = 10;
const EUnsortedPrefixes: u64 = 11;

const MAX_BATCH_SIZE: u64 = 100;

// === Storage Keys ===

/// Key for storing dividend metadata in Account
public struct DividendStorageKey has copy, drop, store {}

/// Key for storing the dividend tree object
public struct DividendTreeKey has copy, drop, store {
    dividend_id: String,
}

/// Key for storing dividend progress tracker
public struct DividendProgressKey has copy, drop, store {
    dividend_id: String,
}

/// Key for storing dividend coin pool
public struct DividendPoolKey has copy, drop, store {
    dividend_id: String,
}

// === Structs ===

/// Storage for dividend metadata
public struct DividendStorage has store {
    next_id: u64,
}

/// Tracks cranking progress for a dividend
public struct DividendProgress has store {
    dividend_id: String,
    tree_id: ID,
    total_recipients: u64,
    total_amount: u64,
    sent_count: u64,
    total_sent: u64,
    next_bucket_index: u64,  // Index into prefix_directory vector
    next_index_in_bucket: u64,
    created_at: u64,
}

// === Action Structs ===

/// Action to create a dividend using a pre-built tree
/// The tree must be built off-chain first using dividend_tree module
public struct CreateDividendAction<phantom CoinType> has store, drop, copy {
    tree_id: ID,  // Pre-built DividendTree object
}

/// Hot potato for requesting vault withdrawal (ResourceRequest pattern)
public struct ResourceRequest<phantom Action> {
    dividend_id: String,
    tree: DividendTree,
    total_amount: u64,
}

/// Receipt proving resource was provided (ResourceRequest pattern)
public struct ResourceReceipt<phantom Action> {
    dividend_id: String,
}

/// Get dividend_id from ResourceReceipt
public fun resource_receipt_dividend_id<Action>(receipt: &ResourceReceipt<Action>): &String {
    &receipt.dividend_id
}

/// Capability proving authority to cancel a specific dividend
/// Issued during dividend creation, held by governance
/// Can only be used if NO payments have been made (sent_count == 0)
public struct DividendCancelCap has key, store {
    id: UID,
    dividend_id: String,
    account_id: ID,
}

/// Helper struct for cranking - represents a recipient payment
/// Replaces tuple type (address, u64) which is not allowed in vectors
public struct RecipientPayment has drop, store {
    addr: address,
    amount: u64,
}

// === Events ===

public struct DividendCreated has copy, drop {
    account_id: ID,
    dividend_id: String,
    tree_id: ID,
    total_amount: u64,
    total_recipients: u64,
    num_buckets: u64,
    created_at: u64,
}

public struct DividendSent has copy, drop {
    account_id: ID,
    dividend_id: String,
    recipient: address,
    amount: u64,
    timestamp: u64,
}

public struct DividendCranked has copy, drop {
    account_id: ID,
    dividend_id: String,
    recipients_processed: u64,
    total_distributed: u64,
    timestamp: u64,
}

public struct DividendCancelled has copy, drop {
    account_id: ID,
    dividend_id: String,
    refund_amount: u64,
    timestamp: u64,
}

// === Constructor Functions ===

/// Create a new CreateDividendAction with pre-built tree
public fun new_create_dividend_action<CoinType>(
    tree_id: ID,
): CreateDividendAction<CoinType> {
    CreateDividendAction {
        tree_id,
    }
}

// === Public Functions ===

/// Execute create dividend action - Returns ResourceRequest for vault withdrawal
/// Takes ownership of the pre-built tree and requests coin withdrawal via hot potato
public fun do_create_dividend<Config: store, Outcome: store, CoinType: drop, IW: copy + drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    tree: DividendTree,  // Receive the pre-built tree
    _version_witness: VersionWitness,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): ResourceRequest<CreateDividendAction<CoinType>> {
    // Get spec and validate type
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));
    action_validation::assert_action_type<action_types::CreateDividend>(spec);

    // Deserialize action data
    let action_data = intents::action_spec_data(spec);
    let mut reader = bcs::new(*action_data);
    let tree_id = bcs::peel_address(&mut reader).to_id();

    let action = CreateDividendAction<CoinType> { tree_id };
    bcs_validation::validate_all_bytes_consumed(reader);

    // Validate tree is finalized
    assert!(dividend_tree::is_finalized(&tree), ETreeNotFinalized);

    // Validate tree ID matches
    assert!(dividend_tree::tree_id(&tree) == action.tree_id, 0);

    // CRITICAL: Validate prefix directory is sorted
    // Binary search in query_allocation and claim_my_dividend relies on this
    assert!(dividend_tree::is_prefix_directory_sorted(&tree), EUnsortedPrefixes);

    // Get tree info
    let total_recipients = dividend_tree::total_recipients(&tree);
    let total_amount = dividend_tree::total_amount(&tree);
    let num_buckets = dividend_tree::num_buckets(&tree);

    // Note: No upfront balance check needed - caller provides coin via ResourceRequest
    // The fulfill_create_dividend function will verify coin amount matches tree total

    // Initialize storage if needed
    if (!account::has_managed_data(account, DividendStorageKey {})) {
        account::add_managed_data(
            account,
            DividendStorageKey {},
            DividendStorage { next_id: 0 },
            version::current()
        );
    };

    // Generate dividend ID
    let storage: &mut DividendStorage = account::borrow_managed_data_mut(
        account,
        DividendStorageKey {},
        version::current()
    );
    let dividend_id = generate_dividend_id(storage.next_id, clock.timestamp_ms());
    storage.next_id = storage.next_id + 1;

    // Create progress tracker
    let progress = DividendProgress {
        dividend_id,
        tree_id: dividend_tree::tree_id(&tree),
        total_recipients,
        total_amount,
        sent_count: 0,
        total_sent: 0,
        next_bucket_index: 0,  // Start at first bucket in prefix directory
        next_index_in_bucket: 0,
        created_at: clock.timestamp_ms(),
    };

    // Store progress
    let progress_key = DividendProgressKey { dividend_id };
    account::add_managed_data(account, progress_key, progress, version::current());

    // Increment action index
    executable::increment_action_idx(executable);

    // Return ResourceRequest hot potato - caller must fulfill with coin
    ResourceRequest {
        dividend_id,
        tree,
        total_amount,
    }
}

/// Fulfill the create dividend resource request by providing the coin
/// Returns ResourceReceipt and DividendCancelCap for governance
/// Caller must withdraw coin from vault (via PTB) and pass it here
public fun fulfill_create_dividend<Config: store, CoinType: drop>(
    request: ResourceRequest<CreateDividendAction<CoinType>>,
    dividend_coin: Coin<CoinType>,
    account: &mut Account<Config>,
    clock: &Clock,
    ctx: &mut TxContext,
): (ResourceReceipt<CreateDividendAction<CoinType>>, DividendCancelCap) {
    let ResourceRequest { dividend_id, tree, total_amount } = request;

    // Verify the coin amount matches the tree total
    assert!(coin::value(&dividend_coin) == total_amount, EInsufficientFunds);
    assert!(total_amount > 0, EInsufficientFunds);

    // Verify coin type and extract event data BEFORE storing tree
    assert!(dividend_tree::coin_type(&tree) == type_name::get<CoinType>(), EWrongCoinType);
    let tree_id = dividend_tree::tree_id(&tree);
    let total_recipients = dividend_tree::total_recipients(&tree);
    let num_buckets = dividend_tree::num_buckets(&tree);

    // Store tree as managed data
    account::add_managed_data(
        account,
        DividendTreeKey { dividend_id },
        tree,
        version::current()
    );

    // Store coin in dividend pool for cranking
    let pool_key = DividendPoolKey { dividend_id };
    account::add_managed_data(
        account,
        pool_key,
        coin::into_balance(dividend_coin),
        version::current()
    );

    // Emit event
    event::emit(DividendCreated {
        account_id: object::id(account),
        dividend_id,
        tree_id,
        total_amount,
        total_recipients,
        num_buckets,
        created_at: clock.timestamp_ms(),
    });

    // Create cancel capability (can only be used if sent_count == 0)
    let cancel_cap = DividendCancelCap {
        id: object::new(ctx),
        dividend_id,
        account_id: object::id(account),
    };

    // Return receipt and cancel cap
    (ResourceReceipt { dividend_id }, cancel_cap)
}

/// Individual claim - user claims their own dividend (out of order, no contention)
/// User must provide the prefix that their address belongs to (found via off-chain binary search)
/// Returns true if claimed successfully, false if already claimed
public fun claim_my_dividend<Config: store, CoinType: drop>(
    account: &mut Account<Config>,
    dividend_id: String,
    prefix: vector<u8>,  // User provides their bucket prefix (from off-chain lookup)
    clock: &Clock,
    ctx: &mut TxContext,
): bool {
    let claimer = tx_context::sender(ctx);

    // Find recipient's allocation
    let tree_key = DividendTreeKey { dividend_id };
    let tree: &DividendTree = account::borrow_managed_data(
        account,
        tree_key,
        version::current()
    );

    // Verify the prefix is valid and claimer's address matches it
    if (!dividend_tree::has_bucket(tree, prefix)) {
        return false  // Invalid prefix
    };

    if (!dividend_tree::address_has_prefix(claimer, &prefix)) {
        return false  // Claimer's address doesn't match provided prefix
    };

    // O(1) bucket lookup using provided prefix!
    let bucket = dividend_tree::get_bucket(tree, prefix);
    let amount_to_claim = dividend_tree::get_recipient_amount(bucket, claimer);

    if (amount_to_claim == 0) {
        return false  // Already claimed or not a recipient
    };

    // Claim payment
    let pool_key = DividendPoolKey { dividend_id };
    let pool: &mut Balance<CoinType> = account::borrow_managed_data_mut(
        account,
        pool_key,
        version::current()
    );

    let payment = pool.split(amount_to_claim);
    transfer::public_transfer(coin::from_balance(payment, ctx), claimer);

    // Mark as claimed in tree and update skip-list
    let tree_mut: &mut DividendTree = account::borrow_managed_data_mut(
        account,
        tree_key,
        version::current()
    );

    let bucket = dividend_tree::get_bucket_mut(tree_mut, prefix);

    // Update skip-list: find address index and decrement interval unclaimed_count
    let addr_idx_opt = dividend_tree::find_address_index(bucket, claimer);
    if (option::is_some(&addr_idx_opt)) {
        let addr_idx = option::destroy_some(addr_idx_opt);
        dividend_tree::update_skip_list_on_claim(bucket, addr_idx);
    };

    // Mark as claimed in recipients table
    let recipients_table = dividend_tree::bucket_recipients_mut(bucket);
    let amount_ptr = table::borrow_mut(recipients_table, claimer);
    *amount_ptr = 0;  // Mark as claimed

    // Update progress (overflow protected by Move runtime)
    // Note: Move aborts on u64 overflow automatically, which is safe for edge cases
    let progress_key = DividendProgressKey { dividend_id };
    let progress: &mut DividendProgress = account::borrow_managed_data_mut(
        account,
        progress_key,
        version::current()
    );
    progress.sent_count = progress.sent_count + 1;
    progress.total_sent = progress.total_sent + amount_to_claim;

    // Emit event
    event::emit(DividendSent {
        account_id: object::id(account),
        dividend_id,
        recipient: claimer,
        amount: amount_to_claim,
        timestamp: clock.timestamp_ms(),
    });

    true
}

/// Anyone can call this to crank out dividends to recipients
/// Processes up to max_recipients in a single transaction (sequential order)
public fun crank_dividend<Config: store, CoinType: drop>(
    account: &mut Account<Config>,
    dividend_id: String,
    max_recipients: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Step 1: Collect recipients to process (read-only phase)
    let (current_bucket_prefix, start_index, scan_end_idx, recipients_to_send) = {
        let progress_key = DividendProgressKey { dividend_id };
        let progress: &DividendProgress = account::borrow_managed_data(
            account,
            progress_key,
            version::current()
        );

        // Check if all processed
        assert!(progress.sent_count < progress.total_recipients, EAllRecipientsProcessed);

        let current_bucket_index = progress.next_bucket_index;
        let start_index = progress.next_index_in_bucket;

        // Get tree and bucket using prefix directory
        let tree_key = DividendTreeKey { dividend_id };
        let tree: &DividendTree = account::borrow_managed_data(
            account,
            tree_key,
            version::current()
        );

        let prefix_directory = dividend_tree::get_prefix_directory(tree);

        // CRITICAL: Bounds check to prevent out-of-bounds panic
        // This can happen if all remaining recipients claimed individually
        assert!(current_bucket_index < prefix_directory.length(), EAllRecipientsProcessed);

        let current_prefix = *prefix_directory.borrow(current_bucket_index);
        let bucket = dividend_tree::get_bucket(tree, current_prefix);
        let addresses = dividend_tree::bucket_addresses(bucket);
        let recipients_table = dividend_tree::bucket_recipients(bucket);
        let skip_intervals = dividend_tree::get_skip_intervals(bucket);

        // Collect recipients using skip-list optimization
        let batch_size = if (max_recipients > MAX_BATCH_SIZE) { MAX_BATCH_SIZE } else { max_recipients };
        let mut to_send = vector::empty<RecipientPayment>();
        let mut idx = start_index;

        // Skip-list optimization: Jump over fully-claimed intervals
        // Find the interval containing start_index
        let skip_interval_size = 1000; // SKIP_INTERVAL_SIZE from dividend_tree
        let mut current_interval_idx = idx / skip_interval_size;

        while (idx < addresses.length() && to_send.length() < batch_size) {
            // Check if we've moved to a new skip interval
            let interval_idx = idx / skip_interval_size;

            if (interval_idx != current_interval_idx && interval_idx < skip_intervals.length()) {
                current_interval_idx = interval_idx;

                // Check if this interval is fully claimed (unclaimed_count = 0)
                let interval = skip_intervals.borrow(interval_idx);
                if (dividend_tree::skip_node_unclaimed_count(interval) == 0) {
                    // Skip entire interval - jump to start of next interval
                    let next_interval_start = (interval_idx + 1) * skip_interval_size;
                    if (next_interval_start < addresses.length()) {
                        idx = next_interval_start;
                        continue  // Jump to next interval
                    } else {
                        break  // No more intervals
                    }
                };
            };

            // Process address at idx
            let addr = *addresses.borrow(idx);
            let amount_ptr = table::borrow(recipients_table, addr);
            let amount = *amount_ptr;

            if (amount > 0) {
                to_send.push_back(RecipientPayment { addr, amount });
            };

            idx = idx + 1;
        };

        // Return scan_end_idx so we can advance cursor even if processed == 0
        (current_prefix, start_index, idx, to_send)
    }; // Borrow ends here

    // Step 2: Process payments
    let mut processed = 0u64;
    let mut total_distributed = 0u64;
    let timestamp = clock.timestamp_ms();
    let account_id = object::id(account); // Get ID before any borrows

    if (recipients_to_send.length() > 0) {
        // Get pool for transfers
        let pool_key = DividendPoolKey { dividend_id };
        let pool: &mut Balance<CoinType> = account::borrow_managed_data_mut(
            account,
            pool_key,
            version::current()
        );

        // Send to each recipient
        let mut i = 0;
        while (i < recipients_to_send.length()) {
            let recipient = recipients_to_send.borrow(i);

            let payment = pool.split(recipient.amount);
            transfer::public_transfer(coin::from_balance(payment, ctx), recipient.addr);

            event::emit(DividendSent {
                account_id,
                dividend_id,
                recipient: recipient.addr,
                amount: recipient.amount,
                timestamp,
            });

            processed = processed + 1;
            total_distributed = total_distributed + recipient.amount;
            i = i + 1;
        };
    };

    // Step 3: Update tracking
    // Always update cursor to avoid stalling on already-claimed recipients
    // Mark as sent in tree (in separate scope to release borrow)
    let (bucket_size, bucket_done) = {
        let tree_key = DividendTreeKey { dividend_id };
        let tree: &mut DividendTree = account::borrow_managed_data_mut(
            account,
            tree_key,
            version::current()
        );

        let bucket = dividend_tree::get_bucket_mut(tree, current_bucket_prefix);

        // Get bucket size in separate scope to release borrow
        let bucket_size = {
            let addresses = dividend_tree::bucket_addresses(bucket);
            addresses.length()
        }; // addresses borrow ends here

        // Mark recipients as sent and update skip-list (only if we processed any)
        if (processed > 0) {
            // Update skip-list for each sent recipient
            let mut i = 0;
            while (i < recipients_to_send.length()) {
                let recipient = recipients_to_send.borrow(i);

                // Find address index and update skip-list
                let addr_idx_opt = dividend_tree::find_address_index(bucket, recipient.addr);
                if (option::is_some(&addr_idx_opt)) {
                    let addr_idx = option::destroy_some(addr_idx_opt);
                    dividend_tree::update_skip_list_on_claim(bucket, addr_idx);
                };

                i = i + 1;
            };

            // Mark as sent in recipients table
            let recipients_table = dividend_tree::bucket_recipients_mut(bucket);
            let mut i = 0;
            while (i < recipients_to_send.length()) {
                let recipient = recipients_to_send.borrow(i);
                let amount_ptr = table::borrow_mut(recipients_table, recipient.addr);
                if (*amount_ptr > 0) {
                    *amount_ptr = 0;  // Mark as sent
                };
                i = i + 1;
            };
        };

        // Check if bucket is done using scan_end_idx (not start_index + processed)
        (bucket_size, scan_end_idx >= bucket_size)
    }; // Tree borrow ends here

    // Update progress (now safe to borrow from account again)
    // Note: Move aborts on u64 overflow automatically, which is safe for edge cases
    let progress_key = DividendProgressKey { dividend_id };
    let progress: &mut DividendProgress = account::borrow_managed_data_mut(
        account,
        progress_key,
        version::current()
    );

    progress.sent_count = progress.sent_count + processed;
    progress.total_sent = progress.total_sent + total_distributed;
    progress.next_index_in_bucket = scan_end_idx;  // Always advance, even if processed == 0

    // Move to next bucket if current is done
    if (bucket_done) {
        progress.next_bucket_index = progress.next_bucket_index + 1;
        progress.next_index_in_bucket = 0;
    };

    // Emit batch event
    event::emit(DividendCranked {
        account_id,
        dividend_id,
        recipients_processed: processed,
        total_distributed,
        timestamp,
    });
}

/// Cancel a dividend and recover all funds
/// CRITICAL SAFETY: Can ONLY be called if sent_count == 0 (no payments made yet)
/// This prevents unfairness where some recipients get paid and others don't
///
/// Use cases:
/// - Wrong coin type was used
/// - Error in tree construction detected
/// - Governance decides to cancel before distribution starts
///
/// Once ANY payment is made, cancellation is permanently disabled
public fun cancel_dividend<Config: store, CoinType: drop>(
    cap: DividendCancelCap,
    account: &mut Account<Config>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    let DividendCancelCap { id, dividend_id, account_id } = cap;

    // Verify cap matches account
    assert!(account_id == object::id(account), EUnauthorizedCancellation);

    // Check that NO payments have been made
    let progress_key = DividendProgressKey { dividend_id };
    let progress: &DividendProgress = account::borrow_managed_data(
        account,
        progress_key,
        version::current()
    );

    // CRITICAL SAFETY CHECK: Reject if any payments sent
    assert!(progress.sent_count == 0, EDistributionAlreadyStarted);

    // Remove all dividend data
    let pool_key = DividendPoolKey { dividend_id };
    let pool: Balance<CoinType> = account::remove_managed_data(
        account,
        pool_key,
        version::current()
    );

    let tree_key = DividendTreeKey { dividend_id };
    let tree: DividendTree = account::remove_managed_data(
        account,
        tree_key,
        version::current()
    );

    // Clean up tree and all its buckets
    dividend_tree::delete_tree(tree);

    let DividendProgress {
        dividend_id: _,
        tree_id: _,
        total_recipients: _,
        total_amount: _,
        sent_count: _,
        total_sent: _,
        next_bucket_index: _,
        next_index_in_bucket: _,
        created_at: _,
    } = account::remove_managed_data(
        account,
        progress_key,
        version::current()
    );

    // Emit cancellation event
    let refund_amount = pool.value();
    event::emit(DividendCancelled {
        account_id: object::id(account),
        dividend_id,
        refund_amount,
        timestamp: clock.timestamp_ms(),
    });

    // Delete capability
    object::delete(id);

    // Return funds to caller (governance)
    coin::from_balance(pool, ctx)
}

/// Clean up a completed dividend to free storage
/// Can ONLY be called after ALL recipients have been paid (sent_count == total_recipients)
/// Returns the tree for archival purposes (caller can delete it or keep it)
///
/// Use cases:
/// - Free storage after successful distribution
/// - Archive old dividends
/// - Reduce on-chain storage costs
///
/// Note: Pool must be empty (all funds distributed)
public fun cleanup_completed_dividend<Config: store, CoinType: drop>(
    account: &mut Account<Config>,
    dividend_id: String,
    ctx: &mut TxContext,
): DividendTree {
    let progress_key = DividendProgressKey { dividend_id };
    let progress: &DividendProgress = account::borrow_managed_data(
        account,
        progress_key,
        version::current()
    );

    // CRITICAL: Require 100% distribution complete
    assert!(progress.sent_count == progress.total_recipients, ENotFullyDistributed);

    // Remove and verify pool is empty
    let pool_key = DividendPoolKey { dividend_id };
    let pool: Balance<CoinType> = account::remove_managed_data(
        account,
        pool_key,
        version::current()
    );
    assert!(pool.value() == 0, EPoolNotEmpty);
    pool.destroy_zero();

    // Remove tree
    let tree_key = DividendTreeKey { dividend_id };
    let tree: DividendTree = account::remove_managed_data(
        account,
        tree_key,
        version::current()
    );

    // Remove progress
    let DividendProgress {
        dividend_id: _,
        tree_id: _,
        total_recipients: _,
        total_amount: _,
        sent_count: _,
        total_sent: _,
        next_bucket_index: _,
        next_index_in_bucket: _,
        created_at: _,
    } = account::remove_managed_data(
        account,
        progress_key,
        version::current()
    );

    // Return tree for caller to archive or delete
    // Use dividend_tree::delete_tree(tree) to fully clean up
    tree
}

// === Helper Functions ===

/// Generate unique dividend ID
fun generate_dividend_id(next_id: u64, timestamp: u64): String {
    let mut id = b"DIV_".to_string();
    id.append(next_id.to_string());
    id.append(b"_T".to_string());
    id.append(timestamp.to_string());
    id
}

// === Cleanup Functions ===

public fun delete_create_dividend<CoinType>(expired: &mut account_protocol::intents::Expired) {
    let spec = account_protocol::intents::remove_action_spec(expired);
    let _ = spec;
}

// === Query Functions ===

/// Get dividend info
public fun get_dividend_info<Config: store>(
    account: &Account<Config>,
    dividend_id: String,
): (u64, u64, u64, u64) {
    let progress_key = DividendProgressKey { dividend_id };
    let progress: &DividendProgress = account::borrow_managed_data(
        account,
        progress_key,
        version::current()
    );

    (
        progress.total_amount,
        progress.total_sent,
        progress.total_recipients,
        progress.sent_count,
    )
}

/// Check if recipient has been sent their dividend
/// User must provide prefix (from off-chain binary search)
public fun has_been_sent<Config: store>(
    account: &Account<Config>,
    dividend_id: String,
    prefix: vector<u8>,
    recipient: address,
): bool {
    let tree_key = DividendTreeKey { dividend_id };

    if (!account::has_managed_data(account, tree_key)) {
        return false
    };

    let tree: &DividendTree = account::borrow_managed_data(
        account,
        tree_key,
        version::current()
    );

    // Verify prefix is valid
    if (!dividend_tree::has_bucket(tree, prefix)) {
        return false
    };

    if (!dividend_tree::address_has_prefix(recipient, &prefix)) {
        return false
    };

    // O(1) bucket lookup using provided prefix!
    let bucket = dividend_tree::get_bucket(tree, prefix);
    let amount = dividend_tree::get_recipient_amount(bucket, recipient);

    amount == 0  // 0 means sent/claimed
}

/// Get recipient allocation amount (0 if already sent)
/// User must provide prefix (from off-chain binary search)
public fun get_allocation_amount<Config: store>(
    account: &Account<Config>,
    dividend_id: String,
    prefix: vector<u8>,
    recipient: address,
): u64 {
    let tree_key = DividendTreeKey { dividend_id };
    let tree: &DividendTree = account::borrow_managed_data(
        account,
        tree_key,
        version::current()
    );

    // Verify prefix is valid
    if (!dividend_tree::has_bucket(tree, prefix)) {
        return 0
    };

    if (!dividend_tree::address_has_prefix(recipient, &prefix)) {
        return 0
    };

    // O(1) bucket lookup using provided prefix!
    let bucket = dividend_tree::get_bucket(tree, prefix);
    dividend_tree::get_recipient_amount(bucket, recipient)
}
