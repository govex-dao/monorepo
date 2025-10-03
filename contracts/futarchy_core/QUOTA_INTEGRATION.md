# Quota System Integration Guide

## Overview

The quota system allows DAOs to grant recurring proposal quotas (N proposals per X time period at reduced fee Y) to allowlisted addresses.

## Architecture

### Core Components

1. **ProposalQuotaRegistry** (`futarchy_core/sources/proposal_quota_registry.move`)
   - DAO-bound registry tracking quotas per address
   - Period alignment prevents time drift
   - Check-then-commit pattern prevents quota loss on failed proposals

2. **QuotaConfig** (`futarchy_core/sources/dao_config.move`)
   - Part of DaoConfig structure
   - Configurable default parameters

3. **SetQuotasAction** (`futarchy_actions/sources/config/quota_actions.move`)
   - Batch set/update/remove quotas
   - Setting `quota_amount = 0` removes quotas

4. **Quota Intents** (`futarchy_actions/sources/config/quota_intents.move`)
   - `create_set_quotas_intent()` - Main function
   - `create_grant_quotas_intent()` - Convenience wrapper
   - `create_remove_quotas_intent()` - Removes quotas (sets amount to 0)

5. **Quota Decoder** (`futarchy_actions/sources/config/quota_decoder.move`)
   - BCS deserialization for UI/SDK
   - Returns human-readable fields

## Integration Pattern

### Step 1: Calculate Fee with Quota Check

When a user submits a proposal, check if they have an available quota:

```move
use futarchy_core::proposal_fee_manager;
use futarchy_core::proposal_quota_registry::ProposalQuotaRegistry;

// In your proposal submission function:
public entry fun submit_proposal<StableCoin>(
    account: &Account<FutarchyConfig>,
    queue: &mut ProposalQueue<StableCoin>,
    fee_manager: &mut ProposalFeeManager,
    quota_registry: &ProposalQuotaRegistry,  // Add this parameter
    mut fee_payment: Coin<SUI>,
    // ... other parameters
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let proposer = ctx.sender();
    let base_fee = calculate_base_fee(...);  // Your existing fee calculation

    // Calculate actual fee considering quotas
    let (actual_fee, used_quota) = proposal_fee_manager::calculate_fee_with_quota(
        quota_registry,
        proposer,
        base_fee,
        clock
    );

    // Validate fee payment
    assert!(fee_payment.value() >= actual_fee, EInsufficientFee);

    // Split payment if overpaid
    let fee_coin = if (fee_payment.value() > actual_fee) {
        fee_payment.split(actual_fee, ctx)
    } else {
        fee_payment
    };

    // Create proposal (existing logic)
    // ...

    // AFTER successful proposal creation, commit quota usage
    if (used_quota) {
        proposal_fee_manager::use_quota_for_proposal(
            quota_registry,
            proposer,
            clock
        );
    };
}
```

### Step 2: ProposalQuotaRegistry Creation

The registry must be created during DAO initialization:

```move
use futarchy_core::proposal_quota_registry;

// In your DAO factory/initialization:
public fun create_dao(...) {
    let dao_id = object::id(&account);

    // Create quota registry bound to this DAO
    let quota_registry = proposal_quota_registry::new(dao_id, ctx);

    // Share it publicly
    transfer::public_share_object(quota_registry);
}
```

### Step 3: Managing Quotas via Governance

DAOs can manage quotas through governance proposals:

```move
use futarchy_actions::quota_intents;

// Grant quotas to core contributors (1 proposal per month, free)
public fun grant_contributor_quotas(
    account: &mut Account<FutarchyConfig>,
    registry: &ActionDecoderRegistry,
    params: Params,
    outcome: FutarchyOutcome,
    ctx: &mut TxContext
) {
    let contributors = vector[@0xabc, @0xdef, @0x123];

    quota_intents::create_grant_quotas_intent(
        account,
        registry,
        params,
        outcome,
        contributors,
        1,                    // 1 proposal
        2_592_000_000,        // per 30 days
        0,                    // free
        ctx
    );
}

// Remove quotas
public fun revoke_quotas(
    account: &mut Account<FutarchyConfig>,
    registry: &ActionDecoderRegistry,
    params: Params,
    outcome: FutarchyOutcome,
    ctx: &mut TxContext
) {
    let users = vector[@0xabc];

    quota_intents::create_remove_quotas_intent(
        account,
        registry,
        params,
        outcome,
        users,
        ctx
    );
}
```

## Security Considerations

### DAO Binding
The `ProposalQuotaRegistry` includes a `dao_id` field that is validated on every operation:

```move
assert!(registry.dao_id == dao_id, EWrongDao);
```

This prevents cross-DAO quota manipulation attacks.

### Check-Then-Commit Pattern
Quota availability is checked BEFORE proposal creation, but usage is only committed AFTER success:

```move
// 1. Check (read-only)
let (has_quota, fee) = check_quota_available(...);

// 2. Create proposal (might fail)
create_proposal(...);

// 3. Commit (only if proposal succeeded)
if (has_quota) {
    use_quota(...);
}
```

This prevents quota loss when proposal creation fails.

### Period Alignment
Time periods align to boundaries instead of resetting to current time:

```move
let periods_elapsed = (now - period_start_ms) / quota_period_ms;
if (periods_elapsed > 0) {
    period_start_ms = period_start_ms + (periods_elapsed * quota_period_ms);
    used_in_period = 0;
}
```

This prevents time drift and ensures fair quota allocation.

## Testing Checklist

- [ ] Verify quota registry is created during DAO init
- [ ] Test quota check reduces fees correctly
- [ ] Test quota usage is only committed on success
- [ ] Test period rollover at boundaries
- [ ] Test batch quota operations
- [ ] Test quota removal (amount = 0)
- [ ] Test cross-DAO protection (wrong dao_id should fail)
- [x] Test decoder registration (registered in config_decoder.move)
- [ ] Verify UI can decode quota actions

## Implementation Status

### ✅ Completed
- ProposalQuotaRegistry with DAO binding
- QuotaConfig in DaoConfig
- SetQuotasAction (batch operations)
- Quota intents (create/grant/remove)
- SetQuotas type registration in action_types
- Quota decoder with BCS validation
- Integration helpers in proposal_fee_manager:
  - `calculate_fee_with_quota()`
  - `use_quota_for_proposal()`
- Decoder registration (via config_decoder)
- Builds successfully (futarchy_core)

### ⏳ Pending
- Quota registry creation in DAO factory
- Actual proposal submission integration (skeleton added)
- End-to-end testing

### 📝 Integration Code Location
- Helper functions: `futarchy_core/sources/proposal_fee_manager.move:369-402`
- Example integration: `futarchy_lifecycle/sources/proposal/proposal_submission.move:218-243`
- Decoder registration: `futarchy_actions/sources/config/config_decoder.move:583`

## Example Usage Flow

1. **DAO Creation**: Factory creates `ProposalQuotaRegistry` bound to DAO
2. **Governance Vote**: DAO votes to grant quotas to core team (1/month, free)
3. **Proposal Execution**: `do_set_quotas()` updates registry with allowlist
4. **User Submits**: Alice (on allowlist) submits proposal
5. **Fee Calculation**: System checks quota → finds she has 1/month free → fee = 0
6. **Proposal Created**: Proposal created successfully
7. **Quota Committed**: Alice's quota usage incremented (1 used this period)
8. **Period Rolls**: 30 days later, Alice's quota resets (0 used, can propose again)

## Migration Notes

If adding to existing DAOs, they will need to:
1. Create `ProposalQuotaRegistry` via governance proposal
2. Update proposal submission entry points to accept registry parameter
3. Register quota decoder for UI support
