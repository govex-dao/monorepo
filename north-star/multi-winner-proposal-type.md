# Multi-Winner Proposal Type

## Concept
Allow k-of-n selection where multiple outcomes can win simultaneously.

## Implementation
- Each outcome gets its own include/exclude conditional market
- Markets predict utility impact of INCLUDING that specific action
- At finalization, select top-k by TWAP using heap-based O(n log k) selection
- Actions can be heterogeneous (grants, memos, parameter changes, etc.)

## Two Selection Modes
1. **Top-K Mode**: Select exactly k highest-scoring outcomes
2. **Threshold Mode**: Select all where accept_TWAP > reject_TWAP (with optional max cap)

## Why Not Building This Now
The economics around marginal incentives to correctly price duplicates or conflicting outcomes is too complex:
- Markets can't efficiently price when two outcomes are identical
- Conflicting outcomes might both price high, violating probability constraints  
- Strategic gaming via outcome splitting or duplication
- Cognitive overhead for traders understanding n-way interactions

## Future Research
- Could work with fixed "action pools" that have clear selection rules
- Markets need to know selection mechanism upfront
- Requires solving correlation and duplicate detection problems first

Currently focusing on perfecting binary accept/reject futarchy before tackling multi-winner complexity.