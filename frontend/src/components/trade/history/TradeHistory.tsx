import { useState, useMemo, useEffect } from "react";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { getOutcomeColor } from "@/utils/outcomes";
import { TableRow } from "./TableRow";
import { SortConfig, SortField, TableHeader } from "./TableHeader";
import {
  calculateAmountInAsset,
  calculatePriceImpact,
} from "./tradeCalculations";

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

interface FilterState {
  showOnlyMyTrades: boolean;
  selectedOutcome: number | null;
  selectedTradeType: "all" | "buy" | "sell";
  searchQuery: string;
}

export interface CalculatedEvent extends Omit<SwapEvent, "price"> {
  amount: number;
  impact: number;
  time: number;
  price: number;
}

// Custom hook for filter logic
const useTradeFilters = (
  swapEvents: SwapEvent[],
  outcomeMessages: string[],
  accountAddress?: string,
) => {
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
      filtered = filtered.filter(
        (event) => event.outcome === filters.selectedOutcome,
      );
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

export function TradeHistory({
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

  const { filters, setFilters, clearFilters, filteredEvents } = useTradeFilters(
    swapEvents,
    outcomeMessages,
    account?.address,
  );

  // Reset My Trades filter when account disconnects
  useEffect(() => {
    if (!account?.address && filters.showOnlyMyTrades) {
      setFilters((prev) => ({ ...prev, showOnlyMyTrades: false }));
    }
  }, [account?.address, filters.showOnlyMyTrades]);

  // Pre-calculate all values when filtered events change
  const calculatedEvents: CalculatedEvent[] = useMemo(() => {
    return filteredEvents.map((event) => ({
      ...event,
      amount: calculateAmountInAsset(
        event.amount_in,
        event.is_buy,
        event.price,
        assetScale,
        stableScale,
      ),
      price: Number(event.price) / assetScale,
      impact: calculatePriceImpact(
        event.amount_in,
        event.is_buy,
        event.stable_reserve,
        event.asset_reserve,
        assetScale,
        stableScale,
      ),
      time: Number(event.timestamp),
    }));
  }, [filteredEvents, assetScale, stableScale]);

  const sortedEvents: CalculatedEvent[] = useMemo(() => {
    return calculatedEvents.sort((a, b) => {
      const field = sortConfig.field;
      const aValue = a[field as keyof CalculatedEvent] as number;
      const bValue = b[field as keyof CalculatedEvent] as number;

      console.log(field, aValue, bValue);
      return sortConfig.direction === "descending"
        ? bValue - aValue
        : aValue - bValue;
    });
  }, [calculatedEvents, sortConfig]);

  const handleSort = (field: SortField) => {
    setSortConfig((current) => ({
      field,
      direction:
        current.field === field && current.direction === "descending"
          ? "ascending"
          : "descending",
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
                onChange={(e) =>
                  setFilters((prev) => ({
                    ...prev,
                    searchQuery: e.target.value,
                  }))
                }
                placeholder="Search by address or outcome..."
                className="w-full px-4 py-1.5 bg-gray-800/50 border border-gray-700/30 rounded-lg text-sm text-gray-200 placeholder-gray-500 focus:outline-none focus:border-blue-500/50"
                aria-label="Search trades"
              />
              {filters.searchQuery && (
                <button
                  onClick={() =>
                    setFilters((prev) => ({ ...prev, searchQuery: "" }))
                  }
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
            <div
              className="flex items-center gap-1.5"
              role="radiogroup"
              aria-label="Filter by account"
            >
              <button
                onClick={() =>
                  setFilters((prev) => ({ ...prev, showOnlyMyTrades: false }))
                }
                className={`text-xs px-2.5 py-1 rounded transition-colors ${
                  !filters.showOnlyMyTrades
                    ? "bg-gray-800 text-gray-200"
                    : "text-gray-400 hover:text-gray-200"
                }`}
                role="radio"
                aria-checked={!filters.showOnlyMyTrades}
              >
                All
              </button>
              <button
                onClick={() =>
                  setFilters((prev) => ({ ...prev, showOnlyMyTrades: true }))
                }
                disabled={!account?.address}
                className={`text-xs px-2.5 py-1 rounded transition-colors ${
                  filters.showOnlyMyTrades
                    ? "bg-blue-900/30 text-blue-400"
                    : "text-gray-400 hover:text-gray-200"
                } ${!account?.address ? "opacity-50 cursor-not-allowed" : ""}`}
                role="radio"
                aria-checked={filters.showOnlyMyTrades}
                aria-disabled={!account?.address}
              >
                My Trades
              </button>
            </div>
          </div>

          <div className="flex items-center gap-2">
            <label className="text-xs font-medium text-gray-300">Outcome</label>
            <div
              className="flex items-center gap-1.5"
              role="radiogroup"
              aria-label="Filter by outcome"
            >
              <button
                onClick={() =>
                  setFilters((prev) => ({ ...prev, selectedOutcome: null }))
                }
                className={`text-xs px-2.5 py-1 rounded transition-colors ${
                  filters.selectedOutcome === null
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
                    onClick={() =>
                      setFilters((prev) => ({
                        ...prev,
                        selectedOutcome:
                          filters.selectedOutcome === index ? null : index,
                      }))
                    }
                    className={`text-xs px-2.5 py-1 rounded transition-colors border ${
                      filters.selectedOutcome === index
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
            <div
              className="flex items-center gap-1.5"
              role="radiogroup"
              aria-label="Filter by trade type"
            >
              <button
                onClick={() =>
                  setFilters((prev) => ({ ...prev, selectedTradeType: "all" }))
                }
                className={`text-xs px-2.5 py-1 rounded transition-colors ${
                  filters.selectedTradeType === "all"
                    ? "bg-gray-800 text-gray-200"
                    : "text-gray-400 hover:text-gray-200"
                }`}
                role="radio"
                aria-checked={filters.selectedTradeType === "all"}
              >
                All
              </button>
              <button
                onClick={() =>
                  setFilters((prev) => ({
                    ...prev,
                    selectedTradeType:
                      prev.selectedTradeType === "buy" ? "all" : "buy",
                  }))
                }
                className={`text-xs px-2.5 py-1 rounded transition-colors ${
                  filters.selectedTradeType === "buy"
                    ? "bg-green-900/30 text-green-400"
                    : "text-gray-400 hover:text-gray-200"
                }`}
                role="radio"
                aria-checked={filters.selectedTradeType === "buy"}
              >
                Buy
              </button>
              <button
                onClick={() =>
                  setFilters((prev) => ({
                    ...prev,
                    selectedTradeType:
                      prev.selectedTradeType === "sell" ? "all" : "sell",
                  }))
                }
                className={`text-xs px-2.5 py-1 rounded transition-colors ${
                  filters.selectedTradeType === "sell"
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
                assetSymbol={assetSymbol}
                stableSymbol={stableSymbol}
              />
            ))}
          </tbody>
        </table>
        {filteredEvents.length === 0 && (
          <div className="text-gray-400 p-8 text-center bg-gray-900/50 border border-gray-800/50 rounded-b-lg shadow-md">
            <p className="text-sm">No trades match the current filters</p>
          </div>
        )}
      </div>
    </div>
  );
}
