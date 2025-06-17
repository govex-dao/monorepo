export function calculateAmountInAsset(
  amountIn: string,
  isBuy: boolean,
  price: string,
  assetScale: number,
  stableScale: number,
): number {
  return isBuy
    ? Number(amountIn) / stableScale / (Number(price) / assetScale)
    : Number(amountIn) / assetScale;
}

export function calculateVolumeInUSDC(
  amountIn: string,
  amountOut: string,
  isBuy: boolean,
  stableScale: number,
): number {
  // For buys: amount_in is USDC
  // For sells: amount_out is USDC
  const usdcAmount = isBuy ? amountIn : amountOut;
  return Number(usdcAmount) / stableScale;
}
