import { mulDivFloor } from "../bigints";
import { calculateFee } from "./fee";
import { SwapAmountsResult } from "./types";

// Error messages
const ERRORS = {
  INSUFFICIENT_RESERVES: "Insufficient reserves for swap",
  INVALID_FEE: "Calculated fee exceeds input amount",
};

/**
 * Calculates the amounts for a swap between tokens in an AMM pool.
 *
 * Fee handling differs based on swap direction:
 * - Stable to Asset (buying asset): Fee is deducted from input amount BEFORE the swap calculation
 * - Asset to Stable (selling asset): Fee is deducted from output amount AFTER the swap calculation
 *
 * @param amountIn The input amount in BigInt
 * @param reserveIn The input reserve in BigInt
 * @param reserveOut The output reserve in BigInt
 * @param isBuy Whether the swap is buying asset (true) or selling asset (false)
 * @returns Detailed breakdown of swap amounts including fees and new reserves
 * @throws Error if input validation fails or swap calculation is invalid
 */
export function calculateSwapAmounts(
  amountIn: bigint,
  reserveIn: bigint,
  reserveOut: bigint,
  isBuy: boolean,
): SwapAmountsResult {
  let ammFee = 0n;
  let amountInAfterFee = amountIn;

  // if is buy, calculate fee before swap
  if (isBuy) {
    ammFee = calculateFee(amountIn);
    if (ammFee >= amountIn) throw new Error(ERRORS.INVALID_FEE);
    amountInAfterFee = amountIn - ammFee;
  }

  // Calculate output amount using AMM formula: dx * y / (x + dx)
  const denominator = reserveIn + amountInAfterFee;
  let amountOutBeforeFee = mulDivFloor(
    amountInAfterFee,
    reserveOut,
    denominator,
  );

  // Cap output if it exceeds reserves
  if (amountOutBeforeFee > reserveOut) {
    console.warn("Calculated output exceeds reserves, capping.");
    amountOutBeforeFee = reserveOut;
  }

  let exactAmountOut = amountOutBeforeFee;
  // if is sell, calculate fee after swap
  if (!isBuy) {
    ammFee = calculateFee(amountOutBeforeFee);
    if (ammFee >= amountOutBeforeFee) throw new Error(ERRORS.INVALID_FEE);
    exactAmountOut = amountOutBeforeFee - ammFee;
  }

  // Calculate new reserves
  const newReserveIn = reserveIn + amountInAfterFee;
  const newReserveOut = reserveOut - exactAmountOut;

  if (newReserveOut <= 0n) throw new Error(ERRORS.INSUFFICIENT_RESERVES);

  return {
    ammFee_BI: ammFee,
    amountInAfterFee_BI: amountInAfterFee,
    exactAmountOut_BI: exactAmountOut,
    newReserveIn_BI: newReserveIn,
    newReserveOut_BI: newReserveOut,
  };
}
