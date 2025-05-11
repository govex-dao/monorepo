import React from "react";
import { InfoCircledIcon } from "@radix-ui/react-icons";

interface TwapLegendProps {
  twaps: string[] | null;
  twap_threshold: string;
  outcomeMessages: string[];
  colors?: string[];
  asset_decimals: number;
  stable_decimals: number;
}

const TwapLegend: React.FC<TwapLegendProps> = ({
  twaps,
  twap_threshold,
  outcomeMessages,
  colors,
  asset_decimals,
  stable_decimals,
}) => {
  const outcomeCount = outcomeMessages.length;

  // Format TWAP value consistently
  const formatTwap = (value: number | null): string => {
    if (value === null) return "N/A";
    if (value === 0) return "0.0000"; // Always show 4 decimal places for zero
    const basisPoints = Math.pow(10, asset_decimals - stable_decimals);
    const adjustedValue = value / (basisPoints * 1000000000000);
    return adjustedValue.toFixed(5);
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
    } else {
      defaultColors = Array.from({ length: outcomeCount }, (_, i) => {
        const hue = (i * (360 / outcomeCount)) % 360;
        return `hsl(${hue}, 100%, 50%)`;
      });
    }
  }

  // Combine outcome messages with twaps and colors
  const items = outcomeMessages.map((message, index) => {
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

  // Sort items in descending order based on effective TWAP value
  items.sort((a, b) => effectiveSortValue(b) - effectiveSortValue(a));

  const pluralSuffix = items.length > 2 ? "s" : "";

  return (
    <div>
      <div className="flex flex-col sm:flex-row gap-4 items-start sm:items-center relative">
        <div className="flex items-center">
          <span className="text-base font-bold text-gray-300">
            Winning TWAP
          </span>
          <div className="relative group ml-1 mr-0.5">
            <InfoCircledIcon className="w-4 h-4 cursor-pointer" />
            <div className="absolute left-0 top-6 px-3 py-2 bg-gray-900 text-white text-sm rounded-lg opacity-0 group-hover:opacity-100 pointer-events-none transition-opacity duration-200 w-64 z-50">
              The time average weighted price for the {outcomeMessages[0]}{" "}
              market. Coins for market with the highest TWAP at the end of the
              traded period can be redeemed for cannonical tokens.
            </div>
          </div>
          <span className="text-base font-bold text-gray-300">:</span>
        </div>

        {items.slice(0, 1).map((item) => (
          <div key={item.index} className="flex items-center relative">
            <div className="flex items-center">
              <svg width="8" height="8">
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

        <div className="flex items-center mt-4 sm:mt-0">
          <span className="text-base font-bold text-gray-300">
            Failing TWAP{pluralSuffix}
          </span>
          <div className="relative group ml-1 mr-0.5">
            <InfoCircledIcon className="w-4 h-4 cursor-pointer" />
            <div className="absolute left-0 top-6 px-3 py-2 bg-gray-900 text-white text-sm rounded-lg opacity-0 group-hover:opacity-100 pointer-events-none transition-opacity duration-200 w-64 z-50">
              The time average weighted price for the failing market
              {items.length > 2 ? "s" : ""}. Coins for markets that fail cannot
              be redeemed for cannonical tokens at the end of the trading
              period.
            </div>
          </div>
          <span className="text-base font-bold text-gray-300">:</span>
        </div>

        <div className="flex flex-wrap gap-4 items-start">
          {items.slice(1).map((item) => (
            <div key={item.index} className="flex items-center relative">
              <div className="flex items-center">
                <svg width="8" height="8">
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
        </div>
      </div>
    </div>
  );
};

export default TwapLegend;
