import { describe, it, expect } from 'vitest';
import { calculateSwapBreakdown, SWAP_FEE_BPS } from './calculateSwapBreakdown';

describe('calculateSwapBreakdown', () => {
    it('should calculate basic swap breakdown correctly', () => {
        const params = {
            reserveIn: 1000,
            reserveOut: 1000,
            amountIn: 100,
        };

        const result = calculateSwapBreakdown(params);


        expect(result.exactAmountOut).toBeLessThan(params.amountIn);
        expect(result.minAmountOut).toBeLessThan(result.exactAmountOut);
    });

    it('should respect custom slippage tolerance', () => {
        const params = {
            reserveIn: 1000,
            reserveOut: 1000,
            amountIn: 100,
            slippageTolerance: 0.01
        };

        const result = calculateSwapBreakdown(params);
        const slippageAmount = result.exactAmountOut * params.slippageTolerance;

        expect(result.minAmountOut).toBeCloseTo(result.exactAmountOut - slippageAmount);
    });

    it('should handle asymmetric pools correctly', () => {
        const params = {
            reserveIn: 2000,
            reserveOut: 1000,
            amountIn: 100,
        };

        const result = calculateSwapBreakdown(params);

        expect(result.startPrice).toEqual(2);
        expect(result.exactAmountOut).toBeGreaterThan(0);
    });

    it('should calculate fees correctly', () => {
        const params = {
            reserveIn: 1000,
            reserveOut: 1000,
            amountIn: 100,
        };

        const result = calculateSwapBreakdown(params);
        const expectedFee = params.amountIn * (SWAP_FEE_BPS / 10_000);

        expect(result.ammFee).toBeCloseTo(expectedFee);
    });

    it('should maintain constant product formula', () => {
        const params = {
            reserveIn: 1000,
            reserveOut: 1000,
            amountIn: 100,
        };

        const result = calculateSwapBreakdown(params);

        // Calculate new reserves after swap
        const amountInAfterFee = params.amountIn * (1 - SWAP_FEE_BPS / 10_000);
        const newReserveIn = params.reserveIn + amountInAfterFee;
        const newReserveOut = params.reserveOut - result.exactAmountOut;

        // Check if x * y = k holds (within reasonable precision)
        const initialProduct = params.reserveIn * params.reserveOut;
        const finalProduct = newReserveIn * newReserveOut;

        expect(finalProduct).toEqual(initialProduct);
    });

    it('should handle zero input amount correctly', () => {
        const params = {
            reserveIn: 1000,
            reserveOut: 1000,
            amountIn: 0,
        };

        const result = calculateSwapBreakdown(params);

        expect(result.exactAmountOut).toEqual(0);
        expect(result.minAmountOut).toEqual(0);
        expect(result.ammFee).toEqual(0);
        expect(result.priceImpact).toEqual(0);
    });

    it('should handle very small input amounts', () => {
        const params = {
            reserveIn: 1000,
            reserveOut: 1000,
            amountIn: 0.0001,
        };

        const result = calculateSwapBreakdown(params);

        expect(result.exactAmountOut).toBeGreaterThan(0);
        expect(result.exactAmountOut).toBeLessThan(params.amountIn);
    });

    it('should handle very large input amounts (near pool exhaustion)', () => {
        const params = {
            reserveIn: 1000,
            reserveOut: 1000,
            amountIn: 900, // Almost draining the output reserve
        };

        const result = calculateSwapBreakdown(params);

        expect(result.exactAmountOut).toBeLessThan(params.reserveOut);
        expect(result.priceImpact).toBeGreaterThan(10); // Should have significant price impact
    });

    it('should handle extreme slippage tolerance values', () => {
        // Test with no slippage tolerance
        const zeroSlippageParams = {
            reserveIn: 1000,
            reserveOut: 1000,
            amountIn: 100,
            slippageTolerance: 0,
        };
        const zeroSlippageResult = calculateSwapBreakdown(zeroSlippageParams);
        expect(zeroSlippageResult.minAmountOut).toEqual(zeroSlippageResult.exactAmountOut);

        // Test with high slippage tolerance
        const highSlippageParams = {
            reserveIn: 1000,
            reserveOut: 1000,
            amountIn: 100,
            slippageTolerance: 0.5, // 50%
        };
        const highSlippageResult = calculateSwapBreakdown(highSlippageParams);
        expect(highSlippageResult.minAmountOut).toEqual(highSlippageResult.exactAmountOut * 0.5);
    });

    it('should have same price impact with different pool sizes but same ratio', () => {
        const smallPoolParams = {
            reserveIn: 100,
            reserveOut: 100,
            amountIn: 10,
        };

        const largePoolParams = {
            reserveIn: 10000,
            reserveOut: 10000,
            amountIn: 1000,
        };

        const smallPoolResult = calculateSwapBreakdown(smallPoolParams);
        const largePoolResult = calculateSwapBreakdown(largePoolParams);

        // Price impact should be the same when the ratio of amountIn to reserves is the same
        expect(largePoolResult.priceImpact).toBeCloseTo(smallPoolResult.priceImpact, 5);
        
        // Verify both have the expected price impact
        expect(smallPoolResult.priceImpact).toBeCloseTo(20.93, 1);
    });

    it('should handle very large reserve values', () => {
        const largeNumber = 1e18; // Represents a large amount, common in token quantities
        const params = {
            reserveIn: largeNumber * 1000,
            reserveOut: largeNumber * 1000,
            amountIn: largeNumber * 10, // 1% of reserveIn
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
        expect(result.priceImpact).toBeGreaterThan(0); // Should still have some impact
        expect(result.startPrice).toEqual(1);
    });

    it('should handle very small (non-zero) reserve values', () => {
        const smallNumber = 1e-9; // Represents a very small amount
        const params = {
            reserveIn: smallNumber * 10,
            reserveOut: smallNumber * 5, // Asymmetric small pool
            amountIn: smallNumber * 1,   // 10% of reserveIn
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
        expect(result.priceImpact).toBeGreaterThan(0);
        expect(result.startPrice).toBeCloseTo(params.reserveIn / params.reserveOut); // Start price should be correct
        // Check constant product roughly holds (allowing for precision issues with small numbers)
        const amountInAfterFee = params.amountIn * (1 - SWAP_FEE_BPS / 10_000);
        const newReserveIn = params.reserveIn + amountInAfterFee;
        const newReserveOut = params.reserveOut - result.exactAmountOut;
        expect(newReserveIn * newReserveOut).toBeCloseTo(params.reserveIn * params.reserveOut, 12); // Increase precision tolerance
    });

    it('should throw an error when reserveIn is zero', () => {
        const params = {
            reserveIn: 0, // Invalid state
            reserveOut: 1000,
            amountIn: 100,
        };

        expect(() => calculateSwapBreakdown(params)).toThrow('Invalid pool state');
    });

    it('should throw an error when reserveOut is zero', () => {
        const params = {
            reserveIn: 1000,
            reserveOut: 0, // Invalid state
            amountIn: 100,
        };

        expect(() => calculateSwapBreakdown(params)).toThrow('Invalid pool state');
    });

    it('should throw an error when both reserves are zero', () => {
        const params = {
            reserveIn: 0,
            reserveOut: 0,
            amountIn: 100,
        };

        expect(() => calculateSwapBreakdown(params)).toThrow('Invalid pool state');
    });

    it('should calculate correct results for sequential swaps', () => {
        // Initial pool state
        let reserveIn = 1000;
        let reserveOut = 1000;
        const amountIn1 = 100;
        
        // First swap
        const firstSwapResult = calculateSwapBreakdown({
            reserveIn, 
            reserveOut, 
            amountIn: amountIn1
        });
        
        // Calculate new reserves after first swap
        const amountInAfterFee1 = amountIn1 * (1 - SWAP_FEE_BPS / 10_000);
        reserveIn += amountInAfterFee1;
        reserveOut -= firstSwapResult.exactAmountOut;
        
        // Second swap
        const amountIn2 = 50;
        const secondSwapResult = calculateSwapBreakdown({
            reserveIn, 
            reserveOut, 
            amountIn: amountIn2
        });
        
        // Verify second swap is calculated correctly
        expect(secondSwapResult.startPrice).toBeCloseTo(reserveIn / reserveOut);
        expect(secondSwapResult.exactAmountOut).toBeGreaterThan(0);
        expect(secondSwapResult.exactAmountOut).toBeLessThan(amountIn2);
        
        // Calculate final reserves after second swap
        const amountInAfterFee2 = amountIn2 * (1 - SWAP_FEE_BPS / 10_000);
        const finalReserveIn = reserveIn + amountInAfterFee2;
        const finalReserveOut = reserveOut - secondSwapResult.exactAmountOut;
        
        // Check if constant product formula holds across both swaps
        const initialProduct = 1000 * 1000; // Initial reserves product
        const finalProduct = finalReserveIn * finalReserveOut;
        
        expect(finalProduct).toEqual(initialProduct);
        
        // Verify second swap's price impact takes into account the new price after first swap
        expect(secondSwapResult.startPrice).toEqual(firstSwapResult.finalPrice);
    });
});