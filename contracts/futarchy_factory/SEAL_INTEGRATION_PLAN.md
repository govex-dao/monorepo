# Seal Integration Plan for Launchpad Max Raise Amount

## ✅ IMPLEMENTATION STATUS: PHASE 2 COMPLETE

**Completed:** Smart contract integration with Seal fields, entry functions, and settlement logic
**Next Steps:** Frontend SDK integration and indexer/backend implementation

## Overview
Integrate Seal time-lock encryption to hide `max_raise_amount` during fundraising, preventing oversubscription gaming while allowing anyone to decrypt and crank settlement after the deadline.

## Problem Statement
**Current Issue**: Public `max_raise_amount` leads to oversubscription gaming
- If raise is 2x oversubscribed, rational contributors contribute 2x their desired amount
- Creates massive capital inefficiency spiral
- Contributors tie up excess capital unnecessarily

**Solution**: Hide max cap using Seal time-lock encryption
- Cap hidden during raise (no gaming possible)
- Anyone can decrypt after deadline (permissionless cranking)
- Your indexer/bot auto-settles instantly (best UX)

## Architecture Design

### Data Structure Changes

#### Current (launchpad.move)
```move
public struct Raise<phantom RaiseToken, phantom StableCoin> has key, store {
    // ... existing fields
    max_raise_amount: Option<u64>, // Currently public, causes gaming
}
```

#### Proposed
```move
public struct Raise<phantom RaiseToken, phantom StableCoin> has key, store {
    // ... existing fields

    // Seal integration fields
    max_raise_sealed_blob_id: Option<u32>,           // Walrus blob ID (encrypted data)
    max_raise_commitment_hash: Option<vector<u8>>,   // Hash of plaintext for verification
    max_raise_revealed: Option<u64>,                 // Set after decryption
    reveal_deadline_ms: u64,                         // deadline_ms + 7 days grace period
}
```

### Flow Design

#### 1. Raise Creation Flow

**Client-Side (TypeScript SDK):**
```typescript
// - [ ] TODO: Research Seal TypeScript SDK API
// - [ ] TODO: Understand Seal.encrypt() parameters and return types
// - [ ] TODO: Confirm Walrus upload API for encrypted blobs

async function createRaiseWithSealedCap(params) {
  // Step 1: Encrypt max_raise_amount with Seal
  const identity = bcs.to_bytes(params.deadline_ms); // Time-lock identity
  const encryptedBlob = await seal.encrypt({
    data: bcs.to_bytes(params.max_raise_amount),
    identity: identity,
    // UNKNOWN: What other parameters does Seal.encrypt() need?
    // UNKNOWN: Does Seal SDK handle Walrus upload or separate step?
  });

  // Step 2: Upload to Walrus (or is this automatic?)
  const blobId = encryptedBlob.blobId; // UNKNOWN: Exact return structure

  // Step 3: Create commitment hash for extra verification
  const commitmentHash = keccak256(bcs.to_bytes(params.max_raise_amount));

  // Step 4: Call on-chain create_raise with blob_id
  await tx.create_raise_with_sealed_cap({
    // ... other params
    max_raise_sealed_blob_id: blobId,
    max_raise_commitment_hash: commitmentHash,
  });
}
```

**On-Chain (launchpad.move):**
```move
// - [ ] TODO: Add new entry function variant
public entry fun create_raise_with_sealed_cap<RaiseToken: drop, StableCoin: drop>(
    factory: &factory::Factory,
    treasury_cap: TreasuryCap<RaiseToken>,
    tokens_for_raise: Coin<RaiseToken>,
    min_raise_amount: u64,
    max_raise_sealed_blob_id: u32,              // NEW: Walrus blob ID
    max_raise_commitment_hash: vector<u8>,      // NEW: Hash for verification
    // ... other params same as current create_raise
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validation
    assert!(factory::is_stable_type_allowed<StableCoin>(factory), EStableTypeNotAllowed);
    assert!(tokens_for_raise.value() == treasury_cap.total_supply(), EWrongTotalSupply);

    // Create raise with sealed fields
    let raise = Raise<RaiseToken, StableCoin> {
        // ... existing fields
        max_raise_sealed_blob_id: option::some(max_raise_sealed_blob_id),
        max_raise_commitment_hash: option::some(max_raise_commitment_hash),
        max_raise_revealed: option::none(),
        reveal_deadline_ms: clock.timestamp_ms() + LAUNCHPAD_DURATION_MS + REVEAL_GRACE_PERIOD_MS,
    };

    transfer::public_share_object(raise);
}
```

#### 2. Settlement Flow (Anyone Can Crank)

**Off-Chain Indexer/Bot (Your Backend):**
```typescript
// - [ ] TODO: Research Seal TypeScript SDK decrypt API
// - [ ] TODO: Understand error handling for Seal decryption
// - [ ] TODO: Test Seal SDK with time-locked identities

// Your indexer watches for raises reaching deadline
async function autoCrankSettlement(raiseId) {
  const raise = await sui.getRaise(raiseId);

  // Check if deadline reached
  if (Date.now() < raise.deadline_ms) return;

  // Step 1: Decrypt max_raise_amount from Seal
  try {
    const identity = bcs.to_bytes(raise.deadline_ms);
    const decryptedData = await seal.decrypt({
      blobId: raise.max_raise_sealed_blob_id,
      identity: identity,
      // UNKNOWN: What other parameters needed?
      // UNKNOWN: Does this fail gracefully if Seal is down?
    });

    const maxRaiseAmount = bcs.from_bytes(decryptedData); // u64

    // Step 2: Call on-chain reveal and settle
    await sui.tx.reveal_and_begin_settlement({
      raiseId,
      decrypted_max_raise: maxRaiseAmount,
    });

    // Step 3: Continue cranking settlement caps
    await crankSettlement(raiseId);

  } catch (error) {
    if (error.type === 'SEAL_UNAVAILABLE') {
      // Retry later, Seal might be temporarily down
      scheduleRetry(raiseId, 60_000); // Retry in 1 minute
    } else {
      console.error('Failed to decrypt:', error);
    }
  }
}
```

**On-Chain (launchpad.move):**
```move
// - [ ] TODO: Implement new entry function for reveal + settlement
// - [ ] TODO: Add validation logic for decrypted value
// - [ ] TODO: Handle commitment hash verification

public entry fun reveal_and_begin_settlement<RT, SC>(
    raise: &mut Raise<RT, SC>,
    decrypted_max_raise: u64,  // Anyone provides this after Seal decryption
    clock: &Clock,
    ctx: &mut TxContext,
): CapSettlement {
    // Validation checks
    assert!(clock.timestamp_ms() >= raise.deadline_ms, EDeadlineNotReached);
    assert!(!raise.settlement_done && !raise.settlement_in_progress, ESettlementAlreadyStarted);
    assert!(raise.max_raise_revealed.is_none(), EAlreadyRevealed);

    // CRITICAL: Validate decrypted value is reasonable
    assert!(decrypted_max_raise >= raise.min_raise_amount, EInvalidMaxRaise);
    assert!(decrypted_max_raise <= MAX_REASONABLE_RAISE, EInvalidMaxRaise); // e.g., 10B USDC

    // Optional: Verify against commitment hash for extra security
    // UNKNOWN: Does this add value or just gas overhead?
    if (option::is_some(&raise.max_raise_commitment_hash)) {
        let computed_hash = hash::keccak256(&bcs::to_bytes(&decrypted_max_raise));
        assert!(computed_hash == *option::borrow(&raise.max_raise_commitment_hash), EHashMismatch);
    };

    // Store revealed value
    raise.max_raise_revealed = option::some(decrypted_max_raise);

    // Mark settlement in progress
    raise.settlement_in_progress = true;

    // Begin settlement with revealed cap
    begin_settlement(raise, clock, ctx)
}

// - [ ] TODO: Modify claim_success_and_activate_dao to use revealed value
// - [ ] TODO: Update all settlement logic to read from max_raise_revealed
```

#### 3. Failure Handling (Seal Downtime)

**On-Chain Safety Mechanism:**
```move
// - [ ] TODO: Add timeout function for Seal failure case
// - [ ] TODO: Emit events for monitoring

const REVEAL_GRACE_PERIOD_MS: u64 = 604_800_000; // 7 days

public entry fun fail_raise_seal_timeout<RT, SC>(
    raise: &mut Raise<RT, SC>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Can only call after reveal deadline (deadline + 7 days)
    assert!(clock.timestamp_ms() >= raise.reveal_deadline_ms, ERevealDeadlineNotReached);

    // Can only call if max_raise not revealed yet
    assert!(raise.max_raise_revealed.is_none(), EAlreadyRevealed);

    // Mark raise as failed
    if (raise.state == STATE_FUNDING) {
        raise.state = STATE_FAILED;

        event::emit(RaiseFailedSealTimeout {
            raise_id: object::id(raise),
            deadline_ms: raise.deadline_ms,
            reveal_deadline_ms: raise.reveal_deadline_ms,
            timestamp_ms: clock.timestamp_ms(),
        });
    };
}
```

## Research Needed

### High Priority - Blocking Implementation

- [ ] **Seal TypeScript SDK API Documentation**
  - Exact function signatures for `seal.encrypt()` and `seal.decrypt()`
  - Required parameters beyond data and identity
  - Return types and data structures
  - Error types and handling
  - NPM package name and installation

- [ ] **Seal + Walrus Integration**
  - Does Seal SDK automatically upload to Walrus?
  - Or separate steps: encrypt with Seal, then upload to Walrus?
  - How to get blob_id after encryption/upload?
  - Blob ID type: u32, u64, vector<u8>, or custom struct?

- [ ] **Time-Lock Identity Format**
  - Confirm identity should be `bcs::to_bytes(deadline_ms)`
  - Does Seal require additional metadata in identity?
  - How do Seal key servers validate time-lock expiry?

- [ ] **Seal Key Server Behavior**
  - What happens if key servers disagree on current time?
  - Threshold requirements (e.g., 2 of 3 servers must be available)?
  - Expected downtime/SLA for Seal mainnet?
  - How long does decryption take (latency)?

### Medium Priority - UX Optimization

- [ ] **Commitment Hash Necessity**
  - Is commitment hash redundant if Seal already validates?
  - Does it add meaningful security or just gas overhead?
  - Should we skip it for simpler implementation?

- [ ] **Error Messages and User Feedback**
  - What error does Seal return if time-lock not expired?
  - How to detect Seal unavailability vs. invalid request?
  - User-friendly error messages for frontend

- [ ] **Gas Costs**
  - Cost to store blob_id on-chain
  - Cost of reveal transaction
  - Compare to current simple Option<u64> storage

### Low Priority - Nice to Have

- [ ] **Seal Testnet/Devnet Availability**
  - Is Seal available on Sui testnet for testing?
  - Test key server endpoints
  - Example repos or working code samples

- [ ] **Monitoring and Analytics**
  - How to monitor Seal availability in production?
  - Metrics to track (decrypt success rate, latency, etc.)
  - Alerting strategy if Seal is down

- [ ] **Batch Operations**
  - Can we batch decrypt multiple raises?
  - Does Seal support bulk operations?

## Implementation Checklist

### Phase 1: Research and Prototyping
- [x] ✅ Research Seal TypeScript SDK and Walrus integration
- [x] ✅ Confirm Seal is live on Sui Mainnet
- [x] ✅ Identify key server providers (Ruby Nodes, NodeInfra, etc.)
- [x] ✅ Understand basic Seal architecture and time-lock encryption
- [ ] Install and test Seal TypeScript SDK locally (Frontend team)
- [ ] Create minimal Seal encryption/decryption test (Frontend team)
- [ ] Test time-lock behavior with past/future timestamps (Frontend team)

### Phase 2: Smart Contract Updates ✅ COMPLETE
- [x] ✅ Add new constants (REVEAL_GRACE_PERIOD_MS, MAX_REASONABLE_RAISE)
- [x] ✅ Add new error codes (EInvalidMaxRaise, EAlreadyRevealed, EHashMismatch, ERevealDeadlineNotReached)
- [x] ✅ Update Raise struct with Seal fields (max_raise_sealed_blob_id, max_raise_commitment_hash, max_raise_revealed, reveal_deadline_ms)
- [x] ✅ Implement create_raise_with_sealed_cap entry function
- [x] ✅ Implement reveal_and_begin_settlement entry function
- [x] ✅ Implement fail_raise_seal_timeout entry function
- [x] ✅ Update claim_success_and_activate_dao to use max_raise_revealed
- [x] ✅ Update claim_success_and_create_dao_with_init to use max_raise_revealed
- [x] ✅ Add new events (RaiseCreatedWithSealedCap, MaxRaiseRevealed, RaiseFailedSealTimeout)
- [x] ✅ Initialize Seal fields in init_raise and init_raise_with_founder functions
- [x] ✅ Build and test - compilation successful

### Phase 3: Frontend/SDK Integration
- [ ] Add Seal SDK to frontend dependencies
- [ ] Implement encryption flow in raise creation UI
- [ ] Add error handling for Seal failures
- [ ] Update UI to show "Cap hidden (revealed after deadline)" messaging
- [ ] Test with mainnet Seal (if available) or testnet

### Phase 4: Indexer/Backend
- [ ] Add Seal SDK to indexer/backend
- [ ] Implement auto-decrypt logic on deadline
- [ ] Implement auto-crank settlement flow
- [ ] Add retry logic for Seal downtime
- [ ] Add monitoring and alerting
- [ ] Test with multiple concurrent raises

### Phase 5: Testing
- [ ] Unit tests for new Move functions
- [ ] Integration tests with Seal SDK (if testnet available)
- [ ] Test failure scenarios (Seal down, invalid values, timeouts)
- [ ] Load testing (many raises ending simultaneously)
- [ ] Security audit of reveal validation logic

### Phase 6: Migration and Deployment
- [ ] Keep backward compatibility (support both sealed and public cap raises)
- [ ] Deploy updated contracts
- [ ] Update frontend to use new sealed cap flow
- [ ] Monitor first few sealed raises closely
- [ ] Document for DAO creators

## Code Changes Summary

### Files to Modify

#### `contracts/futarchy_factory/sources/factory/launchpad.move`
- Update Raise struct (add 4 new fields)
- Add create_raise_with_sealed_cap() entry function
- Add reveal_and_begin_settlement() entry function
- Add fail_raise_seal_timeout() entry function
- Update claim_success_and_activate_dao() to use max_raise_revealed
- Update claim_success_and_create_dao_with_init() to use max_raise_revealed
- Add new constants and error codes
- Add new events

**Estimated Changes:** ~300 lines of new code

#### Frontend SDK (location unknown)
- Add Seal encryption wrapper
- Update raise creation flow
- Add decryption helper

**Estimated Changes:** ~200 lines

#### Indexer/Backend (location unknown)
- Add Seal decryption service
- Add auto-crank settlement job
- Add monitoring

**Estimated Changes:** ~300 lines

## Timeline Estimate

**With unknowns resolved:**
- Phase 1 (Research): 2-3 days
- Phase 2 (Contracts): 2-3 days
- Phase 3 (Frontend): 2 days
- Phase 4 (Backend): 2 days
- Phase 5 (Testing): 3-4 days
- Phase 6 (Deploy): 1 day

**Total:** ~2 weeks with Seal SDK documentation available

**If Seal docs are incomplete:** Add 1-2 weeks for trial-and-error experimentation

## Risks and Mitigation

### Risk 1: Seal Not Production Ready
**Likelihood:** Medium
**Impact:** High (can't implement)
**Mitigation:**
- Research Seal mainnet status before starting
- Have fallback to commit-reveal if Seal unavailable

### Risk 2: Seal SDK Poorly Documented
**Likelihood:** High (new product)
**Impact:** Medium (slower implementation)
**Mitigation:**
- Reach out to Mysten Labs for support
- Check Sui Discord for Seal examples
- Study any existing Seal integrations

### Risk 3: Seal Downtime in Production
**Likelihood:** Low-Medium (2-5% of raises)
**Impact:** Medium (raise fails, but refunds work)
**Mitigation:**
- Implement 7-day grace period
- Clear messaging to users about risk
- Monitor Seal availability proactively

### Risk 4: Key Server Time Disagreement
**Likelihood:** Low
**Impact:** High (unpredictable decryption)
**Mitigation:**
- Use Clock object on Sui as source of truth
- Test time-lock behavior extensively
- Add buffer time (e.g., deadline + 1 minute before attempting decrypt)

### Risk 5: Invalid Decrypted Values
**Likelihood:** Low (user error or malicious)
**Impact:** Low (caught by on-chain validation)
**Mitigation:**
- Strict validation in reveal_and_begin_settlement
- Commitment hash check (optional)
- Clear error messages

## Success Metrics

**Pre-Launch:**
- [ ] Seal integration tested on 10+ test raises
- [ ] Auto-crank settlement < 5 seconds after deadline
- [ ] Zero false positives on validation checks

**Post-Launch:**
- [ ] 98%+ raises decrypt successfully
- [ ] Average settlement time < 10 seconds after deadline
- [ ] Zero funds lost due to Seal issues
- [ ] Positive user feedback on hidden cap UX

## Questions for Mysten Labs / Seal Team

1. What is the official Seal TypeScript SDK package name and version?
2. Is Seal available on Sui mainnet, or only testnet currently?
3. What is the expected SLA/uptime for Seal key servers?
4. Are there example projects using Seal time-lock encryption we can reference?
5. What is the format and type of Walrus blob IDs when stored on-chain?
6. Does Seal SDK handle Walrus upload automatically, or separate steps?
7. What are the gas costs for typical Seal operations?
8. How should we handle Seal downtime in production applications?
9. Is there a Seal status page or monitoring endpoint?
10. What is the threshold configuration for Seal key servers (t-of-n)?

## Alternative Approaches (If Seal Blocked)

### Fallback Option: Commit-Reveal with Founder + Platform Multi-Reveal
```move
// If Seal not ready, use this hybrid approach
public struct Raise {
    max_raise_commitment: vector<u8>,     // hash(amount || salt)
    founder_can_reveal: bool,             // true by default
    platform_can_reveal: bool,            // true if founder delegates
    platform_reveal_address: address,     // your address
}

// Founder can delegate reveal rights to platform
public entry fun delegate_reveal_to_platform(raise, ctx) {
    assert!(ctx.sender() == raise.creator);
    raise.platform_can_reveal = true;
}

// Either founder OR platform can reveal
public entry fun reveal_by_founder_or_platform(raise, amount, salt, ctx) {
    let sender = ctx.sender();
    assert!(
        (sender == raise.creator && raise.founder_can_reveal) ||
        (sender == raise.platform_reveal_address && raise.platform_can_reveal),
        ENotAuthorized
    );
    // ... reveal logic
}
```

**This allows:**
- Founder reveals normally
- If founder AFK, they can opt-in delegate to your platform
- You don't hold keys by default (regulatory safe)
- Optional UX improvement without Seal dependency

## Notes

- **Founder allocation is ALREADY percentage-based** (founder_allocation_bps at line 218-219 in launchpad.move) ✅ No changes needed
- Seal integration is purely additive - keep existing create_raise() for backward compatibility
- This is a UX improvement, not a security fix - acceptable to fail occasionally if Seal down
- Focus on average case UX (98% success) rather than worst case guarantees
