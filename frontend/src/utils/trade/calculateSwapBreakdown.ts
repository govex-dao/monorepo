export const SWAP_FEE_BPS = 40; // 0.4% fee in basis points

/**
 * Parameters for calculating a swap
 */
interface SwapParams {
  reserveIn: number;   // Current reserve of the input token
  reserveOut: number;  // Current reserve of the output token
  amountIn: number;    // Amount of input token the user wants to swap
  feeBps?: number;     // Optional custom fee in basis points
  slippageTolerance?: number; // Optional slippage tolerance (default 0.5%)
}

/**
 * Detailed breakdown of a swap calculation
 */
export interface SwapBreakdown {
  exactAmountOut: number;  // Exact amount user will receive without slippage
  minAmountOut: number;    // Minimum amount user will receive with slippage tolerance
  ammFee: number;          // Fee amount collected by the AMM
  priceImpact: number;     // Price impact percentage caused by this swap
  averagePrice: number;    // Average execution price for the entire swap
  finalPrice: number;      // Final price after the swap is executed
  startPrice: number;      // Starting price before the swap
}

/**
 * Calculates detailed breakdown of a swap using constant product formula (x*y=k)
 * 
 * For asset-to-stable: 
 *   - Expected stable out = S*x/(A+x) where S=stableReserve, A=assetReserve, x=amountIn
 * 
 * For stable-to-asset:
 *   - Expected asset out = A*x/(S+x) where A=assetReserve, S=stableReserve, x=amountIn
 */
export function calculateSwapBreakdown(params: SwapParams): SwapBreakdown {
  const { reserveIn, reserveOut, amountIn, slippageTolerance = 0.005 } = params

  // Calculate fee and amount after fee is deducted
  const feeMultiplier = 1 - SWAP_FEE_BPS / 10_000;
  const amountInAfterFee = amountIn * feeMultiplier;

  // Apply constant product formula (x*y=k)
  const newReserveIn = reserveIn + amountInAfterFee;
  const newReserveOut = (reserveIn * reserveOut) / newReserveIn;

  // Calculate exact output amount
  const amountOut = reserveOut - newReserveOut;

  const averagePrice = amountIn / amountOut;
  const finalPrice = newReserveIn / newReserveOut;
  const startPrice = reserveIn / reserveOut;

  const priceImpact = ((finalPrice / startPrice) - 1) * 100;

  const ammFee = amountIn - amountInAfterFee;

  return {
    exactAmountOut: amountOut,
    minAmountOut: amountOut * (1 - slippageTolerance), // Apply slippage tolerance
    ammFee,
    priceImpact,
    averagePrice,
    finalPrice,
    startPrice,
  };
}