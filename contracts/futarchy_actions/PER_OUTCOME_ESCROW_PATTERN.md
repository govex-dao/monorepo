# Generic Per-Outcome Escrow Pattern

## Overview

A reusable pattern for attaching deposits/escrow to **specific proposal outcomes**, with complete isolation between outcomes and mutation attack prevention.

## Key Security Properties

✅ **Outcome Isolation**: Each outcome has its own escrow + receipt
✅ **Mutation Prevention**: State-locked (STATE ≥ REVIEW) before deposits
✅ **Cross-Outcome Protection**: Attacker's outcome can't steal another outcome's funds
✅ **Outcome Count Locking**: Verifies outcome count unchanged since deposit

---

## Core Components

### 1. Outcome-Keyed Dynamic Fields

```move
/// Key for storing per-outcome data in proposal
public struct OutcomeEscrowKey has copy, drop, store {
    outcome_index: u64,  // Which outcome owns this
}

// Store receipt in proposal
dynamic_field::add(
    proposal.uid_mut(),
    OutcomeEscrowKey { outcome_index: 0 },  // ← Outcome 0
    escrow_receipt
);

// Retrieve receipt for outcome 0 ONLY
let receipt = dynamic_field::borrow(
    proposal.uid(),
    OutcomeEscrowKey { outcome_index: 0 }  // ← Can't access outcome 1's receipt
);
```

### 2. State-Locked Escrow Creation

```move
/// Only create escrow if proposal ready (outcomes finalized)
public fun create_for_outcome_with_coin<AssetType, StableType>(
    proposal: &Proposal<AssetType, StableType>,  // ← Pass actual proposal
    outcome_index: u64,
    deposit: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (ProposalEscrow<AssetType>, EscrowReceipt<AssetType>) {
    // SECURITY: Only after outcomes locked
    let state = proposal::state(proposal);
    assert!(state >= STATE_REVIEW, EProposalNotReady);  // ← No PREMARKET deposits

    // Verify outcome exists
    let outcome_count = proposal::outcome_count(proposal);
    assert!(outcome_index < outcome_count, EInvalidOutcome);

    // Lock outcome count at creation time
    let locked_outcome_count = outcome_count;

    // Create escrow with locked count
    let escrow = ProposalEscrow {
        // ...
        outcome_index,
        locked_outcome_count,  // ← Frozen at creation
        // ...
    };

    let receipt = EscrowReceipt {
        // ...
        outcome_index,
        locked_outcome_count,  // ← Must match on withdrawal
        // ...
    };

    (escrow, receipt)
}
```

### 3. Outcome Count Verification on Withdrawal

```move
/// Withdraw with mutation check
public fun withdraw_partial<AssetType, StableType>(
    escrow: &mut ProposalEscrow<AssetType>,
    proposal: &Proposal<AssetType, StableType>,  // ← Verify current state
    receipt: &EscrowReceipt<AssetType>,
    amount: u64,
    // ...
): Coin<AssetType> {
    // Verify outcome count hasn't changed
    let current_outcome_count = proposal::outcome_count(proposal);
    assert!(
        current_outcome_count == escrow.locked_outcome_count,
        EOutcomeCountMismatch  // ← Mutation detected!
    );
    assert!(
        current_outcome_count == receipt.locked_outcome_count,
        EOutcomeCountMismatch
    );

    // Safe to withdraw - outcome count verified
    // ...
}
```

---

## Generic API

### Store Receipt in Proposal

```move
/// Store receipt keyed by outcome
public fun store_receipt_in_proposal<AssetType, StableType, ReceiptType: store>(
    proposal: &mut Proposal<AssetType, StableType>,
    outcome_index: u64,
    receipt: EscrowReceipt<ReceiptType>,
) {
    let key = OutcomeEscrowKey { outcome_index };
    dynamic_field::add(
        proposal::borrow_uid_mut(proposal),
        key,
        receipt
    );
}
```

### Retrieve Receipt for Specific Outcome

```move
/// Get receipt for outcome - only that outcome can access it
public fun get_receipt_from_proposal<AssetType, StableType, ReceiptType: store>(
    proposal: &Proposal<AssetType, StableType>,
    outcome_index: u64,
): &EscrowReceipt<ReceiptType> {
    let key = OutcomeEscrowKey { outcome_index };
    dynamic_field::borrow(
        proposal::borrow_uid(proposal),
        key
    )
}
```

### Check if Outcome Has Escrow

```move
/// Check before trying to execute escrow-dependent logic
public fun has_escrow_receipt<AssetType, StableType, ReceiptType: store>(
    proposal: &Proposal<AssetType, StableType>,
    outcome_index: u64,
): bool {
    let key = OutcomeEscrowKey { outcome_index };
    dynamic_field::exists_(
        proposal::borrow_uid(proposal),
        key
    )
}
```

---

## Usage Example: Commitment Proposal

### Step 1: Create Escrow for Specific Outcome

```move
// Proposal has 3 outcomes: REJECT, ACCEPT, PARTIAL
// User wants to attach commitment escrow to ACCEPT outcome (index 1)

public fun fulfill_create_commitment_for_outcome<...>(
    request: ResourceRequest<CreateCommitmentAction<AssetType>>,
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    proposal: &mut Proposal<AssetType, StableType>,
    witness: IW,
    clock: &Clock,
    ctx: &mut TxContext,
): (ProposalEscrow<AssetType>, ResourceReceipt<...>) {
    let action = resource_requests::extract_action(request);

    // Withdraw from vault
    let deposit = vault::do_spend<...>(...);

    // Create state-locked escrow for outcome 1 (ACCEPT)
    let (escrow, receipt) = proposal_escrow_v2::create_for_outcome_with_coin(
        proposal,
        1,  // ← ACCEPT outcome
        deposit,
        clock,
        ctx
    );

    // Store receipt in proposal (keyed by outcome 1)
    proposal_escrow_v2::store_receipt_in_proposal(
        proposal,
        1,  // ← Outcome 1
        receipt
    );

    // Also store commitment metadata (tiers, etc.) per-outcome
    let commitment_key = CommitmentDataKey { outcome_index: 1 };
    dynamic_field::add(
        proposal::borrow_uid_mut(proposal),
        commitment_key,
        CommitmentData { tiers, ... }
    );

    // Share escrow
    transfer::public_share_object(escrow);

    (escrow, resource_requests::create_receipt(action))
}
```

### Step 2: Execute for Winning Outcome Only

```move
/// Only winning outcome can withdraw from its escrow
public fun execute_commitment_for_winning_outcome<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut ProposalEscrow<AssetType>,
    winning_outcome: u64,
    accept_market_twap: u128,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<AssetType> {
    // SECURITY: Verify this is the winning outcome
    assert!(proposal::is_finalized(proposal), ENotFinalized);
    let actual_winning_outcome = proposal::get_winning_outcome(proposal);
    assert!(actual_winning_outcome == winning_outcome, EWrongOutcome);

    // Retrieve receipt for THIS outcome ONLY
    let receipt = proposal_escrow_v2::get_receipt_from_proposal<AssetType, StableType, AssetType>(
        proposal,
        winning_outcome  // ← Can't access other outcomes' receipts
    );

    // Get commitment data for this outcome
    let commitment_key = CommitmentDataKey { outcome_index: winning_outcome };
    let commitment_data = dynamic_field::borrow(
        proposal::borrow_uid(proposal),
        commitment_key
    );

    // Execute tier-based withdrawal
    let (tier_idx, found) = find_tier(accept_market_twap, &commitment_data.tiers);
    if (found) {
        // Partial withdrawal
        proposal_escrow_v2::withdraw_partial(escrow, proposal, receipt, amount, clock, ctx)
    } else {
        // Full refund
        let receipt_owned = proposal_escrow_v2::remove_receipt_from_proposal(
            proposal,
            winning_outcome
        );
        proposal_escrow_v2::withdraw_all_coins(escrow, proposal, receipt_owned, clock, ctx)
    }
}
```

---

## Attack Prevention

### Attack: Outcome Mutation + Fund Theft

**Setup**:
- Proposer creates proposal with outcomes: [REJECT, ACCEPT]
- Proposer deposits 1000 USDC to ACCEPT outcome (index 1)

**Attack Attempt**:
```move
// 1. Attacker adds new outcome in PREMARKET
add_outcome(proposal, "STEAL", ...);
// Now: [REJECT, ACCEPT, STEAL] (outcomes 0, 1, 2)

// 2. Market initializes
initialize_market(proposal, ...);
// State → REVIEW (outcomes now locked)

// 3. Proposal finalizes, STEAL wins
finalize_proposal(proposal, winning_outcome = 2);

// 4. Attacker tries to steal ACCEPT's escrow
execute_commitment_for_winning_outcome(
    proposal,
    accept_escrow,  // ← Escrow for outcome 1
    2,  // ← winning_outcome = 2 (STEAL)
    ...
);
```

**Prevention**:

✅ **State Lock**: Can't create escrow in PREMARKET
```move
// Attacker can't create escrow before REVIEW
let (escrow, _) = create_for_outcome_with_coin(
    proposal,  // ← state = PREMARKET
    ...
);
// ❌ ABORTS: EProposalNotReady
```

✅ **Receipt Isolation**: Each outcome has its own receipt
```move
// Outcome 2 (STEAL) tries to get outcome 1's receipt
let receipt = get_receipt_from_proposal(proposal, 2);
// ❌ ABORTS: No receipt stored for outcome 2

let receipt = get_receipt_from_proposal(proposal, 1);
// ✅ Returns outcome 1's receipt, but...

// Receipt has outcome_index = 1 embedded
assert!(receipt.outcome_index == winning_outcome);  // 1 != 2
// ❌ ABORTS: Can't use outcome 1's receipt for outcome 2
```

✅ **Outcome Count Lock**: Detects mutation
```move
// Escrow created when outcome_count = 2
// escrow.locked_outcome_count = 2

// Attacker adds outcome → outcome_count = 3

withdraw_partial(escrow, proposal, receipt, ...);
// Checks: current_outcome_count (3) == escrow.locked_outcome_count (2)
// ❌ ABORTS: EOutcomeCountMismatch
```

---

## Usage for Other Action Types

### Example: Grant Proposal

```move
/// Grant with escrowed payment
public fun create_grant_with_escrow<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    grantee_outcome_index: u64,  // Which outcome approves grant
    payment: Coin<AssetType>,
    clock: &Clock,
    ctx: &mut TxContext,
): ProposalEscrow<AssetType> {
    // Create escrow for specific outcome
    let (escrow, receipt) = proposal_escrow_v2::create_for_outcome_with_coin(
        proposal,
        grantee_outcome_index,
        payment,
        clock,
        ctx
    );

    // Store receipt
    proposal_escrow_v2::store_receipt_in_proposal(
        proposal,
        grantee_outcome_index,
        receipt
    );

    // Store grant metadata (per-outcome)
    let grant_key = GrantDataKey { outcome_index: grantee_outcome_index };
    dynamic_field::add(
        proposal::borrow_uid_mut(proposal),
        grant_key,
        GrantData { grantee, milestones, ... }
    );

    escrow
}

/// Execute grant if that outcome wins
public fun execute_grant<AssetType, StableType>(
    proposal: &mut Proposal<AssetType, StableType>,
    escrow: &mut ProposalEscrow<AssetType>,
    winning_outcome: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Only if grant outcome won
    assert!(proposal::get_winning_outcome(proposal) == winning_outcome);

    // Get receipt for this outcome
    let receipt = proposal_escrow_v2::remove_receipt_from_proposal(
        proposal,
        winning_outcome
    );

    // Withdraw and send to grantee
    let payment = proposal_escrow_v2::withdraw_all_coins(
        escrow,
        proposal,
        receipt,
        clock,
        ctx
    );

    let grant_key = GrantDataKey { outcome_index: winning_outcome };
    let grant_data = dynamic_field::borrow(
        proposal::borrow_uid(proposal),
        grant_key
    );

    transfer::public_transfer(payment, grant_data.grantee);
}
```

---

## Summary

### Pattern Components

1. **OutcomeEscrowKey**: Dynamic field key (per-outcome)
2. **State Lock**: Only create escrow in STATE ≥ REVIEW
3. **Outcome Count Lock**: Store + verify outcome count
4. **Receipt Isolation**: Store receipts keyed by outcome
5. **Withdrawal Verification**: Check outcome + count on withdrawal

### Security Guarantees

✅ No deposits in PREMARKET (mutation window closed)
✅ Each outcome has isolated escrow + receipt
✅ Outcome count verified on creation + withdrawal
✅ Attacker's outcome can't access other outcomes' funds
✅ Generic pattern works for any action type

### Files

- **`proposal_escrow_v2.move`**: Core secure escrow module
- **`commitment_actions_v3.move`**: Example usage for commitments
- **`PER_OUTCOME_ESCROW_PATTERN.md`**: This guide

### Migration Path

1. Keep old `proposal_escrow.move` (deprecated, insecure)
2. Use `proposal_escrow_v2.move` for new actions
3. Update existing actions to v2 when ready
4. Remove v1 after full migration
