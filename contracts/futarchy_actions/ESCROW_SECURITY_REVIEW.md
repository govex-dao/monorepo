# Security Review: Proposal Escrow Design

## Critical Flaw Identified: Mutation Attack Vector

### The Problem

The current `proposal_escrow` design allows funds to be deposited **BEFORE** proposal outcomes are finalized, creating a critical mutation attack:

```move
// Current (BROKEN) Flow:
1. Create proposal in PREMARKET state
2. Create escrow + deposit 1000 tokens  ← TOO EARLY
3. Attacker adds new outcome (allowed in PREMARKET)
4. Market initializes with 3 outcomes instead of 2
5. Attacker's outcome gets 1/3 of escrowed funds (333 tokens)
6. Proposer's funds DILUTED by attacker
```

### Root Cause: Timing Violation

**Proposal State Machine** (proposal.move:46-49):
```move
const STATE_PREMARKET: u8 = 0;  // ← Outcomes can be added/mutated
const STATE_REVIEW: u8 = 1;     // ← Market locked, NO mutations
const STATE_TRADING: u8 = 2;
const STATE_FINALIZED: u8 = 3;
```

**Mutation Rules** (proposal.move:788):
```move
public fun add_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    // ...
) {
    // SECURITY: Only allow adding outcomes in PREMARKET state
    assert!(proposal.state == STATE_PREMARKET, EInvalidState);
    //  ^^^ Allows mutation until market initialized
}
```

**Escrow Design Flaw**:
```move
// My broken design - can deposit anytime
public fun create_with_coin<AssetType>(
    proposal_id: ID,           // ← Just an ID, no state check
    deposit: Coin<AssetType>,  // ← Accepts funds too early
    clock: &Clock,
    ctx: &mut TxContext,
): (ProposalEscrow<AssetType>, EscrowReceipt<AssetType>)
```

No verification that:
1. ✗ Proposal is in correct state (should be ≥ REVIEW)
2. ✗ Outcomes are finalized
3. ✗ Outcome count won't change

---

## Comparison: How Market Init Does It Right

### Correct Pattern (proposal_lifecycle.move:118-242)

```move
public fun activate_proposal_from_queue<AssetType, StableType>(
    account: &mut Account<FutarchyConfig>,
    queue: &mut ProposalQueue<StableType>,
    proposal_fee_manager: &mut ProposalFeeManager>,
    spot_pool: &mut UnifiedSpotPool<AssetType, StableType>,
    asset_liquidity: Coin<AssetType>,      // ← Coins passed here
    stable_liquidity: Coin<StableType>,    // ← At activation time
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID) {
    // 1. Pop proposal from queue (outcomes already frozen in queue)
    let queued_proposal = priority_queue::try_activate_next(...);

    // 2. ATOMICALLY initialize market with coins
    let (proposal_id, market_state_id, _) = proposal::initialize_market<...>(
        proposal_id,
        dao_id,
        // ... params ...
        asset_liquidity,    // ← Funds provided at init time
        stable_liquidity,   // ← ATOMIC with outcome finalization
        // ...
    );

    // 3. Proposal state immediately set to REVIEW (line 408)
    // No window for mutation - outcomes locked before funds deposited
}
```

**Key Security Properties**:
1. ✅ Outcomes finalized BEFORE funds deposited
2. ✅ State transition ATOMIC with deposit
3. ✅ No window for mutation attack
4. ✅ Outcome count locked when funds added

---

## Attack Scenario

### Setup
- Proposer wants to create grant proposal with 1000 USDC escrowed
- 2 outcomes: YES (grant approved) / NO (rejected)

### Attack Flow

```typescript
// 1. Proposer creates proposal (PREMARKET)
const proposal = await createProposal({
  outcomes: ['YES: Approve Grant', 'NO: Reject']
});
// State: PREMARKET, outcome_count = 2

// 2. Proposer creates escrow (MY BROKEN DESIGN)
const escrow = await createEscrowWithCoin(
  proposal.id,
  usdc_1000  // Proposer deposits 1000 USDC
);
// Escrow holds 1000 USDC, but proposal still PREMARKET!

// 3. Attacker sees opportunity (proposal still in PREMARKET)
const attackTx = await addOutcome(proposal, {
  message: 'MAYBE: Partial Grant',
  fee: 10_SUI  // Small fee to add outcome
});
// State: PREMARKET, outcome_count = 3 ← ATTACKER ADDED

// 4. Market initialized
const market = await initializeMarket(proposal, escrow);
// Splits 1000 USDC evenly: 333 per outcome
// Attacker's outcome gets 333 USDC from proposer's funds!
// State: REVIEW (NOW locked, but too late)
```

### Impact
- Proposer deposited 1000 USDC expecting 2 outcomes
- Attacker injected 3rd outcome for 10 SUI
- Each outcome now gets 333 USDC instead of 500 USDC
- **Proposer's funds diluted by 33%**

---

## Three Fix Options

### Option 1: State-Locked Escrow (Recommended for Commitment)

```move
/// Create escrow ONLY if proposal in correct state
public fun create_with_coin_state_locked<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,  // ← Pass actual proposal
    deposit: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (ProposalEscrow<AssetType>, EscrowReceipt<AssetType>) {
    // SECURITY: Only allow escrow after outcomes finalized
    let state = proposal::state(proposal);
    assert!(
        state >= STATE_REVIEW,  // ← Must be at least REVIEW
        EProposalNotReady
    );

    // Capture outcome count at escrow creation
    let locked_outcome_count = proposal::outcome_count(proposal);

    let id = object::new(ctx);
    let escrow_id = object::uid_to_inner(&id);

    let escrow = ProposalEscrow {
        id,
        proposal_id: object::id(proposal),
        locked_outcome_count,  // ← Store for verification
        balance: deposit.into_balance(),
        objects: bag::new(ctx),
        balance_withdrawn: false,
        created_at: clock.timestamp_ms(),
    };

    let receipt = EscrowReceipt {
        escrow_id,
        proposal_id: object::id(proposal),
        locked_outcome_count,  // ← Verify on withdrawal
        coin_amount: deposit.value(),
        object_ids: vector::empty(),
    };

    (escrow, receipt)
}

/// Verify outcome count matches when withdrawing
public fun withdraw_partial<AssetType, StableType>(
    escrow: &mut ProposalEscrow<AssetType>,
    proposal: &Proposal<AssetType, StableType>,  // ← Verify state
    receipt: &EscrowReceipt<AssetType>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    // Verify escrow wasn't created too early
    let current_outcome_count = proposal::outcome_count(proposal);
    assert!(
        current_outcome_count == escrow.locked_outcome_count,
        EOutcomeCountMismatch
    );

    // ... rest of withdrawal logic
}
```

**Pros**:
- ✅ Prevents mutation after escrow created
- ✅ Verifies outcome count on deposit AND withdrawal
- ✅ Works for commitment proposals

**Cons**:
- Requires passing `&Proposal` to escrow functions
- More complex API

---

### Option 2: Atomic Integration (Recommended for Market Init)

```move
/// Don't create escrow separately - integrate with initialize_market
public fun initialize_market_with_optional_escrow<AssetType, StableType>(
    proposal_id: ID,
    // ... all market params ...
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    escrow_config: Option<EscrowConfig>,  // ← Optional escrow
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID, Option<ProposalEscrow<AssetType>>, Option<EscrowReceipt<AssetType>>) {
    // 1. Initialize market (locks outcomes)
    let (proposal_id, market_id, _) = proposal::initialize_market<...>(
        proposal_id,
        // ...
        asset_coin,
        stable_coin,
        // ...
    );
    // State now REVIEW - outcomes locked

    // 2. Create escrow if requested (AFTER outcomes locked)
    let (escrow_opt, receipt_opt) = if (escrow_config.is_some()) {
        let config = escrow_config.extract();
        let (escrow, receipt) = proposal_escrow::create_with_coin(
            proposal_id,
            config.deposit,
            clock,
            ctx
        );
        (option::some(escrow), option::some(receipt))
    } else {
        (option::none(), option::none())
    };

    (proposal_id, market_id, escrow_opt, receipt_opt)
}
```

**Pros**:
- ✅ Completely atomic - no mutation window
- ✅ Follows existing market init pattern
- ✅ Simple - outcomes locked before escrow created

**Cons**:
- Requires changing market init flow
- Less flexible for external deposits

---

### Option 3: Post-Init Escrow (Recommended for Grants/Bounties)

```move
/// Create escrow ONLY for proposals that are already initialized
/// Used for grants, bounties, etc. - NOT for initial market liquidity
public fun create_post_init_escrow<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    deposit: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (ProposalEscrow<AssetType>, EscrowReceipt<AssetType>) {
    // SECURITY: Require market already initialized
    let state = proposal::state(proposal);
    assert!(
        state >= STATE_REVIEW,  // ← Market must be initialized
        EMarketNotInitialized
    );

    // Verify market exists
    assert!(
        proposal::escrow_id(proposal).is_some(),
        EMarketNotInitialized
    );

    // Create separate escrow for this purpose (grants, etc.)
    // Outcomes already locked - safe to deposit
    create_with_coin_internal(
        object::id(proposal),
        proposal::outcome_count(proposal),
        deposit,
        clock,
        ctx
    )
}
```

**Pros**:
- ✅ Safe - only works after market init
- ✅ Flexible - allows external deposits
- ✅ Clear semantics - "post-init" in name

**Cons**:
- Can't be used for initial market liquidity
- Requires market already initialized

---

## Recommended Architecture

### For Commitment Proposals
Use **Option 1** (State-Locked):
```move
// In commitment_actions_v2.move
public fun fulfill_create_commitment_proposal<...>(
    request: ResourceRequest<...>,
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    proposal: &mut Proposal<AssetType, StableType>,  // ← Pass proposal
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): (...) {
    // Verify proposal is ready (STATE >= REVIEW)
    assert!(proposal::state(proposal) >= STATE_REVIEW, EProposalNotReady);

    // Auto-withdraw from vault
    let deposit = vault::do_spend<...>(...);

    // Create state-locked escrow
    let (escrow, receipt) = proposal_escrow::create_with_coin_state_locked(
        proposal,
        deposit,
        clock,
        ctx
    );

    // Store receipt in proposal dynamic fields
    dynamic_field::add(
        proposal::borrow_uid_mut(proposal),
        b"commitment_escrow_receipt",
        receipt
    );

    // ...
}
```

### For Market Init
Use **Option 2** (Atomic):
- Keep coins passed to `initialize_market`
- No separate escrow for initial liquidity
- Outcomes locked at init time

### For Grants/Bounties
Use **Option 3** (Post-Init):
```move
// Grant creator calls this AFTER proposal initialized
public entry fun create_grant_with_escrow<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,
    payment: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Safe - market already initialized, outcomes locked
    let (escrow, receipt) = proposal_escrow::create_post_init_escrow(
        proposal,
        payment,
        clock,
        ctx
    );

    // ... create grant object with receipt
}
```

---

## Summary

### Current Design: ❌ CRITICAL FLAW
- Allows deposit in PREMARKET state
- No outcome count verification
- Mutation attack possible
- **Fund dilution risk**

### Market Init Pattern: ✅ SECURE
- Atomic outcome finalization + deposit
- State transition locks mutations
- No attack window
- **Reference implementation**

### Fix Required
1. Add state checks to escrow creation
2. Verify/lock outcome count
3. Choose timing pattern based on use case:
   - Commitment: State-locked (Option 1)
   - Market init: Atomic (Option 2)
   - Grants/bounties: Post-init (Option 3)

### Action Items
1. Delete current `proposal_escrow.move` (insecure)
2. Implement one of the three secure patterns
3. Add tests for mutation attack prevention
4. Document timing requirements clearly
