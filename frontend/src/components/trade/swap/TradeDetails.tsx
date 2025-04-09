import React, { useState } from 'react';
import { ShowMoreDetails } from '../../ShowMoreDetails';
import { SwapBreakdown } from "@/utils/trade/calculateSwapBreakdown";

interface TradeDetailsProps {
  amount: string;
  averagePrice: string;
  swapDetails: SwapBreakdown | null;
  assetSymbol: string;
  stableSymbol: string;
  isBuy: boolean;
  tolerance: number;
}

const TradeDetails: React.FC<TradeDetailsProps> = ({
  amount,
  averagePrice,
  swapDetails,
  assetSymbol,
  stableSymbol,
  isBuy,
  tolerance
}) => {
  const [showTradeDetails, setShowTradeDetails] = useState<boolean>(false);
  if (!amount || !averagePrice || !swapDetails) return null;

  return (
    <div className="border-t pt-3 border-gray-700/50 mt-3 backdrop-blur-sm shadow-inner space-y-2">
      <div className="flex justify-between items-center">
        <span className="text-white text-xs font-medium whitespace-nowrap">
          1 {assetSymbol} ≈ {averagePrice} {stableSymbol}
        </span>
        <ShowMoreDetails
          show={showTradeDetails}
          setShow={setShowTradeDetails}
          title="Details"
        />
      </div>

      <div className="grid grid-cols-2 gap-2 w-full text-xs">
        <div className="bg-gray-800/40 px-3 py-1.5 rounded-md border border-gray-700/20 flex justify-between items-center">
          <p className="text-gray-400 font-medium">Price Impact</p>
          <span className={`font-semibold ${swapDetails.priceImpact > 5
            ? "text-red-400"
            : swapDetails.priceImpact > 2
              ? "text-yellow-400"
              : "text-green-400"
            }`}>
            {swapDetails.priceImpact > 1000
              ? swapDetails.priceImpact.toExponential(2)
              : swapDetails.priceImpact.toFixed(2)}%
          </span>
        </div>
        <div className="bg-gray-800/40 px-3 py-1 rounded-md border border-gray-700/20 flex justify-between items-center">
          <p className="text-gray-400 font-medium">Slippage</p>
          <p className="text-blue-400 font-semibold">{(tolerance * 100).toFixed(1)}%</p>
        </div>
      </div>

      {showTradeDetails && (
        <div className="mb-2.5 pt-2.5 border-t border-gray-800/40 space-y-2.5 bg-gray-700/20 p-3 rounded-md text-xs backdrop-blur-sm">
          <div className="flex justify-between items-center">
            <p className="text-gray-400">Start Price</p>
            <p className="text-blue-400 font-medium">
              ${swapDetails.startPrice.toPrecision(6)}
            </p>
          </div>
          <div className="flex justify-between items-center">
            <p className="text-gray-400">Average Price</p>
            <p className="text-blue-400 font-medium">
              ${averagePrice}
            </p>
          </div>
          <div className="flex justify-between items-center">
            <p className="text-gray-400">Final Price</p>
            <p className="text-blue-400 font-medium">
              ${swapDetails.finalPrice.toPrecision(6)}
            </p>
          </div>
          <div className="flex justify-between items-center">
            <p className="text-gray-400">Fee</p>
            <p className="text-white font-medium">
              {swapDetails.ammFee.toFixed(6)} {isBuy ? stableSymbol : assetSymbol}
            </p>
          </div>
          <div className="flex justify-between items-center">
            <p className="text-gray-400">Min Received</p>
            <p className="text-white font-medium">
              {swapDetails.minAmountOut.toFixed(6)} {isBuy ? assetSymbol : stableSymbol}
            </p>
          </div>
        </div>
      )}
    </div>
  );
};

export default TradeDetails; 