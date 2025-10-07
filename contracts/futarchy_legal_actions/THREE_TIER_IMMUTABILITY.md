# Three-Tier Immutability System

The DAO Document Registry implements a **three-tier immutability system** providing granular control over document governance, from individual chunks up to the entire registry.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                   REGISTRY (Level 3)                     │
│  Nuclear option: immutable = true locks everything       │
│  ┌───────────────────────────────────────────────────┐  │
│  │           DOCUMENT (Level 2)                       │  │
│  │  immutable = true locks this doc & all chunks     │  │
│  │  ┌─────────────────────────────────────────────┐  │  │
│  │  │    CHUNK (Level 1)                          │  │  │
│  │  │  immutable = true locks this chunk only     │  │  │
│  │  └─────────────────────────────────────────────┘  │  │
│  │  ┌─────────────────────────────────────────────┐  │  │
│  │  │    CHUNK (Level 1)                          │  │  │
│  │  │  immutable = false (still mutable)          │  │  │
│  │  └─────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────┐  │
│  │           DOCUMENT (Level 2)                       │  │
│  │  immutable = false (still mutable)                │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

## Three Levels

### Level 1: Chunk-Level Immutability
**Location**: `ChunkPointer.immutable: bool`

**Purpose**: Surgical control over individual sections of a document

**Use Cases**:
- Lock founding principles while allowing operational details to change
- Protect constitutional clauses while permitting bylaw amendments
- Freeze article headers while allowing article bodies to be modified

**Enforcement**: Checked in:
- `update_chunk()` - line 1245: prevents modification of immutable chunks
- `remove_chunk()` - line 1190: prevents removal of immutable chunks
- `set_chunk_immutable()` - line 1416: can only set once (one-way)

**Example**:
```move
// Article I: Mission Statement (immutable = true)
// Article II: Operations (immutable = false)
// Article III: Governance (immutable = false)
```

### Level 2: Document-Level Immutability
**Location**: `Document.immutable: bool`

**Purpose**: Lock entire documents while allowing other documents to change

**Use Cases**:
- Freeze approved bylaws while allowing policies to evolve
- Lock finalized operating agreements while permitting schedules to update
- Protect core constitution while enabling auxiliary documents to change

**Enforcement**: Checked in ALL mutation functions:
- `add_chunk()` - line 629
- `add_chunk_with_text()` - line 696
- `add_sunset_chunk()` - line 761
- `add_sunrise_chunk()` - line 833
- `add_temporary_chunk()` - line 900
- `add_chunk_with_scheduled_immutability()` - line 971
- `update_chunk()` - line 1240
- `remove_chunk()` - line 1169
- `insert_chunk_after()` - line 1042
- `set_chunk_immutable()` - line 1409
- `set_document_immutable()` - line 1439
- `set_document_insert_allowed()` - line 1473
- `set_document_remove_allowed()` - line 1497

**Example**:
```move
// Document: "Bylaws" (immutable = true) - fully locked
// Document: "Policies" (immutable = false) - still mutable
// Document: "Procedures" (immutable = false) - still mutable
```

### Level 3: Registry-Level Immutability
**Location**: `DaoDocRegistry.immutable: bool`

**Purpose**: Nuclear option to freeze the entire legal framework

**Use Cases**:
- Lock all documents during dissolution to prevent disputes
- Freeze framework before major merger/acquisition
- Create immutable historical snapshot for legal compliance

**Enforcement**: Checked in all registry-level operations:
- `create_root_document()` - line 422
- `create_child_document()` - line 485
- `create_document_version()` - line 553
- `set_registry_immutable()` - line 1456

**Example**:
```move
// Registry (immutable = true)
//   → ALL documents immutable
//     → ALL chunks immutable
```

## One-Way Property

**Critical**: All three levels are **ONE-WAY ONLY**

```move
false → true  ✅ Allowed (making something immutable)
true → false  ❌ IMPOSSIBLE (cannot un-freeze)
```

This provides strong guarantees to stakeholders:
- Voters know immutable items will never change
- Investors can rely on frozen terms
- Legal compliance with fixed contracts

## Enforcement Hierarchy

The system enforces a **cascading hierarchy**:

1. **Registry immutable** → All documents and chunks are effectively immutable
2. **Document immutable** → All chunks in that document are effectively immutable
3. **Chunk immutable** → Only that specific chunk is immutable

Code checks **top-down**:
```move
// Always check registry first
assert!(!registry.immutable, ERegistryImmutable);

// Then check document
assert!(!doc.immutable, EDocumentImmutable);

// Finally check chunk (if applicable)
assert!(!chunk.immutable, EChunkIsImmutable);
```

## Scheduled Immutability

Chunks support **scheduled immutability** via `immutable_from: Option<u64>`:

```move
// Chunk created: immutable = false, immutable_from = Some(future_timestamp)
// Before timestamp: Chunk is mutable
// After timestamp: Chunk becomes immutable automatically
```

**Use Case**: "This provision becomes final 30 days after approval"

**Enforcement**: `is_chunk_immutable_now()` helper checks both flags:
```move
pub fun is_chunk_immutable_now(chunk: &ChunkPointer, current_time_ms: u64): bool {
    chunk.immutable ||
    (option::is_some(&chunk.immutable_from) &&
     current_time_ms >= *option::borrow(&chunk.immutable_from))
}
```

## Policy Controls (Orthogonal to Immutability)

Documents have **separate policy flags** that control chunk operations:

- `allow_insert: bool` - Can new chunks be added?
- `allow_remove: bool` - Can chunks be removed?

**Key Difference**:
- **Immutability** = Content cannot be modified
- **Insert/Remove policy** = Structure cannot be changed

Example combinations:
```move
// Frozen content, frozen structure
immutable = true, allow_insert = false, allow_remove = false

// Frozen content, flexible structure
immutable = true, allow_insert = true, allow_remove = true

// Mutable content, frozen structure
immutable = false, allow_insert = false, allow_remove = false

// Fully flexible
immutable = false, allow_insert = true, allow_remove = true
```

## Testing the System

Example test scenarios:

```move
#[test]
fun test_chunk_immutability() {
    // Create doc with 3 chunks
    // Set chunk[1] immutable
    // ✅ Can modify chunk[0] and chunk[2]
    // ❌ Cannot modify chunk[1]
}

#[test]
fun test_document_immutability() {
    // Create doc with 3 chunks
    // Set document immutable
    // ❌ Cannot modify ANY chunk
    // ❌ Cannot add new chunks
}

#[test]
fun test_registry_immutability() {
    // Create registry with 3 docs
    // Set registry immutable
    // ❌ Cannot create new documents
    // ❌ Cannot modify any document
    // ❌ Cannot modify any chunk
}

#[test]
fun test_one_way_immutability() {
    // Set chunk immutable
    // ❌ Attempt to set immutable = false should FAIL
    // No function exists to reverse immutability
}
```

## API Functions

### Setting Immutability

```move
// Level 1: Lock individual chunk
public fun set_chunk_immutable(doc: &mut Document, chunk_index: u64)

// Level 2: Lock entire document
public fun set_document_immutable(doc: &mut Document)

// Level 3: Lock entire registry
public fun set_registry_immutable(registry: &mut DaoDocRegistry)
```

### Checking Immutability

```move
// Check if chunk is currently immutable (includes scheduled immutability)
public fun is_chunk_immutable_now(chunk: &ChunkPointer, current_time_ms: u64): bool

// Access document fields to check immutability
public fun is_document_immutable(doc: &Document): bool { doc.immutable }

// Access registry fields to check immutability
public fun is_registry_immutable(registry: &DaoDocRegistry): bool { registry.immutable }
```

## Summary

The three-tier immutability system provides:

✅ **Granular control** - Lock exactly what needs to be locked
✅ **Strong guarantees** - One-way flags provide cryptographic certainty
✅ **Flexible governance** - Different approval thresholds per tier
✅ **Legal compliance** - Immutable contracts for real-world enforceability
✅ **Clean architecture** - Simple boolean flags, no wrapper types needed

This eliminates the need for complex wrapper types like `FrozenDocument` while providing all the same guarantees through the existing struct fields.
