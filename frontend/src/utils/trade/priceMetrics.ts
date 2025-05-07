import { mulDivFloor } from "../bigints";
import { PriceMetrics } from "./types";

export const PRICE_SCALE_BI = 1_000_000_000_000n; // For price display matching BASIS_POINTS
export const PRICE_SCALE = 1_000_000_000_000; // For price display matching BASIS_POINTS

/**
 * Calculates price-related metrics for a swap or price calculation
 * prices are calculated in stable for clarity
 * 
 * @param amountIn_BI The input amount in BigInt
 * @param exactAmountOut_BI The exact output amount in BigInt
 * @param assetReserve_BI The asset token reserve in BigInt
 * @param stableReserve_BI The stable token reserve in BigInt
 * @param newAssetReserve_BI The new asset reserve after swap in BigInt
 * @param newStableReserve_BI The new stable reserve after swap in BigInt
 * @returns Object containing startPrice, averagePrice, finalPrice and priceImpact
 */
export function calculatePriceMetrics(
  amountIn_BI: bigint,
  exactAmountOut_BI: bigint,
  assetReserve_BI: bigint,
  stableReserve_BI: bigint,
  newAssetReserve_BI: bigint,
  newStableReserve_BI: bigint
): PriceMetrics {
  // Store initial price (stable per asset for consistency with contract)
  const startPrice_BI = mulDivFloor(stableReserve_BI, PRICE_SCALE_BI, assetReserve_BI);
  const startPrice = Number(startPrice_BI) / Number(PRICE_SCALE_BI); // stable per asset

  let finalPrice = 0;
  if (newAssetReserve_BI > 0n && newStableReserve_BI > 0n) { // Avoid division by zero
    const finalPrice_BI = mulDivFloor(newStableReserve_BI, PRICE_SCALE_BI, newAssetReserve_BI);
    finalPrice = Number(finalPrice_BI) / Number(PRICE_SCALE_BI);
  } else if (newStableReserve_BI > 0n && newAssetReserve_BI <= 0n) {
    finalPrice = Infinity; // Pool depleted of asset token
  } // Else remains 0 if stable reserve is 0

  let averagePrice = 0;
  if (exactAmountOut_BI > 0n) {
    // Avg Price = Input / Output (Amount of stable needed per unit of asset received)
    const avgPrice_BI = mulDivFloor(amountIn_BI, PRICE_SCALE_BI, exactAmountOut_BI);
    averagePrice = Number(avgPrice_BI) / Number(PRICE_SCALE_BI);
  } else if (amountIn_BI > 0n) {
     averagePrice = Infinity; // Received zero output for non-zero input
  }

  let priceImpact = 0;
  // Impact = % change from start marginal price to average execution price
  if (startPrice > 0 && averagePrice > 0) {
      // (avgPrice / startPrice - 1) is deviation from start price stable/asset
      priceImpact = (averagePrice / startPrice - 1) * 100;
  } else if (startPrice === 0 && averagePrice > 0) {
      priceImpact = Infinity; // Started at zero price, now finite
  } else if (finalPrice === Infinity) {
      priceImpact = Infinity; // Pool depleted
  } // Else remains 0

  return {
    averagePrice,
    finalPrice,
    startPrice,
    priceImpact,
  };
}