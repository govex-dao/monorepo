export const SWAP_FEE_BPS = 30; // 0.3% fee in basis points

// Add a parameter to indicate direction, e.g., isStableToAsset
interface SwapParams {
  reserveIn: number; // Current reserve of the input token (e.g., Stable if buying Asset)
  reserveOut: number; // Current reserve of the output token (e.g., Asset if buying Asset)
  amountIn: number; // Amount of input token the user wants to swap
  slippageTolerance?: number; // Optional slippage tolerance (default 0.5%)
  isStableToAsset: boolean; // **** ADD THIS **** True if swapping Stable FOR Asset (Buying Asset)
}

export interface SwapBreakdown {
  exactAmountOut: number; // Exact amount user will receive without slippage
  minAmountOut: number; // Minimum amount user will receive with slippage tolerance
  ammFee: number; // Fee amount collected by the AMM (in stable equivalent for consistency?) - Or just the raw fee amount? Let's stick to raw fee for now.
  priceImpact: number; // Price impact percentage caused by this swap
  averagePrice: number; // Average execution price for the entire swap (Input / Output)
  finalPrice: number; // Final marginal price after the swap is executed (New Reserve In / New Reserve Out)
  startPrice: number; // Starting marginal price before the swap (Reserve In / Reserve Out)
}

export function calculateSwapBreakdown(params: SwapParams): SwapBreakdown {
  const { reserveIn, reserveOut, amountIn, slippageTolerance = 0.05, isStableToAsset } = params;

  if (reserveIn <= 0 || reserveOut <= 0) {
    // Allow calculation even if reserves are low, but maybe return zero amounts?
    // Or keep the error, depends on desired UX. Let's keep the error for now.
     throw new Error("Invalid pool state: reserves must be greater than zero");
  }
  if (amountIn <= 0) {
     // Handle zero or negative input gracefully
     return {
        exactAmountOut: 0,
        minAmountOut: 0,
        ammFee: 0,
        priceImpact: 0,
        averagePrice: reserveIn / reserveOut, // Or startPrice
        finalPrice: reserveIn / reserveOut,   // Or startPrice
        startPrice: reserveIn / reserveOut,
     };
  }

  const feeRate = SWAP_FEE_BPS / 10_000;
  let amountOut: number;
  let ammFee: number;
  let newReserveIn: number;
  let newReserveOut: number;
  let amountInUsedForPoolUpdate: number;
  let amountOutUsedForPoolUpdate: number;

  if (isStableToAsset) { // Backend: swap_stable_to_asset (Fee from Stable Input)
    ammFee = amountIn * feeRate;
    // Handle potential minimal fee if needed, JS floats make this tricky.
    // Let's assume standard float math for now.
    amountInUsedForPoolUpdate = amountIn - ammFee;

    // Calculate output based on amount after fee
    const numerator = amountInUsedForPoolUpdate * reserveOut;
    const denominator = reserveIn + amountInUsedForPoolUpdate;
    if (denominator === 0) throw new Error("Division by zero (Stable->Asset)"); // Safety check
    amountOut = numerator / denominator;
    amountOutUsedForPoolUpdate = amountOut; // The entire calculated amountOut is removed

    // Pool reserves update based on post-fee input and calculated output
    newReserveIn = reserveIn + amountInUsedForPoolUpdate;
    newReserveOut = reserveOut - amountOutUsedForPoolUpdate;

  } else { // Backend: swap_asset_to_stable (Fee from Stable Output)
    // Calculate output *before* fee, using full input amount
    const numerator = amountIn * reserveOut;
    const denominator = reserveIn + amountIn;
     if (denominator === 0) throw new Error("Division by zero (Asset->Stable)"); // Safety check
    const amountOutBeforeFee = numerator / denominator;

    ammFee = amountOutBeforeFee * feeRate;
    amountOut = amountOutBeforeFee - ammFee; // Actual amount user receives

    // Pool reserves update based on full input and *pre-fee* output
    amountInUsedForPoolUpdate = amountIn;
    amountOutUsedForPoolUpdate = amountOutBeforeFee; // Use pre-fee amount for reserve update

    newReserveIn = reserveIn + amountInUsedForPoolUpdate;
    newReserveOut = reserveOut - amountOutUsedForPoolUpdate;
  }

  // Ensure amountOut isn't negative due to floating point issues or huge fees
  amountOut = Math.max(0, amountOut);

  // Calculate metrics
  const startPrice = reserveOut > 0 ? reserveIn / reserveOut : 0; // Price: In per Out
  const finalPrice = newReserveOut > 0 ? newReserveIn / newReserveOut : 0; // Price after swap
  const averagePrice = amountOut > 0 ? amountIn / amountOut : 0; // Avg price: Input / Output

  // Price impact: % change from start price to final price
  const priceImpact = startPrice > 0 ? (finalPrice / startPrice - 1) * 100 : 0;

  // K check (for debugging, should be approximately equal)
  // const k_start = reserveIn * reserveOut;
  // const k_end = newReserveIn * newReserveOut;
  // console.log(`k_start: ${k_start}, k_end: ${k_end}, diff: ${k_end - k_start}`);

  return {
    exactAmountOut: amountOut,
    minAmountOut: amountOut * (1 - slippageTolerance),
    ammFee, // This is the fee amount, units depend on which swap direction
    priceImpact,
    averagePrice,
    finalPrice,
    startPrice,
  };
}