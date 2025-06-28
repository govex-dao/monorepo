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
  amountIn: bigint, // User's input amount
  reserveIn: bigint, // Reserve of the token being GIVEN by user
  reserveOut: bigint, // Reserve of the token being RECEIVED by user
  isBuy: boolean, // True if buying asset (Stable -> Asset), False if selling asset (Asset -> Stable)
): SwapAmountsResult {
  if (amountIn === 0n) throw new Error("Zero amount not allowed"); // Matches contract

  let actualAmmFee_BI = 0n;
  let amountInForSwapCalc_BI = amountIn; // This is the amount used in the x*y=k formula for the "dx" part
  let amountOutBeforeOutputFee_BI: bigint;

  if (isBuy) {
    // Buying Asset (Stable -> Asset). Fee is on Stable INPUT.
    actualAmmFee_BI = calculateFee(amountIn); // Fee on stable input
    amountInForSwapCalc_BI = amountIn - actualAmmFee_BI;

    // Allow amountInForSwapCalc_BI to be 0 if amountIn === actualAmmFee_BI
    // This is critical for small trades matching the minimum fee.
    if (amountInForSwapCalc_BI < 0n) {
      // This should ideally not happen if amountIn > 0 and calculateFee is correct.
      // It implies fee was > input, e.g. amountIn = 0.5 (not possible for bigint unit) and fee = 1.
      throw new Error(ERRORS.INVALID_FEE); // Or set amountInForSwapCalc_BI = 0n and expect 0 output.
    }

    // Denominator for X*Y=K
    const denominator = reserveIn + amountInForSwapCalc_BI; // reserveIn is stableReserve
    if (denominator === 0n && amountInForSwapCalc_BI > 0n) {
      // reserveIn is 0, but input is positive
      amountOutBeforeOutputFee_BI = reserveOut; // Effectively, you'd take the whole output reserve, but this needs EPOOL_EMPTY check
    } else if (denominator === 0n) {
      // reserveIn is 0, input is 0
      amountOutBeforeOutputFee_BI = 0n;
    } else {
      amountOutBeforeOutputFee_BI = mulDivFloor(
        amountInForSwapCalc_BI,
        reserveOut, // assetReserve
        denominator,
      );
    }
    // For buys, amountOutBeforeOutputFee_BI is the final exactAmountOut_BI (asset)
    // No further fees on output for buys.
  } else {
    // Selling Asset (Asset -> Stable). Fee is on Stable OUTPUT.
    // amountInForSwapCalc_BI remains `amountIn` (asset amount)
    // actualAmmFee_BI will be calculated on the output.

    const denominator = reserveIn + amountInForSwapCalc_BI; // reserveIn is assetReserve
    if (denominator === 0n && amountInForSwapCalc_BI > 0n) {
      amountOutBeforeOutputFee_BI = reserveOut;
    } else if (denominator === 0n) {
      amountOutBeforeOutputFee_BI = 0n;
    } else {
      amountOutBeforeOutputFee_BI = mulDivFloor(
        amountInForSwapCalc_BI, // asset_in
        reserveOut, // stableReserve
        denominator,
      );
    }
    // Now, calculate fee on this stable output
    actualAmmFee_BI = calculateFee(amountOutBeforeOutputFee_BI);
    // exactAmountOut will be amountOutBeforeOutputFee_BI - actualAmmFee_BI
  }

  // --- Post-Gross Output Calculation ---

  // Contract EPOOL_EMPTY check equivalent:
  // Output (before output fees, if any) must be less than the output reserve.
  if (amountOutBeforeOutputFee_BI >= reserveOut) {
    throw new Error(ERRORS.INSUFFICIENT_RESERVES);
  }

  let exactAmountOut_BI: bigint;
  if (isBuy) {
    exactAmountOut_BI = amountOutBeforeOutputFee_BI; // No output fee for buys
  } else {
    // Selling Asset (Asset -> Stable)
    exactAmountOut_BI = amountOutBeforeOutputFee_BI - actualAmmFee_BI;
    if (exactAmountOut_BI < 0n) {
      // Fee was greater than calculated output. Result is 0.
      // This can happen if amountOutBeforeOutputFee_BI is small (e.g., 1) and fee is 1.
      exactAmountOut_BI = 0n; // Contract would produce 0 in this case (0-1 underflows u64, but conceptually it's 0 out)
    }
  }

  // --- Reserve Updates (Mirroring Contract Logic) ---
  // newReserveIn = old_reserve_of_input_token + (amount_of_input_token_added_to_pool)
  // newReserveOut = old_reserve_of_output_token - (amount_of_output_token_removed_from_pool_before_output_fees)
  const newReserveIn_BI = reserveIn + amountInForSwapCalc_BI;

  // For sells (!isBuy), contract deducts `amount_out_before_fee`
  // For buys (isBuy), contract deducts `amount_out` (which is asset_out)
  const amountDeductedFromOutputReserve = isBuy
    ? exactAmountOut_BI
    : amountOutBeforeOutputFee_BI;
  const newReserveOut_BI = reserveOut - amountDeductedFromOutputReserve;

  // Final check on reserves (should be caught by the EPOOL_EMPTY earlier, but good safeguard)
  // Contract ensures new reserves are > 0 implicitly.
  if (
    newReserveOut_BI <= 0n &&
    !(newReserveOut_BI === 0n && amountDeductedFromOutputReserve === reserveOut)
  ) {
    // This means we tried to take more than available, or exactly drained it but something is off.
    // The contract's `X < Y_reserve` effectively means new_Y_reserve must be > 0.
    // So if newReserveOut_BI is 0 or less, it's an issue unless it was a perfect drain.
    // A simpler `if (newReserveOut_BI <= 0n)` to match the contract strictness that `new_reserve > 0` is needed.
    // The condition amountOutBeforeOutputFee_BI >= reserveOut should have caught this.
    // If newReserveOut_BI === 0n, it means the pool was perfectly drained of that token, which is allowed if the output was exactly reserveOut.
    // But the contract's check `amount_out < pool.asset_reserve` means `new_reserve > 0`. So `newReserveOut_BI <= 0n` is the right proxy.
    throw new Error(ERRORS.INSUFFICIENT_RESERVES);
  }

  return {
    ammFee_BI: actualAmmFee_BI,
    amountInAfterFee_BI: amountInForSwapCalc_BI, // This is the amount that effectively went into reserves or was basis for swap.
    exactAmountOut_BI: exactAmountOut_BI,
    newReserveIn_BI: newReserveIn_BI,
    newReserveOut_BI: newReserveOut_BI,
  };
}
