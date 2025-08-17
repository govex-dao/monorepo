# Claude AI Context File - Futarchy Protocol

## Architecture Overview

This is a **Hanson-style futarchy implementation** with quantum liquidity splitting.

### Critical Design Decisions

1. **Quantum Liquidity Model**
   - 1 spot token splits into 1 conditional token for EACH outcome
   - NOT proportional - it's quantum (exists in all states simultaneously)
   - Only highest-priced conditional market wins and becomes redeemable

2. **Write-Through Oracle Pattern**
   - `get_twap()` REQUIRES `update_oracle()` in same transaction
   - This is intentional - prevents stale price attacks
   - See detailed explanation in `/contracts/futarchy/sources/markets/oracle.move` line 438

3. **Empty Spot During Proposals**
   - When DAO liquidity is used, spot AMM is COMPLETELY EMPTY
   - All liquidity exists in conditional AMMs
   - Spot TWAP must read from live conditional markets

## Testing Commands

```bash
sui move test --silence-warnings
sui move build --silence-warnings
```

## Common Pitfalls

- Don't assume standard oracle patterns work here
- Liquidity accounting is quantum, not classical
- TWAP must handle empty spot pools during proposals
- Price manipulation requires attacking ALL conditional markets

## Contact

For questions about the architecture, focus on the quantum liquidity model and Hanson-style futarchy design.