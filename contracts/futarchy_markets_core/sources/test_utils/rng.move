/// ============================================================================
/// DETERMINISTIC RNG FOR PROPERTY-BASED TESTING
/// ============================================================================
///
/// A simple Linear Congruential Generator (LCG) for reproducible fuzzing.
/// This is NOT cryptographically secure - only for deterministic test generation.
///
/// **Why not use Sui's native randomness?**
/// - Sui's `Random` object is great for on-chain apps
/// - But for unit tests we need DETERMINISTIC, REPRODUCIBLE results
/// - This LCG ensures tests pass/fail consistently across runs
///
/// ============================================================================

#[test_only]
module futarchy_markets_core::rng;

/// 64-bit LCG state (uses u128 arithmetic internally to avoid overflow)
public struct Rng has copy, drop {
    state: u64,
}

/// Create a new RNG with deterministic seed
/// Same seed always produces same sequence (reproducible tests)
public fun seed(seed_hi: u64, seed_lo: u64): Rng {
    // Combine seeds with XOR to create single u64 state
    Rng {
        state: seed_hi ^ seed_lo,
    }
}

/// Generate next random u64
/// Uses LCG with u128 arithmetic to prevent overflow, then truncates to u64
public fun next_u64(r: &mut Rng): u64 {
    // LCG constants from glibc (a = 1103515245, c = 12345)
    // Do arithmetic in u128 to avoid overflow, then mod 2^64
    let state_u128 = (r.state as u128);
    let next_u128 = state_u128 * 1103515245u128 + 12345u128;

    // Truncate to u64 by taking mod 2^64
    // Use bitwise AND to extract lower 64 bits (guaranteed to fit in u64)
    let truncated = next_u128 & 0xFFFFFFFFFFFFFFFF;
    let next_u64 = (truncated as u64);
    r.state = next_u64;
    next_u64
}

/// Generate random u64 in range [lo, hi_inclusive]
public fun next_range(r: &mut Rng, lo: u64, hi_inclusive: u64): u64 {
    if (hi_inclusive <= lo) return lo;
    let span = hi_inclusive - lo + 1;
    lo + (next_u64(r) % span)
}

/// Bernoulli trial with probability p (in basis points [0, 10000])
/// Returns true with probability p/10000
public fun coin(r: &mut Rng, p_bps: u64): bool {
    (next_u64(r) % 10000) < p_bps
}
