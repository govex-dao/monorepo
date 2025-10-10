/// Shared SEAL Commit-Reveal Utilities
///
/// This module provides time-locked encryption using Walrus SEAL for hiding
/// sensitive proposal parameters until after they enter the queue.
///
/// ## Security Model
///
/// 1. **Commitment Phase**: Creator submits hash(params || salt) on-chain
/// 2. **Encryption**: Creator uploads encrypted(params || salt) to Walrus SEAL with time-lock
/// 3. **Queue Phase**: Proposal waits in queue with hidden parameters
/// 4. **Decryption**: After time-lock expires, anyone can decrypt and reveal parameters
/// 5. **Verification**: On-chain validation that revealed params match commitment hash
///
/// ## Attack Prevention
///
/// - **Rainbow Tables**: 32-byte salt prevents pre-computation attacks
/// - **Fake Reveals**: Hash verification ensures only correct values are accepted
/// - **Griefing**: Timeout mechanism evicts proposals that fail to reveal
/// - **Front-Running**: Time-lock prevents early parameter visibility
///
/// ## Commitment Format
///
/// The commitment hash is computed as: `keccak256(bcs::to_bytes(params) || salt)`
/// - Hash algorithm: Keccak256 (outputs 32 bytes)
/// - Concatenation order: params bytes first, then salt
/// - Salt length: exactly 32 bytes (REQUIRED_SALT_LENGTH constant)
///
/// ## Error Codes
///
/// - `EHashMismatch (0)`: Revealed params don't match commitment hash
/// - `EInvalidSaltLength (1)`: Salt must be exactly 32 bytes
/// - `EAlreadyRevealed (2)`: Container has already been revealed
/// - `EMissingCommitment (3)`: Container has no sealed params to reveal
/// - `ETooEarlyToReveal (4)`: Current time is before reveal_time_ms
/// - `EMissingParams (5)`: No params available (not revealed and no fallback)
/// - `EInvalidCommitmentLength (6)`: Commitment hash must be exactly 32 bytes
module futarchy_seal_utils::seal_commit_reveal;

use std::vector;
use std::option::{Self, Option};
use sui::bcs;
use sui::hash;
use sui::clock::{Self, Clock};
use sui::event;
use sui::tx_context::{Self, TxContext};

// === Errors ===

const EHashMismatch: u64 = 0;
const EInvalidSaltLength: u64 = 1;
const EAlreadyRevealed: u64 = 2;
const EMissingCommitment: u64 = 3;
const ETooEarlyToReveal: u64 = 4;
const EMissingParams: u64 = 5;
const EInvalidCommitmentLength: u64 = 6;

// === Constants ===

/// Salt must be exactly 32 bytes for security
const REQUIRED_SALT_LENGTH: u64 = 32;

/// Container modes
const MODE_SEALED: u8 = 0;
const MODE_SEALED_SAFE: u8 = 1;
const MODE_PUBLIC: u8 = 2;

// === Internal Helper Functions ===

/// Constant-time byte vector equality comparison
///
/// This function compares two byte vectors without early-exit branching,
/// preventing timing side-channel attacks. While on-chain timing isn't
/// directly observable like off-chain, constant-time comparison is a
/// defensive best practice for cryptographic operations.
///
/// # Security
/// - No early exit on mismatch (processes all bytes)
/// - Uses XOR accumulator to avoid data-dependent branches
/// - Returns true only if all bytes match AND lengths are equal
fun bytes_eq(a: &vector<u8>, b: &vector<u8>): bool {
    let la = vector::length(a);
    let lb = vector::length(b);
    if (la != lb) { return false };

    let mut acc: u8 = 0;
    let mut i = 0;
    while (i < la) {
        acc = acc | ((*vector::borrow(a, i)) ^ (*vector::borrow(b, i)));
        i = i + 1;
    };
    acc == 0
}

// === Events ===

/// Emitted when SEAL parameters are successfully revealed
///
/// Note: blob_id_hash is used instead of full blob_id to minimize event size.
/// To match events with blob IDs, compute: keccak256(blob_id) == blob_id_hash
public struct SealRevealed has copy, drop {
    /// Hash of Walrus blob ID (keccak256(blob_id))
    /// Using hash instead of full blob_id saves gas on event storage
    blob_id_hash: vector<u8>,
    /// Original commitment hash
    commitment_hash: vector<u8>,
    /// Scheduled reveal time (when time-lock expired)
    reveal_time_ms: u64,
    /// Actual reveal time (when reveal() was called)
    actual_reveal_time_ms: u64,
    /// Address that submitted the reveal transaction
    revealer: address,
}

// === Structs ===

/// SEAL encryption metadata for Walrus blob storage
///
/// When using Walrus SEAL:
/// 1. Encrypt (params || salt) with time-lock set to reveal_time
/// 2. Upload to Walrus, get blob_id
/// 3. Store blob_id on-chain with commitment hash
///
/// DESIGN: No `copy` ability for consistency with SealContainer<T>
/// Rationale: Maintains ability minimalism and forward compatibility.
/// All access is via borrows through getter functions.
public struct SealedParams has store, drop {
    /// Walrus blob ID containing encrypted (params || salt)
    blob_id: vector<u8>,

    /// Commitment: hash(params || salt)
    /// Used to verify decrypted data is correct
    commitment_hash: vector<u8>,

    /// Timestamp when SEAL time-lock expires (in milliseconds)
    /// Anyone can decrypt after this time
    reveal_time_ms: u64,
}

/// Container for sealed + optional fallback parameters
/// Supports 3 modes from the design document
///
/// DESIGN: Only requires `store + drop` abilities, not `copy`
/// Rationale: Market init params may contain non-copyable data in future
/// (e.g., resource references, capabilities). Using minimal abilities
/// ensures forward compatibility and prevents accidental duplication.
public struct SealContainer<T: store + drop> has store, drop {
    /// Optional sealed parameters (MODE_SEALED, MODE_SEALED_SAFE)
    sealed: Option<SealedParams>,

    /// Optional public fallback parameters (MODE_SEALED_SAFE, MODE_PUBLIC)
    public_fallback: Option<T>,

    /// Revealed parameters after successful decryption
    revealed: Option<T>,
}

// === Public Functions ===

/// Create new sealed params with commitment hash
///
/// Off-chain process:
/// 1. Generate 32-byte salt: `salt = random_bytes(32)`
/// 2. Serialize params: `params_bytes = bcs::to_bytes(&params)`
/// 3. Compute commitment: `hash = keccak256(params_bytes || salt)`
/// 4. Encrypt with SEAL: `encrypted = seal_encrypt(params_bytes || salt, reveal_time)`
/// 5. Upload to Walrus: `blob_id = walrus_upload(encrypted)`
/// 6. Call this function with `blob_id`, `hash`, `reveal_time`
///
/// # Aborts
/// - EInvalidCommitmentLength if commitment_hash is not exactly 32 bytes
public fun new_sealed_params(
    blob_id: vector<u8>,
    commitment_hash: vector<u8>,
    reveal_time_ms: u64,
): SealedParams {
    // Validate commitment hash length (Keccak256 always outputs 32 bytes)
    assert!(vector::length(&commitment_hash) == 32, EInvalidCommitmentLength);

    SealedParams {
        blob_id,
        commitment_hash,
        reveal_time_ms,
    }
}

/// Create MODE_SEALED container (sealed only, no fallback)
public fun new_sealed_only<T: store + drop>(
    sealed: SealedParams,
): SealContainer<T> {
    SealContainer {
        sealed: option::some(sealed),
        public_fallback: option::none(),
        revealed: option::none(),
    }
}

/// Create MODE_SEALED container from optional blob_id and commitment
/// Returns None if either parameter is None
///
/// This is a convenience function to avoid verbose Option handling in calling code.
/// Typical usage:
/// ```
/// let container = seal_commit_reveal::new_sealed_container_from_options<u64>(
///     some_blob_id,
///     some_commitment,
///     reveal_time
/// );
/// ```
public fun new_sealed_container_from_options<T: store + drop>(
    blob_id: Option<vector<u8>>,
    commitment_hash: Option<vector<u8>>,
    reveal_time_ms: u64,
): Option<SealContainer<T>> {
    if (option::is_some(&blob_id) && option::is_some(&commitment_hash)) {
        let sealed = new_sealed_params(
            option::destroy_some(blob_id),
            option::destroy_some(commitment_hash),
            reveal_time_ms
        );
        option::some(new_sealed_only(sealed))
    } else {
        option::none()
    }
}

/// Create MODE_SEALED_SAFE container (sealed + public fallback)
public fun new_sealed_with_fallback<T: store + drop>(
    sealed: SealedParams,
    fallback: T,
): SealContainer<T> {
    SealContainer {
        sealed: option::some(sealed),
        public_fallback: option::some(fallback),
        revealed: option::none(),
    }
}

/// Create MODE_PUBLIC container (no SEAL, just public params)
public fun new_public<T: store + drop>(
    params: T,
): SealContainer<T> {
    SealContainer {
        sealed: option::none(),
        public_fallback: option::some(params),
        revealed: option::none(),
    }
}

/// Verify and reveal sealed parameters
///
/// Anyone can call this after reveal_time with decrypted data from Walrus
///
/// Steps:
/// 1. Decrypt SEAL blob: `(params_bytes, salt) = seal_decrypt(blob_id)`
/// 2. Call this function with params and salt
/// 3. Function verifies: hash(params_bytes || salt) == commitment_hash
/// 4. If valid, stores revealed params in container and emits event
///
/// SECURITY: This function enforces the SEAL time-lock by requiring clock parameter
public fun reveal<T: store + drop>(
    container: &mut SealContainer<T>,
    decrypted_params: T,
    decrypted_salt: vector<u8>,
    clock: &Clock,  // ← CRITICAL: Verify time-lock expired
    ctx: &TxContext,
) {
    // Validate salt length
    assert!(vector::length(&decrypted_salt) == REQUIRED_SALT_LENGTH, EInvalidSaltLength);

    // Must have sealed params to reveal
    assert!(container.sealed.is_some(), EMissingCommitment);
    assert!(container.revealed.is_none(), EAlreadyRevealed);

    let sealed = container.sealed.borrow();

    // CRITICAL SECURITY CHECK: Verify SEAL time-lock has expired
    // This prevents early reveal which would defeat the entire purpose
    let current_time = clock::timestamp_ms(clock);
    assert!(current_time >= sealed.reveal_time_ms, ETooEarlyToReveal);

    // Compute hash(params || salt) and verify
    let mut data = bcs::to_bytes(&decrypted_params);
    vector::append(&mut data, decrypted_salt);
    let computed_hash = hash::keccak256(&data);

    // Use constant-time comparison to prevent timing side-channels
    assert!(bytes_eq(&computed_hash, &sealed.commitment_hash), EHashMismatch);

    // Emit event BEFORE storing (in case storage fails)
    // This ensures indexers can track successful reveals
    // Note: We hash blob_id to reduce event storage costs
    event::emit(SealRevealed {
        blob_id_hash: hash::keccak256(&sealed.blob_id),
        commitment_hash: sealed.commitment_hash,
        reveal_time_ms: sealed.reveal_time_ms,
        actual_reveal_time_ms: current_time,
        revealer: tx_context::sender(ctx),
    });

    // Store revealed params
    container.revealed = option::some(decrypted_params);
}

/// Get parameters with fallback logic per design document
///
/// Priority order:
/// 1. If revealed: use revealed params (SEAL succeeded)
/// 2. If public_fallback exists: use fallback (SEAL failed or MODE_PUBLIC)
/// 3. Otherwise: aborts with EMissingParams
///
/// # Aborts
/// - EMissingParams if no params available (not revealed and no fallback)
///
/// # Recommended Usage
/// ```
/// if (has_params(container)) {
///     let params = get_params(container);
///     // use params
/// }
/// ```
public fun get_params<T: store + drop>(
    container: &SealContainer<T>
): &T {
    // Priority 1: Revealed params (SEAL succeeded)
    if (container.revealed.is_some()) {
        return container.revealed.borrow()
    };

    // Priority 2: Public fallback (SEAL failed or MODE_PUBLIC)
    if (container.public_fallback.is_some()) {
        return container.public_fallback.borrow()
    };

    // No params available - abort
    abort EMissingParams
}

/// Check if params are available (either revealed or fallback exists)
public fun has_params<T: store + drop>(
    container: &SealContainer<T>
): bool {
    container.revealed.is_some() || container.public_fallback.is_some()
}

/// Get the container's mode
///
/// Returns:
/// - MODE_SEALED (0): Sealed only, no fallback
/// - MODE_SEALED_SAFE (1): Sealed with public fallback
/// - MODE_PUBLIC (2): Public parameters only
public fun get_mode<T: store + drop>(
    container: &SealContainer<T>
): u8 {
    let has_sealed = container.sealed.is_some();
    let has_fallback = container.public_fallback.is_some();

    if (has_sealed && !has_fallback) {
        MODE_SEALED
    } else if (has_sealed && has_fallback) {
        MODE_SEALED_SAFE
    } else {
        MODE_PUBLIC
    }
}

/// Check if SEAL reveal succeeded
public fun is_revealed<T: store + drop>(
    container: &SealContainer<T>
): bool {
    container.revealed.is_some()
}

/// Check if using fallback params (SEAL not revealed, but fallback available)
public fun is_using_fallback<T: store + drop>(
    container: &SealContainer<T>
): bool {
    container.revealed.is_none() && container.public_fallback.is_some()
}

/// Get reveal time from sealed params
public fun reveal_time_ms<T: store + drop>(
    container: &SealContainer<T>
): Option<u64> {
    if (container.sealed.is_some()) {
        let sealed = container.sealed.borrow();
        option::some(sealed.reveal_time_ms)
    } else {
        option::none()
    }
}

/// Get Walrus blob ID for off-chain decryption
public fun blob_id<T: store + drop>(
    container: &SealContainer<T>
): Option<vector<u8>> {
    if (container.sealed.is_some()) {
        let sealed = container.sealed.borrow();
        option::some(sealed.blob_id)
    } else {
        option::none()
    }
}

// === View Functions ===

/// Get MODE_SEALED constant value (0)
public fun mode_sealed(): u8 { MODE_SEALED }

/// Get MODE_SEALED_SAFE constant value (1)
public fun mode_sealed_safe(): u8 { MODE_SEALED_SAFE }

/// Get MODE_PUBLIC constant value (2)
public fun mode_public(): u8 { MODE_PUBLIC }

public fun sealed_params_blob_id(sealed: &SealedParams): &vector<u8> {
    &sealed.blob_id
}

public fun sealed_params_commitment_hash(sealed: &SealedParams): &vector<u8> {
    &sealed.commitment_hash
}

public fun sealed_params_reveal_time(sealed: &SealedParams): u64 {
    sealed.reveal_time_ms
}

#[test_only]
public fun test_create_seal_container<T: store + drop>(
    sealed: Option<SealedParams>,
    fallback: Option<T>,
    revealed: Option<T>,
): SealContainer<T> {
    SealContainer { sealed, public_fallback: fallback, revealed }
}
