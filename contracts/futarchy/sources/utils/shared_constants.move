module futarchy::shared_constants;

const AMM_BASIS_POINTS: u64 = 1_000_000_000_000; // 10^12 we need to keep this for saftey to values don't round to 0

public fun amm_basis_points(): u64 { AMM_BASIS_POINTS }
