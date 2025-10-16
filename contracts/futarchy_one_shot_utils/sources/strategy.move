module futarchy_one_shot_utils::strategy;

// === Constants for Strategy Types ===
const STRATEGY_AND: u8 = 0;
const STRATEGY_OR: u8 = 1;
const STRATEGY_EITHER: u8 = 2; // XOR
const STRATEGY_THRESHOLD: u8 = 3;

/// Strategy for combining multiple approval conditions
/// Uses constants instead of magic numbers for clarity
public struct Strategy has copy, drop, store {
    kind: u8,
    m: u64, // For threshold: minimum approvals required
    n: u64, // For threshold: total number of conditions
}

public fun and(): Strategy {
    Strategy { kind: STRATEGY_AND, m: 0, n: 0 }
}

public fun or(): Strategy {
    Strategy { kind: STRATEGY_OR, m: 0, n: 0 }
}

public fun either(): Strategy {
    Strategy { kind: STRATEGY_EITHER, m: 0, n: 0 }
}

public fun threshold(m: u64, n: u64): Strategy {
    Strategy { kind: STRATEGY_THRESHOLD, m, n }
}

/// Combine boolean gates. Extend by adding more sources as needed.
public fun can_execute(ok_a: bool, ok_b: bool, s: Strategy): bool {
    if (s.kind == STRATEGY_AND) {
        // Both conditions must be true
        ok_a && ok_b
    } else if (s.kind == STRATEGY_OR) {
        // At least one condition must be true
        ok_a || ok_b
    } else if (s.kind == STRATEGY_EITHER) {
        // Exactly one condition must be true (XOR)
        (ok_a && !ok_b) || (!ok_a && ok_b)
    } else if (s.kind == STRATEGY_THRESHOLD) {
        // M-of-N threshold over 2 booleans
        let satisfied_count = (if (ok_a) 1 else 0) + (if (ok_b) 1 else 0);
        satisfied_count >= s.m && s.n >= s.m
    } else {
        // Unknown strategy type - fail safe by requiring all conditions
        false
    }
}
