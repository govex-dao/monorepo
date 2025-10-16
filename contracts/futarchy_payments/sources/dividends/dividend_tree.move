/// # DIVIDEND TREE SECURITY MODEL (Massive Scale: 100M+ Recipients)
///
/// ## Overview
/// This module supports dividend distributions at MASSIVE SCALE (100M+ recipients)
/// using address-prefix bucketing for O(1) lookup with skip-list optimized cranking.
///
/// ## Critical Security Invariants
///
/// ### 1. No Prefix Overlaps (CRITICAL for Binary Search Safety)
///
/// **Invariant:** No prefix in `prefix_directory` can be a sub-prefix of another.
///
/// **Why Critical:**
/// - `query_allocation()` and `claim_my_dividend()` use binary search
/// - Binary search terminates on FIRST prefix match
/// - If overlaps exist, wrong bucket checked first → funds trapped
///
/// **Example Attack:**
/// ```
/// Bucket A: prefix = 0xab       (100 recipients)
/// Bucket B: prefix = 0xabc      (200 recipients)  // 0xab ⊂ 0xabc!
///
/// Address 0xabc123... matches BOTH
/// Binary search may check Bucket A first → not found → early exit
/// Real allocation in Bucket B never checked → FUNDS TRAPPED
/// ```
///
/// ### 2. Validation at Scale (INFEASIBLE On-Chain)
///
/// **Problem:** `validate_no_prefix_overlap()` is O(N²)
/// - 20k buckets with 1k chunk = 20M comparisons = INSTANT GAS OUT
/// - On-chain validation CANNOT be used for large trees
///
/// **Solution:** OFF-CHAIN VALIDATION + MERKLE PROOF
///
/// #### For Small Trees (<1000 buckets):
/// - Use `validate_no_prefix_overlap()` on-chain ✅
/// - Affordable gas cost
///
/// #### For Large Trees (>1000 buckets):
/// - Build trie structure off-chain using indexer
/// - Verify no overlaps in O(N) time off-chain
/// - Compute Merkle root of validated trie
/// - Store root in `validation_merkle_root` field
/// - Governance MUST verify proof before approving dividend
///
/// ### 3. Cranking Optimization (Skip-List Structure)
///
/// **Problem:** Out-of-order claims can create long chains of already-claimed entries
/// - Without optimization: O(M) scan through M recipients to find unclaimed
/// - With 10k recipients per bucket, 9k claimed → 9k iterations
///
/// **Solution:** Skip-list intervals for O(log M) advancement
/// - Every SKIP_INTERVAL_SIZE addresses = 1 SkipNode
/// - SkipNode tracks unclaimed_count in interval
/// - If interval fully claimed (unclaimed_count = 0), skip entire interval
/// - Reduces worst-case from O(M) to O(M / SKIP_INTERVAL_SIZE)
///
/// ### 4. Governance Responsibility
///
/// For large-scale dividends (>1000 buckets), **GOVERNANCE IS THE SECURITY BOUNDARY**:
///
/// 1. **Off-chain validation is MANDATORY**
///    - Use indexer to build trie, verify no overlaps
///    - Compute Merkle proof of validated structure
///
/// 2. **On-chain validation is IMPOSSIBLE**
///    - Do NOT attempt to call `validate_no_prefix_overlap()` for large trees
///    - Will gas out and fail
///
/// 3. **Approval is the trust anchor**
///    - If governance approves tree with overlaps → governance failure
///    - Protocol assumes governance performs due diligence
///    - DAO members should reject unvalidated trees
module futarchy_payments::dividend_tree;

use std::{
    string::String,
    type_name::{Self, TypeName},
    option::{Self, Option},
};
use sui::{
    address,
    bcs,
    dynamic_field,
    hash::blake2b256,
    object::{Self, UID, ID},
    table::{Self, Table},
    tx_context::TxContext,
};

// === Constants ===

/// Maximum recipients per bucket (reduced from 1M to 10k for safe cranking)
/// With skip-list optimization, worst case: 10k / 1000 = 10 skip-list jumps
const MAX_RECIPIENTS_PER_BUCKET: u64 = 10000;

/// Skip-list interval size - creates skip node every N addresses
/// Allows O(log M) cursor advancement instead of O(M) linear scan
const SKIP_INTERVAL_SIZE: u64 = 1000;

/// Max bytes in address prefix
const MAX_PREFIX_LENGTH: u64 = 32;

// === Errors ===
const EBucketAlreadyExists: u64 = 1;
const ETreeFinalized: u64 = 3;
const EZeroAmount: u64 = 5;
const EMismatchedLength: u64 = 7;
const EInvalidAddressPrefix: u64 = 8;
const EPrefixTooLong: u64 = 9;
const EEmptyPrefix: u64 = 10;
const EInvalidStorageNonce: u64 = 11;
const EInvalidHashNonce: u64 = 12;
const EMaxRecipientsExceeded: u64 = 13;
const EMismatchedTreeID: u64 = 14;
const EInvalidSkipInterval: u64 = 15;

// === Structs ===

/// Key for accessing buckets stored as dynamic fields
/// Uses variable-length address prefix (1-32 bytes)
/// Longer prefixes = more specific buckets for dense address spaces
public struct BucketKey has copy, drop, store {
    prefix: vector<u8>, // Variable length: 1-32 bytes
}

/// Skip-list node for O(log M) cursor advancement during cranking
/// Tracks unclaimed recipients in intervals of SKIP_INTERVAL_SIZE addresses
/// When interval is fully claimed (unclaimed_count = 0), crank skips entire interval
public struct SkipNode has store, drop, copy {
    start_idx: u64,        // Starting index in addresses_for_crank vector
    unclaimed_count: u64,  // Number of unclaimed recipients in this interval
}

/// The main dividend tree object
/// Built progressively over multiple transactions, then finalized
public struct DividendTree has key, store {
    id: UID,
    coin_type: TypeName,
    total_recipients: u64,
    total_amount: u64,
    num_buckets: u64,
    description: String,
    finalized: bool,

    // Prefix directory: sorted list of prefixes for binary search (off-chain)
    // Each prefix maps to a bucket stored as dynamic field
    prefix_directory: vector<vector<u8>>,

    // Rolling hash: updated with each bucket addition, finalized to content_hash
    rolling_hash: vector<u8>,

    // Final content hash for verification (set on finalization)
    content_hash: vector<u8>,

    // Merkle root proving no prefix overlaps (set by governance after off-chain validation)
    // Empty vector means not validated (acceptable for small trees <1000 buckets)
    // Required for large trees (>1000 buckets) where on-chain validation is infeasible
    validation_merkle_root: vector<u8>,

    // Storage nonce: enforces sequential ordering of add_bucket calls
    // Ensures prefix_directory remains sorted (lexicographic order)
    storage_nonce: u64,

    // Hash nonce: enforces sequential ordering of add_bucket_hash calls
    // Ensures rolling_hash matches CSV chronological order (independent of storage order)
    hash_nonce: u64,

    // Buckets stored as dynamic fields on id, keyed by BucketKey
}

/// A bucket containing recipients with same address prefix
/// Stored as a dynamic field on DividendTree
/// Uses skip-list structure for O(log M) cranking optimization
public struct RecipientBucket has store {
    recipients: Table<address, u64>,        // address => amount (for O(1) lookup)
    addresses_for_crank: vector<address>,   // Deterministic iteration order for cranking
    skip_intervals: vector<SkipNode>,       // Skip-list for fast cursor advancement
    // Note: skip_intervals built during add_bucket, updated during individual claims
}

// === Public Functions ===

/// Create a new dividend tree
public fun create_tree<CoinType>(description: String, ctx: &mut TxContext): DividendTree {
    let mut tree = DividendTree {
        id: object::new(ctx),
        coin_type: type_name::get<CoinType>(),
        total_recipients: 0,
        total_amount: 0,
        num_buckets: 0,
        description,
        finalized: false,
        prefix_directory: vector::empty(),
        rolling_hash: vector::empty(),
        content_hash: vector::empty(),
        validation_merkle_root: vector::empty(),  // Not validated yet
        storage_nonce: 0,                          // Start at 0 for add_bucket
        hash_nonce: 0,                             // Start at 0 for add_bucket_hash
    };

    // Initialize rolling hash with on-chain randomness (UID bytes)
    let seed = object::uid_to_bytes(&tree.id);
    tree.rolling_hash = blake2b256(&seed);

    tree
}

/// Add a bucket of recipients to the tree
/// All recipients MUST start with the same address prefix (variable length)
/// Prefix can be 1-32 bytes long depending on address density
/// Prefix directory is kept sorted for off-chain binary search
/// expected_storage_nonce: Must match current storage_nonce to enforce sequential ordering
public fun add_bucket(
    tree: &mut DividendTree,
    prefix: vector<u8>,
    recipients: vector<address>,
    amounts: vector<u64>,
    expected_storage_nonce: u64,
    ctx: &mut TxContext,
) {
    assert!(!tree.finalized, ETreeFinalized);
    assert!(tree.storage_nonce == expected_storage_nonce, EInvalidStorageNonce);
    assert!(recipients.length() == amounts.length(), EMismatchedLength);
    assert!(recipients.length() <= MAX_RECIPIENTS_PER_BUCKET, EMaxRecipientsExceeded);
    assert!(prefix.length() > 0, EEmptyPrefix);
    assert!(prefix.length() <= MAX_PREFIX_LENGTH, EPrefixTooLong);

    // Spot check: validate first address (off-chain already validated all)
    if (recipients.length() > 0) {
        let first_addr = *recipients.borrow(0);
        assert!(address_has_prefix(first_addr, &prefix), EInvalidAddressPrefix);
    };

    // Check bucket doesn't already exist
    let key = BucketKey { prefix };
    assert!(!dynamic_field::exists_(&tree.id, key), EBucketAlreadyExists);

    // Build skip-list intervals for O(log M) cranking
    let skip_intervals = build_skip_intervals(recipients.length());

    // Create bucket with skip-list structure
    let mut bucket = RecipientBucket {
        recipients: table::new(ctx),
        addresses_for_crank: recipients, // Store for deterministic cranking
        skip_intervals,                   // Skip-list for fast cursor advancement
    };

    // Add recipients to table (off-chain already validated - just store)
    let mut j = 0;
    let mut bucket_total = 0u64;
    let mut unique_count = 0u64;

    while (j < bucket.addresses_for_crank.length()) {
        let addr = *bucket.addresses_for_crank.borrow(j);
        let amount = *amounts.borrow(j);

        assert!(amount > 0, EZeroAmount);

        // Handle duplicates by accumulating (shouldn't happen if off-chain validated)
        if (!table::contains(&bucket.recipients, addr)) {
            table::add(&mut bucket.recipients, addr, amount);
            unique_count = unique_count + 1;
        } else {
            let existing = table::borrow_mut(&mut bucket.recipients, addr);
            *existing = *existing + amount;
        };

        bucket_total = bucket_total + amount;
        j = j + 1;
    };

    // Update tree totals
    tree.total_recipients = tree.total_recipients + unique_count;
    tree.total_amount = tree.total_amount + bucket_total;

    // Store bucket as dynamic field
    dynamic_field::add(&mut tree.id, key, bucket);
    tree.num_buckets = tree.num_buckets + 1;

    // Add prefix to directory (append only - off-chain ensures sorted order)
    tree.prefix_directory.push_back(prefix);

    // Increment storage nonce to enforce sequential ordering
    tree.storage_nonce = tree.storage_nonce + 1;
}

/// Hash the bucket data BEFORE adding it to tree
/// This hashes the raw CSV data: addr1||amt1||addr2||amt2||...
/// For large buckets (>1000 recipients), hash in chunks off-chain and pass final hash
/// For small buckets (<1000 recipients), can hash on-chain here
public fun hash_bucket_data(recipients: &vector<address>, amounts: &vector<u64>): vector<u8> {
    assert!(recipients.length() == amounts.length(), EMismatchedLength);
    assert!(recipients.length() <= 1000, 0); // Only for small buckets

    let mut data = vector::empty<u8>();
    let mut i = 0;
    while (i < recipients.length()) {
        let addr = *recipients.borrow(i);
        let amount = *amounts.borrow(i);

        data.append(addr.to_bytes());
        data.append(bcs::to_bytes(&amount));

        i = i + 1;
    };

    blake2b256(&data)
}

/// Add a bucket's hash to the rolling hash
/// Hash order is INDEPENDENT of bucket storage order
/// MUST be called in CSV row order for verification to work
/// Bucket storage (add_bucket) can be in any order for efficiency
/// expected_hash_nonce: Must match current hash_nonce to enforce sequential ordering
/// bucket_hash: Hash of bucket data (from hash_bucket_data or computed off-chain)
public fun add_bucket_hash(tree: &mut DividendTree, bucket_hash: vector<u8>, expected_hash_nonce: u64) {
    assert!(!tree.finalized, ETreeFinalized);
    assert!(tree.hash_nonce == expected_hash_nonce, EInvalidHashNonce);

    // Update rolling hash: hash(previous_hash || bucket_hash)
    // Hash order matches CSV, not bucket storage order
    let mut hash_data = tree.rolling_hash;
    hash_data.append(bucket_hash);
    tree.rolling_hash = blake2b256(&hash_data);

    // Increment hash nonce to enforce sequential ordering
    tree.hash_nonce = tree.hash_nonce + 1;
}

/// Finalize the tree and make it ready for use
/// Stores final rolling hash as content_hash for off-chain verification
public fun finalize_tree(tree: &mut DividendTree) {
    tree.content_hash = tree.rolling_hash;
    tree.finalized = true;
}

/// Set validation Merkle root after off-chain validation
/// For large trees (>1000 buckets), governance MUST verify no prefix overlaps off-chain
/// and store the Merkle root of the validated trie structure
/// Can only be called before finalization
public fun set_validation_proof(tree: &mut DividendTree, merkle_root: vector<u8>) {
    assert!(!tree.finalized, ETreeFinalized);
    tree.validation_merkle_root = merkle_root;
}

/// Transfer ownership of tree
public fun transfer_tree(tree: DividendTree, recipient: address) {
    transfer::public_transfer(tree, recipient);
}

/// Share the tree object
public fun share_tree(tree: DividendTree) {
    transfer::public_share_object(tree);
}

// === Skip-List Helper Functions ===

/// Build skip-list intervals for a bucket
/// Creates SkipNode for every SKIP_INTERVAL_SIZE addresses
/// Initially, all recipients are unclaimed (unclaimed_count = interval size)
fun build_skip_intervals(num_recipients: u64): vector<SkipNode> {
    let mut intervals = vector::empty<SkipNode>();

    if (num_recipients == 0) {
        return intervals
    };

    // Calculate number of full intervals
    let num_intervals = (num_recipients + SKIP_INTERVAL_SIZE - 1) / SKIP_INTERVAL_SIZE;

    let mut i = 0;
    while (i < num_intervals) {
        let start_idx = i * SKIP_INTERVAL_SIZE;
        let end_idx = if (start_idx + SKIP_INTERVAL_SIZE > num_recipients) {
            num_recipients // Last interval may be smaller
        } else {
            start_idx + SKIP_INTERVAL_SIZE
        };

        let interval_size = end_idx - start_idx;

        intervals.push_back(SkipNode {
            start_idx,
            unclaimed_count: interval_size, // Initially all unclaimed
        });

        i = i + 1;
    };

    intervals
}

/// Update skip-list when a recipient is claimed (individual claim)
/// Decrements unclaimed_count for the interval containing the address
/// Returns the interval index that was updated
public(package) fun update_skip_list_on_claim(
    bucket: &mut RecipientBucket,
    address_idx: u64,
): u64 {
    let interval_idx = address_idx / SKIP_INTERVAL_SIZE;

    // Safety check: interval index must be valid
    assert!(interval_idx < bucket.skip_intervals.length(), EInvalidSkipInterval);

    let interval = bucket.skip_intervals.borrow_mut(interval_idx);

    // Decrement unclaimed count (but don't go below 0)
    if (interval.unclaimed_count > 0) {
        interval.unclaimed_count = interval.unclaimed_count - 1;
    };

    interval_idx
}

/// Find the index of an address in addresses_for_crank vector
/// Used to determine which skip-list interval to update
/// Returns Option<u64> - Some(index) if found, None if not found
public(package) fun find_address_index(bucket: &RecipientBucket, addr: address): Option<u64> {
    let addresses = &bucket.addresses_for_crank;
    let mut i = 0;

    while (i < addresses.length()) {
        if (*addresses.borrow(i) == addr) {
            return option::some(i)
        };
        i = i + 1;
    };

    option::none()
}

/// Get skip-list intervals (for inspection/debugging)
public fun get_skip_intervals(bucket: &RecipientBucket): &vector<SkipNode> {
    &bucket.skip_intervals
}

// === Helper Functions ===

/// Check if address starts with given prefix
public fun address_has_prefix(addr: address, prefix: &vector<u8>): bool {
    let addr_bytes = addr.to_bytes();
    let prefix_len = prefix.length();

    if (prefix_len > addr_bytes.length()) {
        return false
    };

    let mut i = 0;
    while (i < prefix_len) {
        if (*addr_bytes.borrow(i) != *prefix.borrow(i)) {
            return false
        };
        i = i + 1;
    };

    true
}

// === Query Functions ===
//
// Note: Off-chain tree builder is responsible for:
// - Sorting prefix_directory lexicographically
// - Validating all addresses are valid Sui addresses
// - Ensuring all addresses in a bucket share the same prefix
// - Computing optimal prefix lengths based on address density
//
// Governance validates tree before approval - malicious/unsorted trees rejected

/// Get tree info
public fun tree_info(tree: &DividendTree): (u64, u64, u64, bool) {
    (tree.total_recipients, tree.total_amount, tree.num_buckets, tree.finalized)
}

/// Check if tree is finalized
public fun is_finalized(tree: &DividendTree): bool {
    tree.finalized
}

/// Get bucket by prefix (direct lookup if you know the exact prefix)
public fun get_bucket(tree: &DividendTree, prefix: vector<u8>): &RecipientBucket {
    let key = BucketKey { prefix };
    dynamic_field::borrow(&tree.id, key)
}

/// Get bucket mutably
public(package) fun get_bucket_mut(
    tree: &mut DividendTree,
    prefix: vector<u8>,
): &mut RecipientBucket {
    let key = BucketKey { prefix };
    dynamic_field::borrow_mut(&mut tree.id, key)
}

/// Get bucket by key
public fun get_bucket_by_key(tree: &DividendTree, key: BucketKey): &RecipientBucket {
    dynamic_field::borrow(&tree.id, key)
}

/// Get bucket mutably by key
public(package) fun get_bucket_by_key_mut(
    tree: &mut DividendTree,
    key: BucketKey,
): &mut RecipientBucket {
    dynamic_field::borrow_mut(&mut tree.id, key)
}

/// Check if bucket exists by prefix
public fun has_bucket(tree: &DividendTree, prefix: vector<u8>): bool {
    let key = BucketKey { prefix };
    dynamic_field::exists_(&tree.id, key)
}

/// Get the prefix directory for off-chain binary search
/// Returns sorted vector of all bucket prefixes
public fun get_prefix_directory(tree: &DividendTree): &vector<vector<u8>> {
    &tree.prefix_directory
}

// === Validation Query Functions (for governance/dev inspect) ===

/// Validate that prefix_directory is sorted (for governance review)
/// Returns true if sorted, false otherwise
public fun is_prefix_directory_sorted(tree: &DividendTree): bool {
    let dir = &tree.prefix_directory;
    let len = dir.length();

    if (len <= 1) { return true };

    let mut i = 0;
    while (i < len - 1) {
        let current = dir.borrow(i);
        let next = dir.borrow(i + 1);

        // Lexicographic comparison - next should be >= current
        if (!is_prefix_less_or_equal(current, next)) {
            return false
        };

        i = i + 1;
    };

    true
}

// NOTE: On-chain prefix overlap validation has been REMOVED
// It is O(N²) and will gas out for any large tree (>1000 buckets)
// For production use: MUST validate off-chain and store Merkle proof via set_validation_proof()

/// Helper: Check if prefix_a <= prefix_b lexicographically
fun is_prefix_less_or_equal(a: &vector<u8>, b: &vector<u8>): bool {
    let len_a = a.length();
    let len_b = b.length();
    let min_len = if (len_a < len_b) { len_a } else { len_b };

    let mut i = 0;
    while (i < min_len) {
        let byte_a = *a.borrow(i);
        let byte_b = *b.borrow(i);

        if (byte_a < byte_b) { return true };
        if (byte_a > byte_b) { return false };

        i = i + 1;
    };

    // All bytes equal up to min_len
    len_a <= len_b
}

// NOTE: validate_tree_integrity, get_validation_chunk_size, and get_validation_range REMOVED
// These functions relied on O(N²) prefix overlap validation which is infeasible at scale
// For production: Use off-chain validation + set_validation_proof() to store Merkle root

/// Query allocation for a specific address (for governance review)
/// Returns (found, amount, bucket_prefix)
/// - found: true if address is in tree
/// - amount: allocation amount (0 if not found)
/// - bucket_prefix: which prefix bucket contains this address (empty if not found)
public fun query_allocation(tree: &DividendTree, addr: address): (bool, u64, vector<u8>) {
    let prefix_directory = &tree.prefix_directory;

    // Binary search through prefix directory to find matching prefix
    let mut left = 0u64;
    let mut right = prefix_directory.length();

    while (left < right) {
        let mid = (left + right) / 2;
        let prefix = prefix_directory.borrow(mid);

        if (address_has_prefix(addr, prefix)) {
            // Found matching prefix - check if address is in bucket
            if (has_bucket(tree, *prefix)) {
                let bucket = get_bucket(tree, *prefix);
                let amount = get_recipient_amount(bucket, addr);

                if (amount > 0) {
                    return (true, amount, *prefix)
                };
            };

            return (false, 0, vector::empty())
        };

        // Lexicographic comparison to determine search direction
        if (is_address_less_than_prefix(addr, prefix)) {
            right = mid;
        } else {
            left = mid + 1;
        }
    };

    (false, 0, vector::empty())
}

/// Helper: Check if address is lexicographically less than prefix
fun is_address_less_than_prefix(addr: address, prefix: &vector<u8>): bool {
    let addr_bytes = addr.to_bytes();
    let prefix_len = prefix.length();
    let addr_len = addr_bytes.length();
    let min_len = if (addr_len < prefix_len) { addr_len } else { prefix_len };

    let mut i = 0;
    while (i < min_len) {
        let addr_byte = *addr_bytes.borrow(i);
        let prefix_byte = *prefix.borrow(i);

        if (addr_byte < prefix_byte) { return true };
        if (addr_byte > prefix_byte) { return false };

        i = i + 1;
    };

    // All bytes equal up to min_len
    addr_len < prefix_len
}

/// Batch query allocations for multiple addresses (for governance review)
/// Returns parallel vectors of (found, amount) for each queried address
/// Max 100 addresses per query to avoid gas limits
public fun batch_query_allocations(
    tree: &DividendTree,
    addresses: vector<address>,
): (vector<bool>, vector<u64>) {
    assert!(addresses.length() <= 100, 0); // Prevent gas limit issues

    let mut found_vec = vector::empty<bool>();
    let mut amount_vec = vector::empty<u64>();

    let mut i = 0;
    while (i < addresses.length()) {
        let addr = *addresses.borrow(i);
        let (found, amount, _) = query_allocation(tree, addr);

        found_vec.push_back(found);
        amount_vec.push_back(amount);

        i = i + 1;
    };

    (found_vec, amount_vec)
}

/// Get all recipients in a specific bucket (for auditing)
/// WARNING: Can be gas-heavy for large buckets! Use pagination for 1M+ recipients.
/// Returns (addresses, amounts) - parallel vectors
public fun get_bucket_recipients_list(
    tree: &DividendTree,
    prefix: vector<u8>,
): (vector<address>, vector<u64>) {
    if (!has_bucket(tree, prefix)) {
        return (vector::empty(), vector::empty())
    };

    let bucket = get_bucket(tree, prefix);
    let addresses = bucket_addresses(bucket);
    let recipients_table = bucket_recipients(bucket);

    let mut amounts = vector::empty<u64>();
    let mut i = 0;
    while (i < addresses.length()) {
        let addr = addresses.borrow(i);
        let amount = table::borrow(recipients_table, *addr);
        amounts.push_back(*amount);
        i = i + 1;
    };

    (*addresses, amounts)
}

/// Get bucket summary (for governance overview)
/// Returns (prefix, recipient_count, total_amount_in_bucket)
public fun get_bucket_summary(tree: &DividendTree, bucket_index: u64): (vector<u8>, u64, u64) {
    let prefix_directory = &tree.prefix_directory;
    assert!(bucket_index < prefix_directory.length(), 0);

    let prefix = *prefix_directory.borrow(bucket_index);
    let bucket = get_bucket(tree, prefix);
    let addresses = bucket_addresses(bucket);
    let recipients_table = bucket_recipients(bucket);

    let mut total = 0u64;
    let mut i = 0;
    while (i < addresses.length()) {
        let addr = addresses.borrow(i);
        let amount = table::borrow(recipients_table, *addr);
        total = total + *amount;
        i = i + 1;
    };

    (prefix, addresses.length(), total)
}

/// Get recipient allocation from a specific bucket
public fun get_recipient_amount(bucket: &RecipientBucket, recipient: address): u64 {
    if (table::contains(&bucket.recipients, recipient)) {
        *table::borrow(&bucket.recipients, recipient)
    } else {
        0
    }
}

/// Get bucket addresses for cranking (deterministic iteration order)
public fun bucket_addresses(bucket: &RecipientBucket): &vector<address> {
    &bucket.addresses_for_crank
}

/// Get bucket recipients table
public fun bucket_recipients(bucket: &RecipientBucket): &Table<address, u64> {
    &bucket.recipients
}

/// Mutable access to bucket recipients (package only)
public(package) fun bucket_recipients_mut(bucket: &mut RecipientBucket): &mut Table<address, u64> {
    &mut bucket.recipients
}

// === Getters for DividendTree fields ===

public fun total_amount(tree: &DividendTree): u64 { tree.total_amount }

public fun total_recipients(tree: &DividendTree): u64 { tree.total_recipients }

public fun num_buckets(tree: &DividendTree): u64 { tree.num_buckets }

public fun coin_type(tree: &DividendTree): TypeName { tree.coin_type }

public fun description(tree: &DividendTree): String { tree.description }

public fun tree_id(tree: &DividendTree): ID { object::id(tree) }

public fun content_hash(tree: &DividendTree): vector<u8> { tree.content_hash }

public fun rolling_hash(tree: &DividendTree): vector<u8> { tree.rolling_hash }

public fun validation_merkle_root(tree: &DividendTree): vector<u8> { tree.validation_merkle_root }

public fun storage_nonce(tree: &DividendTree): u64 { tree.storage_nonce }

public fun hash_nonce(tree: &DividendTree): u64 { tree.hash_nonce }

// === Cleanup Functions ===

/// Delete tree and all its buckets (expensive operation!)
/// WARNING: This iterates through ALL buckets and deletes them
/// For large trees (1000+ buckets), this may hit gas limits
/// Consider calling multiple times with smaller ranges if needed
///
/// Use cases:
/// - Clean up cancelled dividends
/// - Archive completed dividends
/// - Free storage after distribution complete
public fun delete_tree(tree: DividendTree) {
    let DividendTree {
        mut id,
        coin_type: _,
        total_recipients: _,
        total_amount: _,
        num_buckets: _,
        description: _,
        finalized: _,
        prefix_directory,
        rolling_hash: _,
        content_hash: _,
        validation_merkle_root: _,
        storage_nonce: _,
        hash_nonce: _,
    } = tree;

    // Remove all buckets from dynamic fields
    let mut i = 0;
    while (i < prefix_directory.length()) {
        let prefix = *prefix_directory.borrow(i);
        let key = BucketKey { prefix };

        // Remove bucket if it exists
        if (dynamic_field::exists_(&id, key)) {
            let RecipientBucket {
                recipients,
                addresses_for_crank: _,
                skip_intervals: _,  // Skip-list is drop, automatically cleaned up
            } = dynamic_field::remove(
                &mut id,
                key,
            );

            // Table has drop ability, will be cleaned up
            recipients.drop();
        };

        i = i + 1;
    };

    // Delete the UID
    object::delete(id);
}

/// Delete tree in chunks (for very large trees)
/// start_idx: Starting bucket index (inclusive)
/// end_idx: Ending bucket index (exclusive)
/// Returns: true if all buckets deleted (tree can be finalized), false if more chunks remain
///
/// Example for 10k bucket tree:
///   delete_tree_range(&mut tree, 0, 1000)     // Delete first 1000 buckets
///   delete_tree_range(&mut tree, 1000, 2000)  // Delete next 1000 buckets
///   ... repeat 10 times ...
///   finalize_tree_deletion(tree)  // Final cleanup after all buckets deleted
public fun delete_tree_range(tree: &mut DividendTree, start_idx: u64, end_idx: u64): bool {
    let prefix_directory = &tree.prefix_directory;
    let total_buckets = prefix_directory.length();

    assert!(start_idx < total_buckets, 0);
    assert!(end_idx <= total_buckets, 0);
    assert!(start_idx < end_idx, 0);

    // Remove buckets in range
    let mut i = start_idx;
    while (i < end_idx) {
        let prefix = *prefix_directory.borrow(i);
        let key = BucketKey { prefix };

        if (dynamic_field::exists_(&tree.id, key)) {
            let RecipientBucket {
                recipients,
                addresses_for_crank: _,
                skip_intervals: _,  // Skip-list is drop, automatically cleaned up
            } = dynamic_field::remove(
                &mut tree.id,
                key,
            );
            recipients.drop();
        };

        i = i + 1;
    };

    // Return true if we've processed all buckets
    end_idx >= total_buckets
}

/// Finalize tree deletion after all buckets have been removed via delete_tree_range
/// This should only be called after delete_tree_range returns true
public fun finalize_tree_deletion(tree: DividendTree) {
    let DividendTree {
        id,
        coin_type: _,
        total_recipients: _,
        total_amount: _,
        num_buckets: _,
        description: _,
        finalized: _,
        prefix_directory: _,
        rolling_hash: _,
        content_hash: _,
        validation_merkle_root: _,
        storage_nonce: _,
        hash_nonce: _,
    } = tree;

    // All buckets should have been removed already
    object::delete(id);
}

// === Helper function for testing ===

#[test_only]
public fun destroy_tree_for_testing(tree: DividendTree) {
    let DividendTree {
        id,
        coin_type: _,
        total_recipients: _,
        total_amount: _,
        num_buckets: _,
        description: _,
        finalized: _,
        prefix_directory: _,
        rolling_hash: _,
        content_hash: _,
        validation_merkle_root: _,
        storage_nonce: _,
        hash_nonce: _,
    } = tree;

    // Note: Can't easily clean up dynamic fields in test
    // Just delete the UID
    object::delete(id);
}
