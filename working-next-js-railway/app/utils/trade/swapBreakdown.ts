import { fromScaledBigInt, mulDivFloor, toScaledBigInt } from "../bigints";
import { calculatePriceMetrics } from "./priceMetrics";
import { calculateSwapAmounts } from "./swapAmounts";
import { SwapParams, SwapBreakdown } from "./types";

// Constants
export const SWAP_FEE_BPS = 30; // 0.3% fee in basis points
export const SWAP_FEE_BPS_BI = 30n; // 0.3% fee in basis points as BigInt
export const DEFAULT_SLIPPAGE_BPS = 200;
const MAX_BPS = 10000;

// Error messages
const ERRORS = {
  INVALID_AMOUNT: "Input amount must be greater than zero",
  INVALID_POOL_STATE: "Invalid pool state: reserves must be greater than zero",
  INVALID_SLIPPAGE: "Invalid slippage tolerance BPS (must be 0 <= bps < 10000)",
  NEGATIVE_SLIPPAGE_FACTOR: "Negative slippage factor calculated",
  DIVISION_BY_ZERO: "Division by zero in swap calculation",
};

/**
 * Calculates detailed breakdown of a swap using constant product formula (x*y=k)
 *
 * For asset-to-stable (selling asset):
 *   - Fee is taken from the output amount (stable)
 *   - Expected stable out = S*x/(A+x) where S=stableReserve, A=assetReserve, x=amountIn
 *
 * For stable-to-asset (buying asset):
 *   - Fee is taken from the input amount (stable)
 *   - Expected asset out = A*x/(S+x) where A=assetReserve, S=stableReserve, x=amountIn
 *
 * @param params The parameters for the swap calculation
 * @returns A detailed breakdown of the swap including amounts, fees, and price impact
 * @throws Error if the pool state is invalid or slippage tolerance is out of range
 */
export function calculateSwapBreakdown(params: SwapParams): SwapBreakdown {
  const {
    reserveIn,
    reserveOut,
    amountIn,
    isBuy,
    slippageBps = DEFAULT_SLIPPAGE_BPS,
  } = params;

  // Input validation - match Move's behavior (reject zero amounts)
  if (amountIn <= 0) throw new Error(ERRORS.INVALID_AMOUNT);
  if (reserveIn <= 0 || reserveOut <= 0)
    throw new Error(ERRORS.INVALID_POOL_STATE);
  if (slippageBps < 0 || slippageBps >= MAX_BPS)
    throw new Error(ERRORS.INVALID_SLIPPAGE);

  // Convert inputs to BigInt
  const [reserveIn_BI, reserveOut_BI, amountIn_BI] = [
    toScaledBigInt(reserveIn),
    toScaledBigInt(reserveOut),
    toScaledBigInt(amountIn),
  ];

  // Calculate swap amounts
  const swapAmounts = calculateSwapAmounts(
    amountIn_BI,
    reserveIn_BI,
    reserveOut_BI,
    isBuy,
  );
  const {
    ammFee_BI,
    exactAmountOut_BI,
    newReserveIn_BI,
    newReserveOut_BI,
    amountInAfterFee_BI,
  } = swapAmounts;

  // Calculate amount out before fee for price metrics (matching Move's behavior)
  const amountOutBeforeFee_BI = isBuy
    ? exactAmountOut_BI // For buys, fee is on input so output is already "before fee"
    : exactAmountOut_BI + ammFee_BI; // For sells, add back the fee to get before-fee amount

  // Calculate slippage-adjusted minimum output
  const slippageBps_BI = BigInt(slippageBps);
  const slippageFactor_BI = BigInt(MAX_BPS) - slippageBps_BI;
  if (slippageFactor_BI < 0n) throw new Error(ERRORS.NEGATIVE_SLIPPAGE_FACTOR);
  const minAmountOut_BI = mulDivFloor(
    exactAmountOut_BI,
    slippageFactor_BI,
    BigInt(MAX_BPS),
  );

  // Calculate price metrics in stable
  // For sells: use amountOutBeforeFee to match Move's price_impact calculation
  const priceMetrics = calculatePriceMetrics(
    isBuy ? amountInAfterFee_BI : amountOutBeforeFee_BI, // stable amount
    isBuy ? exactAmountOut_BI : amountIn_BI, // asset amount
    isBuy ? reserveOut_BI : reserveIn_BI, // assetReserve
    isBuy ? reserveIn_BI : reserveOut_BI, // stableReserve
    isBuy ? newReserveOut_BI : newReserveIn_BI, // newAssetReserve
    isBuy ? newReserveIn_BI : newReserveOut_BI, // newStableReserve
  );

  // Calculate and return final result
  return {
    exactAmountOut: fromScaledBigInt(exactAmountOut_BI),
    minAmountOut: fromScaledBigInt(minAmountOut_BI),
    ammFee: fromScaledBigInt(ammFee_BI),
    newReserveIn: fromScaledBigInt(newReserveIn_BI),
    newReserveOut: fromScaledBigInt(newReserveOut_BI),
    ...priceMetrics,
  };
}
