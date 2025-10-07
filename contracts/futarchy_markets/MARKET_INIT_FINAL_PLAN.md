# Market Init - Final Plan

## What We Built ✅

**635 lines - Atomic market initialization strategies**

1. **Conditional Raise** - Mint DAO tokens → Sell in YES market → Raise stable
2. **Conditional Buyback** - Withdraw stable → Buy tokens in outcome markets
3. **PTB atomic execution** - Front-run proof, quantum liquidity aware

## The Simple Rule

**Market init works when:**
```move
review_period_ms == 0  // Instant atomic execution
OR
!enable_premarket_reservation_lock  // DAO disabled lock
```

## New DAO Config

```move
public struct GovernanceConfig {
    // ... existing fields ...
    enable_premarket_reservation_lock: bool,  // Default: true
}
```

**If `true` (default):**
- ✅ Anti-MEV protection (proposals lock queue slot)
- ❌ Market init blocked when slot reserved
- ✅ Use review_period_ms = 0 for market init

**If `false`:**
- ✅ No reservation lock → queue always free
- ✅ Market init works anytime
- ❌ Less MEV protection (no lock-in guarantee)

## Trade-offs

**Security DAOs (lock = true):**
- High MEV protection
- Market init only with review = 0 (atomic)
- Or set high queue fees to keep slot free

**Speed DAOs (lock = false):**
- Market init works anytime (with or without premarket)
- Less MEV protection
- Simpler UX

## Implementation TODO

1. Add `enable_premarket_reservation_lock: bool` to GovernanceConfig ✅
2. Add getter/setter for the config
3. Update queue logic to check config before `set_reserved()`
4. Update default config (recommend `true` for safety)
5. Document in proposal creation

**That's it. Clean, simple, ships.**
