# CRITICAL: FUTARCHY ARCHITECTURE - MUST READ

## This is Hanson-Style Futarchy with Quantum Liquidity

### Core Mechanism (THIS IS NOT OPTIONAL KNOWLEDGE)

**Liquidity Splitting:**
- 1 spot dollar → splits into 1 conditional dollar for EACH outcome
- This is NOT proportional division - it's quantum splitting
- Example: $100 in spot → $100 in YES market + $100 in NO market

**Price Discovery:**
- Only the HIGHEST priced conditional market determines the winning outcome
- Winner's conditional tokens are redeemable 1:1 for spot tokens
- Loser's conditional tokens become worthless

**During Proposals:**
- Spot AMM is COMPLETELY EMPTY (liquidity moved to conditionals)
- All liquidity exists simultaneously in ALL conditional markets
- Price discovery happens across multiple conditional AMMs in parallel

### Why This Matters

1. **TWAP Calculation**: Must check ALL live conditional AMMs and use highest
2. **Liquidity Accounting**: Same liquidity exists in multiple places simultaneously
3. **Oracle Design**: Can't use standard patterns - liquidity is quantum
4. **Security**: Manipulation requires attacking ALL conditional markets

### Common Misconceptions to Avoid

❌ "Liquidity is split proportionally between outcomes"
✅ Liquidity exists fully in ALL outcomes simultaneously

❌ "We can use a standard oracle pattern"
✅ Oracle must be aware of quantum liquidity and conditional markets

❌ "Spot price exists during proposals"
✅ Spot is empty during proposals - price only exists in conditionals

## Implementation Notes

- The "write-through" oracle pattern is REQUIRED because of this architecture
- TWAP must aggregate from multiple simultaneous conditional markets
- Historical price stitching is necessary when liquidity returns to spot

## References

- Robin Hanson's original futarchy papers
- Conditional token implementation: `/contracts/futarchy/sources/markets/conditional_token.move`
- AMM implementation: `/contracts/futarchy/sources/markets/conditional_amm.move`