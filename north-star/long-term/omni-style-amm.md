1. Overhaul the Interest Rate Model (Eliminate Time-Based Divergence)
REMOVE: The taylor_exp approximation function entirely.
REMOVE: The existing calculate_rate logic that depends on time_elapsed (dt).
REPLACE WITH: A Cumulative Interest Index Model (Aave/Compound-style).
Add a liquidityIndex: u128 to the Pair state for each token.
Refactor update() to increment this index based on the current utilization rate and dt. The formula must be simple multiplication (new_index = old_index * (1 + rate * dt)), not an exponential approximation.
Refactor all debt calculations to be based on this index (current_debt = shares * currentIndex), making them path-independent and crankless.
2. Eliminate All Silent Saturation Bugs (Enforce "Revert on Error")
REMOVE: All instances of .unwrap_or(0), .unwrap_or(MAX), and .saturating_add() / .saturating_sub() in any critical financial calculation (interest, debt shares, fees, etc.).
REPLACE WITH: checked_* arithmetic that returns an Option or Result, followed by an .ok_or(ErrorCode::...)?.
PRINCIPLE: Every mathematical operation must either succeed perfectly or revert the entire transaction with a clear error. There can be no silent failures.
3. Break the Reflexive Price Feedback Loop (Eliminate "Phantom Liquidity")
REMOVE: The code that adds accrued interest directly to the AMM reserves (self.reserve0 += interest0 as u64). This is the single most dangerous line in the protocol.
Amm needs to know when price i largely jsut moving due ot amm and go into liquidiation only mode or whatever
4. integrate 3rd party orale have warnings when two differ by 5% when differ by 15% allow dev authority to come in and pause all but spot swapping? idk
5. Overhaul the Oracle Model (Replace Fragile EMA with Robust TWAP)
REMOVE: The compute_ema function and the last_price_ema and half_life fields in the Pair state.
REPLACE WITH: A Uniswap V2-style Cumulative TWAP Oracle.
Add price0_cumulative_last: u128 and block_timestamp_last: u64 to the Pair state.
In the update() function, add logic to update this cumulative price: price_cumulative += spot_price * dt.
Refactor all lending functions (get_max_debt, get_liquidation_price, etc.) to use a TWAP derived from this accumulator for collateral valuation, not an EMA.
The pessimistic_collateral_factor logic, which was a patch for the EMA's unreliability, should be re-evaluated and likely replaced with a simpler model that compares the TWAP to the spot price.
