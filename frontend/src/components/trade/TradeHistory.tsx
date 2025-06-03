import { useState, useMemo } from "react";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { getOutcomeColor } from "@/utils/outcomes";
import { ExplorerLink } from "../ExplorerLink";

interface SwapEvent {
  price: string;
  timestamp: string;
  is_buy: boolean;
  amount_in: string;
  outcome: number;
  asset_reserve: string;
  stable_reserve: string;
  sender: string;
}

interface TradeHistoryProps {
  swapEvents?: SwapEvent[];
  assetSymbol: string;
  stableSymbol: string;
  outcomeMessages: string[];
  assetScale: number;
  stableScale: number;
  hasStarted?: boolean;
}

type SortDirection = "ascending" | "descending";
type SortField = "time" | "amount" | "price" | "impact";

interface SortConfig {
  field: SortField;
  direction: SortDirection;
}

interface FilterState {
  showOnlyMyTrades: boolean;
  selectedOutcome: number | null;
  selectedTradeType: "all" | "buy" | "sell";
  searchQuery: string;
}

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

// Custom hook for filter logic
const useTradeFilters = (swapEvents: SwapEvent[], outcomeMessages: string[], accountAddress?: string) => {
  const [filters, setFilters] = useState<FilterState>({
    showOnlyMyTrades: false,
    selectedOutcome: null,
    selectedTradeType: "all",
    searchQuery: "",
  });

  const clearFilters = () => {
    setFilters({
      showOnlyMyTrades: false,
      selectedOutcome: null,
      selectedTradeType: "all",
      searchQuery: "",
    });
  };

  const filteredEvents = useMemo(() => {
    let filtered = swapEvents;

    if (filters.showOnlyMyTrades && accountAddress) {
      filtered = filtered.filter((event) => event.sender === accountAddress);
    }

    if (filters.selectedOutcome !== null) {
      filtered = filtered.filter((event) => event.outcome === filters.selectedOutcome);
    }

    if (filters.selectedTradeType !== "all") {
      filtered = filtered.filter((event) =>
        filters.selectedTradeType === "buy" ? event.is_buy : !event.is_buy,
      );
    }

    if (filters.searchQuery) {
      const query = filters.searchQuery.toLowerCase();
      filtered = filtered.filter(
        (event) =>
          event.sender.toLowerCase().includes(query) ||
          outcomeMessages[event.outcome].toLowerCase().includes(query),
      );
    }

    return filtered;
  }, [swapEvents, filters, accountAddress, outcomeMessages]);

  return {
    filters,
    setFilters,
    clearFilters,
    filteredEvents,
  };
};

const getSortIndicator = (field: SortField, config: SortConfig) => {
  const isActive = config.field === field;
  return (
    <span
      className={`transition-colors ${isActive ? "text-gray-200" : "text-gray-600 hover:text-gray-200"}`}
      aria-hidden="true"
    >
      {isActive ? (config.direction === "descending" ? "↓" : "↑") : "↓"}
    </span>
  );
};

// Table header component
function TableHeader({ onSort, sortConfig }: { onSort: (field: SortField) => void; sortConfig: SortConfig }) {
  return (
    <thead>
      <tr className="text-xs text-gray-400 border-b border-gray-800 bg-gray-900/70">
        <th
          className="text-left py-3.5 px-4 font-medium cursor-pointer hover:text-gray-300 transition-colors"
          onClick={() => onSort("time")}
          role="columnheader"
          aria-sort={sortConfig.field === "time" ? sortConfig.direction : undefined}
        >
          <div className="flex items-center gap-1.5">
            Time
            {getSortIndicator("time", sortConfig)}
          </div>
        </th>
        <th className="text-left py-3.5 px-4 font-medium" role="columnheader">Type</th>
        <th className="text-left py-3.5 px-4 font-medium" role="columnheader">Outcome</th>
        <th
          className="text-right py-3.5 px-4 font-medium cursor-pointer hover:text-gray-300 transition-colors"
          onClick={() => onSort("price")}
          role="columnheader"
          aria-sort={sortConfig.field === "price" ? sortConfig.direction : undefined}
        >
          <div className="flex items-center justify-end gap-1.5">
            Price
            {getSortIndicator("price", sortConfig)}
          </div>
        </th>
        <th
          className="text-right py-3.5 px-4 font-medium cursor-pointer hover:text-gray-300 transition-colors"
          onClick={() => onSort("amount")}
          role="columnheader"
          aria-sort={sortConfig.field === "amount" ? sortConfig.direction : undefined}
        >
          <div className="flex items-center justify-end gap-1.5">
            Amount
            {getSortIndicator("amount", sortConfig)}
          </div>
        </th>
        <th
          className="text-right py-3.5 px-4 font-medium cursor-pointer hover:text-gray-300 transition-colors"
          onClick={() => onSort("impact")}
          role="columnheader"
          aria-sort={sortConfig.field === "impact" ? sortConfig.direction : undefined}
        >
          <div className="flex items-center justify-end gap-1.5">
            Impact
            {getSortIndicator("impact", sortConfig)}
          </div>
        </th>
        <th className="text-left py-3.5 px-4 font-medium" role="columnheader">Trader</th>
      </tr>
    </thead>
  );
}

// Table row component
function TableRow({
  event,
  isMyTrade,
  outcomeMessages,
  assetScale,
  stableScale,
  assetSymbol,
  stableSymbol,
}: {
  event: SwapEvent;
  isMyTrade: boolean;
  outcomeMessages: string[];
  assetScale: number;
  stableScale: number;
  assetSymbol: string;
  stableSymbol: string;
}) {
  const date = new Date(Number(event.timestamp));
  const formattedDate = Date.now() - date.getTime() > 86400000
    ? `${date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })} ${date.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' })}`
    : date.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });

  const stableReserve = Number(event.stable_reserve) / stableScale;
  const assetReserve = Number(event.asset_reserve) / assetScale;
  const priceImpact = event.is_buy
    ? (Number(event.amount_in) / stableScale / stableReserve) * 100
    : (Number(event.amount_in) / assetScale / assetReserve) * 100;

  const price = Number(event.price) / assetScale;
  const outcomeColor = getOutcomeColor(event.outcome);

  const amountInAsset = event.is_buy
    ? Number(event.amount_in) / stableScale / price
    : Number(event.amount_in) / assetScale;

  return (
    <tr
      className={`text-sm border-b border-gray-800/70 hover:bg-gray-800/50 transition-colors ${isMyTrade ? "bg-blue-900/10" : ""}`}
      role="row"
    >
      <td className="py-3.5 px-4 text-gray-400" role="cell">{formattedDate}</td>
      <td className="py-3.5 px-4" role="cell">
        <span
          className={`px-2.5 py-1 rounded text-xs font-medium ${event.is_buy
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
        <span className="font-medium">{formatNumber(price)}</span>
        <span className="text-gray-400 text-xs ml-1">{stableSymbol}</span>
      </td>
      <td className="py-3.5 px-4 text-right text-gray-200" role="cell">
        <span className="font-medium">{formatNumber(amountInAsset)}</span>
        <span className="text-gray-400 text-xs ml-1">{assetSymbol}</span>
      </td>
      <td className="py-3.5 px-4 text-right text-gray-200" role="cell">
        <span className="font-medium">{formatNumber(priceImpact)}%</span>
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

function TradeHistory({
  swapEvents = [],
  assetSymbol,
  stableSymbol,
  outcomeMessages,
  assetScale,
  stableScale,
  hasStarted = true,
}: TradeHistoryProps) {
  const account = useCurrentAccount();
  const [sortConfig, setSortConfig] = useState<SortConfig>({
    field: "time",
    direction: "descending",
  });

  const {
    filters,
    setFilters,
    clearFilters,
    filteredEvents,
  } = useTradeFilters(swapEvents, outcomeMessages, account?.address);

  const sortedEvents = useMemo(() => {
    return [...filteredEvents].sort((a, b) => {
      if (sortConfig.field === "time") {
        const timeA = Number(a.timestamp);
        const timeB = Number(b.timestamp);
        return sortConfig.direction === "descending" ? timeB - timeA : timeA - timeB;
      } else if (sortConfig.field === "amount") {
        const amountA = a.is_buy
          ? Number(a.amount_in) / Number(a.price)
          : Number(a.amount_in) / assetScale;
        const amountB = b.is_buy
          ? Number(b.amount_in) / Number(b.price)
          : Number(b.amount_in) / assetScale;
        return sortConfig.direction === "descending" ? amountB - amountA : amountA - amountB;
      } else if (sortConfig.field === "price") {
        const priceA = Number(a.price);
        const priceB = Number(b.price);
        return sortConfig.direction === "descending" ? priceB - priceA : priceA - priceB;
      } else if (sortConfig.field === "impact") {
        const stableReserveA = Number(a.stable_reserve) / stableScale;
        const assetReserveA = Number(a.asset_reserve) / assetScale;
        const priceImpactA = a.is_buy
          ? (Number(a.amount_in) / stableScale / stableReserveA) * 100
          : (Number(a.amount_in) / assetScale / assetReserveA) * 100;

        const stableReserveB = Number(b.stable_reserve) / stableScale;
        const assetReserveB = Number(b.asset_reserve) / assetScale;
        const priceImpactB = b.is_buy
          ? (Number(b.amount_in) / stableScale / stableReserveB) * 100
          : (Number(b.amount_in) / assetScale / assetReserveB) * 100;

        return sortConfig.direction === "descending" ? priceImpactB - priceImpactA : priceImpactA - priceImpactB;
      }
      return 0;
    });
  }, [filteredEvents, sortConfig, assetScale, stableScale]);

  const handleSort = (field: SortField) => {
    setSortConfig((current) => ({
      field,
      direction: current.field === field && current.direction === "descending" ? "ascending" : "descending",
    }));
  };

  if (!hasStarted) {
    return null;
  }

  if (!swapEvents || swapEvents.length === 0) {
    return (
      <div className="text-gray-400 p-8 text-center bg-gray-900/50 border border-gray-800/50 rounded-lg shadow-md mt-12">
        <p className="text-sm">No trades recorded</p>
      </div>
    );
  }

  const activeFiltersCount = [
    filters.showOnlyMyTrades,
    filters.selectedOutcome !== null,
    filters.selectedTradeType !== "all",
    filters.searchQuery !== "",
  ].filter(Boolean).length;

  return (
    <div className="space-y-4 p-6" role="region" aria-label="Trade History">
      <div className="flex flex-col gap-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <h3 className="text-sm font-semibold uppercase text-gray-300">
              Recent Trades
            </h3>
            {activeFiltersCount > 0 && (
              <button
                onClick={clearFilters}
                className="text-xs text-gray-400 hover:text-gray-200 transition-colors flex items-center gap-1"
                aria-label={`Clear ${activeFiltersCount} active filters`}
              >
                <span className="px-1.5 py-0.5 bg-gray-800/50 rounded text-gray-300">
                  {activeFiltersCount}
                </span>
                Clear filters
              </button>
            )}
          </div>
          <div className="flex items-center gap-3">
            <div className="relative w-64">
              <input
                type="text"
                value={filters.searchQuery}
                onChange={(e) => setFilters(prev => ({ ...prev, searchQuery: e.target.value }))}
                placeholder="Search by address or outcome..."
                className="w-full px-4 py-1.5 bg-gray-800/50 border border-gray-700/30 rounded-lg text-sm text-gray-200 placeholder-gray-500 focus:outline-none focus:border-blue-500/50"
                aria-label="Search trades"
              />
              {filters.searchQuery && (
                <button
                  onClick={() => setFilters(prev => ({ ...prev, searchQuery: "" }))}
                  className="absolute right-3 top-1/2 -translate-y-1/2 text-gray-400 hover:text-gray-200"
                  aria-label="Clear search"
                >
                  <svg
                    className="w-4 h-4"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      strokeLinecap="round"
                      strokeLinejoin="round"
                      strokeWidth={2}
                      d="M6 18L18 6M6 6l12 12"
                    />
                  </svg>
                </button>
              )}
            </div>
            <span className="text-xs text-gray-500">
              {sortedEvents.length} trades
            </span>
          </div>
        </div>

        <div className="flex flex-wrap items-center gap-4 p-3 bg-gray-900/50 border border-gray-800/50 rounded-lg">
          <div className="flex items-center gap-2">
            <label className="text-xs font-medium text-gray-300">Account</label>
            <div className="flex items-center gap-1.5" role="radiogroup" aria-label="Filter by account">
              <button
                onClick={() => setFilters(prev => ({ ...prev, showOnlyMyTrades: false }))}
                className={`text-xs px-2.5 py-1 rounded transition-colors ${!filters.showOnlyMyTrades
                  ? "bg-gray-800 text-gray-200"
                  : "text-gray-400 hover:text-gray-200"
                  }`}
                role="radio"
                aria-checked={!filters.showOnlyMyTrades}
              >
                All
              </button>
              <button
                onClick={() => setFilters(prev => ({ ...prev, showOnlyMyTrades: true }))}
                className={`text-xs px-2.5 py-1 rounded transition-colors ${filters.showOnlyMyTrades
                  ? "bg-blue-900/30 text-blue-400"
                  : "text-gray-400 hover:text-gray-200"
                  }`}
                role="radio"
                aria-checked={filters.showOnlyMyTrades}
              >
                My Trades
              </button>
            </div>
          </div>

          <div className="flex items-center gap-2">
            <label className="text-xs font-medium text-gray-300">Outcome</label>
            <div className="flex items-center gap-1.5" role="radiogroup" aria-label="Filter by outcome">
              <button
                onClick={() => setFilters(prev => ({ ...prev, selectedOutcome: null }))}
                className={`text-xs px-2.5 py-1 rounded transition-colors ${filters.selectedOutcome === null
                  ? "bg-gray-800 text-gray-200"
                  : "text-gray-400 hover:text-gray-200"
                  }`}
                role="radio"
                aria-checked={filters.selectedOutcome === null}
              >
                All
              </button>
              {outcomeMessages.map((message, index) => {
                const outcomeColor = getOutcomeColor(index);
                return (
                  <button
                    key={index}
                    onClick={() => setFilters(prev => ({ ...prev, selectedOutcome: filters.selectedOutcome === index ? null : index }))}
                    className={`text-xs px-2.5 py-1 rounded transition-colors border ${filters.selectedOutcome === index
                      ? `${outcomeColor.bg} ${outcomeColor.text} ${outcomeColor.border}`
                      : "text-gray-400 hover:text-gray-200 border-transparent"
                      }`}
                    role="radio"
                    aria-checked={filters.selectedOutcome === index}
                  >
                    {message || `Outcome ${index}`}
                  </button>
                );
              })}
            </div>
          </div>

          <div className="flex items-center gap-2">
            <label className="text-xs font-medium text-gray-300">Type</label>
            <div className="flex items-center gap-1.5" role="radiogroup" aria-label="Filter by trade type">
              <button
                onClick={() => setFilters(prev => ({ ...prev, selectedTradeType: "all" }))}
                className={`text-xs px-2.5 py-1 rounded transition-colors ${filters.selectedTradeType === "all"
                  ? "bg-gray-800 text-gray-200"
                  : "text-gray-400 hover:text-gray-200"
                  }`}
                role="radio"
                aria-checked={filters.selectedTradeType === "all"}
              >
                All
              </button>
              <button
                onClick={() => setFilters(prev => ({ ...prev, selectedTradeType: "buy" }))}
                className={`text-xs px-2.5 py-1 rounded transition-colors ${filters.selectedTradeType === "buy"
                  ? "bg-green-900/30 text-green-400"
                  : "text-gray-400 hover:text-gray-200"
                  }`}
                role="radio"
                aria-checked={filters.selectedTradeType === "buy"}
              >
                Buy
              </button>
              <button
                onClick={() => setFilters(prev => ({ ...prev, selectedTradeType: "sell" }))}
                className={`text-xs px-2.5 py-1 rounded transition-colors ${filters.selectedTradeType === "sell"
                  ? "bg-red-900/30 text-red-400"
                  : "text-gray-400 hover:text-gray-200"
                  }`}
                role="radio"
                aria-checked={filters.selectedTradeType === "sell"}
              >
                Sell
              </button>
            </div>
          </div>
        </div>
      </div>

      <div className="overflow-x-auto rounded-lg min-h-[200px]">
        <table className="w-full" role="grid">
          <TableHeader onSort={handleSort} sortConfig={sortConfig} />
          <tbody>
            {sortedEvents.map((event, index) => (
              <TableRow
                key={`${event.timestamp}-${index}`}
                event={event}
                isMyTrade={event.sender === account?.address}
                outcomeMessages={outcomeMessages}
                assetScale={assetScale}
                stableScale={stableScale}
                assetSymbol={assetSymbol}
                stableSymbol={stableSymbol}
              />
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

export default TradeHistory;
