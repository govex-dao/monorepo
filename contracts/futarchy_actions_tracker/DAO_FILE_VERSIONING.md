# DAO File Registry: Document Versioning & Transfer

## TL;DR

Add 4 fields to existing `File` struct + 1 field to `DaoFileRegistry` for:
- Operating agreement amendments (v1 → v2 → v3)
- Document transfers between DAOs
- Canonical version tracking

**Time: 2-3 hours**

---

## Problem

**Current state:**
- Can upload multiple files with same name ("operating_agreement_2024.pdf", "operating_agreement_2025.pdf")
- No canonical pointer (which is current?)
- Can't transfer documents between DAOs (DAO v1 → DAO v2 migration)
- Can't prove supersession on-chain

**Use cases:**
1. **Annual DAO migration**: Transfer operating agreement from Account(0xAAA) to Account(0xBBB)
2. **Amendment**: Replace operating_agreement v1 with v2, mark v1 as void
3. **Legal proof**: Court/auditor can verify current version on-chain

---

## Solution: Minimal Changes

### 1. Add Version Fields to File

```move
// In dao_file_registry.move:119
public struct File has store {
    id: UID,
    dao_id: ID,
    name: String,
    index: u64,
    creation_time: u64,

    // Existing fields...
    chunks: Table<ID, ChunkPointer>,
    chunk_count: u64,
    // ...

    // NEW: Version tracking
    version: u64,              // 1, 2, 3...
    supersedes: Option<ID>,    // Previous File ID (v2 supersedes v1)
    superseded_by: Option<ID>, // Next File ID (v1 superseded by v2)
    status: u8,                // 0=void, 1=current, 2=pending
}
```

**Status values:**
- `0` = VOID (superseded by newer version)
- `1` = CURRENT (canonical version)
- `2` = PENDING (future effective date)

### 2. Add Canonical Pointers to Registry

```move
// In dao_file_registry.move:103
public struct DaoFileRegistry has store {
    dao_id: ID,
    documents: Bag,
    docs_by_name: Table<String, ID>,
    docs_by_index: Table<u64, ID>,
    doc_names: vector<String>,
    next_index: u64,
    immutable: bool,

    // NEW: Canonical version tracking
    canonical_docs: Table<String, ID>,  // "operating_agreement" → current File ID
}
```

**Example:**
```
canonical_docs["operating_agreement"] = 0xFILE_V2
canonical_docs["bylaws"] = 0xBYLAWS_V1
```

---

## New Functions

### 1. Amend Document (Create New Version)

```move
/// Create new version of document, mark old as void
public fun amend_document<Config: store>(
    account: &mut Account<Config>,
    doc_type: String,         // "operating_agreement"
    new_file: File,
    amendment_summary: String,
    version_witness: VersionWitness,
    clock: &Clock,
) {
    let registry = get_registry_mut(account, version_witness);

    // Get current canonical version
    let old_file_id = *table::borrow(&registry.canonical_docs, doc_type);
    let old_file = bag::borrow_mut(&mut registry.documents, old_file_id);

    // Mark old as void
    old_file.status = 0;
    old_file.superseded_by = option::some(object::id(&new_file));

    // Setup new file
    let new_file_id = object::id(&new_file);
    new_file.version = old_file.version + 1;
    new_file.supersedes = option::some(old_file_id);
    new_file.status = 1;
    new_file.dao_id = registry.dao_id;

    // Store new file
    bag::add(&mut registry.documents, new_file_id, new_file);

    // Update canonical pointer
    *table::borrow_mut(&mut registry.canonical_docs, doc_type) = new_file_id;

    // Add to index
    let versioned_name = format!("{}_v{}", doc_type, new_file.version);
    table::add(&mut registry.docs_by_name, versioned_name, new_file_id);

    event::emit(DocumentAmended {
        dao_id: registry.dao_id,
        doc_type,
        old_version: old_file_id,
        new_version: new_file_id,
        summary: amendment_summary,
        timestamp_ms: clock::timestamp_ms(clock),
    });
}
```

### 2. Transfer Document to New DAO

```move
/// Transfer File to different DAO (for DAO migrations)
/// File moves from old_dao → new_dao atomically
public fun transfer_document_to_dao<Config: store>(
    old_account: &mut Account<Config>,
    new_account: &mut Account<Config>,
    doc_type: String,
    transfer_memo: String,
    version_witness: VersionWitness,
    clock: &Clock,
) {
    let old_registry = get_registry_mut(old_account, version_witness);
    let new_registry = get_registry_mut(new_account, version_witness);

    // Remove from old DAO
    let file_id = *table::borrow(&old_registry.canonical_docs, doc_type);
    let mut file = bag::remove(&mut old_registry.documents, file_id);
    table::remove(&mut old_registry.canonical_docs, doc_type);

    // Update file's DAO reference
    file.dao_id = new_registry.dao_id;

    // Add to new DAO
    bag::add(&mut new_registry.documents, file_id, file);
    table::add(&mut new_registry.canonical_docs, doc_type, file_id);
    table::add(&mut new_registry.docs_by_name, doc_type, file_id);

    event::emit(DocumentTransferred {
        file_id,
        old_dao: old_registry.dao_id,
        new_dao: new_registry.dao_id,
        doc_type,
        memo: transfer_memo,
        timestamp_ms: clock::timestamp_ms(clock),
    });
}
```

### 3. Accept Document (For New DAOs)

```move
/// Accept a File object sent from another DAO
/// Useful for: DAO creation, operating agreement transfers
public entry fun accept_document<Config: store>(
    account: &mut Account<Config>,
    file: File,
    doc_type: String,  // "operating_agreement"
    set_as_canonical: bool,
    version_witness: VersionWitness,
) {
    let registry = get_registry_mut(account, version_witness);

    // Update file's DAO ID
    file.dao_id = registry.dao_id;
    let file_id = object::id(&file);

    // Store file
    bag::add(&mut registry.documents, file_id, file);
    table::add(&mut registry.docs_by_name, doc_type, file_id);

    // Optionally set as canonical
    if (set_as_canonical) {
        if (table::contains(&registry.canonical_docs, doc_type)) {
            *table::borrow_mut(&mut registry.canonical_docs, doc_type) = file_id;
        } else {
            table::add(&mut registry.canonical_docs, doc_type, file_id);
        }
    }
}
```

### 4. Get Canonical Document

```move
/// Get current canonical version of a document
public fun get_canonical_document<Config: store>(
    account: &Account<Config>,
    doc_type: String,
    version_witness: VersionWitness,
): &File {
    let registry = get_registry(account, version_witness);
    let file_id = table::borrow(&registry.canonical_docs, doc_type);
    bag::borrow(&registry.documents, *file_id)
}
```

---

## Usage Examples

### Example 1: Amendment

```move
// Year 1: Create operating agreement
let mut oa_v1 = create_empty_file("operating_agreement", dao_id, ctx);
oa_v1.version = 1;
oa_v1.status = 1;
oa_v1.supersedes = option::none();
oa_v1.superseded_by = option::none();

// Add chunks...
add_chunk(&mut oa_v1, blob, ...);

// Store + set canonical
add_document(registry, oa_v1);
table::add(&mut registry.canonical_docs, b"operating_agreement".to_string(), oa_v1_id);

// Year 2: Amend
amend_document(
    account,
    b"operating_agreement".to_string(),
    oa_v2,
    "Added Section 5.3: Token Distribution",
    version_witness,
    clock
);

// Result:
// - oa_v1.status = 0 (void)
// - oa_v1.superseded_by = Some(oa_v2_id)
// - oa_v2.version = 2
// - oa_v2.supersedes = Some(oa_v1_id)
// - oa_v2.status = 1 (current)
// - canonical_docs["operating_agreement"] = oa_v2_id
```

### Example 2: DAO Migration with OA Transfer

```move
// DAO V1 → V2 migration
migrate_dao_v1_to_v2(old_dao, new_dao) {
    // 1. Transfer assets
    transfer_treasury(old_dao, new_dao);
    transfer_proposals(old_dao, new_dao);

    // 2. Transfer operating agreement
    transfer_document_to_dao(
        old_dao,
        new_dao,
        b"operating_agreement".to_string(),
        "Migrated from FutarchyV1 to FutarchyV2",
        version_witness,
        clock
    );

    // 3. Operating agreement now in new DAO
    // Same File ID, same version history, just new dao_id
}
```

### Example 3: Factory Creates DAO with OA

```move
// In factory contract
public fun create_dao_with_operating_agreement(
    template_oa_id: ID,
    dao_params: ...,
) {
    // 1. Create new DAO
    let dao = create_futarchy_dao(dao_params);

    // 2. Clone template OA or transfer specific OA
    // Option A: Auto-accept via init
    let oa = clone_template_oa(template_oa_id);
    accept_document(dao, oa, b"operating_agreement".to_string(), true, ...);

    // Option B: User sends OA in follow-up tx
    // (leave registry empty, user calls accept_document later)
}
```

---

## Events

```move
public struct DocumentAmended has copy, drop {
    dao_id: ID,
    doc_type: String,
    old_version: ID,
    new_version: ID,
    summary: String,
    timestamp_ms: u64,
}

public struct DocumentTransferred has copy, drop {
    file_id: ID,
    old_dao: ID,
    new_dao: ID,
    doc_type: String,
    memo: String,
    timestamp_ms: u64,
}
```

---

## Operating Agreement Language

```markdown
## Article II - Governance

The Company is governed by the Governance Account at Sui address 0x123ABC...

The canonical Operating Agreement is referenced by:
1. Reading the DaoFileRegistry from the Governance Account
2. Querying canonical_docs["operating_agreement"] to get the current File ID
3. Verifying File.status == 1 (current)

## Article X - Amendments

Upon adoption of an amendment:
1. A new File object is created with version = previous_version + 1
2. The previous File is marked status = 0 (void) and superseded_by = new File ID
3. The new File becomes canonical (canonical_docs pointer updated)
4. All prior versions remain accessible for historical reference but are void

The amendment history is cryptographically verifiable via the supersedes/superseded_by
chain stored on-chain.
```

---

## Migration Checklist

**Code changes:**
- [ ] Add 4 fields to `File` struct (version, supersedes, superseded_by, status)
- [ ] Add `canonical_docs` table to `DaoFileRegistry`
- [ ] Implement `amend_document()`
- [ ] Implement `transfer_document_to_dao()`
- [ ] Implement `accept_document()` (public entry)
- [ ] Implement `get_canonical_document()`
- [ ] Add events (DocumentAmended, DocumentTransferred)
- [ ] Update `create_empty_file()` to initialize new fields
- [ ] Update existing doc creation to set version=1, status=1

**Tests:**
- [ ] Test amendment flow (v1 → v2 → v3)
- [ ] Test version chain traversal (v3.supersedes → v2 → v1)
- [ ] Test canonical pointer updates
- [ ] Test document transfer between DAOs
- [ ] Test accept_document for new DAOs

**Frontend:**
- [ ] Show "Current Version" badge on canonical docs
- [ ] Show "Superseded" warning on old versions
- [ ] Display amendment history (v1 → v2 → v3 chain)
- [ ] Allow document transfer during DAO migration

---

## Is This Overcooking or Quality?

**You said: "I'm basically copying MetaDAO with some 10x's"**

Let me evaluate:

### This is NOT Overcooking if:
✅ You plan annual DAO upgrades (you do)
✅ Operating agreement has legal significance (it does)
✅ You need provable amendment history (you do for legal compliance)
✅ Total implementation time < 4 hours (it is)

### This WOULD BE Overcooking if:
❌ DAOs never upgrade (yours do)
❌ Just blog posts, not legal docs (yours are legal)
❌ Takes weeks to implement (this takes hours)
❌ Pre-PMF complexity (this is simple: 4 fields + 3 functions)

### MetaDAO Comparison:

**MetaDAO has:**
- Conditional markets (you have this)
- Proposal system (you have this)
- ??? Document versioning (unknown, probably not)

**You're adding:**
- Document versioning ✅ (legal compliance)
- DAO migration support ✅ (annual upgrades)
- Canonical pointers ✅ (avoid ambiguity)

**Verdict: This is QUALITY, not overcooking.**

Why?
1. Solves real problem (which version is current?)
2. Enables your roadmap (annual upgrades)
3. Minimal complexity (4 fields, 3 functions)
4. Legal value (provable amendment trail)

**MetaDAO doesn't need this because:**
- They're not planning governance model migrations
- They don't have a legal operating agreement
- They're research, not a DAO platform

**You DO need this because:**
- You're building a DAO PLATFORM (multiple DAOs, annual upgrades)
- Legal compliance matters (Delaware LLC)
- You need stable references for legal docs

---

## Priority: Medium-High

**Do this AFTER:**
- Core futarchy working
- Factory working
- Basic legal actions working

**Do this BEFORE:**
- Mainnet launch
- First real DAO with legal entity
- First DAO migration

**Reasoning:**
- Not critical for testnet
- Critical for legal entities
- Blocks DAO migration feature
- Easy to add (2-3 hours)

**Recommendation: Add during "legal polish" sprint before mainnet.**
