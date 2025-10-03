/// DAO Document Registry - Clean table-based architecture for multi-document management
/// Replaces operating_agreement.move with superior design:
/// - Multiple named documents per DAO (bylaws, policies, code of conduct)
/// - Walrus-backed content storage (100MB per doc vs 200KB on-chain)
/// - O(1) lookups by name or index
/// - All time-based provisions preserved (sunset/sunrise/temporary)
/// - Three-tier policy enforcement (registry/document/chunk)
module futarchy_legal_actions::dao_file_registry;

// === Imports ===
use std::{
    string::{Self, String},
    option::{Self, Option},
    vector,
    hash,
};
use sui::{
    clock::{Self, Clock},
    event,
    table::{Self, Table},
    bag::{Self, Bag},
    object::{Self, ID, UID},
    tx_context::TxContext,
    bcs,
};
use account_protocol::{
    account::{Self, Account},
    version_witness::VersionWitness,
};
use futarchy_core::{
    version,
    futarchy_config::FutarchyConfig,
};
use futarchy_one_shot_utils::constants;
use walrus::blob;

// === Constants ===

// Document limits are now in futarchy_one_shot_utils::constants module
// Access via: constants::max_chunks_per_document(), etc.

// Time limits (100 years in milliseconds)
const MAX_EXPIRY_TIME_MS: u64 = 100 * 365 * 24 * 60 * 60 * 1000;

// Traversal safety limit (prevents infinite loops from cycles in linked lists)
const MAX_TRAVERSAL_LIMIT: u64 = 10000;

// Text chunk size limit (4KB max for on-chain storage)
// Larger content should use Walrus blob storage instead
const MAX_TEXT_CHUNK_BYTES: u64 = 4096;

// Minimum Walrus blob expiry (1 year in epochs, ~365 epochs assuming 1 day per epoch)
// Prevents attackers from creating blobs that expire immediately
const MIN_WALRUS_BLOB_EXPIRY_EPOCHS: u64 = 365;

// Chunk types (preserved from original operating_agreement.move)
const CHUNK_TYPE_PERMANENT: u8 = 0;
const CHUNK_TYPE_SUNSET: u8 = 1;     // Auto-deactivates after expiry
const CHUNK_TYPE_SUNRISE: u8 = 2;    // Activates after effective_from
const CHUNK_TYPE_TEMPORARY: u8 = 3;  // Active only between effective_from and expires_at

// Storage types (XOR enforcement: exactly one must be used)
const STORAGE_TYPE_TEXT: u8 = 0;     // On-chain text storage
const STORAGE_TYPE_WALRUS: u8 = 1;   // Off-chain Walrus blob storage

// === Errors ===
const EInvalidStorageType: u64 = 22; // Storage type must be 0 (text) or 1 (walrus)
const EDocumentNotFound: u64 = 1;
const EDuplicateDocName: u64 = 2;
const ERegistryImmutable: u64 = 3;
const EDocumentImmutable: u64 = 4;
const EChunkNotFound: u64 = 5;
const EInvalidVersion: u64 = 6;
const ETooManyChunks: u64 = 8;
const ETooManyDocuments: u64 = 9;
const EChunkIsImmutable: u64 = 10;
const EInsertNotAllowed: u64 = 11;
const ERemoveNotAllowed: u64 = 12;
const ECannotReEnableInsert: u64 = 13;
const ECannotReEnableRemove: u64 = 14;
const EAlreadyImmutable: u64 = 15;
const EChunkHasNoExpiry: u64 = 16;
const EChunkNotExpired: u64 = 17;
const EInvalidTimeOrder: u64 = 18;
const EAlreadyGloballyImmutable: u64 = 19;
const EExpiryTooFarInFuture: u64 = 21;
const ECannotMakeImmutableBeforeScheduled: u64 = 25;
const EEmptyWalrusBlobId: u64 = 23;
const ETraversalLimitExceeded: u64 = 24;
const ETextChunkTooLarge: u64 = 26;
const EConcurrentEditConflict: u64 = 27;
const ERemovalRequiredForTemporaryChunk: u64 = 28;
const EWalrusBlobExpiryTooSoon: u64 = 30;
const EInvalidChunkType: u64 = 31; // Chunk type must be 0 (permanent), 1 (sunset), 2 (sunrise), or 3 (temporary)

// === Type Keys for Dynamic Fields ===

/// Key for storing the registry in the Account
public struct RegistryKey has copy, drop, store {}

public fun new_registry_key(): RegistryKey {
    RegistryKey {}
}

// === Core Structs ===

/// Main registry stored in Account - tracks all documents for a DAO
/// Simple flat list of documents (max 1000 per DAO)
public struct DaoFileRegistry has store {
    dao_id: ID,

    // Document storage (owned File objects)
    documents: bag::Bag,                    // ID → File (owned storage)

    // Simple document lookup
    docs_by_name: Table<String, ID>,        // "bylaws" → doc_id
    docs_by_index: Table<u64, ID>,          // Ordered display (0, 1, 2, ...)
    doc_names: vector<String>,              // ["bylaws", "code-of-conduct", ...]

    next_index: u64,

    // Global immutability (locks entire registry - nuclear option)
    immutable: bool,
}

/// Individual document (owned object stored in Account)
/// Readable by anyone via RPC, but only DAO can mutate
public struct File has store {
    id: UID,
    dao_id: ID,

    // Identity
    name: String,                           // "bylaws", "code-of-conduct"
    index: u64,                             // Position in registry
    creation_time: u64,

    // Content (Walrus-backed chunks in linked list)
    chunks: Table<ID, ChunkPointer>,       // chunk_id → ChunkPointer
    chunk_count: u64,
    head_chunk: Option<ID>,                // First chunk ID (None when empty)
    tail_chunk: Option<ID>,                // Last chunk ID for O(1) append

    // Document-level controls (one-way locks)
    allow_insert: bool,                     // Can add new chunks
    allow_remove: bool,                     // Can remove chunks
    immutable: bool,                        // Document-level immutability

    // Concurrency control (optimistic locking via edit sequence)
    // Replaced content_hash with edit_sequence for 99% gas reduction
    edit_sequence: u64,                     // Increments on every mutation (add/update/remove/policy change)
}

/// Chunk pointer to Walrus blob (content stored off-chain)
/// Chunks = sections of current document (Article I, Article II, Schedule A, etc.)
///
/// IMPORTANT: Stores the Walrus Blob object directly (not just ID)
/// Storage: EXACTLY ONE OF text OR walrus_blob (never both, never neither)
/// - storage_type enforces this invariant
/// - Text for small content (< 4KB recommended)
/// - Blob for large content or content needing off-chain storage
///
/// Linked List: next_chunk and prev_chunk create doubly-linked document ordering
/// - Enables indexer reconstruction (start at head, follow next_chunk)
/// - Supports O(1) insertion and removal (no traversal needed)
/// - Supports insertion between chunks (insert Article 1.5 between 1 and 2)
/// - None = final/first chunk in document
public struct ChunkPointer has store {
    id: UID,                                // Unique chunk identifier

    // DOUBLY-LINKED LIST: Document ordering (O(1) insert/remove)
    prev_chunk: Option<ID>,                 // Previous chunk ID, None = first
    next_chunk: Option<ID>,                 // Next chunk ID, None = final

    // STORAGE: Exactly one must be populated
    storage_type: u8,                       // 0 = Text, 1 = Walrus Blob

    // Option 1: Text storage (when storage_type == 0)
    text: Option<String>,                   // On-chain text content

    // Option 2: Walrus storage (when storage_type == 1)
    walrus_blob: Option<walrus::blob::Blob>, // Off-chain Walrus blob
    walrus_storage_object_id: Option<ID>,   // Storage object ID for renewal
    walrus_expiry_epoch: Option<u64>,       // Cached expiry epoch for quick lookup

    // Immutability controls
    immutable: bool,                        // Permanent immutability (one-way: false → true)
    immutable_from: Option<u64>,           // Scheduled immutability (timestamp in ms)

    // Time-based provisions (PRESERVED FROM OPERATING AGREEMENT)
    chunk_type: u8,                         // 0=permanent, 1=sunset, 2=sunrise, 3=temporary
    expires_at: Option<u64>,               // When this chunk becomes inactive (document-level)
    effective_from: Option<u64>,           // When this chunk becomes active (document-level)
}

// === Three-Tier Immutability System ===
//
// Level 1: Chunk-level immutability (ChunkPointer.immutable)
//   - Individual chunks can be locked independently
//   - Surgical control over which parts of a document cannot change
//
// Level 2: Document-level immutability (Document.immutable)
//   - Entire document becomes read-only
//   - All chunks become immutable when set
//
// Level 3: Registry-level immutability (DaoFileRegistry.immutable)
//   - Nuclear option: entire registry becomes read-only
//   - All documents and all chunks become immutable
//
// All three levels are ONE-WAY: false → true (cannot be reversed)

// === Batch Operations ===

/// Enum-like struct for different chunk actions that can be batched
/// Wraps individual operations for atomic multi-step modifications
///
/// NOTE: No UPDATE action - always use remove + add pattern for replacements
/// This is simpler and works for both text and Walrus blob chunks
public struct ChunkAction has store, drop, copy {
    action_type: u8,  // 0=add, 2=remove, 3=set_immutable, 4=insert_after

    // Common fields
    doc_id: ID,
    chunk_id: Option<ID>,  // None for add operations

    // For insert_after
    prev_chunk_id: Option<ID>,  // Which chunk to insert after

    // For add/insert operations
    text: Option<String>,
    chunk_type: Option<u8>,
    expires_at: Option<u64>,
    effective_from: Option<u64>,
    immutable: Option<bool>,
    immutable_from: Option<u64>,
}

// Action type constants
const ACTION_ADD_CHUNK: u8 = 0;
// ACTION_UPDATE_CHUNK = 1 is REMOVED - use remove + add pattern instead
const ACTION_REMOVE_CHUNK: u8 = 2;
const ACTION_SET_CHUNK_IMMUTABLE: u8 = 3;
const ACTION_INSERT_AFTER: u8 = 4;

/// Batch action for multiple document operations
/// Enables atomic multi-step edits (e.g., remove old article, insert new one)
public struct BatchDocAction has store, drop, copy {
    batch_id: ID,  // Unique ID for this batch
    actions: vector<ChunkAction>,
}

// === Events ===

public struct RegistryCreated has copy, drop {
    dao_id: ID,
    timestamp_ms: u64,
}

public struct DocumentCreated has copy, drop {
    dao_id: ID,
    doc_id: ID,
    name: String,
    timestamp_ms: u64,
}

public struct ChunkAdded has copy, drop {
    dao_id: ID,
    doc_id: ID,
    chunk_id: ID,
    walrus_blob_id: vector<u8>,  // For events, emit the ID as bytes
    chunk_type: u8,
    expires_at: Option<u64>,
    effective_from: Option<u64>,
    immutable_from: Option<u64>,
    position_after: Option<ID>,  // Which chunk this was inserted after (None = head/append)
    timestamp_ms: u64,
}

public struct ChunkUpdated has copy, drop {
    dao_id: ID,
    doc_id: ID,
    chunk_id: ID,
    old_walrus_blob_id: vector<u8>,
    new_walrus_blob_id: vector<u8>,
    timestamp_ms: u64,
}

public struct ChunkTextUpdated has copy, drop {
    dao_id: ID,
    doc_id: ID,
    chunk_id: ID,
    timestamp_ms: u64,
}

public struct ChunkRemoved has copy, drop {
    dao_id: ID,
    doc_id: ID,
    chunk_id: ID,
    timestamp_ms: u64,
}

public struct ChunkImmutabilityChanged has copy, drop {
    dao_id: ID,
    doc_id: ID,
    chunk_id: ID,
    immutable: bool,
    timestamp_ms: u64,
}

public struct DocumentImmutabilityChanged has copy, drop {
    dao_id: ID,
    doc_id: ID,
    immutable: bool,
    timestamp_ms: u64,
}

public struct RegistryImmutabilityChanged has copy, drop {
    dao_id: ID,
    immutable: bool,
    timestamp_ms: u64,
}

public struct DocumentPolicyChanged has copy, drop {
    dao_id: ID,
    doc_id: ID,
    allow_insert: bool,
    allow_remove: bool,
    timestamp_ms: u64,
}

public struct DocumentRead has copy, drop {
    dao_id: ID,
    doc_id: ID,
    name: String,
    chunk_count: u64,
    chunk_blob_ids: vector<vector<u8>>,
    allow_insert: bool,
    allow_remove: bool,
    immutable: bool,
    timestamp_ms: u64,
}

/// Complete document snapshot with all chunk details (mirrors OA's AgreementReadWithStatus)
/// Includes on-chain text for text chunks and blob IDs for Walrus chunks
/// Provides full reconstruction for indexers and UI clients
public struct DocumentReadWithStatus has copy, drop {
    dao_id: ID,
    doc_id: ID,
    name: String,

    // Chunk details in document order
    chunk_ids: vector<ID>,                  // Ordered chunk IDs
    chunk_texts: vector<Option<String>>,    // On-chain text (when storage_type == TEXT)
    chunk_blob_ids: vector<vector<u8>>,     // Walrus blob IDs (when storage_type == WALRUS)
    chunk_storage_types: vector<u8>,        // 0 = text, 1 = walrus
    chunk_immutables: vector<bool>,         // Permanent immutability flags
    chunk_immutable_froms: vector<Option<u64>>, // Scheduled immutability timestamps
    chunk_types: vector<u8>,                // 0=permanent, 1=sunset, 2=sunrise, 3=temporary
    chunk_expires_ats: vector<Option<u64>>, // Expiry timestamps
    chunk_effective_froms: vector<Option<u64>>, // Activation timestamps
    chunk_active_statuses: vector<bool>,    // Active at current time based on time constraints

    // Document-level policy
    allow_insert: bool,
    allow_remove: bool,
    immutable: bool,

    timestamp_ms: u64,
}

public struct WalrusExpiryUpdated has copy, drop {
    dao_id: ID,
    doc_id: ID,
    chunk_id: ID,
    new_expiry_epoch: u64,
    timestamp_ms: u64,
}

public struct WalrusStorageBound has copy, drop {
    dao_id: ID,
    doc_id: ID,
    chunk_id: ID,
    storage_object_id: ID,
    expiry_epoch: u64,
    timestamp_ms: u64,
}

// Removed FrozenDocument-related events (not needed with 3-tier immutability)

// === Registry Management ===

/// Create new registry for a DAO
public fun create_registry(
    dao_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
): DaoFileRegistry {
    event::emit(RegistryCreated {
        dao_id,
        timestamp_ms: clock.timestamp_ms(),
    });

    DaoFileRegistry {
        dao_id,
        documents: bag::new(ctx),
        docs_by_name: table::new(ctx),
        docs_by_index: table::new(ctx),
        doc_names: vector::empty(),
        next_index: 0,
        immutable: false,
    }
}

/// Store registry in Account
public fun store_in_account<Config: store>(
    account: &mut Account<Config>,
    registry: DaoFileRegistry,
    version_witness: VersionWitness,
) {
    account::add_managed_data(account, RegistryKey {}, registry, version_witness);
}

/// Get immutable reference to registry from Account
public fun get_registry<Config: store>(
    account: &Account<Config>,
    version_witness: VersionWitness,
): &DaoFileRegistry {
    account::borrow_managed_data(account, RegistryKey {}, version_witness)
}

/// Get mutable reference to registry from Account
public fun get_registry_mut<Config: store>(
    account: &mut Account<Config>,
    version_witness: VersionWitness,
): &mut DaoFileRegistry {
    account::borrow_managed_data_mut(account, RegistryKey {}, version_witness)
}

/// Check if account has a registry
public fun has_registry<Config: store>(
    account: &Account<Config>,
): bool {
    account::has_managed_data<Config, RegistryKey>(account, RegistryKey {})
}

// === Document Access (from Bag) ===

/// Borrow immutable reference to File from registry's Bag
public fun borrow_file(registry: &DaoFileRegistry, doc_id: ID): &File {
    bag::borrow(&registry.documents, doc_id)
}

/// Borrow mutable reference to File from registry's Bag
public fun borrow_file_mut(registry: &mut DaoFileRegistry, doc_id: ID): &mut File {
    bag::borrow_mut(&mut registry.documents, doc_id)
}

/// Get File ID (File doesn't have `key` ability, so object::id() doesn't work)
public fun get_file_id(doc: &File): ID {
    object::uid_to_inner(&doc.id)
}

// === Batch Operations Support ===
// Files are owned objects (store in Bag), so we can temporarily remove them for batch operations
//
// Example PTB usage:
// ```typescript
// const tx = new TransactionBlock();
//
// // 1. Borrow file from registry (removes from Bag)
// const file = tx.moveCall({
//   target: `${PACKAGE}::dao_file_registry::borrow_file_for_batch`,
//   arguments: [registry, docId]
// });
//
// // 2. Create batch actions
// const actions = [
//   { action_type: 2, doc_id, chunk_id: oldChunkId, ... },  // Remove old chunk
//   { action_type: 0, doc_id, text: newText, ... },         // Add new chunk
// ];
//
// // 3. Execute batch on borrowed file
// tx.moveCall({
//   target: `${PACKAGE}::dao_file_registry::apply_batch_to_file`,
//   arguments: [file, actions, expectedSequence, clock, ctx]
// });
//
// // 4. Return file to registry (adds back to Bag)
// tx.moveCall({
//   target: `${PACKAGE}::dao_file_registry::return_file_after_batch`,
//   arguments: [registry, file]
// });
// ```

/// Borrow File by value from registry for batch operations
/// Must be returned with return_file_after_batch() in same transaction
/// IMPORTANT: PTB ensures atomicity - if any step fails, entire transaction reverts
public fun borrow_file_for_batch(registry: &mut DaoFileRegistry, doc_id: ID): File {
    bag::remove(&mut registry.documents, doc_id)
}

/// Return File to registry after batch operations
/// IMPORTANT: Must be called in same transaction as borrow_file_for_batch()
/// Otherwise the File will be lost (orphaned from registry)
public fun return_file_after_batch(registry: &mut DaoFileRegistry, doc: File) {
    let doc_id = object::uid_to_inner(&doc.id);
    bag::add(&mut registry.documents, doc_id, doc);
}

// === Document Creation ===

/// Create root document (top-level like "bylaws")
/// Stores File in registry's Bag
public fun create_root_document(
    registry: &mut DaoFileRegistry,
    name: String,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Check registry not immutable
    assert!(!registry.immutable, ERegistryImmutable);

    // Check name uniqueness
    assert!(!table::contains(&registry.docs_by_name, name), EDuplicateDocName);

    // Check document limit
    assert!(registry.next_index < constants::max_documents_per_dao(), ETooManyDocuments);

    let doc_uid = object::new(ctx);
    let doc_id = object::uid_to_inner(&doc_uid);

    let doc = File {
        id: doc_uid,
        dao_id: registry.dao_id,
        name,
        index: registry.next_index,
        creation_time: clock.timestamp_ms(),
        chunks: table::new(ctx),
        chunk_count: 0,
        head_chunk: option::none(),      // No chunks yet
        tail_chunk: option::none(),
        allow_insert: true,
        allow_remove: true,
        immutable: false,
        edit_sequence: 0,  // Initialize sequence counter
    };

    // Update registry indexes
    vector::push_back(&mut registry.doc_names, name);
    table::add(&mut registry.docs_by_name, name, doc_id);
    table::add(&mut registry.docs_by_index, registry.next_index, doc_id);
    registry.next_index = registry.next_index + 1;

    event::emit(DocumentCreated {
        dao_id: registry.dao_id,
        doc_id,
        name,
        timestamp_ms: clock.timestamp_ms(),
    });

    // Store document in registry's Bag (owned storage)
    bag::add(&mut registry.documents, doc_id, doc);

    doc_id
}

// Version system and parent-child hierarchy removed - not needed for this use case

// === Unshared Document Creation (For Large Document Construction) ===

/// Create document as owned object (Phase 1: Private staging)
/// Returns unshared Document for multi-transaction construction
/// Proposer can build document incrementally over multiple transactions
/// Document is NOT shared, so no one else can modify it during construction
// Removed FrozenDocument functions - not needed with 3-tier immutability system

// === Concurrency Control Helpers ===

/// Validate expected edit sequence and increment for next mutation
/// This prevents race conditions when multiple transactions try to edit the same document
/// OPTIMIZATION: Replaced O(N) content hashing with O(1) sequence counter (99% gas reduction)
fun expect_sequence_and_increment(doc: &mut File, expected_sequence: u64) {
    assert!(doc.edit_sequence == expected_sequence, EConcurrentEditConflict);
    doc.edit_sequence = doc.edit_sequence + 1;
}

/// Get current edit sequence (for clients to pass back in next mutation)
public fun get_edit_sequence(doc: &File): u64 {
    doc.edit_sequence
}

/// Validate text size limit
fun validate_text_size(text: &String) {
    let byte_length = std::string::length(text);
    assert!(byte_length <= MAX_TEXT_CHUNK_BYTES, ETextChunkTooLarge);
}

/// Storage XOR invariant: exactly one of text or walrus blob must be populated
/// This is a critical safety invariant that prevents invalid chunk states
fun assert_storage_xor(storage_type: u8, has_text: bool, has_blob: bool) {
    let text_mode = storage_type == STORAGE_TYPE_TEXT;
    let blob_mode = storage_type == STORAGE_TYPE_WALRUS;
    assert!(text_mode || blob_mode, EInvalidStorageType);
    // Exactly one of (text, blob) must be present
    assert!((text_mode && has_text && !has_blob) || (blob_mode && !has_text && has_blob), EInvalidStorageType);
}

/// Helper function to append chunk to doubly-linked list
/// Reduces code duplication across all add_* functions
/// Returns the previous chunk ID (for linking)
fun append_chunk_internal(doc: &mut File, chunk_id: ID): Option<ID> {
    let prev_id = if (option::is_some(&doc.tail_chunk)) {
        let tail_id = *option::borrow(&doc.tail_chunk);
        let tail_chunk = table::borrow_mut(&mut doc.chunks, tail_id);
        tail_chunk.next_chunk = option::some(chunk_id);
        option::some(tail_id)
    } else {
        // First chunk - set as head
        doc.head_chunk = option::some(chunk_id);
        option::none()
    };

    doc.chunk_count = doc.chunk_count + 1;
    doc.tail_chunk = option::some(chunk_id); // Update tail

    // Return prev_id for ChunkPointer construction
    prev_id
}

// === Validation Helpers (DRY) ===

/// Common validation for chunk insertion (used by all add_chunk variants)
fun validate_chunk_insertion(
    doc: &File,
    chunk_type: u8,
    expires_at: &Option<u64>,
    effective_from: &Option<u64>,
    immutable: bool,
    immutable_from: &Option<u64>,
    clock: &Clock,
) {
    // Check document not immutable
    assert!(!doc.immutable, EDocumentImmutable);
    assert!(doc.allow_insert, EInsertNotAllowed);
    assert!(doc.chunk_count < constants::max_chunks_per_document(), ETooManyChunks);

    // Validate scheduled immutability
    let now = clock.timestamp_ms();
    if (option::is_some(immutable_from)) {
        let imm_from = *option::borrow(immutable_from);
        assert!(imm_from > now, EInvalidTimeOrder);
        assert!(imm_from <= now + MAX_EXPIRY_TIME_MS, EExpiryTooFarInFuture);
        // Cannot set both immediate and scheduled immutability
        assert!(!immutable, EInvalidTimeOrder);
    };

    // Validate time windows based on chunk type
    if (chunk_type == CHUNK_TYPE_PERMANENT) {
        // Permanent chunks must not have time windows
        assert!(option::is_none(expires_at), EInvalidTimeOrder);
        assert!(option::is_none(effective_from), EInvalidTimeOrder);
    } else if (chunk_type == CHUNK_TYPE_SUNSET) {
        // Sunset chunks must have expires_at but not effective_from
        assert!(option::is_some(expires_at), EChunkHasNoExpiry);
        assert!(option::is_none(effective_from), EInvalidTimeOrder);
        let exp = *option::borrow(expires_at);
        assert!(exp > now, EInvalidTimeOrder);
        assert!(exp <= now + MAX_EXPIRY_TIME_MS, EExpiryTooFarInFuture);
        assert!(doc.allow_remove, ERemoveNotAllowed);
    } else if (chunk_type == CHUNK_TYPE_SUNRISE) {
        // Sunrise chunks must have effective_from but not expires_at
        assert!(option::is_some(effective_from), EInvalidTimeOrder);
        assert!(option::is_none(expires_at), EInvalidTimeOrder);
    } else if (chunk_type == CHUNK_TYPE_TEMPORARY) {
        // Temporary chunks must have both time windows
        assert!(option::is_some(expires_at) && option::is_some(effective_from), EInvalidTimeOrder);
        let exp = *option::borrow(expires_at);
        let eff = *option::borrow(effective_from);
        assert!(eff < exp, EInvalidTimeOrder);
        assert!(exp <= now + MAX_EXPIRY_TIME_MS, EExpiryTooFarInFuture);
        assert!(doc.allow_remove, ERemovalRequiredForTemporaryChunk);
    } else {
        // Invalid chunk type (must be 0, 1, 2, or 3)
        abort EInvalidChunkType
    };
}

// === Chunk Operations ===

/// Add chunk with Walrus blob storage
/// Takes ownership of Walrus Blob object (cheap - just metadata, not content)
/// Supports all chunk types via optional time window parameters
/// immutable_from: Optional timestamp when chunk becomes immutable (scheduled immutability)
public fun add_chunk(
    doc: &mut File,
    expected_sequence: u64,
    walrus_blob: blob::Blob,
    chunk_type: u8,
    expires_at: Option<u64>,
    effective_from: Option<u64>,
    immutable: bool,
    immutable_from: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Validate sequence (optimistic locking)
    expect_sequence_and_increment(doc, expected_sequence);

    // Common validation (DRY)
    validate_chunk_insertion(doc, chunk_type, &expires_at, &effective_from, immutable, &immutable_from, clock);

    // Create UID for chunk
    let chunk_uid = object::new(ctx);
    let chunk_id = object::uid_to_inner(&chunk_uid);

    let blob_id = blob::blob_id(&walrus_blob);
    let expiry_epoch = blob::end_epoch(&walrus_blob) as u64;

    // Validate blob expiry (minimum 1 year to prevent immediate expiration attacks)
    let current_epoch = ctx.epoch();
    assert!(expiry_epoch >= current_epoch + MIN_WALRUS_BLOB_EXPIRY_EPOCHS, EWalrusBlobExpiryTooSoon);

    // Validate storage XOR invariant BEFORE construction (to avoid ownership issues)
    assert_storage_xor(STORAGE_TYPE_WALRUS, false, true);

    // Append to doubly-linked list and get prev_id
    let prev_id = append_chunk_internal(doc, chunk_id);
    let position_after = prev_id; // Same value for event

    let chunk = ChunkPointer {
        id: chunk_uid,
        prev_chunk: prev_id,
        next_chunk: option::none(),
        storage_type: STORAGE_TYPE_WALRUS,
        text: option::none(),
        walrus_blob: option::some(walrus_blob),
        walrus_storage_object_id: option::none(),
        walrus_expiry_epoch: option::some(expiry_epoch),
        immutable,
        immutable_from,
        chunk_type,
        expires_at,
        effective_from,
    };

    table::add(&mut doc.chunks, chunk_id, chunk);

    // Recalculate and update hash
    // edit_sequence already incremented

    event::emit(ChunkAdded {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id,
        walrus_blob_id: bcs::to_bytes(&blob_id),
        chunk_type,
        expires_at,
        effective_from,
        immutable_from,
        position_after,
        timestamp_ms: clock.timestamp_ms(),
    });

    chunk_id
}

/// Add chunk with text storage (for small content, operating agreement lines)
/// Supports all chunk types via optional time window parameters
public fun add_chunk_with_text(
    doc: &mut File,
    expected_sequence: u64,
    text: String,
    chunk_type: u8,
    expires_at: Option<u64>,
    effective_from: Option<u64>,
    immutable: bool,
    immutable_from: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Validate text size and sequence
    validate_text_size(&text);
    expect_sequence_and_increment(doc, expected_sequence);

    // Common validation (DRY)
    validate_chunk_insertion(doc, chunk_type, &expires_at, &effective_from, immutable, &immutable_from, clock);

    // Create UID for chunk
    let chunk_uid = object::new(ctx);
    let chunk_id = object::uid_to_inner(&chunk_uid);

    // Validate storage XOR invariant BEFORE construction
    assert_storage_xor(STORAGE_TYPE_TEXT, true, false);

    // Append to doubly-linked list and get prev_id
    let prev_id = append_chunk_internal(doc, chunk_id);
    let position_after = prev_id; // Same value for event

    let chunk = ChunkPointer {
        id: chunk_uid,
        prev_chunk: prev_id,
        next_chunk: option::none(),
        storage_type: STORAGE_TYPE_TEXT,
        text: option::some(text),
        walrus_blob: option::none(),
        walrus_storage_object_id: option::none(),
        walrus_expiry_epoch: option::none(),
        immutable,
        immutable_from,
        chunk_type,
        expires_at,
        effective_from,
    };

    table::add(&mut doc.chunks, chunk_id, chunk);

    // Recalculate and update hash
    // edit_sequence already incremented

    event::emit(ChunkAdded {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id,
        walrus_blob_id: vector::empty(), // No blob for text storage
        chunk_type,
        expires_at,
        effective_from,
        immutable_from,
        position_after,
        timestamp_ms: clock.timestamp_ms(),
    });

    chunk_id
}

/// Insert chunk after a specific position (for mid-document edits like "Article 1.5")
/// This is essential for precise legal document amendments
public fun insert_chunk_after(
    doc: &mut File,
    expected_sequence: u64,
    prev_chunk_id: ID,
    walrus_blob: blob::Blob,
    chunk_type: u8,
    expires_at: Option<u64>,
    effective_from: Option<u64>,
    immutable: bool,
    immutable_from: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Validate sequence and increment
    expect_sequence_and_increment(doc, expected_sequence);

    // Validate chunk insertion using helper function
    validate_chunk_insertion(doc, chunk_type, &expires_at, &effective_from, immutable, &immutable_from, clock);

    // Additional validation specific to insert_after
    assert!(table::contains(&doc.chunks, prev_chunk_id), EChunkNotFound);

    let new_chunk_uid = object::new(ctx);
    let new_chunk_id = object::uid_to_inner(&new_chunk_uid);
    let blob_id = blob::blob_id(&walrus_blob);
    let expiry_epoch = blob::end_epoch(&walrus_blob) as u64;

    // Validate blob expiry (minimum 1 year to prevent immediate expiration attacks)
    let current_epoch = ctx.epoch();
    assert!(expiry_epoch >= current_epoch + MIN_WALRUS_BLOB_EXPIRY_EPOCHS, EWalrusBlobExpiryTooSoon);

    // Get the previous chunk's next pointer
    let prev_chunk = table::borrow_mut(&mut doc.chunks, prev_chunk_id);
    let old_next = prev_chunk.next_chunk;

    // Update previous chunk to point to new chunk
    prev_chunk.next_chunk = option::some(new_chunk_id);

    // If inserting at the end, update tail
    if (option::is_none(&old_next)) {
        doc.tail_chunk = option::some(new_chunk_id);
    } else {
        // Update next chunk's prev pointer
        let next_id = *option::borrow(&old_next);
        let next_chunk = table::borrow_mut(&mut doc.chunks, next_id);
        next_chunk.prev_chunk = option::some(new_chunk_id);
    };

    // Validate storage XOR invariant BEFORE construction
    assert_storage_xor(STORAGE_TYPE_WALRUS, false, true);

    // Create new chunk with both prev and next pointers
    let new_chunk = ChunkPointer {
        id: new_chunk_uid,
        prev_chunk: option::some(prev_chunk_id),  // Link to previous
        next_chunk: old_next,                      // Link to next (or none)
        storage_type: STORAGE_TYPE_WALRUS,
        text: option::none(),
        walrus_blob: option::some(walrus_blob),
        walrus_storage_object_id: option::none(),
        walrus_expiry_epoch: option::some(expiry_epoch),
        immutable,
        immutable_from,
        chunk_type,
        expires_at,
        effective_from,
    };

    table::add(&mut doc.chunks, new_chunk_id, new_chunk);
    doc.chunk_count = doc.chunk_count + 1;

    // Recalculate and update hash
    // edit_sequence already incremented

    event::emit(ChunkAdded {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id: new_chunk_id,
        walrus_blob_id: bcs::to_bytes(&blob_id),
        chunk_type,
        expires_at,
        effective_from,
        immutable_from,
        position_after: option::some(prev_chunk_id),
        timestamp_ms: clock.timestamp_ms(),
    });

    new_chunk_id
}

/// Insert chunk with text after a specific position
public fun insert_chunk_with_text_after(
    doc: &mut File,
    expected_sequence: u64,
    prev_chunk_id: ID,
    text: String,
    chunk_type: u8,
    expires_at: Option<u64>,
    effective_from: Option<u64>,
    immutable: bool,
    immutable_from: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Validate text size and sequence
    validate_text_size(&text);
    expect_sequence_and_increment(doc, expected_sequence);

    // Validate chunk insertion using helper function
    validate_chunk_insertion(doc, chunk_type, &expires_at, &effective_from, immutable, &immutable_from, clock);

    // Additional validation specific to insert_after
    assert!(table::contains(&doc.chunks, prev_chunk_id), EChunkNotFound);

    let new_chunk_uid = object::new(ctx);
    let new_chunk_id = object::uid_to_inner(&new_chunk_uid);

    // Get the previous chunk's next pointer
    let prev_chunk = table::borrow_mut(&mut doc.chunks, prev_chunk_id);
    let old_next = prev_chunk.next_chunk;
    prev_chunk.next_chunk = option::some(new_chunk_id);

    // If inserting at the end, update tail
    if (option::is_none(&old_next)) {
        doc.tail_chunk = option::some(new_chunk_id);
    } else {
        // Update next chunk's prev pointer
        let next_id = *option::borrow(&old_next);
        let next_chunk = table::borrow_mut(&mut doc.chunks, next_id);
        next_chunk.prev_chunk = option::some(new_chunk_id);
    };

    // Validate storage XOR invariant BEFORE construction
    assert_storage_xor(STORAGE_TYPE_TEXT, true, false);

    // Create new chunk with text
    let new_chunk = ChunkPointer {
        id: new_chunk_uid,
        prev_chunk: option::some(prev_chunk_id),
        next_chunk: old_next,
        storage_type: STORAGE_TYPE_TEXT,
        text: option::some(text),
        walrus_blob: option::none(),
        walrus_storage_object_id: option::none(),
        walrus_expiry_epoch: option::none(),
        immutable,
        immutable_from,
        chunk_type,
        expires_at,
        effective_from,
    };

    table::add(&mut doc.chunks, new_chunk_id, new_chunk);
    doc.chunk_count = doc.chunk_count + 1;

    // Recalculate and update hash
    // edit_sequence already incremented

    event::emit(ChunkAdded {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id: new_chunk_id,
        walrus_blob_id: vector::empty(),
        chunk_type,
        expires_at,
        effective_from,
        immutable_from,
        position_after: option::some(prev_chunk_id),
        timestamp_ms: clock.timestamp_ms(),
    });

    new_chunk_id
}

/// Insert Walrus chunk at the beginning of the document
/// Updates head_chunk and fixes old head's prev_chunk pointer
public fun insert_chunk_at_beginning(
    doc: &mut File,
    expected_sequence: u64,
    walrus_blob: walrus::blob::Blob,
    chunk_type: u8,
    expires_at: Option<u64>,
    effective_from: Option<u64>,
    immutable: bool,
    immutable_from: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Validate sequence and blob
    expect_sequence_and_increment(doc, expected_sequence);
    let expiry_epoch = blob::end_epoch(&walrus_blob) as u64;

    // Validate chunk insertion using helper function
    validate_chunk_insertion(doc, chunk_type, &expires_at, &effective_from, immutable, &immutable_from, clock);

    // Validate blob expiry (minimum 1 year to prevent immediate expiration attacks)
    let current_epoch = ctx.epoch();
    assert!(expiry_epoch >= current_epoch + MIN_WALRUS_BLOB_EXPIRY_EPOCHS, EWalrusBlobExpiryTooSoon);

    let new_chunk_uid = object::new(ctx);
    let new_chunk_id = object::uid_to_inner(&new_chunk_uid);

    // Get the current head
    let old_head = doc.head_chunk;

    // Update old head's prev pointer if it exists
    if (option::is_some(&old_head)) {
        let old_head_id = *option::borrow(&old_head);
        let old_head_chunk = table::borrow_mut(&mut doc.chunks, old_head_id);
        old_head_chunk.prev_chunk = option::some(new_chunk_id);
    } else {
        // If document was empty, also update tail
        doc.tail_chunk = option::some(new_chunk_id);
    };

    // Update head to point to new chunk
    doc.head_chunk = option::some(new_chunk_id);

    // Validate storage XOR invariant BEFORE construction
    assert_storage_xor(STORAGE_TYPE_WALRUS, false, true);

    // Get blob_id BEFORE moving the blob
    let blob_id = blob::blob_id(&walrus_blob);

    // Create new chunk at beginning
    let chunk = ChunkPointer {
        id: new_chunk_uid,
        prev_chunk: option::none(),  // First chunk, no previous
        next_chunk: old_head,         // Link to old head (or none)
        storage_type: STORAGE_TYPE_WALRUS,
        text: option::none(),
        walrus_blob: option::some(walrus_blob),
        walrus_storage_object_id: option::none(),
        walrus_expiry_epoch: option::some(expiry_epoch),
        immutable,
        immutable_from,
        chunk_type,
        expires_at,
        effective_from,
    };

    table::add(&mut doc.chunks, new_chunk_id, chunk);
    doc.chunk_count = doc.chunk_count + 1;

    // Recalculate and update hash
    // edit_sequence already incremented

    event::emit(ChunkAdded {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id: new_chunk_id,
        walrus_blob_id: bcs::to_bytes(&blob_id),
        chunk_type,
        expires_at,
        effective_from,
        immutable_from,
        position_after: option::none(),  // At beginning, no previous chunk
        timestamp_ms: clock.timestamp_ms(),
    });

    new_chunk_id
}

/// Insert text chunk at the beginning of the document
/// Updates head_chunk and fixes old head's prev_chunk pointer
public fun insert_text_chunk_at_beginning(
    doc: &mut File,
    expected_sequence: u64,
    text: String,
    chunk_type: u8,
    expires_at: Option<u64>,
    effective_from: Option<u64>,
    immutable: bool,
    immutable_from: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Validate text size and sequence
    validate_text_size(&text);
    expect_sequence_and_increment(doc, expected_sequence);

    // Validate chunk insertion using helper function
    validate_chunk_insertion(doc, chunk_type, &expires_at, &effective_from, immutable, &immutable_from, clock);

    let new_chunk_uid = object::new(ctx);
    let new_chunk_id = object::uid_to_inner(&new_chunk_uid);

    // Get the current head
    let old_head = doc.head_chunk;

    // Update old head's prev pointer if it exists
    if (option::is_some(&old_head)) {
        let old_head_id = *option::borrow(&old_head);
        let old_head_chunk = table::borrow_mut(&mut doc.chunks, old_head_id);
        old_head_chunk.prev_chunk = option::some(new_chunk_id);
    } else {
        // If document was empty, also update tail
        doc.tail_chunk = option::some(new_chunk_id);
    };

    // Update head to point to new chunk
    doc.head_chunk = option::some(new_chunk_id);

    // Validate storage XOR invariant BEFORE construction
    assert_storage_xor(STORAGE_TYPE_TEXT, true, false);

    // Create new chunk at beginning with text
    let chunk = ChunkPointer {
        id: new_chunk_uid,
        prev_chunk: option::none(),  // First chunk, no previous
        next_chunk: old_head,         // Link to old head (or none)
        storage_type: STORAGE_TYPE_TEXT,
        text: option::some(text),
        walrus_blob: option::none(),
        walrus_storage_object_id: option::none(),
        walrus_expiry_epoch: option::none(),
        immutable,
        immutable_from,
        chunk_type,
        expires_at,
        effective_from,
    };

    table::add(&mut doc.chunks, new_chunk_id, chunk);
    doc.chunk_count = doc.chunk_count + 1;

    // Recalculate and update hash
    // edit_sequence already incremented

    event::emit(ChunkAdded {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id: new_chunk_id,
        walrus_blob_id: vector::empty(),
        chunk_type,
        expires_at,
        effective_from,
        immutable_from,
        position_after: option::none(),  // At beginning, no previous chunk
        timestamp_ms: clock.timestamp_ms(),
    });

    new_chunk_id
}

/// Update text chunk (only if not immutable)
/// Changes the on-chain text content of a chunk
public fun update_text_chunk(
    doc: &mut File,
    expected_sequence: u64,
    chunk_id: ID,
    new_text: String,
    clock: &Clock,
) {
    // Validate text size and hash
    validate_text_size(&new_text);
    expect_sequence_and_increment(doc, expected_sequence);

    assert!(!doc.immutable, EDocumentImmutable);
    assert!(table::contains(&doc.chunks, chunk_id), EChunkNotFound);

    // Remove chunk to get ownership
    let ChunkPointer {
        id: chunk_uid,
        prev_chunk,
        next_chunk,
        storage_type,
        text: _,
        walrus_blob,
        walrus_storage_object_id,
        walrus_expiry_epoch,
        immutable,
        immutable_from,
        chunk_type,
        expires_at,
        effective_from,
    } = table::remove(&mut doc.chunks, chunk_id);

    // Check storage type and immutability
    assert!(storage_type == STORAGE_TYPE_TEXT, EInvalidStorageType);
    let current_time_ms = clock.timestamp_ms();
    assert!(!immutable, EChunkIsImmutable);
    if (option::is_some(&immutable_from)) {
        assert!(current_time_ms < *option::borrow(&immutable_from), EChunkIsImmutable);
    };

    // Validate storage XOR invariant BEFORE construction
    assert_storage_xor(STORAGE_TYPE_TEXT, true, false);

    // Create updated chunk with new text
    let updated_chunk = ChunkPointer {
        id: chunk_uid,
        prev_chunk,
        next_chunk,
        storage_type,
        text: option::some(new_text),
        walrus_blob,
        walrus_storage_object_id,
        walrus_expiry_epoch,
        immutable,
        immutable_from,
        chunk_type,
        expires_at,
        effective_from,
    };

    table::add(&mut doc.chunks, chunk_id, updated_chunk);

    // Recalculate and update hash
    // edit_sequence already incremented

    // Emit ChunkTextUpdated event
    event::emit(ChunkTextUpdated {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id,
        timestamp_ms: clock.timestamp_ms(),
    });
}

/// Update Walrus blob chunk (only if not immutable)
public fun update_chunk(
    doc: &mut File,
    expected_sequence: u64,
    chunk_id: ID,
    new_walrus_blob: blob::Blob,
    clock: &Clock,
    ctx: &TxContext,
): blob::Blob {
    // Validate hash
    expect_sequence_and_increment(doc, expected_sequence);

    assert!(!doc.immutable, EDocumentImmutable);
    assert!(table::contains(&doc.chunks, chunk_id), EChunkNotFound);

    // Remove old chunk to get ownership
    let ChunkPointer {
        id: chunk_uid,
        prev_chunk,
        next_chunk,
        storage_type,
        text: _,
        walrus_blob: old_blob_option,
        walrus_storage_object_id: _,
        walrus_expiry_epoch: _,
        immutable,
        immutable_from,
        chunk_type,
        expires_at,
        effective_from,
    } = table::remove(&mut doc.chunks, chunk_id);

    // Check storage type BEFORE trying to extract blob
    assert!(storage_type == STORAGE_TYPE_WALRUS, EInvalidStorageType);

    // Check if chunk was immutable
    let current_time_ms = clock.timestamp_ms();
    assert!(!immutable, EChunkIsImmutable);
    if (option::is_some(&immutable_from)) {
        assert!(current_time_ms < *option::borrow(&immutable_from), EChunkIsImmutable);
    };

    // Extract old blob from option (safe now that we've checked storage type)
    let old_blob = option::destroy_some(old_blob_option);
    let old_blob_id = blob::blob_id(&old_blob);
    let new_blob_id = blob::blob_id(&new_walrus_blob);
    let new_expiry_epoch = blob::end_epoch(&new_walrus_blob) as u64;

    // Validate blob expiry (minimum 1 year to prevent immediate expiration attacks)
    let current_epoch = ctx.epoch();
    assert!(new_expiry_epoch >= current_epoch + MIN_WALRUS_BLOB_EXPIRY_EPOCHS, EWalrusBlobExpiryTooSoon);

    // Validate storage XOR invariant BEFORE construction
    assert_storage_xor(STORAGE_TYPE_WALRUS, false, true);

    // Create new chunk with new blob (preserve doubly-linked list pointers)
    let new_chunk = ChunkPointer {
        id: chunk_uid,
        prev_chunk,
        next_chunk,
        storage_type: STORAGE_TYPE_WALRUS,
        text: option::none(),
        walrus_blob: option::some(new_walrus_blob),
        walrus_storage_object_id: option::none(),
        walrus_expiry_epoch: option::some(new_expiry_epoch),
        immutable,
        immutable_from,
        chunk_type,
        expires_at,
        effective_from,
    };

    table::add(&mut doc.chunks, chunk_id, new_chunk);

    // Recalculate and update hash
    // edit_sequence already incremented

    event::emit(ChunkUpdated {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id,
        old_walrus_blob_id: bcs::to_bytes(&old_blob_id),
        new_walrus_blob_id: bcs::to_bytes(&new_blob_id),
        timestamp_ms: clock.timestamp_ms(),
    });

    old_blob
}

/// Remove chunk with Walrus blob (only if not immutable and allow_remove = true)
/// Returns the Blob so caller can handle it (transfer, delete, etc.)
/// NOTE: Only for Walrus storage chunks. Use remove_text_chunk for text chunks.
/// IMPORTANT: Properly relinks the list by finding the predecessor chunk
public fun remove_chunk(
    doc: &mut File,
    expected_sequence: u64,
    chunk_id: ID,
    clock: &Clock,
): blob::Blob {
    // Validate hash
    expect_sequence_and_increment(doc, expected_sequence);

    assert!(!doc.immutable, EDocumentImmutable);
    assert!(doc.allow_remove, ERemoveNotAllowed);
    assert!(table::contains(&doc.chunks, chunk_id), EChunkNotFound);

    let chunk = table::borrow(&doc.chunks, chunk_id);
    assert!(chunk.storage_type == STORAGE_TYPE_WALRUS, EInvalidStorageType);
    assert!(!is_chunk_immutable_now(chunk, clock.timestamp_ms()), EChunkIsImmutable);

    // Remove the chunk and capture its pointers (O(1) with doubly-linked list)
    let ChunkPointer {
        id: chunk_uid,
        prev_chunk: removed_prev,
        next_chunk: removed_next,
        storage_type: _,
        text: _,
        walrus_blob: walrus_blob_option,
        walrus_storage_object_id: _,
        walrus_expiry_epoch: _,
        immutable: _,
        immutable_from: _,
        chunk_type: _,
        expires_at: _,
        effective_from: _,
    } = table::remove(&mut doc.chunks, chunk_id);

    // Delete the UID
    object::delete(chunk_uid);

    // O(1) RELINK: Update prev chunk's next pointer
    if (option::is_some(&removed_prev)) {
        let prev_id = *option::borrow(&removed_prev);
        let prev_chunk = table::borrow_mut(&mut doc.chunks, prev_id);
        prev_chunk.next_chunk = removed_next;
    } else {
        // Removing head - update head pointer
        doc.head_chunk = removed_next;
    };

    // O(1) RELINK: Update next chunk's prev pointer
    if (option::is_some(&removed_next)) {
        let next_id = *option::borrow(&removed_next);
        let next_chunk = table::borrow_mut(&mut doc.chunks, next_id);
        next_chunk.prev_chunk = removed_prev;
    } else {
        // Removing tail - update tail pointer to predecessor
        doc.tail_chunk = removed_prev;
    };

    doc.chunk_count = doc.chunk_count - 1;

    // Recalculate and update hash
    // edit_sequence already incremented

    event::emit(ChunkRemoved {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id,
        timestamp_ms: clock.timestamp_ms(),
    });

    // Extract blob from option (must be Walrus storage)
    option::destroy_some(walrus_blob_option)
}

/// Remove text chunk (only if not immutable and allow_remove = true)
/// For text-based chunks that don't have Walrus blobs
public fun remove_text_chunk(
    doc: &mut File,
    expected_sequence: u64,
    chunk_id: ID,
    clock: &Clock,
) {
    // Validate hash
    expect_sequence_and_increment(doc, expected_sequence);

    assert!(!doc.immutable, EDocumentImmutable);
    assert!(doc.allow_remove, ERemoveNotAllowed);
    assert!(table::contains(&doc.chunks, chunk_id), EChunkNotFound);

    let chunk = table::borrow(&doc.chunks, chunk_id);
    assert!(chunk.storage_type == STORAGE_TYPE_TEXT, EInvalidStorageType);
    assert!(!is_chunk_immutable_now(chunk, clock.timestamp_ms()), EChunkIsImmutable);

    // Remove the chunk and capture its pointers (O(1) with doubly-linked list)
    let ChunkPointer {
        id: chunk_uid,
        prev_chunk: removed_prev,
        next_chunk: removed_next,
        storage_type: _,
        text: _,
        walrus_blob: walrus_blob_option,
        walrus_storage_object_id: _,
        walrus_expiry_epoch: _,
        immutable: _,
        immutable_from: _,
        chunk_type: _,
        expires_at: _,
        effective_from: _,
    } = table::remove(&mut doc.chunks, chunk_id);

    // Walrus blob must be None for text chunks
    option::destroy_none(walrus_blob_option);

    // Delete the UID
    object::delete(chunk_uid);

    // O(1) RELINK: Update prev chunk's next pointer
    if (option::is_some(&removed_prev)) {
        let prev_id = *option::borrow(&removed_prev);
        let prev_chunk = table::borrow_mut(&mut doc.chunks, prev_id);
        prev_chunk.next_chunk = removed_next;
    } else {
        // Removing head - update head pointer
        doc.head_chunk = removed_next;
    };

    // O(1) RELINK: Update next chunk's prev pointer
    if (option::is_some(&removed_next)) {
        let next_id = *option::borrow(&removed_next);
        let next_chunk = table::borrow_mut(&mut doc.chunks, next_id);
        next_chunk.prev_chunk = removed_prev;
    } else {
        // Removing tail - update tail pointer to predecessor
        doc.tail_chunk = removed_prev;
    };

    doc.chunk_count = doc.chunk_count - 1;

    // Recalculate and update hash
    // edit_sequence already incremented

    event::emit(ChunkRemoved {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id,
        timestamp_ms: clock.timestamp_ms(),
    });
}

/// Remove expired Walrus chunk (can remove even if immutable - expiry overrides immutability)
/// Returns the Blob for caller to handle
/// NOTE: Only for Walrus storage chunks. Use remove_expired_text_chunk for text chunks.
/// IMPORTANT: Properly relinks the list by finding the predecessor chunk
/// PUBLIC: Enables permissionless cleanup of expired chunks (cannot be entry due to return value)
public fun remove_expired_chunk(
    doc: &mut File,
    expected_sequence: u64,
    chunk_id: ID,
    clock: &Clock,
): blob::Blob {
    // Validate hash
    expect_sequence_and_increment(doc, expected_sequence);

    assert!(doc.allow_remove, ERemoveNotAllowed);
    assert!(table::contains(&doc.chunks, chunk_id), EChunkNotFound);

    let chunk = table::borrow(&doc.chunks, chunk_id);
    assert!(chunk.storage_type == STORAGE_TYPE_WALRUS, EInvalidStorageType);
    let now = clock.timestamp_ms();

    // Must have expiry and be past it
    assert!(option::is_some(&chunk.expires_at), EChunkHasNoExpiry);
    assert!(now >= *option::borrow(&chunk.expires_at), EChunkNotExpired);

    // Remove the chunk and capture its pointers (O(1) with doubly-linked list)
    let ChunkPointer {
        id: chunk_uid,
        prev_chunk: removed_prev,
        next_chunk: removed_next,
        storage_type: _,
        text: _,
        walrus_blob: walrus_blob_option,
        walrus_storage_object_id: _,
        walrus_expiry_epoch: _,
        immutable: _,
        immutable_from: _,
        chunk_type: _,
        expires_at: _,
        effective_from: _,
    } = table::remove(&mut doc.chunks, chunk_id);

    // Delete the UID
    object::delete(chunk_uid);

    // O(1) RELINK: Update prev chunk's next pointer
    if (option::is_some(&removed_prev)) {
        let prev_id = *option::borrow(&removed_prev);
        let prev_chunk = table::borrow_mut(&mut doc.chunks, prev_id);
        prev_chunk.next_chunk = removed_next;
    } else {
        // Removing head - update head pointer
        doc.head_chunk = removed_next;
    };

    // O(1) RELINK: Update next chunk's prev pointer
    if (option::is_some(&removed_next)) {
        let next_id = *option::borrow(&removed_next);
        let next_chunk = table::borrow_mut(&mut doc.chunks, next_id);
        next_chunk.prev_chunk = removed_prev;
    } else {
        // Removing tail - update tail pointer to predecessor
        doc.tail_chunk = removed_prev;
    };

    doc.chunk_count = doc.chunk_count - 1;

    // Recalculate and update hash
    // edit_sequence already incremented

    event::emit(ChunkRemoved {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id,
        timestamp_ms: clock.timestamp_ms(),
    });

    // Extract blob from option
    option::destroy_some(walrus_blob_option)
}

/// Remove expired text chunk (can remove even if immutable - expiry overrides immutability)
/// For text-based chunks that don't have Walrus blobs
/// Note: File objects are owned by Account, so this is called through DAO governance
public fun remove_expired_text_chunk(
    doc: &mut File,
    expected_sequence: u64,
    chunk_id: ID,
    clock: &Clock,
) {
    // Validate hash
    expect_sequence_and_increment(doc, expected_sequence);

    assert!(doc.allow_remove, ERemoveNotAllowed);
    assert!(table::contains(&doc.chunks, chunk_id), EChunkNotFound);

    let chunk = table::borrow(&doc.chunks, chunk_id);
    assert!(chunk.storage_type == STORAGE_TYPE_TEXT, EInvalidStorageType);
    let now = clock.timestamp_ms();

    // Must have expiry and be past it
    assert!(option::is_some(&chunk.expires_at), EChunkHasNoExpiry);
    assert!(now >= *option::borrow(&chunk.expires_at), EChunkNotExpired);

    // Remove the chunk and capture its pointers (O(1) with doubly-linked list)
    let ChunkPointer {
        id: chunk_uid,
        prev_chunk: removed_prev,
        next_chunk: removed_next,
        storage_type: _,
        text: _,
        walrus_blob: walrus_blob_option,
        walrus_storage_object_id: _,
        walrus_expiry_epoch: _,
        immutable: _,
        immutable_from: _,
        chunk_type: _,
        expires_at: _,
        effective_from: _,
    } = table::remove(&mut doc.chunks, chunk_id);

    // Walrus blob must be None for text chunks
    option::destroy_none(walrus_blob_option);

    // Delete the UID
    object::delete(chunk_uid);

    // O(1) RELINK: Update prev chunk's next pointer
    if (option::is_some(&removed_prev)) {
        let prev_id = *option::borrow(&removed_prev);
        let prev_chunk = table::borrow_mut(&mut doc.chunks, prev_id);
        prev_chunk.next_chunk = removed_next;
    } else {
        // Removing head - update head pointer
        doc.head_chunk = removed_next;
    };

    // O(1) RELINK: Update next chunk's prev pointer
    if (option::is_some(&removed_next)) {
        let next_id = *option::borrow(&removed_next);
        let next_chunk = table::borrow_mut(&mut doc.chunks, next_id);
        next_chunk.prev_chunk = removed_prev;
    } else {
        // Removing tail - update tail pointer to predecessor
        doc.tail_chunk = removed_prev;
    };

    doc.chunk_count = doc.chunk_count - 1;

    // Recalculate and update hash
    // edit_sequence already incremented

    event::emit(ChunkRemoved {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id,
        timestamp_ms: clock.timestamp_ms(),
    });
}

// === Immutability Controls ===

/// Set chunk as permanently immutable
public fun set_chunk_immutable(
    doc: &mut File,
    expected_sequence: u64,
    chunk_id: ID,
    clock: &Clock,
) {
    // Validate hash
    expect_sequence_and_increment(doc, expected_sequence);

    assert!(!doc.immutable, EDocumentImmutable);
    assert!(table::contains(&doc.chunks, chunk_id), EChunkNotFound);

    let chunk = table::borrow_mut(&mut doc.chunks, chunk_id);
    let now = clock.timestamp_ms();

    // One-way lock: can only go from mutable to immutable
    assert!(!is_chunk_immutable_now(chunk, now), EAlreadyImmutable);

    // If chunk has scheduled immutability, must wait until that time
    if (option::is_some(&chunk.immutable_from)) {
        assert!(now >= *option::borrow(&chunk.immutable_from), ECannotMakeImmutableBeforeScheduled);
    };

    chunk.immutable = true;

    // Recalculate and update hash
    // edit_sequence already incremented

    event::emit(ChunkImmutabilityChanged {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id,
        immutable: true,
        timestamp_ms: clock.timestamp_ms(),
    });
}

/// Set document as immutable (one-way lock)
public fun set_document_immutable(
    doc: &mut File,
    expected_sequence: u64,
    clock: &Clock,
) {
    // Validate hash
    expect_sequence_and_increment(doc, expected_sequence);

    assert!(!doc.immutable, EAlreadyImmutable);

    doc.immutable = true;

    // Recalculate and update hash
    // edit_sequence already incremented

    event::emit(DocumentImmutabilityChanged {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        immutable: true,
        timestamp_ms: clock.timestamp_ms(),
    });
}

/// Set entire registry as immutable (nuclear option)
public fun set_registry_immutable(
    registry: &mut DaoFileRegistry,
    clock: &Clock,
) {
    assert!(!registry.immutable, EAlreadyGloballyImmutable);

    registry.immutable = true;

    event::emit(RegistryImmutabilityChanged {
        dao_id: registry.dao_id,
        immutable: true,
        timestamp_ms: clock.timestamp_ms(),
    });
}

/// Set insert allowed (one-way: true → false only)
public fun set_insert_allowed(
    doc: &mut File,
    expected_sequence: u64,
    allowed: bool,
    clock: &Clock,
) {
    // Validate hash
    expect_sequence_and_increment(doc, expected_sequence);

    assert!(!doc.immutable, EDocumentImmutable);

    // One-way lock
    if (!allowed) {
        doc.allow_insert = false;
    } else {
        assert!(doc.allow_insert, ECannotReEnableInsert);
    };

    // Recalculate and update hash
    // edit_sequence already incremented

    event::emit(DocumentPolicyChanged {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        allow_insert: doc.allow_insert,
        allow_remove: doc.allow_remove,
        timestamp_ms: clock.timestamp_ms(),
    });
}

/// Set remove allowed (one-way: true → false only)
public fun set_remove_allowed(
    doc: &mut File,
    expected_sequence: u64,
    allowed: bool,
    clock: &Clock,
) {
    // Validate hash
    expect_sequence_and_increment(doc, expected_sequence);

    assert!(!doc.immutable, EDocumentImmutable);

    // One-way lock
    if (!allowed) {
        doc.allow_remove = false;
    } else {
        assert!(doc.allow_remove, ECannotReEnableRemove);
    };

    // Recalculate and update hash
    // edit_sequence already incremented

    event::emit(DocumentPolicyChanged {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        allow_insert: doc.allow_insert,
        allow_remove: doc.allow_remove,
        timestamp_ms: clock.timestamp_ms(),
    });
}

// === Query Functions ===

/// Get document by name
public fun get_document_by_name(
    registry: &DaoFileRegistry,
    name: String,
): Option<ID> {
    if (table::contains(&registry.docs_by_name, name)) {
        option::some(*table::borrow(&registry.docs_by_name, name))
    } else {
        option::none()
    }
}

/// Check if chunk is active at current time
public fun is_chunk_active(chunk: &ChunkPointer, current_time_ms: u64): bool {
    // Check effective_from
    if (option::is_some(&chunk.effective_from)) {
        if (current_time_ms < *option::borrow(&chunk.effective_from)) {
            return false
        }
    };

    // Check expires_at
    if (option::is_some(&chunk.expires_at)) {
        if (current_time_ms >= *option::borrow(&chunk.expires_at)) {
            return false
        }
    };

    true
}

/// Check if chunk is immutable at current time
public fun is_chunk_immutable_now(chunk: &ChunkPointer, current_time_ms: u64): bool {
    // Already permanently immutable
    if (chunk.immutable) {
        return true
    };

    // Check if scheduled immutability has been reached
    if (option::is_some(&chunk.immutable_from)) {
        if (current_time_ms >= *option::borrow(&chunk.immutable_from)) {
            return true
        }
    };

    false
}

/// Check if chunk is currently active based on time windows
/// A chunk is active if:
/// - It's past its effective_from time (if set)
/// - It hasn't reached its expires_at time (if set)
public fun is_chunk_active_now(chunk: &ChunkPointer, now_ms: u64): bool {
    // Check if expired
    if (option::is_some(&chunk.expires_at)) {
        if (now_ms >= *option::borrow(&chunk.expires_at)) {
            return false // Expired (sunset or temporary)
        }
    };

    // Check if not yet effective
    if (option::is_some(&chunk.effective_from)) {
        if (now_ms < *option::borrow(&chunk.effective_from)) {
            return false // Not yet active (sunrise or temporary)
        }
    };

    true // Active
}

// === Chunk Getter Functions ===

/// Get chunk type
public fun get_chunk_type(chunk: &ChunkPointer): u8 {
    chunk.chunk_type
}

/// Get chunk expiry time
public fun get_expires_at(chunk: &ChunkPointer): Option<u64> {
    chunk.expires_at
}

/// Get chunk effective from time
public fun get_effective_from(chunk: &ChunkPointer): Option<u64> {
    chunk.effective_from
}

/// Get chunk scheduled immutability time
public fun get_immutable_from(chunk: &ChunkPointer): Option<u64> {
    chunk.immutable_from
}

/// Get chunk storage type
public fun get_storage_type(chunk: &ChunkPointer): u8 {
    chunk.storage_type
}

/// Check if chunk is immediately immutable
public fun is_chunk_immediately_immutable(chunk: &ChunkPointer): bool {
    chunk.immutable
}


/// Read and emit full document state with complete chunk details
/// This is the comprehensive version that provides all chunk information for indexers
/// Note: File objects are owned by Account. For permissionless reads, use RPC object queries.
/// This function emits DocumentReadWithStatus event for indexers to process.
public fun read_document_with_status(doc: &File, clock: &Clock) {
    let mut chunk_ids = vector::empty<ID>();
    let mut chunk_texts = vector::empty<Option<String>>();
    let mut chunk_blob_ids = vector::empty<vector<u8>>();
    let mut chunk_storage_types = vector::empty<u8>();
    let mut chunk_immutables = vector::empty<bool>();
    let mut chunk_immutable_froms = vector::empty<Option<u64>>();
    let mut chunk_types = vector::empty<u8>();
    let mut chunk_expires_ats = vector::empty<Option<u64>>();
    let mut chunk_effective_froms = vector::empty<Option<u64>>();
    let mut chunk_active_statuses = vector::empty<bool>();

    let now = clock.timestamp_ms();

    // Traverse linked list starting from head
    if (option::is_some(&doc.head_chunk)) {
        let mut current_id = *option::borrow(&doc.head_chunk);
        let mut steps = 0;

        while (table::contains(&doc.chunks, current_id)) {
            // Check traversal limit FIRST (early abort on cycles)
            assert!(steps <= MAX_TRAVERSAL_LIMIT, ETraversalLimitExceeded);

            let chunk = table::borrow(&doc.chunks, current_id);

            // Collect all chunk data
            vector::push_back(&mut chunk_ids, current_id);
            vector::push_back(&mut chunk_texts, chunk.text);
            vector::push_back(&mut chunk_storage_types, chunk.storage_type);
            vector::push_back(&mut chunk_immutables, chunk.immutable);
            vector::push_back(&mut chunk_immutable_froms, chunk.immutable_from);
            vector::push_back(&mut chunk_types, chunk.chunk_type);
            vector::push_back(&mut chunk_expires_ats, chunk.expires_at);
            vector::push_back(&mut chunk_effective_froms, chunk.effective_from);

            // Get blob ID if Walrus storage
            let blob_id_bytes = if (chunk.storage_type == STORAGE_TYPE_WALRUS && option::is_some(&chunk.walrus_blob)) {
                let blob_ref = option::borrow(&chunk.walrus_blob);
                let blob_id = blob::blob_id(blob_ref);
                bcs::to_bytes(&blob_id)
            } else {
                vector::empty()
            };
            vector::push_back(&mut chunk_blob_ids, blob_id_bytes);

            // Check if chunk is currently active based on time constraints
            let is_active = is_chunk_active_now(chunk, now);
            vector::push_back(&mut chunk_active_statuses, is_active);

            // Move to next chunk
            if (option::is_some(&chunk.next_chunk)) {
                current_id = *option::borrow(&chunk.next_chunk);
                steps = steps + 1;
            } else {
                break
            };
        };
    };

    event::emit(DocumentReadWithStatus {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        name: doc.name,
        chunk_ids,
        chunk_texts,
        chunk_blob_ids,
        chunk_storage_types,
        chunk_immutables,
        chunk_immutable_froms,
        chunk_types,
        chunk_expires_ats,
        chunk_effective_froms,
        chunk_active_statuses,
        allow_insert: doc.allow_insert,
        allow_remove: doc.allow_remove,
        immutable: doc.immutable,
        timestamp_ms: clock.timestamp_ms(),
    });
}

/// Read and emit simplified document state (legacy, use read_document_with_status for full details)
/// Note: File objects are owned by Account. For permissionless reads, use RPC object queries.
/// This function emits DocumentRead event for indexers to process.
public fun read_document(doc: &File, clock: &Clock) {
    let mut blob_ids = vector::empty<vector<u8>>();

    // Traverse linked list starting from head
    if (option::is_some(&doc.head_chunk)) {
        let mut current_id = *option::borrow(&doc.head_chunk);
        let mut steps = 0;

        while (table::contains(&doc.chunks, current_id)) {
            // Check traversal limit FIRST (early abort on cycles)
            assert!(steps <= MAX_TRAVERSAL_LIMIT, ETraversalLimitExceeded);

            let chunk = table::borrow(&doc.chunks, current_id);

            // Only get blob ID if chunk uses Walrus storage
            if (chunk.storage_type == STORAGE_TYPE_WALRUS && option::is_some(&chunk.walrus_blob)) {
                let blob_ref = option::borrow(&chunk.walrus_blob);
                let blob_id = blob::blob_id(blob_ref);
                vector::push_back(&mut blob_ids, bcs::to_bytes(&blob_id));
            };

            // Move to next chunk
            if (option::is_some(&chunk.next_chunk)) {
                current_id = *option::borrow(&chunk.next_chunk);
                steps = steps + 1;
            } else {
                break
            };
        };
    };

    event::emit(DocumentRead {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        name: doc.name,
        chunk_count: doc.chunk_count,
        chunk_blob_ids: blob_ids,
        allow_insert: doc.allow_insert,
        allow_remove: doc.allow_remove,
        immutable: doc.immutable,
        timestamp_ms: clock.timestamp_ms(),
    });
}

// === Getters for Document Fields ===

public fun get_document_name(doc: &File): String {
    doc.name
}

public fun get_document_dao_id(doc: &File): ID {
    doc.dao_id
}

/// Get chunk for verification (read-only)
public fun get_chunk(doc: &File, chunk_id: ID): &ChunkPointer {
    assert!(table::contains(&doc.chunks, chunk_id), EChunkNotFound);
    table::borrow(&doc.chunks, chunk_id)
}

/// Get the Walrus blob ID from a chunk (for renewal verification)
/// Aborts if chunk doesn't use Walrus storage
public fun get_chunk_blob_id(chunk: &ChunkPointer): u256 {
    assert!(chunk.storage_type == STORAGE_TYPE_WALRUS, EInvalidStorageType);
    assert!(option::is_some(&chunk.walrus_blob), EInvalidStorageType);
    let blob_ref = option::borrow(&chunk.walrus_blob);
    let blob_id = blob::blob_id(blob_ref);
    // Validate blob ID is non-empty to prevent hash collisions
    assert!(blob_id != 0, EEmptyWalrusBlobId);
    blob_id
}

// === Walrus Renewal Helper Functions ===

/// Check if a chunk needs Walrus renewal (for walrus_renewal module)
public fun chunk_needs_walrus_renewal(
    chunk: &ChunkPointer,
    current_epoch: u64,
    threshold_epochs: u64,
): bool {
    // Must have Walrus storage
    if (option::is_none(&chunk.walrus_expiry_epoch)) { return false };

    let expiry = *option::borrow(&chunk.walrus_expiry_epoch);

    // Renew if within threshold of expiry
    current_epoch + threshold_epochs >= expiry
}

/// Get all chunks that need renewal for a document
public fun get_chunks_needing_renewal(
    doc: &File,
    current_epoch: u64,
    threshold_epochs: u64,
): vector<ID> {
    let mut chunks_to_renew = vector::empty<ID>();

    // Traverse linked list starting from head
    if (option::is_some(&doc.head_chunk)) {
        let mut current_id = *option::borrow(&doc.head_chunk);
        let mut steps = 0;

        while (table::contains(&doc.chunks, current_id)) {
            // Check traversal limit FIRST (early abort on cycles)
            assert!(steps <= MAX_TRAVERSAL_LIMIT, ETraversalLimitExceeded);

            let chunk = table::borrow(&doc.chunks, current_id);
            if (chunk_needs_walrus_renewal(chunk, current_epoch, threshold_epochs)) {
                vector::push_back(&mut chunks_to_renew, current_id);
            };

            // Move to next chunk
            if (option::is_some(&chunk.next_chunk)) {
                current_id = *option::borrow(&chunk.next_chunk);
                steps = steps + 1;
            } else {
                break
            };
        };
    };

    chunks_to_renew
}

/// Update chunk Walrus expiry (called after successful renewal)
public fun update_chunk_walrus_expiry(
    doc: &mut File,
    expected_sequence: u64,
    chunk_id: ID,
    new_expiry_epoch: u64,
    clock: &Clock,
) {
    // Concurrency control
    expect_sequence_and_increment(doc, expected_sequence);

    assert!(table::contains(&doc.chunks, chunk_id), EChunkNotFound);
    let chunk = table::borrow_mut(&mut doc.chunks, chunk_id);
    chunk.walrus_expiry_epoch = option::some(new_expiry_epoch);

    // Emit event for audit trail
    event::emit(WalrusExpiryUpdated {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id,
        new_expiry_epoch,
        timestamp_ms: clock.timestamp_ms(),
    });
}

/// Get chunk Walrus metadata for renewal
/// Returns empty blob_id if chunk doesn't use Walrus storage
public fun get_chunk_walrus_metadata(
    doc: &File,
    chunk_id: ID,
): (Option<ID>, Option<u64>, vector<u8>) {
    assert!(table::contains(&doc.chunks, chunk_id), EChunkNotFound);
    let chunk = table::borrow(&doc.chunks, chunk_id);

    let blob_id_bytes = if (chunk.storage_type == STORAGE_TYPE_WALRUS && option::is_some(&chunk.walrus_blob)) {
        let blob_ref = option::borrow(&chunk.walrus_blob);
        let blob_id = blob::blob_id(blob_ref);
        bcs::to_bytes(&blob_id)
    } else {
        vector::empty()
    };

    (
        chunk.walrus_storage_object_id,
        chunk.walrus_expiry_epoch,
        blob_id_bytes,
    )
}

/// Set chunk Walrus storage object ID (when first uploaded)
public fun set_chunk_walrus_storage_id(
    doc: &mut File,
    expected_sequence: u64,
    chunk_id: ID,
    storage_object_id: ID,
    expiry_epoch: u64,
    clock: &Clock,
) {
    // Concurrency control
    expect_sequence_and_increment(doc, expected_sequence);

    assert!(table::contains(&doc.chunks, chunk_id), EChunkNotFound);
    let chunk = table::borrow_mut(&mut doc.chunks, chunk_id);
    chunk.walrus_storage_object_id = option::some(storage_object_id);
    chunk.walrus_expiry_epoch = option::some(expiry_epoch);

    // Emit event for audit trail
    event::emit(WalrusStorageBound {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id,
        storage_object_id,
        expiry_epoch,
        timestamp_ms: clock.timestamp_ms(),
    });
}

// === Batch Operations API ===

/// Create a new batch action
public fun new_batch_action(batch_id: ID, actions: vector<ChunkAction>): BatchDocAction {
    BatchDocAction { batch_id, actions }
}

/// Create a ChunkAction for adding a text chunk
public fun new_add_text_chunk_action(
    doc_id: ID,
    text: String,
    chunk_type: u8,
    expires_at: Option<u64>,
    effective_from: Option<u64>,
    immutable: bool,
    immutable_from: Option<u64>,
): ChunkAction {
    ChunkAction {
        action_type: ACTION_ADD_CHUNK,
        doc_id,
        chunk_id: option::none(),
        prev_chunk_id: option::none(),
        text: option::some(text),
        chunk_type: option::some(chunk_type),
        expires_at,
        effective_from,
        immutable: option::some(immutable),
        immutable_from,
    }
}

/// Create a ChunkAction for inserting after a specific chunk
public fun new_insert_after_action(
    doc_id: ID,
    prev_chunk_id: ID,
    text: String,
    ): ChunkAction {
    ChunkAction {
        action_type: ACTION_INSERT_AFTER,
        doc_id,
        chunk_id: option::none(),
        prev_chunk_id: option::some(prev_chunk_id),
        text: option::some(text),
                chunk_type: option::some(CHUNK_TYPE_PERMANENT),
        expires_at: option::none(),
        effective_from: option::none(),
        immutable: option::some(false),
        immutable_from: option::none(),
    }
}

/// Create a ChunkAction for removing a chunk
public fun new_remove_chunk_action(doc_id: ID, chunk_id: ID): ChunkAction {
    ChunkAction {
        action_type: ACTION_REMOVE_CHUNK,
        doc_id,
        chunk_id: option::some(chunk_id),
        prev_chunk_id: option::none(),
        text: option::none(),
                chunk_type: option::none(),
        expires_at: option::none(),
        effective_from: option::none(),
        immutable: option::none(),
        immutable_from: option::none(),
    }
}

/// Create a ChunkAction for setting a chunk immutable
public fun new_set_immutable_action(doc_id: ID, chunk_id: ID): ChunkAction {
    ChunkAction {
        action_type: ACTION_SET_CHUNK_IMMUTABLE,
        doc_id,
        chunk_id: option::some(chunk_id),
        prev_chunk_id: option::none(),
        text: option::none(),
                chunk_type: option::none(),
        expires_at: option::none(),
        effective_from: option::none(),
        immutable: option::none(),
        immutable_from: option::none(),
    }
}

/// Execute a batch of chunk actions on a single File
/// This allows complex multi-step edits like "remove Article 2, insert new Article 2.5"
///
/// IMPORTANT: This operates on a single File that has been borrowed by value
/// For multi-document batches, use PTB to chain operations:
/// ```typescript
/// const file = tx.moveCall({ target: 'borrow_file_for_batch', arguments: [registry, docId] });
/// tx.moveCall({ target: 'apply_batch_to_file', arguments: [file, actions, clock, ctx] });
/// tx.moveCall({ target: 'return_file_after_batch', arguments: [registry, file] });
/// ```
public fun apply_batch_to_file(
    doc: &mut File,
    actions: vector<ChunkAction>,
    expected_sequence: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<blob::Blob> {
    // Validate initial sequence
    assert!(doc.edit_sequence == expected_sequence, EConcurrentEditConflict);

    let mut removed_blobs = vector::empty<blob::Blob>();
    let mut i = 0;
    let len = vector::length(&actions);

    while (i < len) {
        let action = vector::borrow(&actions, i);

        // All actions must be for this document
        assert!(action.doc_id == get_file_id(doc), EDocumentNotFound);

        // Each action uses current edit_sequence (functions will increment it)
        let current_seq = doc.edit_sequence;

        if (action.action_type == ACTION_ADD_CHUNK) {
            // Add text chunk at end
            let text = *option::borrow(&action.text);
            let chunk_type = *option::borrow(&action.chunk_type);
            let immutable = *option::borrow(&action.immutable);

            add_chunk_with_text(
                doc,
                current_seq,
                text,
                chunk_type,
                action.expires_at,
                action.effective_from,
                immutable,
                action.immutable_from,
                clock,
                ctx,
            );
        } else if (action.action_type == ACTION_INSERT_AFTER) {
            // Insert after specific chunk
            let prev_chunk_id = *option::borrow(&action.prev_chunk_id);
            let text = *option::borrow(&action.text);
            let chunk_type = *option::borrow(&action.chunk_type);
            let immutable = *option::borrow(&action.immutable);

            insert_chunk_with_text_after(
                doc,
                current_seq,
                prev_chunk_id,
                text,
                chunk_type,
                action.expires_at,
                action.effective_from,
                immutable,
                action.immutable_from,
                clock,
                ctx,
            );
        } else if (action.action_type == ACTION_REMOVE_CHUNK) {
            // Remove chunk - check storage type first
            let chunk_id = *option::borrow(&action.chunk_id);
            let chunk = table::borrow(&doc.chunks, chunk_id);
            if (chunk.storage_type == STORAGE_TYPE_TEXT) {
                remove_text_chunk(doc, current_seq, chunk_id, clock);
            } else {
                // Walrus storage - collect removed blob
                let old_blob = remove_chunk(doc, current_seq, chunk_id, clock);
                vector::push_back(&mut removed_blobs, old_blob);
            };
        } else if (action.action_type == ACTION_SET_CHUNK_IMMUTABLE) {
            // Set chunk immutable
            let chunk_id = *option::borrow(&action.chunk_id);
            set_chunk_immutable(doc, current_seq, chunk_id, clock);
        } else {
            // Invalid action type (must be 0, 2, 3, or 4)
            // Note: action_type 1 (update) is intentionally not supported - use remove + add
            abort EInvalidChunkType
        };

        i = i + 1;
    };

    removed_blobs
}

// OLD COMMENTED CODE - Kept for reference, will be removed in future
/*
public fun apply_batch_actions_OLD_BROKEN(
    registry: &mut DaoFileRegistry,
    docs: &mut vector<&mut Document>,  // ← THIS DOESN'T WORK IN MOVE
    batch: BatchDocAction,
    clock: &Clock,
) {
    let actions = batch.actions;
    let i = 0;
    let len = vector::length(&actions);

    while (i < len) {
        let action = vector::borrow(&actions, i);

        // Find the document for this action
        let doc_found = false;
        let j = 0;
        let docs_len = vector::length(docs);

        while (j < docs_len && !doc_found) {
            let doc_ref = vector::borrow_mut(docs, j);
            if (object::uid_to_inner(&doc_ref.id) == action.doc_id) {
                doc_found = true;

                // Execute the action based on type
                if (action.action_type == ACTION_ADD_CHUNK) {
                    // Add text chunk
                    let text = *option::borrow(&action.text);
                    let chunk_type = *option::borrow(&action.chunk_type);
                    let immutable = *option::borrow(&action.immutable);

                    add_chunk_with_text(
                        doc_ref,
                        text,
                        clock,
                        ctx,
                    );
                } else if (action.action_type == ACTION_INSERT_AFTER) {
                    // Insert after specific chunk
                    let prev_chunk_id = *option::borrow(&action.prev_chunk_id);
                    let text = *option::borrow(&action.text);

                    insert_chunk_with_text_after(
                        doc_ref,
                        prev_chunk_id,
                        text,
                        clock,
                        ctx,
                    );
                } else if (action.action_type == ACTION_SET_CHUNK_IMMUTABLE) {
                    // Set chunk immutable
                    let chunk_id = *option::borrow(&action.chunk_id);
                    set_chunk_immutable(doc_ref, chunk_id, clock);
                }
                // Note: We intentionally skip REMOVE_CHUNK and UPDATE_CHUNK in this simplified
                // batch implementation because they require handling Walrus blobs which is
                // complex in batch context. For those operations, use individual functions.
            };
            j = j + 1;
        };

        i = i + 1;
    };
}
*/

/// Get batch ID
public fun get_batch_id(batch: &BatchDocAction): ID {
    batch.batch_id
}

/// Get batch actions
public fun get_batch_actions(batch: &BatchDocAction): &vector<ChunkAction> {
    &batch.actions
}

// === Query Helpers ===

/// Get all chunk IDs in document order by traversing the linked list
/// Returns vector of IDs in the order they appear in the document
/// This is useful for efficient iteration and display
public fun get_ordered_chunk_ids(doc: &File): vector<ID> {
    let mut result = vector::empty<ID>();

    // If no chunks, return empty
    if (doc.chunk_count == 0) {
        return result
    };

    // Start at head and traverse the linked list
    if (option::is_some(&doc.head_chunk)) {
        let mut current_id = *option::borrow(&doc.head_chunk);
        let mut steps = 0;

        // Traverse until we reach the end (with safety limit)
        while (table::contains(&doc.chunks, current_id)) {
            // Check traversal limit FIRST (early abort on cycles)
            assert!(steps <= MAX_TRAVERSAL_LIMIT, ETraversalLimitExceeded);

            vector::push_back(&mut result, current_id);

            let chunk = table::borrow(&doc.chunks, current_id);

            // Move to next chunk if exists
            if (option::is_some(&chunk.next_chunk)) {
                current_id = *option::borrow(&chunk.next_chunk);
                steps = steps + 1;
            } else {
                // Reached the end
                break
            };
        };
    };

    result
}

/// Get full policy state for a document (convenience getter)
/// Returns (allow_insert, allow_remove, immutable)
public fun get_document_full_policy(doc: &File): (bool, bool, bool) {
    (doc.allow_insert, doc.allow_remove, doc.immutable)
}



// I do need is hash of each document and any changes must check hash was as expected  or cant make changes 