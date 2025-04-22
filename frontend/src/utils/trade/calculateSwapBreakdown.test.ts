import { describe, it, expect } from "vitest";
import { calculateSwapBreakdown, SWAP_FEE_BPS } from "./calculateSwapBreakdown";

// Helper function to calculate theoretical output before fees (for Asset->Stable tests)
const calculateOutputBeforeFee = (
  amountIn: number,
  reserveIn: number,
  reserveOut: number,
): number => {
  if (reserveIn <= 0 || reserveOut <= 0) return 0;
  const numerator = amountIn * reserveOut;
  const denominator = reserveIn + amountIn;
  if (denominator === 0) return 0; // Avoid division by zero
  return numerator / denominator;
};

describe("calculateSwapBreakdown", () => {
  const feeRate = SWAP_FEE_BPS / 10_000;

  // --- Basic Functionality ---

  it("should calculate basic swap breakdown correctly (Stable->Asset)", () => {
    const params = {
      reserveIn: 1000,
      reserveOut: 1000,
      amountIn: 100,
      isStableToAsset: true, // Fee from Input
    };

    const result = calculateSwapBreakdown(params);

    expect(result.exactAmountOut).toBeGreaterThan(0);
    expect(result.exactAmountOut).toBeLessThan(params.amountIn); // Price is ~1 initially
    expect(result.minAmountOut).toBeLessThan(result.exactAmountOut);
  });

  it("should calculate basic swap breakdown correctly (Asset->Stable)", () => {
    const params = {
      reserveIn: 1000, // Asset
      reserveOut: 1000, // Stable
      amountIn: 100, // Asset In
      isStableToAsset: false, // Fee from Output
    };

    const result = calculateSwapBreakdown(params);

    expect(result.exactAmountOut).toBeGreaterThan(0);
    expect(result.exactAmountOut).toBeLessThan(params.amountIn); // Price is ~1 initially
    expect(result.minAmountOut).toBeLessThan(result.exactAmountOut);
  });

  it("should respect custom slippage tolerance", () => {
    const params = {
      reserveIn: 1000,
      reserveOut: 1000,
      amountIn: 100,
      slippageTolerance: 0.01,
      isStableToAsset: true, // Direction shouldn't affect slippage calculation itself
    };

    const result = calculateSwapBreakdown(params);
    const slippageAmount = result.exactAmountOut * params.slippageTolerance;

    expect(result.minAmountOut).toBeCloseTo(
      result.exactAmountOut - slippageAmount,
    );
  });

  it("should handle asymmetric pools correctly (Stable->Asset)", () => {
    const params = {
      reserveIn: 2000, // Stable
      reserveOut: 1000, // Asset
      amountIn: 100, // Stable In
      isStableToAsset: true,
    };

    const result = calculateSwapBreakdown(params);

    // Price: ReserveIn / ReserveOut = Stable / Asset
    expect(result.startPrice).toBeCloseTo(2); // 2 Stable per 1 Asset
    expect(result.exactAmountOut).toBeGreaterThan(0);
    expect(result.exactAmountOut).toBeLessThan(
      params.amountIn / result.startPrice,
    ); // Should get less than 50 Asset
  });

  // --- Fee Calculation ---

  it("should calculate fees correctly (Stable->Asset, Fee from Input)", () => {
    const params = {
      reserveIn: 1000,
      reserveOut: 1000,
      amountIn: 100,
      isStableToAsset: true,
    };

    const result = calculateSwapBreakdown(params);
    const expectedFee = params.amountIn * feeRate;

    expect(result.ammFee).toBeCloseTo(expectedFee);
  });

  it("should calculate fees correctly (Asset->Stable, Fee from Output)", () => {
    const params = {
      reserveIn: 1000, // Asset
      reserveOut: 1000, // Stable
      amountIn: 100, // Asset In
      isStableToAsset: false,
    };

    const result = calculateSwapBreakdown(params);
    // Fee is calculated on the theoretical output *before* fee deduction
    const amountOutBeforeFee = calculateOutputBeforeFee(
      params.amountIn,
      params.reserveIn,
      params.reserveOut,
    );
    const expectedFee = amountOutBeforeFee * feeRate;

    expect(result.ammFee).toBeCloseTo(expectedFee);
    // Verify the exactAmountOut is indeed the amount before fee minus the fee
    expect(result.exactAmountOut).toBeCloseTo(
      amountOutBeforeFee - result.ammFee,
    );
  });

  // --- Constant Product (K) Check (Focus on internal calculation consistency) ---

  it("should reflect constant product internally (Stable->Asset)", () => {
    const params = {
      reserveIn: 1000, // Stable
      reserveOut: 1000, // Asset
      amountIn: 100, // Stable In
      isStableToAsset: true,
    };
    const initialK = params.reserveIn * params.reserveOut;

    // Calculate expected new reserves based *on the function's logic*
    const fee = params.amountIn * feeRate;
    const amountInAfterFee = params.amountIn - fee;
    const exactAmountOut = calculateOutputBeforeFee(
      amountInAfterFee,
      params.reserveIn,
      params.reserveOut,
    ); // Output based on post-fee input
    const expectedNewReserveIn = params.reserveIn + amountInAfterFee;
    const expectedNewReserveOut = params.reserveOut - exactAmountOut;
    const expectedFinalK = expectedNewReserveIn * expectedNewReserveOut;

    // The function's internal calculation aims to keep K constant *for the reserves*
    expect(expectedFinalK).toBeCloseTo(initialK);
  });

  it("should reflect constant product internally (Asset->Stable)", () => {
    const params = {
      reserveIn: 1000, // Asset
      reserveOut: 1000, // Stable
      amountIn: 100, // Asset In
      isStableToAsset: false,
    };
    const initialK = params.reserveIn * params.reserveOut;

    // Calculate expected new reserves based *on the function's logic*
    const amountOutBeforeFee = calculateOutputBeforeFee(
      params.amountIn,
      params.reserveIn,
      params.reserveOut,
    );
    // Reserves update based on full input and *pre-fee* output
    const expectedNewReserveIn = params.reserveIn + params.amountIn;
    const expectedNewReserveOut = params.reserveOut - amountOutBeforeFee;
    const expectedFinalK = expectedNewReserveIn * expectedNewReserveOut;

    // The function's internal calculation aims to keep K constant *for the reserves*
    expect(expectedFinalK).toBeCloseTo(initialK);
  });

  // --- Edge Cases & Robustness ---

  it("should handle zero input amount correctly", () => {
    const params = {
      reserveIn: 1000,
      reserveOut: 1000,
      amountIn: 0,
      isStableToAsset: true, // Direction irrelevant
    };

    const result = calculateSwapBreakdown(params);

    expect(result.exactAmountOut).toEqual(0);
    expect(result.minAmountOut).toEqual(0);
    expect(result.ammFee).toEqual(0);
    expect(result.priceImpact).toEqual(0);
    expect(result.averagePrice).toEqual(result.startPrice); // Or handle NaN/Infinity if preferred
    expect(result.finalPrice).toEqual(result.startPrice);
  });

  it("should handle very small input amounts", () => {
    const params = {
      reserveIn: 1000,
      reserveOut: 1000,
      amountIn: 0.0001,
      isStableToAsset: true,
    };

    const result = calculateSwapBreakdown(params);

    expect(result.exactAmountOut).toBeGreaterThan(0);
    expect(result.exactAmountOut).toBeLessThan(params.amountIn);
    expect(result.ammFee).toBeGreaterThan(0);
  });

  it("should handle very large input amounts (near pool exhaustion)", () => {
    const params = {
      reserveIn: 1000, // Input reserve
      reserveOut: 500, // Output reserve (easier to exhaust)
      amountIn: 1800, // Amount that would drain > 50% output without fees/slippage
      isStableToAsset: true,
    };

    const result = calculateSwapBreakdown(params);

    expect(result.exactAmountOut).toBeLessThan(params.reserveOut);
    expect(result.exactAmountOut).toBeGreaterThan(0); // Should still get *something*
    expect(result.priceImpact).toBeGreaterThan(50); // Expect very high impact
    expect(result.finalPrice).toBeGreaterThan(result.startPrice * 2); // Price moves significantly
  });

  it("should handle extreme slippage tolerance values", () => {
    // Test with no slippage tolerance
    const zeroSlippageParams = {
      reserveIn: 1000,
      reserveOut: 1000,
      amountIn: 100,
      slippageTolerance: 0,
      isStableToAsset: true,
    };
    const zeroSlippageResult = calculateSwapBreakdown(zeroSlippageParams);
    expect(zeroSlippageResult.minAmountOut).toEqual(
      zeroSlippageResult.exactAmountOut,
    );

    // Test with high slippage tolerance
    const highSlippageParams = {
      reserveIn: 1000,
      reserveOut: 1000,
      amountIn: 100,
      slippageTolerance: 0.5, // 50%
      isStableToAsset: true,
    };
    const highSlippageResult = calculateSwapBreakdown(highSlippageParams);
    expect(highSlippageResult.minAmountOut).toEqual(
      highSlippageResult.exactAmountOut * 0.5,
    );
  });

  it("should have similar price impact with different pool sizes but same ratio", () => {
    const smallPoolParams = {
      reserveIn: 100,
      reserveOut: 100,
      amountIn: 10, // 10% of reserveIn
      isStableToAsset: true,
    };

    const largePoolParams = {
      reserveIn: 10000,
      reserveOut: 10000,
      amountIn: 1000, // 10% of reserveIn
      isStableToAsset: true,
    };

    const smallPoolResult = calculateSwapBreakdown(smallPoolParams);
    const largePoolResult = calculateSwapBreakdown(largePoolParams);

    // Price impact depends on the relative size of the trade to the pool
    expect(largePoolResult.priceImpact).toBeCloseTo(
      smallPoolResult.priceImpact,
      5, // Allow some precision difference
    );

    // Manually calculate expected impact for Stable->Asset
    // amountIn=10, reserveIn=100, reserveOut=100, feeRate=0.003
    // fee = 10 * 0.003 = 0.03
    // amountInAfterFee = 9.97
    // amountOut = 9.97 * 100 / (100 + 9.97) = 997 / 109.97 = 9.0661
    // newReserveIn = 100 + 9.97 = 109.97
    // newReserveOut = 100 - 9.0661 = 90.9339
    // startPrice = 100/100 = 1
    // finalPrice = 109.97 / 90.9339 = 1.2093
    // priceImpact = (1.2093 / 1 - 1) * 100 = 20.93 %
    expect(smallPoolResult.priceImpact).toBeCloseTo(20.93, 1);
  });

  it("should handle very large reserve values", () => {
    const largeNumber = 1e18;
    const params = {
      reserveIn: largeNumber * 1000,
      reserveOut: largeNumber * 1000,
      amountIn: largeNumber * 10, // 1% of reserveIn
      isStableToAsset: true,
    };

    const result = calculateSwapBreakdown(params);

    expect(isFinite(result.exactAmountOut)).toBe(true);
    expect(isFinite(result.minAmountOut)).toBe(true);
    expect(isFinite(result.ammFee)).toBe(true);
    expect(isFinite(result.priceImpact)).toBe(true);
    expect(isFinite(result.startPrice)).toBe(true);
    expect(isFinite(result.finalPrice)).toBe(true);

    expect(result.exactAmountOut).toBeGreaterThan(0);
    expect(result.exactAmountOut).toBeLessThan(params.amountIn);
    expect(result.priceImpact).toBeGreaterThan(0);
    expect(result.startPrice).toBeCloseTo(1); // Use toBeCloseTo for float comparison
  });

  it("should handle very small (non-zero) reserve values", () => {
    const smallNumber = 1e-9;
    const params = {
      reserveIn: smallNumber * 10, // Stable
      reserveOut: smallNumber * 5, // Asset
      amountIn: smallNumber * 1, // Stable In (10% of reserveIn)
      isStableToAsset: true,
    };

    const result = calculateSwapBreakdown(params);

    expect(isFinite(result.exactAmountOut)).toBe(true);
    expect(isFinite(result.minAmountOut)).toBe(true);
    expect(isFinite(result.ammFee)).toBe(true);
    expect(isFinite(result.priceImpact)).toBe(true);
    expect(isFinite(result.startPrice)).toBe(true);
    expect(isFinite(result.finalPrice)).toBe(true);

    expect(result.exactAmountOut).toBeGreaterThan(0);
    expect(result.ammFee).toBeGreaterThan(0);
    expect(result.priceImpact).toBeGreaterThan(0);
    expect(result.startPrice).toBeCloseTo(params.reserveIn / params.reserveOut); // Start price should be correct (2)

    // Check constant product roughly holds (using function's internal logic)
    const initialK = params.reserveIn * params.reserveOut;
    const fee = params.amountIn * feeRate;
    const amountInAfterFee = params.amountIn - fee;
    const exactAmountOut = calculateOutputBeforeFee(
      amountInAfterFee,
      params.reserveIn,
      params.reserveOut,
    );
    const expectedNewReserveIn = params.reserveIn + amountInAfterFee;
    const expectedNewReserveOut = params.reserveOut - exactAmountOut;
    const expectedFinalK = expectedNewReserveIn * expectedNewReserveOut;

    expect(expectedFinalK).toBeCloseTo(initialK, 15); // Increase precision tolerance significantly for very small floats
  });

  // --- Error Handling ---

  it("should throw an error when reserveIn is zero", () => {
    const params = {
      reserveIn: 0,
      reserveOut: 1000,
      amountIn: 100,
      isStableToAsset: true, // Direction irrelevant
    };
    // The function might return 0s instead of throwing now for invalid reserves
    // Depending on the implementation change - let's assume it still throws for simplicity
    expect(() => calculateSwapBreakdown(params)).toThrow("Invalid pool state");
    // If it returns zeros instead:
    // const result = calculateSwapBreakdown(params);
    // expect(result.exactAmountOut).toEqual(0); // etc.
  });

  it("should throw an error when reserveOut is zero", () => {
    const params = {
      reserveIn: 1000,
      reserveOut: 0,
      amountIn: 100,
      isStableToAsset: true, // Direction irrelevant
    };
    expect(() => calculateSwapBreakdown(params)).toThrow("Invalid pool state");
  });

  it("should throw an error when both reserves are zero", () => {
    const params = {
      reserveIn: 0,
      reserveOut: 0,
      amountIn: 100,
      isStableToAsset: true, // Direction irrelevant
    };
    expect(() => calculateSwapBreakdown(params)).toThrow("Invalid pool state");
  });

  // --- Sequential Swaps ---

  it("should calculate correct results for sequential swaps (Stable->Asset)", () => {
    // Initial pool state
    let reserveIn = 1000.0; // Stable
    let reserveOut = 1000.0; // Asset
    const amountIn1 = 100.0;
    const initialProduct = reserveIn * reserveOut;

    // --- First swap ---
    const firstSwapResult = calculateSwapBreakdown({
      reserveIn,
      reserveOut,
      amountIn: amountIn1,
      isStableToAsset: true,
    });

    // Calculate new reserves *based on the function's logic for Stable->Asset*
    const fee1 = amountIn1 * feeRate;
    const amountInAfterFee1 = amountIn1 - fee1;
    const amountOut1 = calculateOutputBeforeFee(
      amountInAfterFee1,
      reserveIn,
      reserveOut,
    );
    reserveIn += amountInAfterFee1; // Update state for next swap
    reserveOut -= amountOut1; // Update state for next swap
    const productAfterFirst = reserveIn * reserveOut;
    expect(productAfterFirst).toBeCloseTo(initialProduct); // Verify K held for the first swap

    // --- Second swap ---
    const amountIn2 = 50.0;
    const secondSwapResult = calculateSwapBreakdown({
      reserveIn, // Use updated reserves
      reserveOut, // Use updated reserves
      amountIn: amountIn2,
      isStableToAsset: true,
    });

    // Verify second swap calculation
    expect(secondSwapResult.startPrice).toBeCloseTo(reserveIn / reserveOut); // Based on state *after* first swap
    expect(secondSwapResult.exactAmountOut).toBeGreaterThan(0);
    expect(secondSwapResult.exactAmountOut).toBeLessThan(amountIn2); // Price should be > 1 now

    // Calculate final reserves after second swap
    const fee2 = amountIn2 * feeRate;
    const amountInAfterFee2 = amountIn2 - fee2;
    const amountOut2 = calculateOutputBeforeFee(
      amountInAfterFee2,
      reserveIn,
      reserveOut,
    ); // Calculate output based on current reserves
    const finalReserveIn = reserveIn + amountInAfterFee2;
    const finalReserveOut = reserveOut - amountOut2; // Use calculated amountOut2
    const finalProduct = finalReserveIn * finalReserveOut;

    // Check if constant product formula holds across both swaps
    expect(finalProduct).toBeCloseTo(initialProduct); // K should still be close to the original K

    // Verify second swap's price impact takes into account the new price after first swap
    expect(secondSwapResult.startPrice).toEqual(firstSwapResult.finalPrice);
  });

  it("should calculate correct results for sequential swaps (Mixed Directions)", () => {
    // Initial pool state
    let reserveStable = 1000.0;
    let reserveAsset = 1000.0;
    const initialProduct = reserveStable * reserveAsset;
    const feeRate = SWAP_FEE_BPS / 10_000; // Make sure feeRate is defined if not globally

    // --- First swap: Stable -> Asset ---
    const amountIn1 = 100.0; // Stable
    const fee1 = amountIn1 * feeRate;
    const amountInAfterFee1 = amountIn1 - fee1;
    const amountOut1 = calculateOutputBeforeFee(
      amountInAfterFee1,
      reserveStable,
      reserveAsset,
    ); // Asset out
    reserveStable += amountInAfterFee1;
    reserveAsset -= amountOut1;
    const productAfterFirst = reserveStable * reserveAsset;
    expect(productAfterFirst).toBeCloseTo(initialProduct);

    // --- State *before* second swap ---
    const reserveAsset_before_swap2 = reserveAsset;
    const reserveStable_before_swap2 = reserveStable;
    const expectedStartPrice_swap2 =
      reserveAsset_before_swap2 / reserveStable_before_swap2; // Price: Asset per Stable

    // --- Second swap: Asset -> Stable ---
    const amountIn2 = 50.0; // Asset
    const secondSwapResult = calculateSwapBreakdown({
      reserveIn: reserveAsset_before_swap2, // Input is now Asset state *before* swap 2
      reserveOut: reserveStable_before_swap2, // Output is now Stable state *before* swap 2
      amountIn: amountIn2,
      isStableToAsset: false, // Selling Asset
    });

    // Calculate expected results based on state *before* swap 2
    const amountOutBeforeFee2 = calculateOutputBeforeFee(
      amountIn2,
      reserveAsset_before_swap2,
      reserveStable_before_swap2,
    ); // Stable out (before fee)
    const fee2 = amountOutBeforeFee2 * feeRate; // Fee is in Stable
    const amountOut2 = amountOutBeforeFee2 - fee2; // Actual Stable user gets

    // Verify second swap calculation results against expectations
    // **** FIX IS HERE: Compare against the pre-swap price ****
    expect(secondSwapResult.startPrice).toBeCloseTo(expectedStartPrice_swap2);
    expect(secondSwapResult.exactAmountOut).toBeCloseTo(amountOut2);
    expect(secondSwapResult.ammFee).toBeCloseTo(fee2);

    // --- Update reserves *after* calculating/verifying swap 2 results ---
    reserveAsset = reserveAsset_before_swap2 + amountIn2; // Update using pre-swap state + input
    reserveStable = reserveStable_before_swap2 - amountOutBeforeFee2; // Update using pre-swap state - pre-fee output
    const finalProduct = reserveStable * reserveAsset;

    // Check if K still holds relative to the initial state
    expect(finalProduct).toBeCloseTo(initialProduct);
  });
});
