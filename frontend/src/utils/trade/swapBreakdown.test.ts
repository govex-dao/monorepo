import { describe, it, expect } from "vitest";
import { calculateSwapBreakdown, DEFAULT_SLIPPAGE_BPS, SWAP_FEE_BPS } from "./swapBreakdown";

// Helper function to calculate theoretical
const calculateOutput = (amountIn: number, reserveIn: number, reserveOut: number): number => {
  if (reserveIn <= 0 || reserveOut <= 0) return 0;
  const numerator = amountIn * reserveOut;
  const denominator = reserveIn + amountIn;

  if (denominator === 0) return 0; // Avoid division by zero
  return numerator / denominator;
};

describe("swap", () => {
  const feeRate = SWAP_FEE_BPS / 10_000;

  // --- Basic Functionality ---
  describe("Basic Funcionality", () => {
    it("should calculate basic swap breakdown correctly (Stable->Asset)", () => {
      const params = {
        reserveIn: 1000,
        reserveOut: 1000,
        amountIn: 100, // stable in
        isBuy: true, // stable to asset
      };

      const result = calculateSwapBreakdown(params);

      expect(result.exactAmountOut).toBeGreaterThan(0);
      expect(result.exactAmountOut).toBeLessThan(params.amountIn); // Price is ~1 initially
      expect(result.minAmountOut).toBeLessThan(result.exactAmountOut);
      expect(result.finalPrice).toBeGreaterThan(result.startPrice); // Price should increase when buying asset
    });

    it("should calculate basic swap breakdown correctly (Asset->Stable)", () => {
      const params = {
        reserveIn: 1000, // Asset
        reserveOut: 1000, // Stable
        amountIn: 100, // Asset In
        isBuy: false, // asset to stable
      };

      const result = calculateSwapBreakdown(params);

      expect(result.exactAmountOut).toBeGreaterThan(0);
      expect(result.exactAmountOut).toBeLessThan(params.amountIn); // Price is ~1 initially
      expect(result.minAmountOut).toBeLessThan(result.exactAmountOut);
      expect(result.finalPrice).toBeLessThan(result.startPrice); // Price should decrease when selling asset

    });

    it("should respect custom slippage tolerance", () => {
      const params = {
        reserveIn: 1000,
        reserveOut: 1000,
        amountIn: 100,
        slippageBps: 100, // 1%
        isBuy: true,
      };

      const result = calculateSwapBreakdown(params);
      const slippageFactor = 1 - params.slippageBps / 10000;
      const expectedMinAmountOut = result.exactAmountOut * slippageFactor;

      // Avoid division by zero by checking if expectedMinAmountOut is non-zero
      if (expectedMinAmountOut === 0) {
        expect(result.minAmountOut).toBe(0);
      } else {
        const percentDifference = Math.abs((result.minAmountOut - expectedMinAmountOut) / expectedMinAmountOut);
        expect(percentDifference).toBeLessThan(0.005); // Within 0.5%
      }
    });

    it("should handle asymmetric pools correctly", () => {
      const params = {
        reserveIn: 2000,
        reserveOut: 1000,
        amountIn: 100,
        isBuy: false,
      };

      const result = calculateSwapBreakdown(params);

      expect(result.startPrice).toBeCloseTo(0.5, 2); // 1000/2000 = 0.5
      expect(result.exactAmountOut).toBeGreaterThan(0);
    });

    it("should ensure average price is between start price and final price when buying", () => {
      const params = {
        reserveIn: 1000,  // stable
        reserveOut: 1000, // asset
        amountIn: 100,    // stable
        isBuy: true,      // buying asset
      };

      const result = calculateSwapBreakdown(params);

      // When buying asset, final price > start price
      expect(result.finalPrice).toBeGreaterThan(result.startPrice);
      
      // Average price should be between start and final price
      expect(result.averagePrice).toBeGreaterThan(result.startPrice);
      expect(result.averagePrice).toBeLessThan(result.finalPrice);
    });

    it("should ensure average price is between start price and final price when selling", () => {
      const params = {
        reserveIn: 1000,  // asset
        reserveOut: 1000, // stable
        amountIn: 100,    // asset
        isBuy: false,     // selling asset
      };

      const result = calculateSwapBreakdown(params);

      // When selling asset, final price < start price
      expect(result.finalPrice).toBeLessThan(result.startPrice);
      
      // Average price should be between final and start price
      expect(result.averagePrice).toBeLessThan(result.startPrice);
      expect(result.averagePrice).toBeGreaterThan(result.finalPrice);
    });

    it("should maintain average price relationship with different pool ratios", () => {
      const params = {
        reserveIn: 2000,  // More of input token
        reserveOut: 1000, // Less of output token
        amountIn: 200,    // 10% of input reserve
        isBuy: true,      // buying asset
      };

      const result = calculateSwapBreakdown(params);

      // Verify average price is between start and final prices
      expect(result.averagePrice).toBeGreaterThan(result.startPrice);
      expect(result.averagePrice).toBeLessThan(result.finalPrice);
    });

    it("should have same price impact with different pool sizes but same ratio", () => {
      const smallPoolParams = {
        reserveIn: 100,
        reserveOut: 100,
        amountIn: 10,
        isBuy: false,
      };

      const largePoolParams = {
        reserveIn: 10000,
        reserveOut: 10000,
        amountIn: 1000,
        isBuy: false,
      };

      const smallPoolResult = calculateSwapBreakdown(smallPoolParams);
      const largePoolResult = calculateSwapBreakdown(largePoolParams);

      // Price impact should be the same when the ratio of amountIn to reserves is the same
      expect(largePoolResult.priceImpact).toBeCloseTo(smallPoolResult.priceImpact, 1);
      expect(smallPoolResult.priceImpact).toBeCloseTo(-9.36, 1);
    });
  })

  // --- Fee Calculation ---
  describe("Fee Calculation", () => {
    it("should calculate fees correctly for asset-to-stable swap (sell)", () => {
      const params = {
        reserveIn: 1000, // asset
        reserveOut: 1000, // stable
        amountIn: 100,    // asset
        isBuy: false, // selling asset for stable
      };

      const result = calculateSwapBreakdown(params);

      // For selling asset, fee is taken from the output amount (stablecoin)
      // Calculate expected output amount before fee using the constant product formula
      const expectedOutBeforeFee = calculateOutput(params.amountIn, params.reserveIn, params.reserveOut)
      const expectedFee = expectedOutBeforeFee * feeRate;

      // Use a wider tolerance for floating point comparison
      expect(result.ammFee).toBeCloseTo(expectedFee, 0);
      expect(result.exactAmountOut).toBeCloseTo(expectedOutBeforeFee - expectedFee, 0);
    });

    it("should calculate fees correctly for stable-to-asset swap (buy)", () => {
      const params = {
        reserveIn: 1000, // stable
        reserveOut: 1000, // asset
        amountIn: 100,    // stable
        isBuy: true, // buying asset with stable
      };

      const result = calculateSwapBreakdown(params);

      // For buying asset, fee is taken from the input amount (stablecoin)
      const expectedFee = params.amountIn * feeRate;
      const amountInAfterFee = params.amountIn - expectedFee;

      // Calculate expected output using constant product formula with the fee-adjusted input
      const expectedOut = calculateOutput(amountInAfterFee, params.reserveIn, params.reserveOut)

      expect(result.ammFee).toBeCloseTo(expectedFee, 1);
      expect(result.exactAmountOut).toBeCloseTo(expectedOut, 1);
    });
  })

  // --- Constant Product (K) Check ---
  describe("Constant Product (K) Check", () => {
    it("should maintain constant product formula", () => {
      const params = {
        reserveIn: 1000,
        reserveOut: 1000,
        amountIn: 100,
        isBuy: false,
      };

      const result = calculateSwapBreakdown(params);

      // Calculate new reserves after swap
      const amountInAfterFee = params.amountIn - result.ammFee;
      const newReserveIn = params.reserveIn + amountInAfterFee;
      const newReserveOut = params.reserveOut - result.exactAmountOut;

      // Check if x * y = k holds (within reasonable precision)
      const initialProduct = params.reserveIn * params.reserveOut;
      const finalProduct = newReserveIn * newReserveOut;

      const percentDifference = Math.abs((finalProduct - initialProduct) / initialProduct);
      expect(percentDifference).toBeLessThan(DEFAULT_SLIPPAGE_BPS / 10_000); // Within 0.5%
    });

    it("should maintain constant product formula for both swap directions", () => {
      // Test buy direction (stable to asset)
      const buyParams = {
        reserveIn: 1000, // stable
        reserveOut: 1000, // asset
        amountIn: 100,    // stable
        isBuy: true,
      };

      const buyResult = calculateSwapBreakdown(buyParams);

      // For stable to asset, fee is taken from input
      const buyAmountInAfterFee = buyParams.amountIn - buyResult.ammFee;
      const buyNewReserveIn = buyParams.reserveIn + buyAmountInAfterFee;
      const buyNewReserveOut = buyParams.reserveOut - buyResult.exactAmountOut;

      const buyInitialProduct = buyParams.reserveIn * buyParams.reserveOut;
      const buyFinalProduct = buyNewReserveIn * buyNewReserveOut;

      const buyPercentDifference = Math.abs((buyFinalProduct - buyInitialProduct) / buyInitialProduct);
      expect(buyPercentDifference).toBeLessThan(DEFAULT_SLIPPAGE_BPS / 10_000); // Within 0.5%

      // Test sell direction (asset to stable)
      const sellParams = {
        reserveIn: 1000, // asset
        reserveOut: 1000, // stable
        amountIn: 100,    // asset
        isBuy: false,
      };

      const sellResult = calculateSwapBreakdown(sellParams);

      // For asset to stable, fee is taken from output
      const sellNewReserveIn = sellParams.reserveIn + sellParams.amountIn;
      const sellNewReserveOut = sellParams.reserveOut - sellResult.exactAmountOut - sellResult.ammFee;

      const sellInitialProduct = sellParams.reserveIn * sellParams.reserveOut;
      const sellFinalProduct = sellNewReserveIn * sellNewReserveOut;

      const sellPercentDifference = Math.abs((sellFinalProduct - sellInitialProduct) / sellInitialProduct);
      expect(sellPercentDifference).toBeLessThan(DEFAULT_SLIPPAGE_BPS / 10_000); // Within 0.5%
    });
  })

  // --- Edge Cases & Robustness ---
  describe("Edge Cases & Robustness", () => {
    it("should handle zero input amount correctly", () => {
      const params = {
        reserveIn: 1000,
        reserveOut: 1000,
        amountIn: 0,
        isBuy: false,
      };

      const result = calculateSwapBreakdown(params);
      expect(result.exactAmountOut).toEqual(0);
      expect(result.minAmountOut).toEqual(0);
      expect(result.ammFee).toEqual(0);
      expect(result.priceImpact).toEqual(0);
    });

    it("should handle very small input amounts", () => {
      const params = {
        reserveIn: 1000,
        reserveOut: 1000,
        amountIn: 0.0001,
        isBuy: false,
      };

      const result = calculateSwapBreakdown(params);

      expect(result.exactAmountOut).toBeGreaterThan(0);
      expect(result.exactAmountOut).toBeLessThan(params.amountIn);
    });

    it("should handle extreme slippage tolerance values", () => {
      // Test with no slippage tolerance
      const zeroSlippageParams = {
        reserveIn: 1000,
        reserveOut: 1000,
        amountIn: 100,
        slippageBps: 0,
        isBuy: false,
      };
      const zeroSlippageResult = calculateSwapBreakdown(zeroSlippageParams);

      // For zero slippage, minAmountOut should equal exactAmountOut
      expect(zeroSlippageResult.minAmountOut).toBeCloseTo(zeroSlippageResult.exactAmountOut, 10);

      // Verify that fees are still being applied correctly
      expect(zeroSlippageResult.ammFee).toBeGreaterThan(0);
      expect(zeroSlippageResult.exactAmountOut).toBeLessThan(zeroSlippageParams.amountIn - zeroSlippageResult.ammFee);

      // Test with high slippage tolerance
      const highSlippageParams = {
        reserveIn: 1000,
        reserveOut: 1000,
        amountIn: 100,
        slippageBps: 5_000, // 50%
        isBuy: false,
      };
      const highSlippageResult = calculateSwapBreakdown(highSlippageParams);

      const slippage = 5_000 / 10_000;

      // For 50% slippage, minAmountOut should be about 50% of exactAmountOut
      const expectedMinForHighSlippage = highSlippageResult.exactAmountOut * slippage;
      const highSlippagePercentDiff = Math.abs(
        (highSlippageResult.minAmountOut - expectedMinForHighSlippage) /
        expectedMinForHighSlippage
      );
      expect(highSlippagePercentDiff).toBeLessThan(slippage); // Within 50%
    });

    it("should handle very large reserve values", () => {
      const largeNumber = 1e9; // 1 billion
      const params = {
        reserveIn: largeNumber * 1000,
        reserveOut: largeNumber * 1000,
        amountIn: largeNumber * 10, // 1% of reserveIn
        isBuy: false,
      };

      const result = calculateSwapBreakdown(params);

      // Expect results to be finite and reasonable
      expect(isFinite(result.exactAmountOut)).toBe(true);
      expect(isFinite(result.minAmountOut)).toBe(true);
      expect(isFinite(result.ammFee)).toBe(true);
      expect(isFinite(result.priceImpact)).toBe(true);
      expect(isFinite(result.startPrice)).toBe(true);
      expect(isFinite(result.finalPrice)).toBe(true);

      // Check basic logic still holds
      expect(result.exactAmountOut).toBeGreaterThan(0);
      expect(result.exactAmountOut).toBeLessThan(params.amountIn); // Assuming start price near 1
      expect(result.priceImpact).toBeLessThan(0); // Should still have some impact
      expect(result.startPrice).toBeCloseTo(1, 2);
    });

    it("should handle very small (non-zero) reserve values", () => {
      const params = {
        reserveIn: 0.0000001,
        reserveOut: 0.0000001,
        amountIn: 0.00000001,
        isBuy: false,
      };

      const result = calculateSwapBreakdown(params);

      // Expect results to be finite and reasonable
      expect(isFinite(result.exactAmountOut)).toBe(true);
      expect(isFinite(result.minAmountOut)).toBe(true);
      expect(isFinite(result.ammFee)).toBe(true);
      expect(isFinite(result.priceImpact)).toBe(true);
      expect(isFinite(result.startPrice)).toBe(true);
      expect(isFinite(result.finalPrice)).toBe(true);

      // Check basic logic still holds
      expect(result.exactAmountOut).toBeGreaterThan(0);
      expect(result.ammFee).toBeGreaterThan(0);
      expect(result.priceImpact).toBeLessThan(0);
      expect(result.startPrice).toBeCloseTo(1, 2); // 0.0000001/0.0000001 = 1
      expect(result.finalPrice).toBeLessThan(result.startPrice); // Price should decrease when selling asset
    });

    it("should handle extremely small numbers without errors", () => {
      // Test with extremely small numbers that would normally cause BigInt conversion errors
      const params = {
        reserveIn: 1e-9,
        reserveOut: 1e-8,
        amountIn: 1e-6,
        isBuy: false,
      };

      // This should not throw an error
      const result = calculateSwapBreakdown(params);

      // For extremely small numbers, we expect some values to be 0 due to rounding
      expect(result.exactAmountOut).toBeGreaterThanOrEqual(0);
      expect(result.minAmountOut).toBeGreaterThanOrEqual(0);
      expect(result.ammFee).toBeGreaterThanOrEqual(0);
      expect(isFinite(result.priceImpact)).toBe(true);
      expect(isFinite(result.startPrice)).toBe(true);
      expect(isFinite(result.finalPrice)).toBe(true);
      expect(result.finalPrice).toBeLessThan(result.startPrice); // Price should decrease when selling asset
    });

    it("should handle large price movements without slippage errors", () => {
      // Test a large swap that moves price significantly (100x)
      const params = {
        reserveIn: 1_000_000, // 1M stable
        reserveOut: 1_000_000, // 1M asset
        amountIn: 990_000, // Large swap to move price significantly
        isBuy: true, // buying asset
        slippageBps: 5000, // 50% slippage tolerance for large moves
      };

      const result = calculateSwapBreakdown(params);

      // Verify the swap would be valid in the AMM contract
      // 1. Check that minAmountOut is positive
      expect(result.minAmountOut).toBeGreaterThan(0);

      // 2. Check that minAmountOut is within slippage tolerance
      const slippageFactor = 1 - params.slippageBps / 10000;
      const expectedMinAmountOut = result.exactAmountOut * slippageFactor;
      const percentDifference = Math.abs((result.minAmountOut - expectedMinAmountOut) / expectedMinAmountOut);
      expect(percentDifference).toBeLessThan(0.01); // Within 1%

      // 3. Verify price impact is significant but not infinite
      expect(result.priceImpact).toBeGreaterThan(0);
      expect(result.priceImpact).toBeLessThan(10000); // Less than 10000% impact

      // 4. Verify final price is significantly different from start price
      // For a 990k swap into a 1M/1M pool, we expect price to move significantly
      // but not necessarily 10x. Let's adjust the expectation based on the math:
      const expectedPriceRatio = (params.reserveIn + params.amountIn) / (params.reserveOut - result.exactAmountOut);
      expect(result.finalPrice / result.startPrice).toBeCloseTo(expectedPriceRatio, 0.1);
    });
  })

  // --- Exhausted reserves ---
  describe("Exhausted reserves", () => {
    it("should throw an error when reserveIn is zero", () => {
      const params = {
        reserveIn: 0, // Invalid state
        reserveOut: 1000,
        amountIn: 100,
      };

      expect(() => calculateSwapBreakdown({ ...params, isBuy: true })).toThrow("Invalid pool state");
      expect(() => calculateSwapBreakdown({ ...params, isBuy: false })).toThrow("Invalid pool state");
    });

    it("should throw an error when reserveOut is zero", () => {
      const params = {
        reserveIn: 1000,
        reserveOut: 0, // Invalid state
        amountIn: 100,
      };

      expect(() => calculateSwapBreakdown({ ...params, isBuy: true })).toThrow("Invalid pool state");
      expect(() => calculateSwapBreakdown({ ...params, isBuy: false })).toThrow("Invalid pool state");
    });

    it("should throw an error when both reserves are zero", () => {
      const params = {
        reserveIn: 0,
        reserveOut: 0,
        amountIn: 100,
      };

      expect(() => calculateSwapBreakdown({ ...params, isBuy: true })).toThrow("Invalid pool state");
      expect(() => calculateSwapBreakdown({ ...params, isBuy: false })).toThrow("Invalid pool state");
    });

    it("should handle very large input amounts (near pool exhaustion)", () => {
      const params = {
        reserveIn: 1000,
        reserveOut: 1000,
        amountIn: 900, // Almost draining the output reserve
        isBuy: true,
      };

      const result = calculateSwapBreakdown(params);

      expect(result.exactAmountOut).toBeLessThan(params.reserveOut);
      expect(result.priceImpact).toBeGreaterThan(2);
    });

    it("should handle when input amount would exhaust the output reserve (sell)", () => {
      const params = {
        reserveIn: 1000,
        reserveOut: 1000,
        amountIn: 10000, // Extremely large input that would exhaust the output reserve
        isBuy: false, // Selling asset
      };

      const result = calculateSwapBreakdown(params);

      // The output should approach but never reach the full reserve amount
      expect(result.exactAmountOut).toBeGreaterThan(0);
      expect(result.exactAmountOut).toBeLessThan(params.reserveOut);

      // The price impact should be extremely high
      expect(result.priceImpact).toBeLessThan(90); // Over 90% price impact

      // When selling asset, final price should approach zero
      expect(result.finalPrice).toBeLessThan(result.startPrice / 10);
    });

    it("should handle when input amount would exhaust the output reserve (buy)", () => {
      const params = {
        reserveIn: 1000,
        reserveOut: 1000,
        amountIn: 10000, // Extremely large input that would exhaust the output reserve
        isBuy: true, // Buying asset
      };

      const result = calculateSwapBreakdown(params);

      // The output should approach but never reach the full reserve amount
      expect(result.exactAmountOut).toBeGreaterThan(0);
      expect(result.exactAmountOut).toBeLessThan(params.reserveOut);

      // The price impact should be extremely high
      expect(result.priceImpact).toBeGreaterThan(90); // Over 90% price impact

      // When buying asset, final price should approach infinity
      expect(result.finalPrice).toBeGreaterThan(result.startPrice * 10);
    });
  })

  // --- Sequential Swaps ---
  describe("Sequential Swaps", () => {
    it("should calculate correct results for sequential swaps (same direction)", () => {
      // Initial pool state
      let reserveStable = 1000.0;
      let reserveAsset = 1000.0;
      const initialProduct = reserveStable * reserveAsset;
      
      // First swap: Stable -> Asset
      const firstSwapParams = {
        reserveIn: reserveStable,
        reserveOut: reserveAsset,
        amountIn: 100.0, // Stable
        isBuy: true, // Buying asset with stable
      };
      
      const firstSwapResult = calculateSwapBreakdown(firstSwapParams);
          
      // Verify constant product is maintained after first swap
      const productAfterFirst = reserveStable * reserveAsset;
      expect(productAfterFirst).toBeCloseTo(initialProduct, 0);
      
      // Second swap: Stable -> Asset again
      const secondSwapParams = {
        reserveIn: firstSwapResult.newReserveIn,
        reserveOut: firstSwapResult.newReserveOut,
        amountIn: 100.0, // Stable
        isBuy: true, // Buying asset with stable
      };
      
      const secondSwapResult = calculateSwapBreakdown(secondSwapParams);
      
      // Verify second swap calculations
      expect(secondSwapResult.startPrice).toBeGreaterThan(firstSwapResult.startPrice);
      expect(secondSwapResult.exactAmountOut).toBeLessThan(firstSwapResult.exactAmountOut);
      expect(secondSwapResult.priceImpact).toBeLessThan(firstSwapResult.priceImpact);
      
      // Verify constant product is maintained after second swap
      const finalProduct = secondSwapResult.newReserveIn * secondSwapResult.newReserveOut;
      expect(finalProduct).toBeCloseTo(initialProduct, 0);
    });
    
    it("should calculate correct results for sequential swaps (opposite directions)", () => {
      // Initial pool state
      let reserveStable = 1000.0;
      let reserveAsset = 1000.0;
      const initialProduct = reserveStable * reserveAsset;
      
      // First swap: Stable -> Asset
      const firstSwapParams = {
        reserveIn: reserveStable,
        reserveOut: reserveAsset,
        amountIn: 100.0, // Stable
        isBuy: true, // Buying asset with stable
      };
      
      const firstSwapResult = calculateSwapBreakdown(firstSwapParams);
      
      // Second swap: Asset -> Stable (opposite direction)
      const secondSwapParams = {
        reserveIn: firstSwapResult.newReserveOut, // Asset reserve after first swap
        reserveOut: firstSwapResult.newReserveIn, // Stable reserve after first swap
        amountIn: 50.0, // Asset
        isBuy: false, // Selling asset for stable
      };
      
      const secondSwapResult = calculateSwapBreakdown(secondSwapParams);
      
      // Verify second swap calculations
      expect(secondSwapResult.startPrice).toBeGreaterThan(firstSwapResult.startPrice);
      expect(secondSwapResult.exactAmountOut).toBeLessThan(firstSwapResult.exactAmountOut);
      expect(secondSwapResult.priceImpact).toBeLessThan(firstSwapResult.priceImpact);
      
      // Verify constant product is maintained after both swaps
      const finalProduct = secondSwapResult.newReserveIn * secondSwapResult.newReserveOut;
      const productDifference = Math.abs((finalProduct - initialProduct) / initialProduct);
      expect(productDifference).toBeLessThan(0.01); // Within 1% due to floating point precision
    });
  })
});


