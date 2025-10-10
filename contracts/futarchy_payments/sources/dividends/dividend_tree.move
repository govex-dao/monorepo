/// Dividend tree construction module
/// Allows building dividend distributions over multiple transactions
/// Uses address-prefix bucketing for O(1) lookup (256 buckets max)
module futarchy_payments::dividend_tree;

use std::{
    string::String,
    type_name::{Self, TypeName},
};
use sui::{
    object::{Self, UID, ID},
    dynamic_field,
    table::{Self, Table},
    tx_context::TxContext,
    address,
    hash::blake2b256,
    bcs,
};

// === Constants ===
const MAX_RECIPIENTS_PER_BUCKET: u64 = 1000000;  // 1M per bucket (safe with prefix bucketing)
const MAX_PREFIX_LENGTH: u64 = 32;  // Max bytes in address prefix

// === Errors ===
const EBucketAlreadyExists: u64 = 1;
const ETreeFinalized: u64 = 3;
const EZeroAmount: u64 = 5;
const EMismatchedLength: u64 = 7;
const EInvalidAddressPrefix: u64 = 8;
const EPrefixTooLong: u64 = 9;
const EEmptyPrefix: u64 = 10;
const EInvalidNonce: u64 = 11;

// === Structs ===

/// Key for accessing buckets stored as dynamic fields
/// Uses variable-length address prefix (1-32 bytes)
/// Longer prefixes = more specific buckets for dense address spaces
public struct BucketKey has copy, drop, store {
    prefix: vector<u8>,  // Variable length: 1-32 bytes
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
    // Build nonce: forces sequential ordering of operations (add_bucket, add_bucket_hash)
    // Builder must pass expected nonce, increments after each operation
    build_nonce: u64,
    // Buckets stored as dynamic fields on id, keyed by BucketKey
}

/// A bucket containing recipients with same address prefix
/// Stored as a dynamic field on DividendTree
public struct RecipientBucket has store {
    recipients: Table<address, u64>,     // address => amount (for lookup)
    addresses_for_crank: vector<address>, // ONLY for deterministic cranking iteration
    // Note: Addresses stored to enable resumable cranking, not for duplicate lookup
}

// === Public Functions ===

/// Create a new dividend tree
public fun create_tree<CoinType>(
    description: String,
    ctx: &mut TxContext,
): DividendTree {
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
        build_nonce: 0,
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
/// expected_nonce: Must match current build_nonce to enforce sequential ordering
public fun add_bucket(
    tree: &mut DividendTree,
    prefix: vector<u8>,
    recipients: vector<address>,
    amounts: vector<u64>,
    expected_nonce: u64,
    ctx: &mut TxContext,
) {
    assert!(!tree.finalized, ETreeFinalized);
    assert!(tree.build_nonce == expected_nonce, EInvalidNonce);
    assert!(recipients.length() == amounts.length(), EMismatchedLength);
    assert!(recipients.length() <= MAX_RECIPIENTS_PER_BUCKET, 0);
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

    // Create bucket
    let mut bucket = RecipientBucket {
        recipients: table::new(ctx),
        addresses_for_crank: recipients, // Store for deterministic cranking
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

    // Increment nonce to enforce sequential ordering
    tree.build_nonce = tree.build_nonce + 1;
}

/// Hash the bucket data BEFORE adding it to tree
/// This hashes the raw CSV data: addr1||amt1||addr2||amt2||...
/// For large buckets (>1000 recipients), hash in chunks off-chain and pass final hash
/// For small buckets (<1000 recipients), can hash on-chain here
public fun hash_bucket_data(
    recipients: &vector<address>,
    amounts: &vector<u64>,
) : vector<u8> {
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
/// expected_nonce: Must match current build_nonce to enforce sequential ordering
/// bucket_hash: Hash of bucket data (from hash_bucket_data or computed off-chain)
public fun add_bucket_hash(
    tree: &mut DividendTree,
    bucket_hash: vector<u8>,
    expected_nonce: u64,
) {
    assert!(!tree.finalized, ETreeFinalized);
    assert!(tree.build_nonce == expected_nonce, EInvalidNonce);

    // Update rolling hash: hash(previous_hash || bucket_hash)
    // Hash order matches CSV, not bucket storage order
    let mut hash_data = tree.rolling_hash;
    hash_data.append(bucket_hash);
    tree.rolling_hash = blake2b256(&hash_data);

    // Increment nonce to enforce sequential ordering
    tree.build_nonce = tree.build_nonce + 1;
}

/// Finalize the tree and make it ready for use
/// Stores final rolling hash as content_hash for off-chain verification
public fun finalize_tree(tree: &mut DividendTree) {
    tree.content_hash = tree.rolling_hash;
    tree.finalized = true;
}

/// Transfer ownership of tree
public fun transfer_tree(tree: DividendTree, recipient: address) {
    transfer::public_transfer(tree, recipient);
}

/// Share the tree object
public fun share_tree(tree: DividendTree) {
    transfer::public_share_object(tree);
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
    (
        tree.total_recipients,
        tree.total_amount,
        tree.num_buckets,
        tree.finalized,
    )
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
public(package) fun get_bucket_mut(tree: &mut DividendTree, prefix: vector<u8>): &mut RecipientBucket {
    let key = BucketKey { prefix };
    dynamic_field::borrow_mut(&mut tree.id, key)
}

/// Get bucket by key
public fun get_bucket_by_key(tree: &DividendTree, key: BucketKey): &RecipientBucket {
    dynamic_field::borrow(&tree.id, key)
}

/// Get bucket mutably by key
public(package) fun get_bucket_by_key_mut(tree: &mut DividendTree, key: BucketKey): &mut RecipientBucket {
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

/// Validate that no prefix overlaps with another (for governance review)
/// Returns true if no overlaps, false if any prefix is a sub-prefix of another
/// CRITICAL: Overlapping prefixes can make funds inaccessible via query_allocation
/// Example of overlap: 0xab and 0xabc (0xab is prefix of 0xabc)
/// This is expensive (O(n²)) but only run once during governance review
/// NOTE: For trees with >1000 buckets, use validate_no_prefix_overlap_range() instead
public fun validate_no_prefix_overlap(tree: &DividendTree): bool {
    validate_no_prefix_overlap_range(tree, 0, tree.prefix_directory.length())
}

/// Crankable version: Validate prefix overlap for a specific range of buckets
/// Allows splitting validation across multiple dev inspect calls
/// start_idx: Starting bucket index (inclusive)
/// end_idx: Ending bucket index (exclusive)
/// Returns true if no overlaps found in this range check
///
/// Example for 20k buckets:
///   validate_no_prefix_overlap_range(tree, 0, 1000)     // Check buckets 0-999
///   validate_no_prefix_overlap_range(tree, 1000, 2000)  // Check buckets 1000-1999
///   ... repeat 20 times
public fun validate_no_prefix_overlap_range(
    tree: &DividendTree,
    start_idx: u64,
    end_idx: u64
): bool {
    let dir = &tree.prefix_directory;
    let len = dir.length();

    // Validate range bounds
    assert!(start_idx < len, 0);
    assert!(end_idx <= len, 0);
    assert!(start_idx < end_idx, 0);

    if (len <= 1) { return true };

    // For each bucket in range [start_idx, end_idx)
    let mut i = start_idx;
    while (i < end_idx) {
        let prefix_a = dir.borrow(i);

        // Check against ALL other buckets (not just range)
        // This ensures complete validation even when cranking
        let mut j = 0;
        while (j < len) {
            if (i != j) {
                let prefix_b = dir.borrow(j);

                // Check if prefix_a is a prefix of prefix_b (or vice versa)
                if (is_prefix_of(prefix_a, prefix_b) || is_prefix_of(prefix_b, prefix_a)) {
                    return false  // Found overlap
                };
            };

            j = j + 1;
        };

        i = i + 1;
    };

    true
}

/// Helper: Check if prefix_a is a prefix of prefix_b
/// Returns true if prefix_a is a prefix of prefix_b (NOT vice versa)
fun is_prefix_of(prefix_a: &vector<u8>, prefix_b: &vector<u8>): bool {
    let len_a = prefix_a.length();
    let len_b = prefix_b.length();

    // Can't be a prefix if longer
    if (len_a >= len_b) { return false };

    // Check if all bytes of prefix_a match prefix_b
    let mut i = 0;
    while (i < len_a) {
        if (*prefix_a.borrow(i) != *prefix_b.borrow(i)) {
            return false
        };
        i = i + 1;
    };

    true  // All bytes matched, prefix_a is a prefix of prefix_b
}

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

/// Get full tree validation report (for governance UI)
/// Returns (is_sorted, no_overlaps, total_amount, total_recipients, num_buckets)
/// CRITICAL: Both is_sorted and no_overlaps MUST be true for safe dividend distribution
/// NOTE: For trees with >1000 buckets, this may hit gas limits - use range validation instead
public fun validate_tree_integrity(tree: &DividendTree): (bool, bool, u64, u64, u64) {
    (
        is_prefix_directory_sorted(tree),
        validate_no_prefix_overlap(tree),
        tree.total_amount,
        tree.total_recipients,
        tree.num_buckets,
    )
}

/// Calculate recommended chunk size for crankable validation
/// Returns (chunk_size, num_chunks)
/// Example: 20k buckets → (1000, 20) means validate in 20 chunks of 1000 each
public fun get_validation_chunk_size(tree: &DividendTree): (u64, u64) {
    let num_buckets = tree.prefix_directory.length();

    // Target: ~1000 buckets per chunk (safe gas limit)
    let chunk_size = if (num_buckets <= 1000) {
        num_buckets  // Small tree, validate all at once
    } else {
        1000  // Large tree, validate in chunks
    };

    let num_chunks = (num_buckets + chunk_size - 1) / chunk_size;  // Ceiling division

    (chunk_size, num_chunks)
}

/// Get the range for a specific validation chunk
/// chunk_index: Which chunk to validate (0-indexed)
/// Returns (start_idx, end_idx) for validate_no_prefix_overlap_range
public fun get_validation_range(tree: &DividendTree, chunk_index: u64): (u64, u64) {
    let (chunk_size, num_chunks) = get_validation_chunk_size(tree);
    let num_buckets = tree.prefix_directory.length();

    assert!(chunk_index < num_chunks, 0);

    let start_idx = chunk_index * chunk_size;
    let end_idx = if (start_idx + chunk_size > num_buckets) {
        num_buckets  // Last chunk may be smaller
    } else {
        start_idx + chunk_size
    };

    (start_idx, end_idx)
}

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
    addresses: vector<address>
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
    prefix: vector<u8>
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
public fun get_bucket_summary(
    tree: &DividendTree,
    bucket_index: u64
): (vector<u8>, u64, u64) {
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
public fun build_nonce(tree: &DividendTree): u64 { tree.build_nonce }

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
        build_nonce: _,
    } = tree;

    // Remove all buckets from dynamic fields
    let mut i = 0;
    while (i < prefix_directory.length()) {
        let prefix = *prefix_directory.borrow(i);
        let key = BucketKey { prefix };

        // Remove bucket if it exists
        if (dynamic_field::exists_(&id, key)) {
            let RecipientBucket { recipients, addresses_for_crank: _ } =
                dynamic_field::remove(&mut id, key);

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
            let RecipientBucket { recipients, addresses_for_crank: _ } =
                dynamic_field::remove(&mut tree.id, key);
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
        build_nonce: _,
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
        build_nonce: _,
    } = tree;

    // Note: Can't easily clean up dynamic fields in test
    // Just delete the UID
    object::delete(id);
}
