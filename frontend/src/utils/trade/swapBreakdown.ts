import { fromScaledBigInt, mulDivFloor, toScaledBigInt } from "../bigints";
import { calculatePriceMetrics, PRICE_SCALE, PRICE_SCALE_BI } from "./priceMetrics";
import { calculateSwapAmounts } from "./swapAmounts";
import { SwapParams, SwapBreakdown } from "./types";

// Constants
export const SWAP_FEE_BPS = 30; // 0.3% fee in basis points
const MAX_BPS = 10000;

// Error messages
const ERRORS = {
  INVALID_AMOUNT: "Input amount must be greater than zero",
  INVALID_POOL_STATE: "Invalid pool state: reserves must be greater than zero",
  INVALID_SLIPPAGE: "Invalid slippage tolerance BPS (must be 0 <= bps < 10000)",
  NEGATIVE_SLIPPAGE_FACTOR: "Negative slippage factor calculated",
  DIVISION_BY_ZERO: "Division by zero in swap calculation",
}

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
  const { reserveIn, reserveOut, amountIn, isBuy, slippageBps } = params;
  const slippageBps_BI = BigInt(slippageBps);

  // Input validation
  if (amountIn < 0) throw new Error(ERRORS.INVALID_AMOUNT);
  if (reserveIn <= 0 || reserveOut <= 0) throw new Error(ERRORS.INVALID_POOL_STATE);
  if (slippageBps_BI < 0n || slippageBps_BI >= BigInt(MAX_BPS)) throw new Error(ERRORS.INVALID_SLIPPAGE);
  
  // Convert inputs to BigInt
  const [reserveIn_BI, reserveOut_BI, amountIn_BI] = [
    toScaledBigInt(reserveIn),
    toScaledBigInt(reserveOut),
    toScaledBigInt(amountIn),
  ];

  if (amountIn === 0) {
    const price = reserveIn_BI > 0n
      ? Number(mulDivFloor(reserveOut_BI, PRICE_SCALE_BI, reserveIn_BI)) / PRICE_SCALE
      : 0;
    return {
      exactAmountOut: 0,
      minAmountOut: 0,
      ammFee: 0,
      priceImpact: 0,
      averagePrice: price,
      finalPrice: price,
      startPrice: price,
      newReserveIn: reserveIn,
      newReserveOut: reserveOut,
    };
  }

  // Calculate swap amounts and price metrics
  const swapAmounts = calculateSwapAmounts(amountIn_BI, reserveIn_BI, reserveOut_BI, isBuy);
  const { ammFee_BI, exactAmountOut_BI, newReserveIn_BI, newReserveOut_BI } = swapAmounts;

  // Calculate slippage-adjusted minimum output
  const slippageFactor_BI = BigInt(MAX_BPS) - slippageBps_BI;
  if (slippageFactor_BI < 0n) throw new Error(ERRORS.NEGATIVE_SLIPPAGE_FACTOR);
  const minAmountOut_BI = mulDivFloor(exactAmountOut_BI, slippageFactor_BI, BigInt(MAX_BPS));

  // Calculate price metrics in stable
  const priceMetrics = calculatePriceMetrics(
    isBuy ? amountIn_BI: exactAmountOut_BI,
    isBuy ? exactAmountOut_BI: amountIn_BI,
    isBuy ? reserveOut_BI : reserveIn_BI,  // assetReserve
    isBuy ? reserveIn_BI : reserveOut_BI,  // stableReserve
    isBuy ? newReserveOut_BI : newReserveIn_BI,  // newAssetReserve
    isBuy ? newReserveIn_BI : newReserveOut_BI,  // newStableReserve
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
