import React from "react";
import { InfoCircledIcon } from "@radix-ui/react-icons";

interface TwapLegendProps {
  twaps: string[] | null;
  twap_threshold: string;
  outcomeMessages: string[];
  colors?: string[];
  asset_decimals: number;
  stable_decimals: number;
  winning_outcome: string | null;
}

const TwapLegend: React.FC<TwapLegendProps> = ({
  twaps,
  twap_threshold,
  outcomeMessages,
  colors,
  asset_decimals,
  stable_decimals,
  winning_outcome,
}) => {
  if (twaps === null) {
    return null;
  }
  const winningOutcomeIndex =
    winning_outcome != null ? Number(winning_outcome) : null;
  const isResolved = winningOutcomeIndex !== null;
  const outcomeCount = outcomeMessages.length;

  const formatTwap = (value: number | null): string => {
    if (value === null) return "N/A";
    if (value === 0) return "0.00000";

    const ON_CHAIN_PRICE_SCALING_FACTOR = 1000000000000; // 1e12

    const adjustedValue =
      (value / ON_CHAIN_PRICE_SCALING_FACTOR) *
      Math.pow(10, asset_decimals - stable_decimals);

    return adjustedValue.toFixed(7);
  };

  // Generate default colors if not provided
  let defaultColors: string[] = [];
  if (colors && colors.length === outcomeCount) {
    defaultColors = colors;
  } else {
    if (outcomeCount === 1) {
      defaultColors = ["#ef4444"];
    } else if (outcomeCount === 2) {
      defaultColors = ["#ef4444", "#22c55e"];
    } else if (outcomeCount === 3) {
      defaultColors = ["#ef4444", "#22c55e", "#0080ff"];
    } else {
      // outcomeCount > 3
      defaultColors = Array.from({ length: outcomeCount }, (_, i) => {
        const hue = (i * (360 / outcomeCount)) % 360;
        return `hsl(${hue}, 100%, 50%)`;
      });
    }
  }

  // Combine outcome messages with twaps and colors
  const baseItems = outcomeMessages.map((message, index) => {
    const raw = twaps && twaps[index] ? parseFloat(twaps[index]) : null;
    const twapValue = raw !== null && !isNaN(raw) ? raw : null;
    return {
      index,
      message,
      twap: twapValue,
      color: defaultColors[index],
    };
  });

  // For outcome index 0, adjust its TWAP by multiplying it by (1 + threshold/100000)
  const effectiveSortValue = (item: {
    index: number;
    twap: number | null;
  }): number => {
    if (item.twap === null) return -Infinity;
    if (item.index === 0) {
      return item.twap * ((100000 + Number(twap_threshold)) / 100000);
    }
    return item.twap;
  };

  let winningItems: typeof baseItems = [];
  let failingItems: typeof baseItems = [];

  if (isResolved) {
    const winner = baseItems.find((item) => item.index === winningOutcomeIndex);
    if (winner) {
      winningItems.push(winner);
    }
    failingItems = baseItems.filter(
      (item) => item.index !== winningOutcomeIndex,
    );
  } else {
    // Sort items in descending order based on effective TWAP value
    const sortedItems = [...baseItems].sort(
      (a, b) => effectiveSortValue(b) - effectiveSortValue(a),
    );
    if (sortedItems.length > 0) {
      winningItems.push(sortedItems[0]);
    }
    failingItems = sortedItems.slice(1);
  }

  const pluralSuffix = failingItems.length > 1 ? "s" : "";

  return (
    <div>
      <div className="flex flex-col sm:flex-row gap-4 items-start sm:items-center relative">
        <div className="flex items-center">
          <span className="text-base font-bold text-gray-300">
            {isResolved ? "Winning Outcome" : "Winning TWAP"}
          </span>
          <div className="relative group ml-1 mr-0.5 shrink-0">
            <InfoCircledIcon className="w-4 h-4 cursor-pointer" />
            <div className="absolute left-0 top-6 px-3 py-2 bg-gray-900 text-white text-sm rounded-lg opacity-0 group-hover:opacity-100 pointer-events-none transition-opacity duration-200 w-64 z-50">
              {isResolved
                ? "The final winning outcome for this market."
                : `The time average weighted price for the ${outcomeMessages[0]} market. Coins for market with the highest TWAP at the end of the traded period can be redeemed for cannonical tokens.`}
            </div>
          </div>
          <span className="text-base font-bold text-gray-300">:</span>
        </div>

        {winningItems.map((item) => (
          <div key={item.index} className="flex items-center relative">
            <div className="flex items-center">
              <svg width="8" height="8" className="shrink-0">
                <circle cx="4" cy="4" r="4" fill={item.color} />
              </svg>
              <span className="text-gray-300 text-base ml-2 whitespace-nowrap">
                <span className="font-bold">{formatTwap(item.twap)} </span>
                <span className="text-gray-400 font-bold">
                  for {item.message}
                </span>
              </span>
            </div>
          </div>
        ))}

        {failingItems.length > 0 && (
          <>
            <div className="flex items-center mt-4 sm:mt-0">
              <span className="text-base font-bold text-gray-300">
                {isResolved
                  ? `Losing Outcome${pluralSuffix}`
                  : `Failing TWAP${pluralSuffix}`}
              </span>
              <div className="relative group ml-1 mr-0.5 shrink-0">
                <InfoCircledIcon className="w-4 h-4 cursor-pointer" />
                <div className="absolute left-0 top-6 px-3 py-2 bg-gray-900 text-white text-sm rounded-lg opacity-0 group-hover:opacity-100 pointer-events-none transition-opacity duration-200 w-64 z-50">
                  {isResolved
                    ? `The final losing outcome${pluralSuffix} for this market.`
                    : `The time average weighted price for the failing market${
                        failingItems.length > 1 ? "s" : ""
                      }. Coins for markets that fail cannot be redeemed for cannonical tokens at the end of the trading period.`}
                </div>
              </div>
              <span className="text-base font-bold text-gray-300">:</span>
            </div>

            <div className="flex flex-wrap gap-4 items-start">
              {failingItems.map((item) => (
                <div key={item.index} className="flex items-center relative">
                  <div className="flex items-center">
                    <svg width="8" height="8" className="shrink-0">
                      <circle
                        cx="4"
                        cy="4"
                        r="4"
                        fill={isResolved ? `${item.color}80` : item.color}
                      />
                    </svg>
                    <span className="text-gray-300 text-base ml-2 whitespace-nowrap">
                      <span className="font-bold">
                        {formatTwap(item.twap)}{" "}
                      </span>
                      <span className="text-gray-400 font-bold">
                        for {item.message}
                      </span>
                    </span>
                  </div>
                </div>
              ))}
            </div>
          </>
        )}
      </div>
    </div>
  );
};

export default TwapLegend;
