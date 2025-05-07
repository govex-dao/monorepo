/**
 * Parameters for calculating a swap
 */
export interface SwapParams {
  /** Current reserve of the input token */
  reserveIn: number;
  /** Current reserve of the output token */
  reserveOut: number;
  /** Amount of input token the user wants to swap */
  amountIn: number;
  /** True if swapping Stable FOR Asset (Buying Asset) */
  isBuy: boolean;
  /** Optional slippage tolerance (default 0.5%) */
  slippageBps?: number;
}

/**
 * Detailed breakdown of a swap calculation
 */
export interface SwapBreakdown {
  /** Exact amount user will receive without slippage */
  exactAmountOut: number;
  /** Minimum amount user will receive with slippage tolerance */
  minAmountOut: number;
  /** Fee amount collected by the AMM */
  ammFee: number;
  /** Price impact percentage caused by this swap */
  priceImpact: number;
  /** Average execution price for the entire swap */
  averagePrice: number;
  /** Final price after the swap is executed */
  finalPrice: number;
  /** Starting price before the swap */
  startPrice: number;
  /** New reserve of the input token after the swap */
  newReserveIn: number;
  /** New reserve of the output token after the swap */
  newReserveOut: number;
}

/**
 * Price-related metrics for a swap or price calculation
 */
export interface PriceMetrics {
  /** Average execution price for the entire swap */
  averagePrice: number;
  /** Final price after the swap is executed */
  finalPrice: number;
  /** Starting price before the swap */
  startPrice: number;
  /** Price impact percentage caused by this swap */
  priceImpact: number;
}

/**
 * Parameters for calculating swap amounts
 */
export interface SwapAmountsParams {
  /** The input amount in BigInt */
  amountIn_BI: bigint;
  /** The input reserve in BigInt */
  reserveIn_BI: bigint;
  /** The output reserve in BigInt */
  reserveOut_BI: bigint;
  /** Whether the swap is from stable to asset */
  isStableToAsset: boolean;
} 

/**
 * Result of swap amount calculations
 */
export interface SwapAmountsResult {
  /** Fee amount collected by the AMM in BigInt */
  ammFee_BI: bigint;
  /** Input amount after fee deduction in BigInt */
  amountInAfterFee_BI: bigint;
  /** Exact output amount in BigInt */
  exactAmountOut_BI: bigint;
  /** New input reserve after swap in BigInt */
  newReserveIn_BI: bigint;
  /** New output reserve after swap in BigInt */
  newReserveOut_BI: bigint;
}
