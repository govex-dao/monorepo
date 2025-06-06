import { getOutcomeColor } from "@/utils/outcomes";
import { ExplorerLink } from "../../ExplorerLink";
import { CalculatedEvent } from "./TradeHistory";

// Memoized format number function
const formatNumber = (() => {
  const memo = new Map<number, string>();

  return (num: number): string => {
    if (memo.has(num)) return memo.get(num)!;

    if (num === 0) return "0";

    let result: string;
    if (num < 0.000001) {
      result = num.toExponential(2);
    } else if (num >= 1000000) {
      result = num.toLocaleString(undefined, {
        maximumFractionDigits: 2,
        notation: "compact",
        compactDisplay: "short",
      });
    } else if (num >= 1) {
      result = num.toLocaleString(undefined, {
        maximumFractionDigits: 2,
        minimumFractionDigits: 0,
      });
    } else {
      const str = num.toString();
      const match = str.match(/^0\.0*/);
      const leadingZeros = match ? match[0].length - 2 : 0;
      const decimalPlaces = Math.min(6, leadingZeros + 3);
      result = num.toFixed(decimalPlaces).replace(/\.?0+$/, "");
    }

    memo.set(num, result);
    return result;
  };
})();

// Table row component
export function TableRow({
  event,
  isMyTrade,
  outcomeMessages,
  assetSymbol,
  stableSymbol,
}: {
  event: CalculatedEvent;
  isMyTrade: boolean;
  outcomeMessages: string[];
  assetSymbol: string;
  stableSymbol: string;
}) {
  const date = new Date(Number(event.timestamp));
  const formattedDate =
    Date.now() - date.getTime() > 86400000
      ? `${date.toLocaleDateString("en-US", { month: "short", day: "numeric" })} ${date.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit" })}`
      : date.toLocaleTimeString("en-US", {
          hour: "2-digit",
          minute: "2-digit",
        });

  const outcomeColor = getOutcomeColor(event.outcome);

  // Common class patterns
  const cellClass = "py-3.5 px-4";
  const badgeClass = "px-2.5 py-1 rounded text-xs font-medium border";
  const rightAlignedCellClass = `${cellClass} text-right text-gray-200`;
  const valueClass = "font-medium";
  const unitClass = "text-gray-400 text-xs ml-1";

  return (
    <tr
      className={`text-sm border-b border-gray-800/70 hover:bg-gray-800/50 transition-colors ${isMyTrade ? "bg-blue-900/10" : ""}`}
      role="row"
    >
      <td className={`${cellClass} text-gray-400`} role="cell">
        {formattedDate}
      </td>
      <td className={cellClass + " text-center"} role="cell">
        <span
          className={`${badgeClass} ${
            event.is_buy
              ? "bg-green-900/30 text-green-400 border-green-700/30"
              : "bg-red-900/30 text-red-400 border-red-700/30"
          }`}
        >
          {event.is_buy ? "Buy" : "Sell"}
        </span>
      </td>
      <td className={cellClass + " text-center"} role="cell">
        <span
          className={`${badgeClass} ${outcomeColor.bg} ${outcomeColor.text} ${outcomeColor.border}`}
        >
          {outcomeMessages[event.outcome] || `Outcome ${event.outcome}`}
        </span>
      </td>
      <td className={rightAlignedCellClass} role="cell">
        <span className={valueClass}>{formatNumber(event.price)}</span>
        <span className={unitClass}>{stableSymbol}</span>
      </td>
      <td className={rightAlignedCellClass} role="cell">
        <span className={valueClass}>{formatNumber(event.amount)}</span>
        <span className={unitClass}>{assetSymbol}</span>
      </td>
      <td className={rightAlignedCellClass} role="cell">
        <span className={valueClass}>{formatNumber(event.impact)}%</span>
        <span className={unitClass}>of reserves</span>
      </td>
      <td className={rightAlignedCellClass + " flex flex-row"} role="cell">
        <div className="flex-1"></div>
        <ExplorerLink id={event.sender} type="address" />
        {isMyTrade && (
          <span className="text-blue-400 font-medium px-1.5 py-0.5 bg-blue-900/30 rounded-sm text-right">
            You
          </span>
        )}
      </td>
    </tr>
  );
}
