/// DAO Document Registry - Clean table-based architecture for multi-document management
/// Replaces operating_agreement.move with superior design:
/// - Multiple named documents per DAO (bylaws, policies, code of conduct)
/// - Parent-child hierarchy (amendments, schedules, exhibits)
/// - Walrus-backed content storage (100MB per doc vs 200KB on-chain)
/// - O(1) lookups by name, index, or parent ID
/// - All time-based provisions preserved (sunset/sunrise/temporary)
/// - Three-tier policy enforcement (registry/document/chunk)
module futarchy_legal_actions::dao_file_registry;

// === Imports ===
use std::{
    string::String,
    option::{Self, Option},
    vector,
};
use sui::{
    clock::{Self, Clock},
    event,
    table::{Self, Table},
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
const EIncorrectLengths: u64 = 0;
const EDocumentNotFound: u64 = 1;
const EDuplicateDocName: u64 = 2;
const ERegistryImmutable: u64 = 3;
const EDocumentImmutable: u64 = 4;
const EChunkNotFound: u64 = 5;
const EInvalidVersion: u64 = 6;
const EDocumentNotActive: u64 = 7;
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
const EInsertNotAllowedForTemporaryChunk: u64 = 20;
const EExpiryTooFarInFuture: u64 = 21;
const ECannotMakeImmutableBeforeScheduled: u64 = 22;
const EEmptyWalrusBlobId: u64 = 23;

// === Type Keys for Dynamic Fields ===

/// Key for storing the registry in the Account
public struct RegistryKey has copy, drop, store {}

public fun new_registry_key(): RegistryKey {
    RegistryKey {}
}

// === Core Structs ===

/// Main registry stored in Account - tracks all documents for a DAO
public struct DaoFileRegistry has store {
    dao_id: ID,

    // Root document lookup (top-level docs like "bylaws", "code-of-conduct")
    root_docs: Table<String, ID>,           // "bylaws" → doc_id
    root_names: vector<String>,             // ["bylaws", "code-of-conduct", ...]

    // Global document indexes
    docs_by_name: Table<String, ID>,        // ALL docs (roots + children)
    docs_by_index: Table<u64, ID>,          // Ordered display (0, 1, 2, ...)
    children_by_parent: Table<ID, vector<ID>>, // parent_id → [child_ids]

    next_index: u64,

    // Global immutability (locks entire registry - nuclear option)
    immutable: bool,
}

/// Individual document (shared object for parallel access)
public struct File has key, store {
    id: UID,
    dao_id: ID,

    // Identity
    name: String,                           // "bylaws", "amendment-001"
    index: u64,                             // Position in registry
    creation_time: u64,

    // Hierarchy
    parent_id: Option<ID>,                  // None = root document

    // Versioning (for amendment tracking)
    version: u64,                           // 1, 2, 3, ...
    previous_version_id: Option<ID>,       // Link to previous version
    superseded_by_id: Option<ID>,          // Link to newer version (if superseded)
    is_active: bool,                        // Only one version active at a time

    // Content (Walrus-backed chunks in linked list)
    chunks: Table<ID, ChunkPointer>,       // chunk_id → ChunkPointer
    chunk_count: u64,
    head_chunk: Option<ID>,                // First chunk ID (None when empty)
    tail_chunk: Option<ID>,                // Last chunk ID for O(1) append

    // Document-level controls (one-way locks)
    allow_insert: bool,                     // Can add new chunks
    allow_remove: bool,                     // Can remove chunks
    immutable: bool,                        // Document-level immutability
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
/// Linked List: next_chunk creates document ordering
/// - Enables indexer reconstruction (start at head, follow next_chunk)
/// - Supports insertion between chunks (insert Article 1.5 between 1 and 2)
/// - None = final chunk in document
public struct ChunkPointer has store {
    id: UID,                                // Unique chunk identifier

    // LINKED LIST: Document ordering
    next_chunk: Option<ID>,                 // Next chunk ID, None = final

    // STORAGE: Exactly one must be populated
    storage_type: u8,                       // 0 = Text, 1 = Walrus Blob

    // Option 1: Text storage (when storage_type == 0)
    text: Option<String>,                   // On-chain text content

    // Option 2: Walrus storage (when storage_type == 1)
    walrus_blob: Option<walrus::blob::Blob>, // Off-chain Walrus blob
    walrus_storage_object_id: Option<ID>,   // Storage object ID for renewal
    walrus_expiry_epoch: Option<u64>,       // Cached expiry epoch for quick lookup

    // Governance
    difficulty: u64,                        // Approval threshold to MODIFY (basis points 0-10000)

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
public struct ChunkAction has store, drop, copy {
    action_type: u8,  // 0=add, 1=update, 2=remove, 3=set_immutable, 4=insert_after

    // Common fields
    doc_id: ID,
    chunk_id: Option<ID>,  // None for add operations

    // For insert_after
    prev_chunk_id: Option<ID>,  // Which chunk to insert after

    // For add/insert operations
    text: Option<String>,
    difficulty: Option<u64>,
    chunk_type: Option<u8>,
    expires_at: Option<u64>,
    effective_from: Option<u64>,
    immutable: Option<bool>,
    immutable_from: Option<u64>,
}

// Action type constants
const ACTION_ADD_CHUNK: u8 = 0;
const ACTION_UPDATE_CHUNK: u8 = 1;
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
    parent_id: Option<ID>,
    version: u64,
    timestamp_ms: u64,
}

public struct ChunkAdded has copy, drop {
    dao_id: ID,
    doc_id: ID,
    chunk_id: ID,
    walrus_blob_id: vector<u8>,  // For events, emit the ID as bytes
    difficulty: u64,
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
    parent_id: Option<ID>,
    version: u64,
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
    parent_id: Option<ID>,
    version: u64,
    is_active: bool,

    // Chunk details in document order
    chunk_ids: vector<ID>,                  // Ordered chunk IDs
    chunk_texts: vector<Option<String>>,    // On-chain text (when storage_type == TEXT)
    chunk_blob_ids: vector<vector<u8>>,     // Walrus blob IDs (when storage_type == WALRUS)
    chunk_storage_types: vector<u8>,        // 0 = text, 1 = walrus
    chunk_difficulties: vector<u64>,        // Approval thresholds per chunk
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

// Removed FrozenDocument-related events (not needed with 3-tier immutability)

// === Registry Management ===

/// Create new registry for a DAO
public fun create_registry(
    dao_id: ID,
    ctx: &mut TxContext,
): DaoFileRegistry {
    DaoFileRegistry {
        dao_id,
        root_docs: table::new(ctx),
        root_names: vector::empty(),
        docs_by_name: table::new(ctx),
        docs_by_index: table::new(ctx),
        children_by_parent: table::new(ctx),
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

// === Document Creation ===

/// Create root document (top-level like "bylaws")
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
        parent_id: option::none(),
        version: 1,
        previous_version_id: option::none(),
        superseded_by_id: option::none(),
        is_active: true,
        chunks: table::new(ctx),
        chunk_count: 0,
        head_chunk: option::none(),      // No chunks yet
        tail_chunk: option::none(),
        allow_insert: true,
        allow_remove: true,
        immutable: false,
    };

    // Update registry indexes
    table::add(&mut registry.root_docs, name, doc_id);
    vector::push_back(&mut registry.root_names, name);
    table::add(&mut registry.docs_by_name, name, doc_id);
    table::add(&mut registry.docs_by_index, registry.next_index, doc_id);
    registry.next_index = registry.next_index + 1;

    event::emit(DocumentCreated {
        dao_id: registry.dao_id,
        doc_id,
        name,
        parent_id: option::none(),
        version: 1,
        timestamp_ms: clock.timestamp_ms(),
    });

    // Share document as separate object
    sui::transfer::public_share_object(doc);

    doc_id
}

/// Create child document (amendment, schedule, exhibit)
public fun create_child_document(
    registry: &mut DaoFileRegistry,
    parent_id: ID,
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
        parent_id: option::some(parent_id),
        version: 1,
        previous_version_id: option::none(),
        superseded_by_id: option::none(),
        is_active: true,
        chunks: table::new(ctx),
        chunk_count: 0,
        head_chunk: option::none(),
        tail_chunk: option::none(),
        allow_insert: true,
        allow_remove: true,
        immutable: false,
    };

    // Update registry indexes
    table::add(&mut registry.docs_by_name, name, doc_id);
    table::add(&mut registry.docs_by_index, registry.next_index, doc_id);
    registry.next_index = registry.next_index + 1;

    // Add to parent's children list
    if (!table::contains(&registry.children_by_parent, parent_id)) {
        table::add(&mut registry.children_by_parent, parent_id, vector::empty());
    };
    let children = table::borrow_mut(&mut registry.children_by_parent, parent_id);
    vector::push_back(children, doc_id);

    event::emit(DocumentCreated {
        dao_id: registry.dao_id,
        doc_id,
        name,
        parent_id: option::some(parent_id),
        version: 1,
        timestamp_ms: clock.timestamp_ms(),
    });

    // Share document as separate object
    sui::transfer::public_share_object(doc);

    doc_id
}

/// Create new version of document (for amendments)
public fun create_document_version(
    registry: &mut DaoFileRegistry,
    previous_doc: &mut File,
    new_name: String,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Check registry not immutable
    assert!(!registry.immutable, ERegistryImmutable);

    // Check name uniqueness
    assert!(!table::contains(&registry.docs_by_name, new_name), EDuplicateDocName);

    // Check document limit
    assert!(registry.next_index < constants::max_documents_per_dao(), ETooManyDocuments);

    let doc_uid = object::new(ctx);
    let new_doc_id = object::uid_to_inner(&doc_uid);
    let prev_doc_id = object::uid_to_inner(&previous_doc.id);

    let new_doc = File {
        id: doc_uid,
        dao_id: registry.dao_id,
        name: new_name,
        index: registry.next_index,
        creation_time: clock.timestamp_ms(),
        parent_id: previous_doc.parent_id,
        version: previous_doc.version + 1,
        previous_version_id: option::some(prev_doc_id),
        superseded_by_id: option::none(),
        is_active: true,
        chunks: table::new(ctx),
        chunk_count: 0,
        head_chunk: option::none(),
        tail_chunk: option::none(),
        allow_insert: true,
        allow_remove: true,
        immutable: false,
    };

    // Mark previous version as superseded
    previous_doc.superseded_by_id = option::some(new_doc_id);
    previous_doc.is_active = false;

    // Update registry indexes
    table::add(&mut registry.docs_by_name, new_name, new_doc_id);
    table::add(&mut registry.docs_by_index, registry.next_index, new_doc_id);
    registry.next_index = registry.next_index + 1;

    event::emit(DocumentCreated {
        dao_id: registry.dao_id,
        doc_id: new_doc_id,
        name: new_name,
        parent_id: previous_doc.parent_id,
        version: previous_doc.version + 1,
        timestamp_ms: clock.timestamp_ms(),
    });

    // Share new document
    sui::transfer::public_share_object(new_doc);

    new_doc_id
}

// === Unshared Document Creation (For Large Document Construction) ===

/// Create document as owned object (Phase 1: Private staging)
/// Returns unshared Document for multi-transaction construction
/// Proposer can build document incrementally over multiple transactions
/// Document is NOT shared, so no one else can modify it during construction
// Removed FrozenDocument functions - not needed with 3-tier immutability system

// === Chunk Operations ===

/// Add permanent chunk
/// Takes ownership of Walrus Blob object (cheap - just metadata, not content)
public fun add_chunk(
    doc: &mut File,
    walrus_blob: blob::Blob,
    difficulty: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Check document not immutable
    assert!(!doc.immutable, EDocumentImmutable);
    assert!(doc.allow_insert, EInsertNotAllowed);
    assert!(doc.chunk_count < constants::max_chunks_per_document(), ETooManyChunks);

    // Create UID for chunk
    let chunk_uid = object::new(ctx);
    let chunk_id = object::uid_to_inner(&chunk_uid);

    let blob_id = blob::blob_id(&walrus_blob);
    let expiry_epoch = blob::end_epoch(&walrus_blob) as u64;

    // Update linked list: append to tail
    let position_after = if (option::is_some(&doc.tail_chunk)) {
        let tail_id = *option::borrow(&doc.tail_chunk);
        let tail_chunk = table::borrow_mut(&mut doc.chunks, tail_id);
        tail_chunk.next_chunk = option::some(chunk_id);
        option::some(tail_id)
    } else {
        // First chunk - set as head
        doc.head_chunk = option::some(chunk_id);
        option::none()
    };

    let chunk = ChunkPointer {
        id: chunk_uid,
        next_chunk: option::none(),  // Last chunk (for now)
        storage_type: STORAGE_TYPE_WALRUS,
        text: option::none(),
        walrus_blob: option::some(walrus_blob),
        walrus_storage_object_id: option::none(),
        walrus_expiry_epoch: option::some(expiry_epoch),
        difficulty,
        immutable: false,
        immutable_from: option::none(),
        chunk_type: CHUNK_TYPE_PERMANENT,
        expires_at: option::none(),
        effective_from: option::none(),
    };

    table::add(&mut doc.chunks, chunk_id, chunk);
    doc.chunk_count = doc.chunk_count + 1;
    doc.tail_chunk = option::some(chunk_id);  // Update tail

    event::emit(ChunkAdded {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id,
        walrus_blob_id: bcs::to_bytes(&blob_id),
        difficulty,
        chunk_type: CHUNK_TYPE_PERMANENT,
        expires_at: option::none(),
        effective_from: option::none(),
        immutable_from: option::none(),
        position_after,  // Track where chunk was inserted
        timestamp_ms: clock.timestamp_ms(),
    });

    chunk_id
}

/// Add chunk with text storage (for small content, operating agreement lines)
public fun add_chunk_with_text(
    doc: &mut File,
    text: String,
    difficulty: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Check document not immutable
    assert!(!doc.immutable, EDocumentImmutable);
    assert!(doc.allow_insert, EInsertNotAllowed);
    assert!(doc.chunk_count < constants::max_chunks_per_document(), ETooManyChunks);

    // Create UID for chunk
    let chunk_uid = object::new(ctx);
    let chunk_id = object::uid_to_inner(&chunk_uid);

    // Update linked list: append to tail
    let position_after = if (option::is_some(&doc.tail_chunk)) {
        let tail_id = *option::borrow(&doc.tail_chunk);
        let tail_chunk = table::borrow_mut(&mut doc.chunks, tail_id);
        tail_chunk.next_chunk = option::some(chunk_id);
        option::some(tail_id)
    } else {
        doc.head_chunk = option::some(chunk_id);
        option::none()
    };

    let chunk = ChunkPointer {
        id: chunk_uid,
        next_chunk: option::none(),
        storage_type: STORAGE_TYPE_TEXT,
        text: option::some(text),
        walrus_blob: option::none(),
        walrus_storage_object_id: option::none(),
        walrus_expiry_epoch: option::none(),
        difficulty,
        immutable: false,
        immutable_from: option::none(),
        chunk_type: CHUNK_TYPE_PERMANENT,
        expires_at: option::none(),
        effective_from: option::none(),
    };

    table::add(&mut doc.chunks, chunk_id, chunk);
    doc.chunk_count = doc.chunk_count + 1;
    doc.tail_chunk = option::some(chunk_id);

    event::emit(ChunkAdded {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id,
        walrus_blob_id: vector::empty(), // No blob for text storage
        difficulty,
        chunk_type: CHUNK_TYPE_PERMANENT,
        expires_at: option::none(),
        effective_from: option::none(),
        immutable_from: option::none(),
        position_after,
        timestamp_ms: clock.timestamp_ms(),
    });

    chunk_id
}

/// Add sunset chunk (auto-deactivates after expiry)
public fun add_sunset_chunk(
    doc: &mut File,
    walrus_blob: blob::Blob,
    difficulty: u64,
    expires_at_ms: u64,
    immutable: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Check document not immutable
    assert!(!doc.immutable, EDocumentImmutable);
    assert!(doc.allow_insert, EInsertNotAllowed);
    assert!(doc.allow_remove, ERemoveNotAllowed); // Need removal for cleanup
    assert!(doc.chunk_count < constants::max_chunks_per_document(), ETooManyChunks);

    // Validate time
    let now = clock.timestamp_ms();
    assert!(expires_at_ms > now, EInvalidTimeOrder);
    assert!(expires_at_ms <= now + MAX_EXPIRY_TIME_MS, EExpiryTooFarInFuture);

    let chunk_uid = object::new(ctx);
    let chunk_id = object::uid_to_inner(&chunk_uid);
    let blob_id = blob::blob_id(&walrus_blob);
    let expiry_epoch = blob::end_epoch(&walrus_blob) as u64;

    // Update linked list: append to tail
    let position_after = if (option::is_some(&doc.tail_chunk)) {
        let tail_id = *option::borrow(&doc.tail_chunk);
        let tail_chunk = table::borrow_mut(&mut doc.chunks, tail_id);
        tail_chunk.next_chunk = option::some(chunk_id);
        option::some(tail_id)
    } else {
        doc.head_chunk = option::some(chunk_id);
        option::none()
    };

    let chunk = ChunkPointer {
        id: chunk_uid,
        next_chunk: option::none(),
        storage_type: STORAGE_TYPE_WALRUS,
        text: option::none(),
        walrus_blob: option::some(walrus_blob),
        walrus_storage_object_id: option::none(),
        walrus_expiry_epoch: option::some(expiry_epoch),
        difficulty,
        immutable,
        immutable_from: option::none(),
        chunk_type: CHUNK_TYPE_SUNSET,
        expires_at: option::some(expires_at_ms),
        effective_from: option::none(),
    };

    table::add(&mut doc.chunks, chunk_id, chunk);
    doc.chunk_count = doc.chunk_count + 1;
    doc.tail_chunk = option::some(chunk_id);

    event::emit(ChunkAdded {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id,
        walrus_blob_id: bcs::to_bytes(&blob_id),
        difficulty,
        chunk_type: CHUNK_TYPE_SUNSET,
        expires_at: option::some(expires_at_ms),
        effective_from: option::none(),
        immutable_from: option::none(),
        position_after,
        timestamp_ms: clock.timestamp_ms(),
    });

    chunk_id
}

/// Add sunrise chunk (activates after effective_from)
public fun add_sunrise_chunk(
    doc: &mut File,
    walrus_blob: blob::Blob,
    difficulty: u64,
    effective_from_ms: u64,
    immutable: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Check document not immutable
    assert!(!doc.immutable, EDocumentImmutable);
    assert!(doc.allow_insert, EInsertNotAllowed);
    assert!(doc.chunk_count < constants::max_chunks_per_document(), ETooManyChunks);

    let chunk_uid = object::new(ctx);
    let chunk_id = object::uid_to_inner(&chunk_uid);
    let blob_id = blob::blob_id(&walrus_blob);
    let expiry_epoch = blob::end_epoch(&walrus_blob) as u64;

    // Update linked list: append to tail
    let position_after = if (option::is_some(&doc.tail_chunk)) {
        let tail_id = *option::borrow(&doc.tail_chunk);
        let tail_chunk = table::borrow_mut(&mut doc.chunks, tail_id);
        tail_chunk.next_chunk = option::some(chunk_id);
        option::some(tail_id)
    } else {
        doc.head_chunk = option::some(chunk_id);
        option::none()
    };

    let chunk = ChunkPointer {
        id: chunk_uid,
        next_chunk: option::none(),
        storage_type: STORAGE_TYPE_WALRUS,
        text: option::none(),
        walrus_blob: option::some(walrus_blob),
        walrus_storage_object_id: option::none(),
        walrus_expiry_epoch: option::some(expiry_epoch),
        difficulty,
        immutable,
        immutable_from: option::none(),
        chunk_type: CHUNK_TYPE_SUNRISE,
        expires_at: option::none(),
        effective_from: option::some(effective_from_ms),
    };

    table::add(&mut doc.chunks, chunk_id, chunk);
    doc.chunk_count = doc.chunk_count + 1;
    doc.tail_chunk = option::some(chunk_id);

    event::emit(ChunkAdded {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id,
        walrus_blob_id: bcs::to_bytes(&blob_id),
        difficulty,
        chunk_type: CHUNK_TYPE_SUNRISE,
        expires_at: option::none(),
        effective_from: option::some(effective_from_ms),
        immutable_from: option::none(),
        position_after,
        timestamp_ms: clock.timestamp_ms(),
    });

    chunk_id
}

/// Add temporary chunk (active between effective_from and expires_at)
public fun add_temporary_chunk(
    doc: &mut File,
    walrus_blob: blob::Blob,
    difficulty: u64,
    effective_from_ms: u64,
    expires_at_ms: u64,
    immutable: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Check document not immutable
    assert!(!doc.immutable, EDocumentImmutable);
    assert!(doc.allow_insert, EInsertNotAllowed);
    assert!(doc.allow_remove, EInsertNotAllowedForTemporaryChunk);
    assert!(doc.chunk_count < constants::max_chunks_per_document(), ETooManyChunks);
    assert!(effective_from_ms < expires_at_ms, EInvalidTimeOrder);

    // Validate times
    let now = clock.timestamp_ms();
    assert!(expires_at_ms <= now + MAX_EXPIRY_TIME_MS, EExpiryTooFarInFuture);

    let chunk_uid = object::new(ctx);
    let chunk_id = object::uid_to_inner(&chunk_uid);
    let blob_id = blob::blob_id(&walrus_blob);
    let expiry_epoch = blob::end_epoch(&walrus_blob) as u64;

    // Update linked list: append to tail
    let position_after = if (option::is_some(&doc.tail_chunk)) {
        let tail_id = *option::borrow(&doc.tail_chunk);
        let tail_chunk = table::borrow_mut(&mut doc.chunks, tail_id);
        tail_chunk.next_chunk = option::some(chunk_id);
        option::some(tail_id)
    } else {
        doc.head_chunk = option::some(chunk_id);
        option::none()
    };

    let chunk = ChunkPointer {
        id: chunk_uid,
        next_chunk: option::none(),
        storage_type: STORAGE_TYPE_WALRUS,
        text: option::none(),
        walrus_blob: option::some(walrus_blob),
        walrus_storage_object_id: option::none(),
        walrus_expiry_epoch: option::some(expiry_epoch),
        difficulty,
        immutable,
        immutable_from: option::none(),
        chunk_type: CHUNK_TYPE_TEMPORARY,
        expires_at: option::some(expires_at_ms),
        effective_from: option::some(effective_from_ms),
    };

    table::add(&mut doc.chunks, chunk_id, chunk);
    doc.chunk_count = doc.chunk_count + 1;
    doc.tail_chunk = option::some(chunk_id);

    event::emit(ChunkAdded {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id,
        walrus_blob_id: bcs::to_bytes(&blob_id),
        difficulty,
        chunk_type: CHUNK_TYPE_TEMPORARY,
        expires_at: option::some(expires_at_ms),
        effective_from: option::some(effective_from_ms),
        immutable_from: option::none(),
        position_after,
        timestamp_ms: clock.timestamp_ms(),
    });

    chunk_id
}

/// Add chunk with scheduled immutability
public fun add_chunk_with_scheduled_immutability(
    doc: &mut File,
    walrus_blob: blob::Blob,
    difficulty: u64,
    immutable_from_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Check document not immutable
    assert!(!doc.immutable, EDocumentImmutable);
    assert!(doc.allow_insert, EInsertNotAllowed);
    assert!(doc.chunk_count < constants::max_chunks_per_document(), ETooManyChunks);

    // Validate time
    let now = clock.timestamp_ms();
    assert!(immutable_from_ms > now, EInvalidTimeOrder);
    assert!(immutable_from_ms <= now + MAX_EXPIRY_TIME_MS, EExpiryTooFarInFuture);

    let chunk_uid = object::new(ctx);
    let chunk_id = object::uid_to_inner(&chunk_uid);
    let blob_id = blob::blob_id(&walrus_blob);
    let expiry_epoch = blob::end_epoch(&walrus_blob) as u64;

    // Update linked list: append to tail
    let position_after = if (option::is_some(&doc.tail_chunk)) {
        let tail_id = *option::borrow(&doc.tail_chunk);
        let tail_chunk = table::borrow_mut(&mut doc.chunks, tail_id);
        tail_chunk.next_chunk = option::some(chunk_id);
        option::some(tail_id)
    } else {
        doc.head_chunk = option::some(chunk_id);
        option::none()
    };

    let chunk = ChunkPointer {
        id: chunk_uid,
        next_chunk: option::none(),
        storage_type: STORAGE_TYPE_WALRUS,
        text: option::none(),
        walrus_blob: option::some(walrus_blob),
        walrus_storage_object_id: option::none(),
        walrus_expiry_epoch: option::some(expiry_epoch),
        difficulty,
        immutable: false,  // Starts mutable
        immutable_from: option::some(immutable_from_ms),
        chunk_type: CHUNK_TYPE_PERMANENT,
        expires_at: option::none(),
        effective_from: option::none(),
    };

    table::add(&mut doc.chunks, chunk_id, chunk);
    doc.chunk_count = doc.chunk_count + 1;
    doc.tail_chunk = option::some(chunk_id);

    event::emit(ChunkAdded {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id,
        walrus_blob_id: bcs::to_bytes(&blob_id),
        difficulty,
        chunk_type: CHUNK_TYPE_PERMANENT,
        expires_at: option::none(),
        effective_from: option::none(),
        immutable_from: option::some(immutable_from_ms),
        position_after,
        timestamp_ms: clock.timestamp_ms(),
    });

    chunk_id
}

/// Insert chunk after a specific position (for mid-document edits like "Article 1.5")
/// This is essential for precise legal document amendments
public fun insert_chunk_after(
    doc: &mut File,
    prev_chunk_id: ID,
    walrus_blob: blob::Blob,
    difficulty: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Check document not immutable
    assert!(!doc.immutable, EDocumentImmutable);
    assert!(doc.allow_insert, EInsertNotAllowed);
    assert!(doc.chunk_count < constants::max_chunks_per_document(), ETooManyChunks);
    assert!(table::contains(&doc.chunks, prev_chunk_id), EChunkNotFound);

    let new_chunk_uid = object::new(ctx);
    let new_chunk_id = object::uid_to_inner(&new_chunk_uid);
    let blob_id = blob::blob_id(&walrus_blob);
    let expiry_epoch = blob::end_epoch(&walrus_blob) as u64;

    // Get the previous chunk's next pointer
    let prev_chunk = table::borrow_mut(&mut doc.chunks, prev_chunk_id);
    let old_next = prev_chunk.next_chunk;

    // Update previous chunk to point to new chunk
    prev_chunk.next_chunk = option::some(new_chunk_id);

    // If inserting at the end, update tail
    if (option::is_none(&old_next)) {
        doc.tail_chunk = option::some(new_chunk_id);
    };

    // Create new chunk pointing to what prev_chunk used to point to
    let new_chunk = ChunkPointer {
        id: new_chunk_uid,
        next_chunk: old_next,  // Insert in the middle
        storage_type: STORAGE_TYPE_WALRUS,
        text: option::none(),
        walrus_blob: option::some(walrus_blob),
        walrus_storage_object_id: option::none(),
        walrus_expiry_epoch: option::some(expiry_epoch),
        difficulty,
        immutable: false,
        immutable_from: option::none(),
        chunk_type: CHUNK_TYPE_PERMANENT,
        expires_at: option::none(),
        effective_from: option::none(),
    };

    table::add(&mut doc.chunks, new_chunk_id, new_chunk);
    doc.chunk_count = doc.chunk_count + 1;

    event::emit(ChunkAdded {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id: new_chunk_id,
        walrus_blob_id: bcs::to_bytes(&blob_id),
        difficulty,
        chunk_type: CHUNK_TYPE_PERMANENT,
        expires_at: option::none(),
        effective_from: option::none(),
        immutable_from: option::none(),
        position_after: option::some(prev_chunk_id),
        timestamp_ms: clock.timestamp_ms(),
    });

    new_chunk_id
}

/// Insert chunk with text after a specific position
public fun insert_chunk_with_text_after(
    doc: &mut File,
    prev_chunk_id: ID,
    text: String,
    difficulty: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert!(!doc.immutable, EDocumentImmutable);
    assert!(doc.allow_insert, EInsertNotAllowed);
    assert!(doc.chunk_count < constants::max_chunks_per_document(), ETooManyChunks);
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
    };

    // Create new chunk with text
    let new_chunk = ChunkPointer {
        id: new_chunk_uid,
        next_chunk: old_next,
        storage_type: STORAGE_TYPE_TEXT,
        text: option::some(text),
        walrus_blob: option::none(),
        walrus_storage_object_id: option::none(),
        walrus_expiry_epoch: option::none(),
        difficulty,
        immutable: false,
        immutable_from: option::none(),
        chunk_type: CHUNK_TYPE_PERMANENT,
        expires_at: option::none(),
        effective_from: option::none(),
    };

    table::add(&mut doc.chunks, new_chunk_id, new_chunk);
    doc.chunk_count = doc.chunk_count + 1;

    event::emit(ChunkAdded {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id: new_chunk_id,
        walrus_blob_id: vector::empty(),
        difficulty,
        chunk_type: CHUNK_TYPE_PERMANENT,
        expires_at: option::none(),
        effective_from: option::none(),
        immutable_from: option::none(),
        position_after: option::some(prev_chunk_id),
        timestamp_ms: clock.timestamp_ms(),
    });

    new_chunk_id
}

/// Update chunk (only if not immutable)
public fun update_chunk(
    doc: &mut File,
    chunk_id: ID,
    new_walrus_blob: blob::Blob,
    clock: &Clock,
): blob::Blob {
    assert!(!doc.immutable, EDocumentImmutable);
    assert!(table::contains(&doc.chunks, chunk_id), EChunkNotFound);

    // Remove old chunk to get ownership
    let ChunkPointer {
        id: chunk_uid,
        next_chunk,
        storage_type: _,
        text: _,
        walrus_blob: old_blob_option,
        walrus_storage_object_id: _,
        walrus_expiry_epoch: _,
        difficulty,
        immutable,
        immutable_from,
        chunk_type,
        expires_at,
        effective_from,
    } = table::remove(&mut doc.chunks, chunk_id);

    // Check if chunk was immutable
    let current_time_ms = clock.timestamp_ms();
    assert!(!immutable, EChunkIsImmutable);
    if (option::is_some(&immutable_from)) {
        assert!(current_time_ms < *option::borrow(&immutable_from), EChunkIsImmutable);
    };

    // Extract old blob from option (must be Walrus storage for update)
    let old_blob = option::destroy_some(old_blob_option);
    let old_blob_id = blob::blob_id(&old_blob);
    let new_blob_id = blob::blob_id(&new_walrus_blob);
    let new_expiry_epoch = blob::end_epoch(&new_walrus_blob) as u64;

    // Create new chunk with new blob
    let new_chunk = ChunkPointer {
        id: chunk_uid,
        next_chunk,
        storage_type: STORAGE_TYPE_WALRUS,
        text: option::none(),
        walrus_blob: option::some(new_walrus_blob),
        walrus_storage_object_id: option::none(),
        walrus_expiry_epoch: option::some(new_expiry_epoch),
        difficulty,
        immutable,
        immutable_from,
        chunk_type,
        expires_at,
        effective_from,
    };

    table::add(&mut doc.chunks, chunk_id, new_chunk);

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

/// Remove chunk (only if not immutable and allow_remove = true)
/// Returns the Blob so caller can handle it (transfer, delete, etc.)
/// NOTE: Only works for Walrus storage chunks. Text chunks have no blob to return.
/// IMPORTANT: Properly relinks the list by finding the predecessor chunk
public fun remove_chunk(
    doc: &mut File,
    chunk_id: ID,
    clock: &Clock,
): blob::Blob {
    assert!(!doc.immutable, EDocumentImmutable);
    assert!(doc.allow_remove, ERemoveNotAllowed);
    assert!(table::contains(&doc.chunks, chunk_id), EChunkNotFound);

    let chunk = table::borrow(&doc.chunks, chunk_id);
    assert!(!is_chunk_immutable_now(chunk, clock.timestamp_ms()), EChunkIsImmutable);

    // Remove the chunk and capture its next pointer
    let ChunkPointer {
        id: chunk_uid,
        next_chunk: removed_next,
        storage_type: _,
        text: _,
        walrus_blob: walrus_blob_option,
        walrus_storage_object_id: _,
        walrus_expiry_epoch: _,
        difficulty: _,
        immutable: _,
        immutable_from: _,
        chunk_type: _,
        expires_at: _,
        effective_from: _,
    } = table::remove(&mut doc.chunks, chunk_id);

    // Delete the UID
    object::delete(chunk_uid);

    // CRITICAL: Relink the list by finding predecessor
    // Check if removing the head chunk
    if (option::is_some(&doc.head_chunk) && *option::borrow(&doc.head_chunk) == chunk_id) {
        // Update head to point to the chunk after removed one
        doc.head_chunk = removed_next;
    } else {
        // Not removing head - traverse to find predecessor (O(n) operation)
        if (option::is_some(&doc.head_chunk)) {
            let mut current_id = *option::borrow(&doc.head_chunk);
            let mut found = false;

            while (!found && table::contains(&doc.chunks, current_id)) {
                let current_chunk = table::borrow_mut(&mut doc.chunks, current_id);

                // Check if this chunk points to the one we're removing
                if (option::is_some(&current_chunk.next_chunk) &&
                    *option::borrow(&current_chunk.next_chunk) == chunk_id) {
                    // Found predecessor - update its next pointer to skip removed chunk
                    current_chunk.next_chunk = removed_next;
                    found = true;
                } else if (option::is_some(&current_chunk.next_chunk)) {
                    // Move to next chunk in the list
                    current_id = *option::borrow(&current_chunk.next_chunk);
                } else {
                    // Dead end - shouldn't happen in well-formed list
                    break
                }
            }
        }
    };

    // Update tail if we removed the tail chunk
    if (option::is_some(&doc.tail_chunk) && *option::borrow(&doc.tail_chunk) == chunk_id) {
        doc.tail_chunk = option::none();
    };

    doc.chunk_count = doc.chunk_count - 1;

    event::emit(ChunkRemoved {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id,
        timestamp_ms: clock.timestamp_ms(),
    });

    // Extract blob from option (must be Walrus storage)
    option::destroy_some(walrus_blob_option)
}

/// Remove expired chunk (can remove even if immutable - expiry overrides immutability)
/// Returns the Blob for caller to handle
/// IMPORTANT: Properly relinks the list by finding the predecessor chunk
public fun remove_expired_chunk(
    doc: &mut File,
    chunk_id: ID,
    clock: &Clock,
): blob::Blob {
    assert!(doc.allow_remove, ERemoveNotAllowed);
    assert!(table::contains(&doc.chunks, chunk_id), EChunkNotFound);

    let chunk = table::borrow(&doc.chunks, chunk_id);
    let now = clock.timestamp_ms();

    // Must have expiry and be past it
    assert!(option::is_some(&chunk.expires_at), EChunkHasNoExpiry);
    assert!(now >= *option::borrow(&chunk.expires_at), EChunkNotExpired);

    // Remove the chunk and capture its next pointer
    let ChunkPointer {
        id: chunk_uid,
        next_chunk: removed_next,
        storage_type: _,
        text: _,
        walrus_blob: walrus_blob_option,
        walrus_storage_object_id: _,
        walrus_expiry_epoch: _,
        difficulty: _,
        immutable: _,
        immutable_from: _,
        chunk_type: _,
        expires_at: _,
        effective_from: _,
    } = table::remove(&mut doc.chunks, chunk_id);

    // Delete the UID
    object::delete(chunk_uid);

    // CRITICAL: Relink the list by finding predecessor
    // Check if removing the head chunk
    if (option::is_some(&doc.head_chunk) && *option::borrow(&doc.head_chunk) == chunk_id) {
        // Update head to point to the chunk after removed one
        doc.head_chunk = removed_next;
    } else {
        // Not removing head - traverse to find predecessor (O(n) operation)
        if (option::is_some(&doc.head_chunk)) {
            let mut current_id = *option::borrow(&doc.head_chunk);
            let mut found = false;

            while (!found && table::contains(&doc.chunks, current_id)) {
                let current_chunk = table::borrow_mut(&mut doc.chunks, current_id);

                // Check if this chunk points to the one we're removing
                if (option::is_some(&current_chunk.next_chunk) &&
                    *option::borrow(&current_chunk.next_chunk) == chunk_id) {
                    // Found predecessor - update its next pointer to skip removed chunk
                    current_chunk.next_chunk = removed_next;
                    found = true;
                } else if (option::is_some(&current_chunk.next_chunk)) {
                    // Move to next chunk in the list
                    current_id = *option::borrow(&current_chunk.next_chunk);
                } else {
                    // Dead end - shouldn't happen in well-formed list
                    break
                }
            }
        }
    };

    // Update tail if we removed the tail chunk
    if (option::is_some(&doc.tail_chunk) && *option::borrow(&doc.tail_chunk) == chunk_id) {
        doc.tail_chunk = option::none();
    };

    doc.chunk_count = doc.chunk_count - 1;

    event::emit(ChunkRemoved {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        chunk_id,
        timestamp_ms: clock.timestamp_ms(),
    });

    // Extract blob from option
    option::destroy_some(walrus_blob_option)
}

// === Immutability Controls ===

/// Set chunk as permanently immutable
public fun set_chunk_immutable(
    doc: &mut File,
    chunk_id: ID,
    clock: &Clock,
) {
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
    clock: &Clock,
) {
    assert!(!doc.immutable, EAlreadyImmutable);

    doc.immutable = true;

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
    allowed: bool,
    clock: &Clock,
) {
    assert!(!doc.immutable, EDocumentImmutable);

    // One-way lock
    if (!allowed) {
        doc.allow_insert = false;
    } else {
        assert!(doc.allow_insert, ECannotReEnableInsert);
    };

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
    allowed: bool,
    clock: &Clock,
) {
    assert!(!doc.immutable, EDocumentImmutable);

    // One-way lock
    if (!allowed) {
        doc.allow_remove = false;
    } else {
        assert!(doc.allow_remove, ECannotReEnableRemove);
    };

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

/// Get all root document names
public fun get_root_names(registry: &DaoFileRegistry): &vector<String> {
    &registry.root_names
}

/// Get children of a document
public fun get_children(
    registry: &DaoFileRegistry,
    parent_id: ID,
): vector<ID> {
    if (table::contains(&registry.children_by_parent, parent_id)) {
        *table::borrow(&registry.children_by_parent, parent_id)
    } else {
        vector::empty()
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

/// Get chunk difficulty
public fun get_chunk_difficulty(doc: &File, chunk_id: ID): u64 {
    assert!(table::contains(&doc.chunks, chunk_id), EChunkNotFound);
    table::borrow(&doc.chunks, chunk_id).difficulty
}

/// Read and emit full document state
public fun read_document(doc: &File, clock: &Clock) {
    let mut blob_ids = vector::empty<vector<u8>>();

    // Traverse linked list starting from head
    if (option::is_some(&doc.head_chunk)) {
        let mut current_id = *option::borrow(&doc.head_chunk);
        let mut visited = 0;

        while (visited < doc.chunk_count && table::contains(&doc.chunks, current_id)) {
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
                visited = visited + 1;
            } else {
                break
            };
        };
    };

    event::emit(DocumentRead {
        dao_id: doc.dao_id,
        doc_id: object::uid_to_inner(&doc.id),
        name: doc.name,
        parent_id: doc.parent_id,
        version: doc.version,
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

public fun get_document_parent_id(doc: &File): Option<ID> {
    doc.parent_id
}

public fun get_document_version(doc: &File): u64 {
    doc.version
}

public fun is_document_active(doc: &File): bool {
    doc.is_active
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
    let blob_ref = option::borrow(&chunk.walrus_blob);
    blob::blob_id(blob_ref)
}

// === Walrus Renewal Helper Functions ===

/// Check if a chunk needs Walrus renewal (for walrus_renewal module)
public fun chunk_needs_walrus_renewal(
    chunk: &ChunkPointer,
    current_epoch: u64,
    threshold_epochs: u64,
): bool {
    // Must have Walrus storage
    if (option::is_none(&chunk.walrus_expiry_epoch)) return false;

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
        let mut visited = 0;

        while (visited < doc.chunk_count && table::contains(&doc.chunks, current_id)) {
            let chunk = table::borrow(&doc.chunks, current_id);
            if (chunk_needs_walrus_renewal(chunk, current_epoch, threshold_epochs)) {
                vector::push_back(&mut chunks_to_renew, current_id);
            };

            // Move to next chunk
            if (option::is_some(&chunk.next_chunk)) {
                current_id = *option::borrow(&chunk.next_chunk);
                visited = visited + 1;
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
    chunk_id: ID,
    new_expiry_epoch: u64,
) {
    assert!(table::contains(&doc.chunks, chunk_id), EChunkNotFound);
    let chunk = table::borrow_mut(&mut doc.chunks, chunk_id);
    chunk.walrus_expiry_epoch = option::some(new_expiry_epoch);
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
    chunk_id: ID,
    storage_object_id: ID,
    expiry_epoch: u64,
) {
    assert!(table::contains(&doc.chunks, chunk_id), EChunkNotFound);
    let chunk = table::borrow_mut(&mut doc.chunks, chunk_id);
    chunk.walrus_storage_object_id = option::some(storage_object_id);
    chunk.walrus_expiry_epoch = option::some(expiry_epoch);
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
    difficulty: u64,
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
        difficulty: option::some(difficulty),
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
    difficulty: u64,
): ChunkAction {
    ChunkAction {
        action_type: ACTION_INSERT_AFTER,
        doc_id,
        chunk_id: option::none(),
        prev_chunk_id: option::some(prev_chunk_id),
        text: option::some(text),
        difficulty: option::some(difficulty),
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
        difficulty: option::none(),
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
        difficulty: option::none(),
        chunk_type: option::none(),
        expires_at: option::none(),
        effective_from: option::none(),
        immutable: option::none(),
        immutable_from: option::none(),
    }
}

/// Execute a batch of chunk actions atomically
/// This allows complex multi-step edits like "remove Article 2, insert new Article 2.5"
/// NOTE: Batch operations are currently disabled due to Move limitations with vector<&mut T>
/// For batch operations, call individual functions sequentially in a PTB
/*
public fun apply_batch_actions(
    registry: &mut DaoFileRegistry,
    docs: &mut vector<&mut Document>,
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
                    let difficulty = *option::borrow(&action.difficulty);
                    let chunk_type = *option::borrow(&action.chunk_type);
                    let immutable = *option::borrow(&action.immutable);

                    add_chunk_with_text(
                        doc_ref,
                        text,
                        difficulty,
                        clock,
                        ctx,
                    );
                } else if (action.action_type == ACTION_INSERT_AFTER) {
                    // Insert after specific chunk
                    let prev_chunk_id = *option::borrow(&action.prev_chunk_id);
                    let text = *option::borrow(&action.text);
                    let difficulty = *option::borrow(&action.difficulty);

                    insert_chunk_with_text_after(
                        doc_ref,
                        prev_chunk_id,
                        text,
                        difficulty,
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
        let mut visited = 0;

        // Traverse until we reach the end or have visited all chunks
        while (visited < doc.chunk_count && table::contains(&doc.chunks, current_id)) {
            vector::push_back(&mut result, current_id);

            let chunk = table::borrow(&doc.chunks, current_id);

            // Move to next chunk if exists
            if (option::is_some(&chunk.next_chunk)) {
                current_id = *option::borrow(&chunk.next_chunk);
                visited = visited + 1;
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