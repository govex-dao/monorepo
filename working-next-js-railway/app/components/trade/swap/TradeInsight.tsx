import { ShowMoreDetails } from '../../../components/ShowMoreDetails';
import { Tooltip } from "@radix-ui/themes";
import React, { Dispatch, SetStateAction, useMemo, useState } from "react";

// Determine outcome class based on the selected outcome
const getOutcomeClass = (index: number) => {
  // This can be expanded for multiple outcomes with different colors
  const colorClasses = [
    "text-red-300",
    "text-green-300",
    "text-blue-300",
    "text-yellow-300",
    "text-purple-300",
  ];
  return colorClasses[index % colorClasses.length];
};

// Function to truncate long outcome messages
const truncateMessage = (message: string, maxLength: number = 32) => {
  if (!message || message.length <= maxLength) return message;
  return `${message.substring(0, maxLength)}...`;
};

interface TradeInsightProps {
  isBuy: boolean;
  setIsBuy: Dispatch<SetStateAction<boolean>>;
  selectedOutcome: string;
  outcomeMessages: string[];
  amount: string;
  updateFromAmount: (amount: string) => void;
  assetSymbol: string;
  stableSymbol: string;
  stableScale: number;
  assetScale: number;
  averagePrice?: number;
}

const TradeInsight: React.FC<TradeInsightProps> = ({
  isBuy,
  setIsBuy,
  selectedOutcome,
  outcomeMessages,
  amount,
  updateFromAmount,
  averagePrice,
  assetSymbol,
  stableSymbol,
  stableScale,
  assetScale,
}) => {
  const [showTradeInsight, setShowTradeInsight] = useState<boolean>(false);
  const selectedOutcomeIndex = parseInt(selectedOutcome);
  const outcomeMessage = outcomeMessages[selectedOutcomeIndex];

  const truncatedMessage = useMemo(
    () => truncateMessage(outcomeMessage),
    [outcomeMessage],
  );

  const outcomeClass = getOutcomeClass(selectedOutcomeIndex);
  const fromSymbol = isBuy ? stableSymbol : assetSymbol;
  const scale = isBuy ? stableScale : assetScale;

  function renderAmountInput(symbol: string, scale: number) {
    return (
      <span className="font-mono bg-black/30 px-2 py-0.5 rounded-md font-medium">
        <input
          type="number"
          value={amount}
          onChange={(e) => updateFromAmount(e.target.value)}
          className="w-12 bg-transparent text-white border-b border-dashed border-gray-500 focus:outline-none font-medium appearance-none [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none [-moz-appearance:textfield]"
          step={1 / Number(scale)}
          aria-label={`Enter amount in ${symbol}`}
        />{" "}
        {symbol}
      </span>
    );
  }

  function renderTradeButton(isPositive: boolean) {
    return (
      <button
        className={`${isPositive ? "bg-green-900/40 text-green-300 hover:bg-green-800/40" : "bg-red-900/40 text-red-300 hover:bg-red-800/40"} font-medium px-3 py-1.5 rounded-md mr-2 inline-flex items-center shadow-sm cursor-pointer transition-colors duration-200`}
        onClick={() => setIsBuy((p) => !p)}
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          className="h-3.5 w-3.5 mr-1.5"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          strokeWidth={2}
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            d={isPositive ? "M5 15l7-7 7 7" : "M19 9l-7 7-7-7"}
          />
        </svg>
        {isPositive ? "BULLISH" : "BEARISH"}
      </button>
    );
  }

  function renderTradeDescription() {
    return (
      <div>
        {renderTradeButton(isBuy)}
        <p className="leading-relaxed mt-2.5 text-xs">
          You expect the price to{" "}
          {isBuy ? (
            <strong className="text-green-300">rise</strong>
          ) : (
            <strong className="text-red-300">fall</strong>
          )}{" "}
          if{" "}
          {truncatedMessage !== outcomeMessage ? (
            <Tooltip
              content={
                <div className="max-w-xs p-4 text-sm bg-gray-950 border border-gray-900 rounded-md shadow-lg text-gray-200">
                  {outcomeMessage}
                </div>
              }
            >
              <strong className={`${outcomeClass} cursor-help`}>
                {truncatedMessage}
              </strong>
            </Tooltip>
          ) : (
            <strong className={outcomeClass}>{truncatedMessage}</strong>
          )}{" "}
          wins.
        </p>
        <p className="leading-relaxed mt-1 text-xs">
          You're betting {renderAmountInput(fromSymbol, scale)} that the price
          of {assetSymbol} at{" "}
          <span className="font-mono bg-black/30 px-2 py-0.5 rounded-md font-medium">
            $
            {averagePrice
              ? (isBuy ? averagePrice : 1 / averagePrice).toFixed(3)
              : ""}
          </span>{" "}
          is too {isBuy ? "low" : "high"}.
        </p>
      </div>
    );
  }

  return (
    <div>
      <div className="flex justify-end">
        <ShowMoreDetails
          show={showTradeInsight}
          setShow={setShowTradeInsight}
          title="Beginner Guide"
        />
      </div>
      {showTradeInsight && (
        <div className="bg-gray-800/20 rounded-lg p-4 mb-3 text-sm border border-gray-700/20 shadow-lg backdrop-blur-sm text-gray-200">
          {renderTradeDescription()}
        </div>
      )}
    </div>
  );
};

export default TradeInsight;
