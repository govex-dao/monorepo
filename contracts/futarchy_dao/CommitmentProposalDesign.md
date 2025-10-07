# Decentralization Commitment Proposal

## Concept
Allow founders/whales to propose burning or locking their tokens to reduce centralization risk. Markets decide if this decentralization would increase the DAO's value.

## Proposal Structure

### Basic Flow
1. **Founder/whale deposits their DAO tokens** into escrow
2. **Creates proposal**: "I'll lock tokens at different price levels"
   - Sets multiple tiers: e.g., 
     - Lock 10% if TWAP > $1.50
     - Lock 20% if TWAP > $2.00
     - Lock 30% if TWAP > $3.00
3. **Markets trade** conditional tokens as normal
4. **After trading ends**: 
   - Check TWAP of ACCEPT market (not reject)
   - Lock tokens based on highest tier reached
   - Return unlocked portion to proposer
5. **No execution** = All tokens returned (markets rejected)

## Implementation Components

### 1. CommitmentProposal Type
```move
public struct PriceTier has store {
    twap_threshold: u128, // TWAP price to trigger this tier
    lock_amount: u64, // Amount to lock at this price
    lock_duration_ms: u64, // How long to lock
}

public struct CommitmentProposal<phantom AssetType, phantom StableType> has key, store {
    id: UID,
    
    // Proposer info
    proposer: address,
    withdrawal_recipient: address, // Can be changed by proposer
    
    // Commitment details
    committed_amount: u64,
    committed_coins: Balance<AssetType>, // Held in escrow
    
    // Price-based lock tiers (ordered by price)
    tiers: vector<PriceTier>,
    
    // Execution results
    locked_amount: u64, // Amount actually locked
    unlock_time: Option<u64>, // When locked tokens unlock
    
    // Standard proposal fields
    state: ProposalState,
    outcome: Option<ProposalOutcome>,
    created_at: u64,
    trading_start: u64,
    trading_end: u64,
}
```

### 2. Actions Required

#### CreateCommitmentProposalAction
```move
public struct CreateCommitmentProposalAction has store {
    committed_amount: u64,
    required_price_increase_bps: u64,
    lock_duration_ms: u64,
    burn_on_failure: bool,
    description: String,
}
```

#### UpdateWithdrawalRecipientAction
```move
public struct UpdateWithdrawalRecipientAction has store {
    proposal_id: ID,
    new_recipient: address,
}
```

#### ExecuteCommitmentAction
```move
public struct ExecuteCommitmentAction has store {
    proposal_id: ID,
}
```

### 3. Execution Logic

#### If COMMIT wins:
```move
fun execute_commitment<AssetType, StableType>(
    proposal: &mut CommitmentProposal<AssetType, StableType>,
    spot_pool: &SpotAMM<AssetType, StableType>,
    clock: &Clock,
) {
    // Get current price via TWAP
    let current_price = spot_amm::get_twap_for_interval(
        spot_pool,
        MEASUREMENT_PERIOD_MS, // e.g., 7 days
        clock
    );
    
    // Calculate required price
    let required_price = proposal.baseline_price * 
        (10000 + proposal.required_price_increase_bps) / 10000;
    
    if (current_price >= required_price) {
        // Success! Lock tokens
        proposal.unlock_time = option::some(
            clock.timestamp_ms() + proposal.lock_duration_ms
        );
        // Tokens remain in proposal escrow until unlock
    } else {
        // Failed prediction
        if (proposal.burn_on_failure) {
            // Burn the tokens
            let coins = balance::withdraw_all(&mut proposal.committed_coins);
            balance::destroy_for_testing(coins); // Or proper burn mechanism
        } else {
            // Return to proposer
            let coins = balance::withdraw_all(&mut proposal.committed_coins);
            transfer::public_transfer(
                coin::from_balance(coins, ctx),
                proposal.proposer
            );
        }
    }
}
```

#### Withdrawal (after lock period):
```move
public entry fun withdraw_locked_commitment<AssetType, StableType>(
    proposal: &mut CommitmentProposal<AssetType, StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(proposal.proposer == tx_context::sender(ctx), ENotProposer);
    assert!(proposal.unlock_time.is_some(), ENotLocked);
    assert!(clock.timestamp_ms() >= *proposal.unlock_time.borrow(), EStillLocked);
    
    let coins = balance::withdraw_all(&mut proposal.committed_coins);
    transfer::public_transfer(
        coin::from_balance(coins, ctx),
        proposal.withdrawal_recipient
    );
}
```

### 4. Market Structure

Two outcomes:
- **COMMIT**: Markets predict commitment will increase price by X%
- **REJECT**: Markets predict it won't or isn't worth it

Trading works same as normal futarchy proposals.

### 5. Integration Points

#### With existing proposal system:
- Extends base `Proposal` type
- Uses same conditional token mechanism
- Same trading periods and oracle

#### New requirements:
- Need to track baseline price at creation
- Need to measure price after execution
- Need escrow mechanism for committed tokens
- Need time-lock mechanism

## Benefits

1. **Skin in the game**: Proposers risk their own tokens
2. **Quality filter**: Only serious proposals with real conviction
3. **Aligned incentives**: Proposer wins only if DAO wins
4. **Market validation**: Two-level check (market prediction + actual result)

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Price manipulation | Use TWAP over long period |
| Proposer loses unfairly | Allow "return" mode instead of burn |
| Tokens locked too long | Reasonable max lock periods |
| Change of plans | Allow recipient address updates |

## Implementation Checklist

- [ ] Create `commitment_proposal.move` module
- [ ] Add `CommitmentProposal` struct
- [ ] Implement creation function with escrow
- [ ] Add execution logic with price checking
- [ ] Implement withdrawal after lock period
- [ ] Add recipient update function
- [ ] Create actions for dispatcher
- [ ] Add to proposal type enum
- [ ] Update UI to show commitment details
- [ ] Add events for all operations

## Example Use Cases

1. **Founder decentralization**: "I hold 40% of tokens, will burn 20% to reduce centralization risk"
2. **Whale reduction**: "My 15% stake might be concerning, I'll lock 10% for 2 years"
3. **Team vesting acceleration**: "We'll burn half our unvested tokens to show long-term alignment"
4. **Crisis response**: "After controversy, founder burns tokens to restore confidence"

## Answers to Design Questions

- **Max commitment amount**: No max (u64 max = SUI coin supply)
- **Unsuccessful commits**: Always return to caller
- **Price measurement**: Use TWAP of ACCEPT market
- **Lock period**: Variable per tier
- **Cancel before trading**: No cancellation allowed
- **Multiple tiers**: Yes, multiple price targets with different lock amounts

## Implementation Checklist

### Phase 1: Core Module Structure
- [ ] Create `commitment_proposal.move` module
- [ ] Define `PriceTier` struct with twap_threshold, lock_amount, lock_duration_ms
- [ ] Define `CommitmentProposal` struct with escrow balance and tiers
- [ ] Add to proposal type enum in main proposal module

### Phase 2: Creation Functions
- [ ] `create_commitment_proposal` entry function
  - [ ] Accept deposited coins into escrow
  - [ ] Validate tiers are sorted by price
  - [ ] Validate tier amounts don't exceed deposit
  - [ ] Create proposal with standard trading periods
  - [ ] Emit `CommitmentProposalCreated` event

### Phase 3: Execution Logic
- [ ] `execute_commitment` function (called after proposal passes)
  - [ ] Get TWAP from ACCEPT conditional market
  - [ ] Find highest tier where TWAP >= threshold
  - [ ] Lock corresponding amount
  - [ ] Set unlock_time based on tier's duration
  - [ ] Return excess tokens to proposer
  - [ ] Emit `CommitmentExecuted` event

### Phase 4: Withdrawal Functions
- [ ] `withdraw_unlocked_tokens` entry function
  - [ ] Check caller is withdrawal_recipient
  - [ ] Check current time >= unlock_time
  - [ ] Transfer locked tokens to recipient
  - [ ] Emit `CommitmentWithdrawn` event
  
- [ ] `update_withdrawal_recipient` entry function
  - [ ] Check caller is current proposer
  - [ ] Update recipient address
  - [ ] Emit `RecipientUpdated` event

### Phase 5: Integration with Proposal System
- [ ] Add `CommitmentProposal` to proposal factory
- [ ] Update action dispatcher to handle commitment actions
- [ ] Ensure conditional markets work with commitment proposals
- [ ] Add TWAP reading from ACCEPT market

### Phase 6: Actions for Dispatcher
- [ ] Create `commitment_actions.move`
- [ ] Define `CreateCommitmentProposalAction`
- [ ] Define `ExecuteCommitmentAction`
- [ ] Define `UpdateRecipientAction`
- [ ] Add to action_dispatcher routing

### Phase 7: Events & Monitoring
- [ ] `CommitmentProposalCreated` event
- [ ] `CommitmentExecuted` event with tier reached
- [ ] `CommitmentWithdrawn` event
- [ ] `RecipientUpdated` event
- [ ] Add getter functions for UI

