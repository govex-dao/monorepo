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
module futarchy_seal_utils::seal_commit_reveal;

use std::vector;
use std::option::{Self, Option};
use sui::bcs;
use sui::hash;
use sui::clock::{Self, Clock};
use sui::event;

// === Errors ===

const EHashMismatch: u64 = 0;
const EInvalidSaltLength: u64 = 1;
const EAlreadyRevealed: u64 = 2;
const EMissingCommitment: u64 = 3;
const ETooEarlyToReveal: u64 = 4;
const EMissingParams: u64 = 5;

// === Constants ===

/// Salt must be exactly 32 bytes for security
const REQUIRED_SALT_LENGTH: u64 = 32;

/// Container modes
const MODE_SEALED: u8 = 0;
const MODE_SEALED_SAFE: u8 = 1;
const MODE_PUBLIC: u8 = 2;

// === Events ===

/// Emitted when SEAL parameters are successfully revealed
public struct SealRevealed has copy, drop {
    /// Walrus blob ID that was decrypted
    blob_id: vector<u8>,
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
public struct SealedParams has store, copy, drop {
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
public fun new_sealed_params(
    blob_id: vector<u8>,
    commitment_hash: vector<u8>,
    reveal_time_ms: u64,
): SealedParams {
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
    assert!(option::is_some(&container.sealed), EMissingCommitment);
    assert!(option::is_none(&container.revealed), EAlreadyRevealed);

    let sealed = option::borrow(&container.sealed);

    // CRITICAL SECURITY CHECK: Verify SEAL time-lock has expired
    // This prevents early reveal which would defeat the entire purpose
    let current_time = clock::timestamp_ms(clock);
    assert!(current_time >= sealed.reveal_time_ms, ETooEarlyToReveal);

    // Compute hash(params || salt) and verify
    let mut data = bcs::to_bytes(&decrypted_params);
    vector::append(&mut data, decrypted_salt);
    let computed_hash = hash::keccak256(&data);

    assert!(computed_hash == sealed.commitment_hash, EHashMismatch);

    // Emit event BEFORE storing (in case storage fails)
    // This ensures indexers can track successful reveals
    event::emit(SealRevealed {
        blob_id: sealed.blob_id,
        commitment_hash: sealed.commitment_hash,
        reveal_time_ms: sealed.reveal_time_ms,
        actual_reveal_time_ms: current_time,
        revealer: ctx.sender(),
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
    if (option::is_some(&container.revealed)) {
        return option::borrow(&container.revealed)
    };

    // Priority 2: Public fallback (SEAL failed or MODE_PUBLIC)
    if (option::is_some(&container.public_fallback)) {
        return option::borrow(&container.public_fallback)
    };

    // No params available - abort
    abort EMissingParams
}

/// Check if params are available (either revealed or fallback exists)
public fun has_params<T: store + drop>(
    container: &SealContainer<T>
): bool {
    option::is_some(&container.revealed) || option::is_some(&container.public_fallback)
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
    let has_sealed = option::is_some(&container.sealed);
    let has_fallback = option::is_some(&container.public_fallback);

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
    option::is_some(&container.revealed)
}

/// Check if using fallback params (SEAL not revealed, but fallback available)
public fun is_using_fallback<T: store + drop>(
    container: &SealContainer<T>
): bool {
    option::is_none(&container.revealed) && option::is_some(&container.public_fallback)
}

/// Get reveal time from sealed params
public fun reveal_time_ms<T: store + drop>(
    container: &SealContainer<T>
): Option<u64> {
    if (option::is_some(&container.sealed)) {
        let sealed = option::borrow(&container.sealed);
        option::some(sealed.reveal_time_ms)
    } else {
        option::none()
    }
}

/// Get Walrus blob ID for off-chain decryption
public fun blob_id<T: store + drop>(
    container: &SealContainer<T>
): Option<vector<u8>> {
    if (option::is_some(&container.sealed)) {
        let sealed = option::borrow(&container.sealed);
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
