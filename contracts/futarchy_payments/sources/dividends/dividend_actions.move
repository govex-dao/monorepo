/// Generic dividend distribution actions for Account Protocol
/// Works with any Account<Config> type (DAOs, multisigs, etc.)
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
/// - `WeightedMultisig` - Standalone multisig ✅
/// - Custom configs - Just need managed data support ✅
module futarchy_payments::dividend_actions;

// === Imports ===
use std::{
    string::{Self, String},
    type_name::{Self, TypeName},
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
    bag,
};
use futarchy_core::{
    action_validation,
    action_types,
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
use futarchy_payments::dividend_tree::{Self, DividendTree};

// === Errors ===
const EDividendNotFound: u64 = 1;
const ETreeNotFinalized: u64 = 2;
const EAllRecipientsProcessed: u64 = 3;
const EInsufficientFunds: u64 = 4;

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
/// Caller must withdraw coin from vault (via PTB) and pass it here
public fun fulfill_create_dividend<Config: store, CoinType: drop>(
    request: ResourceRequest<CreateDividendAction<CoinType>>,
    dividend_coin: Coin<CoinType>,
    account: &mut Account<Config>,
    clock: &Clock,
    ctx: &mut TxContext,
): ResourceReceipt<CreateDividendAction<CoinType>> {
    let ResourceRequest { dividend_id, tree, total_amount } = request;

    // Verify the coin amount matches the tree total
    assert!(coin::value(&dividend_coin) == total_amount, EInsufficientFunds);

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

    // Get tree info for event
    let tree_ref: &DividendTree = account::borrow_managed_data(
        account,
        DividendTreeKey { dividend_id },
        version::current()
    );
    let tree_id = dividend_tree::tree_id(tree_ref);
    let total_recipients = dividend_tree::total_recipients(tree_ref);
    let num_buckets = dividend_tree::num_buckets(tree_ref);

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

    // Return receipt
    ResourceReceipt { dividend_id }
}

/// Individual claim - user claims their own dividend (out of order, no contention)
/// User must provide the prefix that their address belongs to (found via off-chain binary search)
/// Returns true if claimed successfully, false if already claimed
public fun claim_my_dividend<Config: store, CoinType: drop>(
    account: &mut Account<Config>,
    dividend_id: String,
    prefix: vector<u8>,  // User provides their bucket prefix (from off-chain lookup)
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

    // Mark as claimed in tree
    let tree_mut: &mut DividendTree = account::borrow_managed_data_mut(
        account,
        tree_key,
        version::current()
    );

    let bucket = dividend_tree::get_bucket_mut(tree_mut, prefix);
    let recipients_table = dividend_tree::bucket_recipients_mut(bucket);
    let amount_ptr = table::borrow_mut(recipients_table, claimer);
    *amount_ptr = 0;  // Mark as claimed

    // Update progress
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
        timestamp: tx_context::epoch(ctx),
    });

    true
}

/// Anyone can call this to crank out dividends to recipients
/// Processes up to max_recipients in a single transaction (sequential order)
public fun crank_dividend<Config: store, CoinType: drop>(
    account: &mut Account<Config>,
    dividend_id: String,
    max_recipients: u64,
    ctx: &mut TxContext,
) {
    // Step 1: Collect recipients to process (read-only phase)
    let (current_bucket_prefix, start_index, recipients_to_send) = {
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
        let current_prefix = *prefix_directory.borrow(current_bucket_index);
        let bucket = dividend_tree::get_bucket(tree, current_prefix);
        let addresses = dividend_tree::bucket_addresses(bucket);
        let recipients_table = dividend_tree::bucket_recipients(bucket);

        // Collect recipients
        let batch_size = if (max_recipients > MAX_BATCH_SIZE) { MAX_BATCH_SIZE } else { max_recipients };
        let mut to_send = vector::empty<RecipientPayment>();
        let mut idx = start_index;

        while (idx < addresses.length() && to_send.length() < batch_size) {
            let addr = *addresses.borrow(idx);
            let amount_ptr = table::borrow(recipients_table, addr);
            let amount = *amount_ptr;

            if (amount > 0) {
                to_send.push_back(RecipientPayment { addr, amount });
            };

            idx = idx + 1;
        };

        (current_prefix, start_index, to_send)
    }; // Borrow ends here

    // Step 2: Process payments
    let mut processed = 0u64;
    let mut total_distributed = 0u64;
    let timestamp = tx_context::epoch(ctx);
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
    if (processed > 0) {
        // Mark as sent in tree (in separate scope to release borrow)
        let (next_idx, bucket_done) = {
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

            // Now safe to get mutable recipients table
            let recipients_table = dividend_tree::bucket_recipients_mut(bucket);

            // Mark recipients as sent using addresses from recipients_to_send
            let mut i = 0;
            while (i < recipients_to_send.length()) {
                let recipient = recipients_to_send.borrow(i);
                let amount_ptr = table::borrow_mut(recipients_table, recipient.addr);
                if (*amount_ptr > 0) {
                    *amount_ptr = 0;  // Mark as sent
                };
                i = i + 1;
            };

            let next_idx = start_index + processed;
            (next_idx, next_idx >= bucket_size)
        }; // Tree borrow ends here

        // Update progress (now safe to borrow from account again)
        let progress_key = DividendProgressKey { dividend_id };
        let progress: &mut DividendProgress = account::borrow_managed_data_mut(
            account,
            progress_key,
            version::current()
        );

        progress.sent_count = progress.sent_count + processed;
        progress.total_sent = progress.total_sent + total_distributed;
        progress.next_index_in_bucket = next_idx;

        // Move to next bucket if current is done
        if (bucket_done) {
            progress.next_bucket_index = progress.next_bucket_index + 1;
            progress.next_index_in_bucket = 0;
        };
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
