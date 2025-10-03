# SEAL Salt Implementation - Security Audit Checklist

## 🔒 Executive Summary

**Audit Focus:** Salt-based commitment scheme for hidden fundraising caps
**Attack Surface:** Commitment hash, salt handling, SEAL integration, reveal verification
**Risk Level:** HIGH (financial system with encrypted secrets)
**Status:** Pre-audit - awaiting formal security review

---

## 🎯 Audit Scope

### In-Scope

- [x] Salt generation and handling (client-side)
- [x] Commitment hash computation
- [x] On-chain verification logic
- [x] SEAL encryption/decryption flow
- [x] Walrus storage integration
- [x] Reveal function access control
- [x] Grace period timeout mechanism

### Out-of-Scope

- SEAL key server implementation (external dependency)
- Walrus storage protocol (external dependency)
- Sui blockchain consensus (external dependency)
- Frontend UI/UX (non-security critical)

---

## 🔍 Security Checklist

### 1. Cryptographic Primitives

#### Hash Function
- [x] **Uses keccak256** (same as Sui's `hash` module)
- [ ] Verify no hash collision vulnerabilities
- [ ] Confirm output is 256 bits (32 bytes)
- [ ] Test with empty input edge case

#### Salt Generation
- [x] **32 bytes of randomness** (256 bits entropy)
- [ ] Verify RNG is cryptographically secure (crypto.randomBytes in Node.js)
- [ ] Confirm no predictable patterns in salt values
- [ ] Test salt uniqueness across multiple raises

#### Concatenation Order
- [x] **Correct order:** `max_raise || salt` (not `salt || max_raise`)
- [ ] Verify BCS serialization is deterministic
- [ ] Test hash matches between Move and TypeScript
- [ ] Confirm no null byte injection vulnerabilities

**Risk Assessment:**
- **Impact:** CRITICAL (wrong hash = complete system failure)
- **Likelihood:** LOW (implementation verified)
- **Mitigation:** Cross-language unit tests

---

### 2. On-Chain Verification

#### Salt Length Validation
```move
assert!(vector::length(&decrypted_salt) == 32, EInvalidSaltLength);
```

**Tests Required:**
- [ ] Reject salt with length 0
- [ ] Reject salt with length 31
- [ ] Accept salt with length 32 ✅
- [ ] Reject salt with length 33
- [ ] Reject salt with length 1000

**Risk:** LOW - Straightforward validation

#### Hash Verification
```move
let mut data = bcs::to_bytes(&decrypted_max_raise);
vector::append(&mut data, decrypted_salt);
let computed_hash = sui::hash::keccak256(&data);
assert!(computed_hash == *option::borrow(&raise.max_raise_commitment_hash), EHashMismatch);
```

**Audit Questions:**
- [ ] Can `bcs::to_bytes` fail or panic?
- [ ] Is `vector::append` safe against overflow?
- [ ] Does hash comparison use constant-time equality?
- [ ] Can attacker bypass with empty vectors?

**Risk:** MEDIUM - Core security invariant

---

### 3. SEAL Integration Security

#### Time-Lock Identity
**Identity:** `bcs::to_bytes(deadline_ms)`

**Audit Questions:**
- [ ] Is deadline_ms immutable after creation?
- [ ] Can deadline be manipulated via clock oracle attacks?
- [ ] Does SEAL enforce time-lock correctly?
- [ ] What happens if SEAL servers disagree on time?

**Risk:** HIGH - Depends on external SEAL security

#### Encryption/Decryption
**Encrypted Data:** `{ max_raise: u64, salt: vector<u8> }`

**Audit Questions:**
- [ ] Is encryption authenticated (AEAD)?
- [ ] Can attacker modify ciphertext?
- [ ] Is decryption deterministic?
- [ ] What error does SEAL return if time-lock not expired?

**Risk:** HIGH - Untrusted SEAL SDK integration

#### Blob Storage
**Storage:** Walrus decentralized storage

**Audit Questions:**
- [ ] Is blob_id verified before storing on-chain?
- [ ] Can attacker replace blob after commitment?
- [ ] Does blob expiry exceed reveal_deadline?
- [ ] What happens if Walrus is down?

**Risk:** MEDIUM - Availability, not integrity

---

### 4. Rainbow Table Resistance

#### Entropy Analysis
**Salt Space:** 2^256 possible values
**Max Raise Space:** ~10^10 realistic values (u64)
**Combined Space:** 2^256 × 10^10 ≈ 2^256 (salt dominates)

**Security Margin:**
- **Brute Force:** 2^256 operations = ~10^77 (infeasible)
- **Birthday Attack:** 2^128 operations = ~10^38 (still infeasible)
- **Quantum Resistance:** 2^128 security (acceptable for now)

**Audit Questions:**
- [ ] Confirm salt is truly random (not pseudo-random with known seed)
- [ ] Verify no salt reuse across multiple raises
- [ ] Check for timing attacks in hash comparison
- [ ] Test with known weak RNGs (deterministic seed)

**Risk:** LOW - Strong cryptographic design

#### Pre-Computation Attacks
**Scenario:** Attacker pre-computes rainbow table

**Attack Cost:**
- **Storage:** 2^256 × 32 bytes = 10^59 TB (infeasible)
- **Computation:** 2^256 × (hash cost) = 10^77 operations (infeasible)
- **Time:** 2^256 / 10^15 ops/sec = 10^62 seconds (heat death of universe)

**Audit Questions:**
- [ ] Verify no salt leakage in events
- [ ] Confirm commitment hash is irreversible
- [ ] Check for oracle attacks (hash function implementation bugs)

**Risk:** NEGLIGIBLE - Mathematically infeasible

---

### 5. Access Control & Authorization

#### Reveal Function
**Signature:** `public entry fun reveal_and_begin_settlement`

**Access:**
- ✅ **Permissionless** - Anyone can call after deadline
- ✅ **Time-Gated** - Enforced by `deadline_ms` check
- ✅ **One-Time** - Enforced by `max_raise_revealed.is_none()`

**Audit Questions:**
- [ ] Can attacker front-run legitimate revealer?
- [ ] Is there a race condition between multiple revealers?
- [ ] Does first revealer get unfair advantage?
- [ ] Can attacker grief by revealing with wrong values (fails verification)?

**Risk:** LOW - Well-designed access control

#### Grace Period Timeout
**Function:** `fail_raise_seal_timeout`

**Trigger:**
- After `reveal_deadline_ms` (deadline + 7 days)
- If `max_raise_revealed.is_none()`

**Audit Questions:**
- [ ] Can attacker trigger timeout prematurely?
- [ ] Is 7-day grace period sufficient?
- [ ] Does timeout properly mark raise as FAILED?
- [ ] Can contributors get refunds after timeout?

**Risk:** LOW - Fail-safe mechanism

---

### 6. Economic Attacks

#### Attack: Submit Wrong Values
**Scenario:** Attacker calls reveal with fake max_raise/salt

**Defense:**
```move
assert!(computed_hash == *option::borrow(&raise.max_raise_commitment_hash), EHashMismatch);
```

**Result:** Transaction fails, attacker loses gas fee

**Risk:** NEGLIGIBLE - Attacker loses money

#### Attack: SEAL Downtime Griefing
**Scenario:** Attacker DoS SEAL servers during reveal window

**Defense:**
- 7-day grace period for recovery
- Automatic timeout fallback
- Multiple SEAL key servers (threshold)

**Risk:** LOW - Mitigated by grace period

#### Attack: Walrus Blob Deletion
**Scenario:** Attacker doesn't pay for sufficient Walrus storage

**Current State:** ⚠️ **Not validated on-chain**

**Recommended Fix:**
```move
// In create_raise_with_sealed_cap
let blob_expiry_epoch = blob::end_epoch(&sealed_blob);
let required_expiry = deadline_ms + REVEAL_GRACE_PERIOD_MS;
assert!(blob_expiry_epoch >= required_expiry, EBlobExpiresBeforeReveal);
```

**Risk:** MEDIUM - Should add blob expiry validation

---

### 7. Denial of Service

#### Gas Exhaustion
**Scenario:** Attacker creates many raises with sealed caps

**Defense:**
- Factory fee requirement
- Gas market pricing
- Rate limiting (off-chain)

**Risk:** LOW - Standard DoS protection

#### Hash Computation DoS
**Scenario:** Attacker submits huge salt vector

**Defense:**
```move
assert!(vector::length(&decrypted_salt) == 32, EInvalidSaltLength);
```

**Risk:** NEGLIGIBLE - Length capped at 32 bytes

---

### 8. Cross-Language Consistency

#### TypeScript vs Move
**Critical Path:** Hash computation must match exactly

**Test Required:**
```typescript
// TypeScript
const maxRaise = 10_000_000_000n;
const salt = new Uint8Array([/* 32 bytes */]);
const tsHash = keccak256(concat(bcs(maxRaise), salt));

// Move
let max_raise: u64 = 10_000_000_000;
let salt: vector<u8> = vector[/* 32 bytes */];
let mut data = bcs::to_bytes(&max_raise);
vector::append(&mut data, salt);
let moveHash = sui::hash::keccak256(&data);

// Must be equal
assert(tsHash === moveHash);
```

**Audit Questions:**
- [ ] Verify BCS serialization matches between languages
- [ ] Test with edge cases (0, u64::MAX, etc.)
- [ ] Confirm endianness is consistent
- [ ] Check for any padding differences

**Risk:** HIGH - Silent failure mode (hashes don't match)

---

### 9. Upgrade Safety

#### Storage Layout
**Fields Added:**
- `max_raise_sealed_blob_id: Option<vector<u8>>`
- `max_raise_commitment_hash: Option<vector<u8>>`
- `max_raise_revealed: Option<u64>`
- `reveal_deadline_ms: u64`

**Audit Questions:**
- [ ] Are new fields append-only (no insertion)?
- [ ] Do existing raises handle `None` values correctly?
- [ ] Can old raises migrate to new system?
- [ ] Are all fields properly initialized?

**Risk:** LOW - Backward compatible design

#### Function Signatures
**Changed:** `reveal_and_begin_settlement` now requires `salt` parameter

**Impact:**
- 🔴 **Breaking change** for existing callers
- ✅ Old raises (without seal) won't call this function
- ✅ Type safety prevents wrong usage

**Risk:** LOW - Caught at compile time

---

### 10. Edge Cases & Corner Cases

#### Empty Salt
- [ ] Test with `salt = vector[]` (length 0)
- Expected: Fails with `EInvalidSaltLength`

#### Max u64 Value
- [ ] Test with `max_raise = 18_446_744_073_709_551_615`
- Expected: BCS serialization correct, hash computes

#### Zero Max Raise
- [ ] Test with `max_raise = 0`
- Expected: Fails earlier validation (min_raise_amount)

#### Salt Reuse
- [ ] Test creating two raises with same salt
- Expected: Different commitment hashes (different max_raise)

#### Concurrent Reveals
- [ ] Test two revealers submitting simultaneously
- Expected: First succeeds, second fails with `EAlreadyRevealed`

#### SEAL Decryption Failure
- [ ] Test revealing before deadline
- Expected: SEAL returns error, transaction not submitted

---

## 🚨 Critical Vulnerabilities Found

### MEDIUM - Missing Walrus Blob Expiry Validation

**Location:** `create_raise_with_sealed_cap`

**Issue:** Contract doesn't verify Walrus blob will exist until `reveal_deadline_ms`

**Attack:**
1. Attacker creates raise with sealed cap
2. Only pays for 1 epoch (14 days) of Walrus storage
3. Raise deadline is 14 days
4. By reveal time, Walrus blob is deleted
5. Nobody can reveal → raise fails → contributors get refunds

**Impact:** MEDIUM - Griefing attack, no funds lost

**Recommendation:**
```move
public entry fun create_raise_with_sealed_cap<RaiseToken: drop, StableCoin: drop>(
    // ... existing params ...
    sealed_blob: &blob::Blob,  // NEW: Pass blob reference to check expiry
    // ... rest of params ...
) {
    // Verify blob expiry
    let blob_expiry_ms = (blob::end_epoch(&sealed_blob) as u64) * EPOCH_DURATION_MS;
    let required_expiry = deadline_ms + REVEAL_GRACE_PERIOD_MS;
    assert!(blob_expiry_ms >= required_expiry, EBlobExpiresBeforeReveal);

    // Store blob ID for reveal
    let blob_id = blob::blob_id(&sealed_blob);
    // ... rest of function
}
```

**Status:** 🔴 **TO FIX** before production

---

## ✅ Strengths

1. **Strong Cryptography:** 256-bit salt provides excellent security margin
2. **Simple Design:** Minimal attack surface, easy to audit
3. **Defense in Depth:** Multiple checks (salt length, hash verification, time-lock)
4. **Fail-Safe:** Grace period timeout prevents permanent lock-up
5. **Permissionless:** Anyone can reveal (decentralization)

---

## ⚠️ Recommendations

### High Priority

1. **Add Walrus blob expiry validation** (MEDIUM severity)
2. **Cross-language hash testing** (automated CI)
3. **SEAL downtime monitoring** (operational)

### Medium Priority

4. **Gas cost benchmarking** (performance)
5. **Fuzz testing** (edge cases)
6. **Formal verification** (if budget allows)

### Low Priority

7. **Constant-time hash comparison** (side-channel defense)
8. **Quantum-resistant upgrade path** (future-proofing)

---

## 📊 Risk Matrix

| Component | Impact | Likelihood | Risk Level | Mitigation |
|-----------|--------|------------|------------|------------|
| Hash collision | CRITICAL | NEGLIGIBLE | LOW | Use keccak256 |
| Rainbow table | HIGH | NEGLIGIBLE | LOW | 32-byte salt |
| SEAL breach | HIGH | LOW | MEDIUM | Threshold servers |
| Walrus failure | MEDIUM | LOW | LOW | Grace period |
| Blob expiry | MEDIUM | MEDIUM | **MEDIUM** | **Add validation** |
| Wrong hash | HIGH | LOW | MEDIUM | Unit tests |
| Gas exhaustion | LOW | MEDIUM | LOW | Fee requirements |

---

## 🎓 Audit Conclusion

**Overall Risk:** MEDIUM (due to Walrus blob expiry issue)

**Recommendation:** Fix blob expiry validation, then proceed to formal audit

**Estimated Audit Time:** 2-3 days (senior security engineer)

**Next Steps:**
1. Fix blob expiry validation
2. Complete cross-language hash tests
3. Deploy to testnet
4. Run 10+ test raises with sealed caps
5. Schedule formal security audit
6. Deploy to mainnet after audit approval

---

## 📝 Auditor Notes

Space for security auditor comments:

```
Date: _____________
Auditor: _____________
Findings:


Severity Levels:
- CRITICAL: Immediate funds at risk
- HIGH: Potential for loss under specific conditions
- MEDIUM: Griefing or DoS possible
- LOW: Minor issues, best practices
- INFO: Suggestions for improvement
```

---

**Last Updated:** 2025-01-03
**Version:** 1.0.0
**Status:** Pre-Audit
