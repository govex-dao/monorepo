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

  return (
    <tr
      className={`text-sm border-b border-gray-800/70 hover:bg-gray-800/50 transition-colors ${isMyTrade ? "bg-blue-900/10" : ""}`}
      role="row"
    >
      <td className="py-3.5 px-4 text-gray-400" role="cell">
        {formattedDate}
      </td>
      <td className="py-3.5 px-4" role="cell">
        <span
          className={`px-2.5 py-1 rounded text-xs font-medium ${
            event.is_buy
              ? "bg-green-900/30 text-green-400 border border-green-700/30"
              : "bg-red-900/30 text-red-400 border border-red-700/30"
          }`}
        >
          {event.is_buy ? "Buy" : "Sell"}
        </span>
      </td>
      <td className="py-3.5 px-4" role="cell">
        <span
          className={`px-2.5 py-1 rounded text-xs font-medium border ${outcomeColor.bg} ${outcomeColor.text} ${outcomeColor.border}`}
        >
          {outcomeMessages[event.outcome] || `Outcome ${event.outcome}`}
        </span>
      </td>
      <td className="py-3.5 px-4 text-right text-gray-200" role="cell">
        <span className="font-medium">{formatNumber(event.price)}</span>
        <span className="text-gray-400 text-xs ml-1">{stableSymbol}</span>
      </td>
      <td className="py-3.5 px-4 text-right text-gray-200" role="cell">
        <span className="font-medium">{formatNumber(event.amount)}</span>
        <span className="text-gray-400 text-xs ml-1">{assetSymbol}</span>
      </td>
      <td className="py-3.5 px-4 text-right text-gray-200" role="cell">
        <span className="font-medium">{formatNumber(event.impact)}%</span>
        <span className="text-gray-400 text-xs ml-1">of reserves</span>
      </td>
      <td className="py-3.5 px-4" role="cell">
        <ExplorerLink id={event.sender} type="address" />
        {isMyTrade && (
          <span className="text-blue-400 font-medium px-1.5 py-0.5 bg-blue-900/30 rounded-sm">
            You
          </span>
        )}
      </td>
    </tr>
  );
}
