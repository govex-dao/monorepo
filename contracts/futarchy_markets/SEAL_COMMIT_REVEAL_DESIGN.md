# 🔒 SEAL Commit-Reveal for Market Init Strategies - COMPREHENSIVE DESIGN

## Core Problem Statement

**Busy Queue = Strategy Exposure = Front-Running**

```
Queue Wait Time: 6 hours
Parameters Visible: mint_amount, swap_outcome, swap_size
Attack Window: 6 hours of prep time
Expected Loss: $5,000 per proposal
```

---

## Design Principles (Combined)

### 1. **Optional with Public Fallback** (Your Point)
```move
// Three modes:
MODE_SEALED:        // Max privacy, risk if SEAL fails
MODE_SEALED_SAFE:   // SEAL + public fallback
MODE_PUBLIC:        // No privacy, simple & fast
```

### 2. **Graceful Degradation** (My Point)
```move
// Never stuck - always a path forward
SEAL success   → Private execution ✅
SEAL failure   → Public fallback ⚠️
No SEAL        → Public execution 🔓
```

### 3. **Time-Based Eviction** (Your Point - CRITICAL!)
```move
// Can't block queue indefinitely
max_time_at_top_of_queue: 24 hours  // After this → evicted
```

### 4. **Permissionless Cranking with Bounty** (Your Point)
```move
// Anyone can execute if proposer doesn't
crank_bounty: 100 SUI  // Reward for cranking stuck proposals
```

---

## Data Structures

### Updated QueuedProposal
```move
public struct QueuedProposal<StableCoin> has store {
    // ... existing fields ...

    // SEAL commit-reveal (optional)
    sealed_params: Option<SealedMarketInitParams>,

    // Public fallback (required if sealed_params.is_some())
    public_params_fallback: Option<IntentSpec>,

    // Time tracking for eviction
    time_reached_top_of_queue: Option<u64>,  // Track when hit #1

    // Cranking bounty
    crank_bounty: Balance<SUI>,  // Reward for anyone who cranks
}

public struct SealedMarketInitParams has store, drop, copy {
    blob_id: u32,                    // Walrus blob ID
    commitment_hash: vector<u8>,     // Hash for verification
    reveal_deadline_ms: u64,         // Time limit to reveal
    max_time_at_top: u64,           // Max time at #1 before eviction (e.g., 24hr)
}
```

---

## Execution Flow with All Safety Mechanisms

### Step 1: Proposal Creation (3 Modes)

#### Mode A: Full SEAL (Max Privacy, User Accepts Risk)
```typescript
// Advanced users only - no fallback
createSealedProposal({
    sealed_params: {
        blob_id: encryptedBlob.id,
        hash: commitment,
        reveal_deadline: now + 7_days,
        max_time_at_top: 24_hours
    },
    public_fallback: null,  // ⚠️ No safety net!
    crank_bounty: 100_SUI   // Incentive for others to help
})
```

#### Mode B: SEAL with Fallback (Recommended)
```typescript
// Best of both worlds
createSealedProposal({
    sealed_params: {
        blob_id: encryptedBlob.id,
        hash: commitment,
        reveal_deadline: now + 7_days,
        max_time_at_top: 24_hours
    },
    public_fallback: intentSpec,  // ✅ Safety net
    crank_bounty: 50_SUI   // Lower bounty (fallback exists)
})
```

#### Mode C: Public (Simple & Fast)
```typescript
// No SEAL - just atomic execution
createPublicProposal({
    intent_spec: intentSpec,
    crank_bounty: 10_SUI  // Small bounty for cranking
})
```

### Step 2: Queue Progression
```move
// Proposal moves through queue normally
// When reaches #1 position:
public fun mark_proposal_at_top<StableCoin>(
    queue: &mut ProposalQueue<StableCoin>,
    clock: &Clock,
) {
    let top = get_top_proposal_mut(queue);
    top.time_reached_top_of_queue = option::some(clock.timestamp_ms());
}
```

### Step 3: Execution (with Time Limits!)

```move
/// Anyone can crank proposal from top of queue → execution
/// Proposer gets preference, but anyone can claim bounty after timeout
public entry fun crank_top_proposal_to_execution<AssetType, StableType>(
    queue: &mut ProposalQueue<StableType>,
    account: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let top = get_top_proposal_mut(queue);

    // Check time limits
    let time_at_top = clock.timestamp_ms() - *top.time_reached_top_of_queue.borrow();

    // Only proposer can crank in first hour (grace period)
    if (time_at_top < 3600000) {  // 1 hour
        assert!(ctx.sender() == top.proposer, EOnlyProposerCanCrankYet);
    };

    // After 1 hour, anyone can crank for bounty
    // After 24 hours, MUST be cranked or evicted
    assert!(time_at_top < top.sealed_params.borrow().max_time_at_top, EProposalExpired);

    // Try SEAL reveal first
    if (top.sealed_params.is_some()) {
        let sealed = top.sealed_params.borrow();

        // Attempt reveal
        let reveal_result = try_reveal_sealed_params(
            sealed.blob_id,
            sealed.commitment_hash,
            clock
        );

        if (reveal_result.is_ok()) {
            // SEAL SUCCESS ✅
            let revealed_params = reveal_result.unwrap();
            execute_market_init_with_params(account, revealed_params, clock, ctx);

            // Pay bounty to cranker
            pay_crank_bounty(top, ctx.sender());
            return
        };

        // SEAL FAILED - check for fallback
        if (top.public_params_fallback.is_some()) {
            // Use fallback ⚠️
            let fallback = *top.public_params_fallback.borrow();
            execute_market_init_with_params(account, fallback, clock, ctx);

            // Reduced bounty (fallback used, less privacy)
            pay_crank_bounty_reduced(top, ctx.sender());

            event::emit(SealRevealFailed {
                proposal_id: top.proposal_id,
                used_fallback: true,
            });
            return
        };

        // NO FALLBACK - check if past deadline
        if (clock.timestamp_ms() > sealed.reveal_deadline_ms) {
            // SEAL failed + no fallback + past deadline = EVICT
            evict_proposal_from_top(queue, top, ERevealFailedNoFallback);
            return
        };

        // Still within deadline - keep waiting
        abort ESealRevealPendingRetryLater
    };

    // No SEAL - execute with public params
    assert!(top.public_params_fallback.is_some(), ENoParamsToExecute);
    execute_market_init_with_params(account, *top.public_params_fallback.borrow(), clock, ctx);
    pay_crank_bounty(top, ctx.sender());
}
```

### Step 4: Auto-Eviction (Your Critical Point!)

```move
/// Background job or anyone can call to clean up stuck proposals
public entry fun evict_expired_proposal_at_top<StableType>(
    queue: &mut ProposalQueue<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let top = get_top_proposal(queue);

    // Check if proposal expired
    let time_at_top = clock.timestamp_ms() - *top.time_reached_top_of_queue.borrow();
    let max_time = if (top.sealed_params.is_some()) {
        top.sealed_params.borrow().max_time_at_top
    } else {
        86400000  // 24 hours default for public proposals
    };

    assert!(time_at_top >= max_time, EProposalNotExpired);

    // Evict and refund bond to proposer
    let evicted = remove_top_proposal(queue);

    // Return bond
    if (evicted.bond.is_some()) {
        transfer::public_transfer(evicted.bond.extract(), evicted.proposer);
    };

    // Bounty goes to caller (cleanup incentive)
    let bounty_coin = coin::from_balance(evicted.crank_bounty, ctx);
    transfer::public_transfer(bounty_coin, ctx.sender());

    event::emit(ProposalEvictedFromTop {
        proposal_id: evicted.proposal_id,
        reason: b"max_time_at_top_exceeded",
        time_at_top: time_at_top,
    });

    // Destroy remaining proposal data
    destroy_queued_proposal(evicted);
}
```

---

## Critical Validation (Your Point!)

### Cannot Crank to Execution if SEAL Invalid

```move
/// Validation happens BEFORE market creation
/// Prevents proposal from entering PREMARKET with bad SEAL
fun try_reveal_sealed_params(
    blob_id: u32,
    commitment_hash: vector<u8>,
    clock: &Clock,
): Result<IntentSpec, SealError> {
    // Step 1: Fetch encrypted blob from Walrus
    let encrypted_blob = walrus::fetch_blob(blob_id);
    if (encrypted_blob.is_none()) {
        return err(SealError::BlobNotFound)
    };

    // Step 2: Decrypt with SEAL
    let decrypted_data = seal::decrypt(
        encrypted_blob.unwrap(),
        clock.timestamp_ms()  // Identity = time lock
    );
    if (decrypted_data.is_err()) {
        return err(SealError::DecryptionFailed)
    };

    // Step 3: Verify commitment hash
    let revealed_params = decrypted_data.unwrap();
    let computed_hash = hash::keccak256(&revealed_params);
    if (computed_hash != commitment_hash) {
        return err(SealError::HashMismatch)  // ❌ INVALID!
    };

    // Step 4: Deserialize to IntentSpec
    let mut reader = bcs::new(revealed_params);
    let intent_spec: IntentSpec = bcs::peel(&mut reader);
    bcs_validation::validate_all_bytes_consumed(reader);

    ok(intent_spec)  // ✅ Valid!
}
```

**Key Insight:** If SEAL is invalid:
1. `try_reveal_sealed_params()` returns Error
2. Falls back to public params (if available)
3. OR gets evicted (if no fallback)
4. **Never enters PREMARKET with broken SEAL** ✅

---

## Timeout & Fund Validation (Your Point!)

### Scenario: DAO Doesn't Have Funds for Buyback

```move
/// Validate DAO has sufficient funds BEFORE cranking to execution
public entry fun crank_top_proposal_to_execution<AssetType, StableType>(
    queue: &mut ProposalQueue<StableType>,
    account: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // ... SEAL reveal logic ...

    // Get revealed/public params
    let intent_spec = get_intent_spec_to_execute(top);

    // VALIDATE: Check if DAO has required resources
    let validation_result = validate_dao_has_resources(
        account,
        &intent_spec
    );

    if (validation_result.is_err()) {
        // DAO doesn't have funds - EVICT proposal
        event::emit(ProposalEvictedDueToInsufficientFunds {
            proposal_id: top.proposal_id,
            required_funds: validation_result.required,
            available_funds: validation_result.available,
        });

        evict_proposal_from_top(
            queue,
            top,
            EInsufficientDaoFundsForExecution
        );
        return
    };

    // Proceed with execution...
    execute_market_init_with_params(account, intent_spec, clock, ctx);
}

/// Check if DAO has sufficient resources for intent spec
fun validate_dao_has_resources<Config>(
    account: &Account<Config>,
    intent_spec: &IntentSpec,
): Result<(), ResourceError> {
    // Parse intent spec actions
    let actions = intent_spec.actions();

    for (i in 0..vector::length(actions)) {
        let action = vector::borrow(actions, i);

        // Check action type
        if (action.action_type == type_name::get<WithdrawAction>()) {
            // Buyback requires stable in vault
            let withdraw_data = parse_withdraw_action(action.action_data);
            let vault_balance = account::get_vault_balance<StableType>(account);

            if (vault_balance < withdraw_data.amount) {
                return err(ResourceError {
                    required: withdraw_data.amount,
                    available: vault_balance,
                })
            }
        } else if (action.action_type == type_name::get<MintAction>()) {
            // Conditional raise requires TreasuryCap
            // (This should always exist, but validate anyway)
            assert!(account::has_treasury_cap<AssetType>(account), EMissingTreasuryCap);
        }
    };

    ok(())
}
```

---

## Cranking Bounty Economics

### Bounty Payment Logic
```move
/// Pay full bounty if successfully cranked
fun pay_crank_bounty<StableCoin>(
    proposal: &mut QueuedProposal<StableCoin>,
    cranker: address,
) {
    let bounty = balance::withdraw_all(&mut proposal.crank_bounty);
    let bounty_coin = coin::from_balance(bounty, ctx);
    transfer::public_transfer(bounty_coin, cranker);
}

/// Reduced bounty if used fallback (less value delivered)
fun pay_crank_bounty_reduced<StableCoin>(
    proposal: &mut QueuedProposal<StableCoin>,
    cranker: address,
) {
    // Only pay 50% bounty if fallback used (privacy failed)
    let full_bounty = balance::value(&proposal.crank_bounty);
    let reduced_bounty = balance::split(&mut proposal.crank_bounty, full_bounty / 2);

    let bounty_coin = coin::from_balance(reduced_bounty, ctx);
    transfer::public_transfer(bounty_coin, cranker);

    // Remaining 50% refunded to proposer
    let refund = balance::withdraw_all(&mut proposal.crank_bounty);
    let refund_coin = coin::from_balance(refund, ctx);
    transfer::public_transfer(refund_coin, proposal.proposer);
}
```

### Recommended Bounty Amounts
```move
// In DAO config
public struct QueueConfig has store, drop, copy {
    min_crank_bounty_sealed: u64,      // 100 SUI (high - SEAL is complex)
    min_crank_bounty_sealed_safe: u64, // 50 SUI (medium - has fallback)
    min_crank_bounty_public: u64,      // 10 SUI (low - simple execution)
    max_time_at_top_of_queue_ms: u64,  // 86400000 (24 hours default)
}
```

---

## Code Reuse: Extract SEAL Module (Your Point!)

### New Shared Module Structure
```
futarchy_seal_utils/
├─ sources/
│  ├─ seal_commit_reveal.move     // Core SEAL logic
│  ├─ seal_validation.move        // Hash verification
│  └─ seal_types.move             // Shared types
```

### Shared by Both:
1. **Launchpad** - Hide max_raise_amount
2. **Market Init** - Hide market init params

```move
/// In futarchy_seal_utils::seal_commit_reveal
public struct SealedData has store, drop, copy {
    blob_id: u32,
    commitment_hash: vector<u8>,
    reveal_deadline_ms: u64,
}

/// Generic reveal function used by both launchpad and market init
public fun reveal_sealed_data(
    sealed: &SealedData,
    clock: &Clock,
): Result<vector<u8>, SealError> {
    // Shared logic for:
    // 1. Fetch blob from Walrus
    // 2. Decrypt with SEAL
    // 3. Verify hash
    // 4. Return raw bytes

    // Each caller deserializes bytes to their specific type
}
```

---

## Implementation Checklist

### Phase 1: Extract SEAL Module (Prerequisite)
```markdown
- [ ] Create futarchy_seal_utils package
- [ ] Move SEAL logic from launchpad to shared module
- [ ] Add seal_commit_reveal.move (core logic)
- [ ] Add seal_validation.move (hash verification)
- [ ] Add seal_types.move (SealedData struct)
- [ ] Update launchpad to use shared module
- [ ] Test launchpad still works with extracted module
```

### Phase 2: Add SEAL to Market Init
```markdown
- [ ] Add SealedMarketInitParams to QueuedProposal
- [ ] Add public_params_fallback field
- [ ] Add time_reached_top_of_queue tracking
- [ ] Add crank_bounty field
- [ ] Implement try_reveal_sealed_params()
- [ ] Implement validate_dao_has_resources()
- [ ] Add mark_proposal_at_top() when #1 reached
- [ ] Add crank_top_proposal_to_execution() entry function
- [ ] Add evict_expired_proposal_at_top() entry function
- [ ] Add cranking bounty payment logic
```

### Phase 3: UI/UX
```markdown
- [ ] SDK: createSealedProposal() function
- [ ] SDK: SEAL encryption helpers
- [ ] UI: 3-mode selector (Sealed/Sealed+Safe/Public)
- [ ] UI: Show "🔒 SEALED" badge on proposals
- [ ] UI: Show countdown timer for proposals at top
- [ ] UI: "Crank Proposal" button (with bounty amount)
- [ ] UI: Warn if SEAL setup looks invalid
- [ ] UI: Show fallback params if user selected safe mode
```

### Phase 4: Monitoring & Alerts
```markdown
- [ ] Indexer: Track SEAL success rate
- [ ] Indexer: Track proposals stuck at top
- [ ] Indexer: Track time-to-crank metrics
- [ ] Alert: SEAL failure rate > 10%
- [ ] Alert: Proposal stuck at top > 12 hours
- [ ] Dashboard: Cranking opportunities (bounties available)
```

---

## Security Considerations

### Attack Vectors Mitigated
✅ **6-hour visibility window** - SEAL hides params
✅ **Stuck proposals blocking queue** - 24hr eviction
✅ **Proposer abandons proposal** - Bounty incentivizes cranking
✅ **SEAL setup errors** - Fallback prevents loss
✅ **DAO lacks funds** - Pre-execution validation

### New Attack Vectors Introduced
⚠️ **SEAL infrastructure failure** - Fallback mitigates
⚠️ **Walrus blob unavailability** - Fallback mitigates
⚠️ **Bounty too low, no one cranks** - Queue eviction after 24hr

---

## Economic Analysis

### Cost-Benefit (Busy Queue)
```
Benefit: $5,000 saved from front-running
Cost:
  - SEAL encryption: $0.50
  - Walrus storage: $2
  - Crank bounty: $50
  - Risk premium: $5 (5% failure rate)
Total Cost: $57.50

Net Benefit: $4,942.50
ROI: 8,595%
```

### Expected Value by Queue Congestion

| Queue Wait Time | Front-Run Risk | SEAL EV | Recommendation |
|-----------------|----------------|---------|----------------|
| < 5 minutes | 0% | -$57 | ❌ Don't use SEAL |
| 30 minutes | 5% | -$32 | ❌ Don't use SEAL |
| 2 hours | 20% | +$443 | ✅ Consider SEAL |
| 6 hours | 50% | +$2,443 | ✅✅ Strongly recommend |
| 24 hours | 80% | +$3,943 | ✅✅✅ Essential |

**SDK should auto-recommend SEAL based on current queue wait time!**

---

## Summary

| Feature | Status | Impact |
|---------|--------|--------|
| Optional SEAL with 3 modes | ✅ Designed | High - User flexibility |
| Public fallback safety net | ✅ Designed | Critical - Prevents stuck proposals |
| 24hr eviction from top | ✅ Designed | Critical - Queue can't be blocked |
| Cranking bounty system | ✅ Designed | High - Permissionless execution |
| Pre-execution fund validation | ✅ Designed | Medium - Prevents failed execution |
| Shared SEAL module | 📝 TODO | High - Code reuse with launchpad |

**This design addresses ALL your concerns while maintaining UX safety.** 🎯
