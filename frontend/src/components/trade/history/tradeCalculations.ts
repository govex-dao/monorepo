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

export function calculatePriceImpact(
  amountIn: string,
  isBuy: boolean,
  stableReserve: string,
  assetReserve: string,
  assetScale: number,
  stableScale: number,
): number {
  const stableReserveNum = Number(stableReserve) / stableScale;
  const assetReserveNum = Number(assetReserve) / assetScale;

  return isBuy
    ? (Number(amountIn) / stableScale / stableReserveNum) * 100
    : (Number(amountIn) / assetScale / assetReserveNum) * 100;
}
