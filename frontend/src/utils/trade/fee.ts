import { mulDivFloor } from "../bigints";

const SWAP_FEE_BPS_BI = 30n; // 0.3%

/**
 * Calculates the fee based on Move contract logic.
 *
 * This follows the AMM swap implementation in the futarchy::swap module:
 * - A minimum fee of 1 is applied when calculated fee would be 0
 *
 * The minimum fee prevents free trading, ensures protocol revenue,
 * deters spam transactions, and matches the Move contract implementation.
 *
 * Formula: amount * feeBps / feeScale
 * @param amount The amount to calculate fee for
 * @param feeBps The fee in basis points (defaults to 30 for 0.3%)
 * @returns The calculated fee amount
 */
export function calculateFee(
  amount: bigint,
  feeBps: bigint = SWAP_FEE_BPS_BI,
): bigint {
  if (amount <= 0n) return 1n;
  const calculatedFee = mulDivFloor(amount, feeBps, 10000n);
  return calculatedFee === 0n ? 1n : calculatedFee;
}
