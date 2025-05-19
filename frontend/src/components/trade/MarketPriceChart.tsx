import React, { useEffect, useRef, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import {
  createChart,
  ISeriesApi,
  Time,
  ColorType,
  PriceScaleMode,
} from "lightweight-charts";
import { CONSTANTS } from "@/constants";
import TimeRangeSelector from "./TimeRangeSelector";
import TwapLegend from "./TwapLegend";

interface SwapEvent {
  price: string;
  timestamp: string;
  is_buy: boolean;
  amount_in: string;
  outcome: number;
  asset_reserve: string; // Added
  stable_reserve: string; // Added
}

interface StateChange {
  id: number;
  proposal_id: string;
  old_state: number;
  new_state: number;
  timestamp: string;
}

interface StateHistoryResponse {
  data: StateChange[];
}

interface MarketPriceChartProps {
  proposalId: string;
  assetValue: string;
  stableValue: string;
  asset_decimals: number;
  stable_decimals: number;
  currentState: number;
  outcome_count: string;
  outcome_messages: string[];
  initial_outcome_amounts?: string[];
  twaps: string[] | null;
  twap_threshold: string;
  winning_outcome: string | null;
  swapEvents?: SwapEvent[];
  swapError?: Error;
}

const hslToHex = (h: number, s: number, l: number): string => {
  s /= 100;
  l /= 100;

  const k = (n: number) => (n + h / 30) % 12;
  const a = s * Math.min(l, 1 - l);
  const f = (n: number) =>
    l - a * Math.max(Math.min(k(n) - 3, 9 - k(n), 1), -1);

  const toHex = (x: number) =>
    Math.round(x * 255)
      .toString(16)
      .padStart(2, "0");

  return `#${toHex(f(0))}${toHex(f(8))}${toHex(f(4))}`;
};

const CustomLegend = ({ payload }: { payload?: any[] }) => (
  <div
    style={{
      display: "flex",
      justifyContent: "flex-end",
      backgroundColor: "#111113",
      padding: "5px 10px",
      borderRadius: "4px",
    }}
  >
    {payload?.map((entry, index) => (
      <div
        key={`item-${index}`}
        style={{
          display: "flex",
          alignItems: "center",
          marginRight: "15px",
        }}
      >
        <svg width="16" height="16" style={{ marginRight: "8px" }}>
          <rect
            x="0"
            y="0"
            width="16"
            height="16"
            rx="4"
            ry="4"
            fill={entry.color}
          />
        </svg>
        <span style={{ color: "rgb(209, 213, 219)" }}>{entry.value}</span>
      </div>
    ))}
  </div>
);

const MarketPriceChart = ({
  proposalId,
  assetValue,
  stableValue,
  asset_decimals,
  stable_decimals,
  currentState,
  outcome_count,
  outcome_messages,
  initial_outcome_amounts,
  twaps,
  twap_threshold,
  winning_outcome,
  swapEvents,
  swapError,
}: MarketPriceChartProps) => {
  const chartContainerRef = useRef<HTMLDivElement | null>(null);
  const chartRef = useRef<ReturnType<typeof createChart> | null>(null);
  const seriesRefs = useRef<ISeriesApi<"Line">[]>([]);
  const [selectedRange, setSelectedRange] = useState("MAX");
  const decimalAdjustmentFactor = Math.pow(
    10,
    asset_decimals - stable_decimals,
  );
  const handleRangeSelect = (range: string) => {
    setSelectedRange(range);
    if (!chartRef.current) return;

    const endTime =
      currentState === 1
        ? Math.floor(Date.now() / 1000)
        : Math.floor(
            new Date(Number(tradingEnd || Date.now())).getTime() / 1000,
          );

    const startTime = getTimeRangeStart(range, endTime);

    chartRef.current.timeScale().setVisibleRange({
      from: startTime as Time,
      to: endTime as Time,
    });
  };

  useEffect(() => {
    if (!chartContainerRef.current || !chartRef.current) return;

    const handleResize = () => {
      if (chartRef.current && chartContainerRef.current) {
        const { clientWidth } = chartContainerRef.current;
        chartRef.current.applyOptions({
          width: clientWidth,
        });
        chartRef.current.timeScale().fitContent();
      }
    };

    // Create ResizeObserver for container size changes (including zoom)
    const resizeObserver = new ResizeObserver((entries) => {
      const { width } = entries[0].contentRect;
      if (chartRef.current) {
        chartRef.current.applyOptions({ width });
        chartRef.current.timeScale().fitContent();
      }
    });

    // Observe the container
    resizeObserver.observe(chartContainerRef.current);

    window.addEventListener("resize", handleResize);
    return () => {
      window.removeEventListener("resize", handleResize);
      resizeObserver.disconnect();
    };
  }, []);

  // Fetch state changes
  const { data: stateChanges, error: stateError } =
    useQuery<StateHistoryResponse>({
      queryKey: ["stateHistory", proposalId],
      queryFn: async () => {
        const response = await fetch(
          `${CONSTANTS.apiEndpoint}proposals/${proposalId}/state-history`,
        );
        if (!response.ok) throw new Error("Failed to fetch state history");
        return response.json();
      },
    });

  interface ChartDataPoint {
    time: number;
    [key: `market${number}`]: number; // This allows for dynamic market0, market1, etc keys
  }

  const tradingStart = stateChanges?.data?.find(
    (change) => change.old_state === 0 && change.new_state === 1,
  )?.timestamp;

  const tradingEnd = stateChanges?.data?.find(
    (change) => change.old_state === 1 && change.new_state === 2,
  )?.timestamp;

  // Calculate initial prices either from the provided amounts or fallback to default
  const getInitialPrices = () => {
    const numOutcomes = Number(outcome_count);
    const adjustmentFactor = Math.pow(10, asset_decimals - stable_decimals); // Use it here

    if (
      initial_outcome_amounts &&
      initial_outcome_amounts.length >= numOutcomes * 2
    ) {
      const prices = Array.from({ length: numOutcomes }, (_, i) => {
        const assetAmount = BigInt(initial_outcome_amounts[i * 2] || "0");
        const stableAmount = BigInt(initial_outcome_amounts[i * 2 + 1] || "0");

        if (assetAmount > 0n && stableAmount > 0n) {
          const rawRatio = Number(stableAmount) / Number(assetAmount);
          return rawRatio * adjustmentFactor; // Apply adjustment
        }
        const fallbackRawRatio =
          BigInt(assetValue) === 0n
            ? 0
            : Number(BigInt(stableValue)) / Number(BigInt(assetValue));
        return fallbackRawRatio * adjustmentFactor; // Apply adjustment
      });
      return prices;
    }

    const defaultRawRatio =
      BigInt(assetValue) === 0n
        ? 0
        : Number(BigInt(stableValue)) / Number(BigInt(assetValue));
    const defaultPrice = defaultRawRatio * adjustmentFactor; // Apply adjustment
    return Array(numOutcomes).fill(defaultPrice);
  };

  const initialPrices = getInitialPrices();

  const chartData = React.useMemo(() => {
    if (!swapEvents || !tradingStart) return [];

    const adjustmentFactor = Math.pow(10, asset_decimals - stable_decimals);
    // First, create an array of actual price updates with timestamps
    const priceUpdates = [
      {
        time: Math.floor(new Date(Number(tradingStart)).getTime() / 1000),
        prices: initialPrices,
      },
    ];

    // Add all price updates from events
    [...swapEvents]
      .sort((a, b) => Number(a.timestamp) - Number(b.timestamp))
      .forEach((event) => {
        const rawEventPriceOnChain = Number(BigInt(event.price));
        const atomicRatio = rawEventPriceOnChain / 1e12;
        const time = Math.floor(
          new Date(Number(event.timestamp)).getTime() / 1000,
        );
        const priceValue = atomicRatio * adjustmentFactor;

        // Copy last known prices
        const lastPrices = [...priceUpdates[priceUpdates.length - 1].prices];
        // Update the specific outcome's price
        lastPrices[event.outcome] = priceValue;

        priceUpdates.push({ time, prices: lastPrices });
      });

    // Calculate time range
    const startTime = Math.floor(
      new Date(Number(tradingStart)).getTime() / 1000,
    );
    const endTime =
      currentState === 1
        ? Math.floor(Date.now() / 1000) // Use current time if still trading
        : tradingEnd
          ? Math.floor(new Date(Number(tradingEnd)).getTime() / 1000)
          : Math.floor(
              new Date(
                Number(
                  swapEvents[swapEvents.length - 1]?.timestamp || tradingStart,
                ),
              ).getTime() / 1000,
            );

    const FIVE_MIN = 300; // 5 minutes in seconds
    const sampledData: ChartDataPoint[] = [];

    // Generate a point every 5 minutes for the entire range
    for (let time = startTime; time <= endTime; time += FIVE_MIN) {
      // Find the last price update before or at this time
      const lastUpdate = priceUpdates
        .filter((update) => update.time <= time)
        .pop();

      if (lastUpdate) {
        sampledData.push({
          time,
          ...Object.fromEntries(
            lastUpdate.prices.map((price, i) => [`market${i}`, price]),
          ),
        } as ChartDataPoint);
      }
    }

    // Ensure we have the exact start and end points
    if (sampledData[0]?.time !== startTime) {
      sampledData.unshift({
        time: startTime,
        ...Object.fromEntries(
          priceUpdates[0].prices.map((price, i) => [`market${i}`, price]),
        ),
      } as ChartDataPoint);
    }

    const lastKnownPrices = priceUpdates[priceUpdates.length - 1].prices;
    if (sampledData[sampledData.length - 1]?.time !== endTime) {
      sampledData.push({
        time: endTime,
        ...Object.fromEntries(
          lastKnownPrices.map((price, i) => [`market${i}`, price]),
        ),
      } as ChartDataPoint);
    }

    return sampledData;
  }, [
    swapEvents,
    initialPrices,
    tradingStart,
    tradingEnd,
    decimalAdjustmentFactor,
    outcome_count,
    currentState,
  ]);

  const colors = React.useMemo(() => {
    const outcomeCount = Number(outcome_count);

    if (outcomeCount === 1) {
      return ["#ef4444"];
    }
    if (outcomeCount === 2) {
      return ["#ef4444", "#22c55e"];
    }

    const generateDistantColors = (count: number) => {
      const startHue = 120;
      const endHue = 300;
      const step = (endHue - startHue) / (count - 1);

      return Array.from({ length: count - 1 }, (_, i) => {
        const hue = startHue + i * step;
        return hslToHex(hue, 100, 50);
      });
    };

    const additionalColors = generateDistantColors(outcomeCount);
    return ["#ef4444", ...additionalColors];
  }, [outcome_count]);

  const legendPayload = React.useMemo(
    () =>
      outcome_messages.map((message, index) => ({
        color: colors[index],
        value: message,
      })),
    [colors, outcome_messages],
  );

  const getTimeRangeStart = (range: string, endTime: number) => {
    switch (range) {
      case "1H":
        return endTime - 3600;
      case "4H":
        return endTime - 4 * 3600;
      case "1D":
        return endTime - 24 * 3600;
      case "MAX":
      default:
        return Math.floor(new Date(Number(tradingStart)).getTime() / 1000);
    }
  };

  useEffect(() => {
    if (!chartContainerRef.current || !chartData.length) {
      return;
    }

    const chart = createChart(chartContainerRef.current, {
      width: chartContainerRef.current.clientWidth,
      height: 400,
      layout: {
        background: { type: ColorType.Solid, color: "#111113" },
        textColor: "#ffffff",
        fontSize: 14,
      },
      grid: {
        horzLines: { color: "transparent" },
        vertLines: { color: "transparent" },
      },
      timeScale: {
        timeVisible: true,
        secondsVisible: true,
        borderColor: "transparent",
        rightOffset: 0,
        fixLeftEdge: true,
        fixRightEdge: true,
        rightBarStaysOnScroll: true,
      },
      rightPriceScale: {
        borderColor: "transparent",
        autoScale: false,
        mode: PriceScaleMode.Normal,
        minimumWidth: 50,
        scaleMargins: {
          top: 0.1,
          bottom: 0.1,
        },
      },
      handleScroll: false,
      handleScale: false,
    });

    chartRef.current = chart;

    const numOutcomes = Number(outcome_count);
    const series = Array.from({ length: numOutcomes }, (_, i) => {
      const lineSeries = chart.addLineSeries({
        color: colors[i],
        lineWidth: 2,
        title: outcome_messages[i],
        priceLineVisible: false,
        priceFormat: {
          type: "price",
          precision: 5,
          minMove: 0.00001,
        },
      });

      lineSeries.setData(
        chartData.map((point) => ({
          time: point.time as Time,
          value: point[`market${i}`],
        })),
      );

      return lineSeries;
    });

    seriesRefs.current = series;

    const endTime =
      currentState === 1
        ? Math.floor(Date.now() / 1000)
        : Math.floor(
            new Date(Number(tradingEnd || Date.now())).getTime() / 1000,
          );

    const startTime = getTimeRangeStart(selectedRange, endTime);

    chart.timeScale().setVisibleRange({
      from: startTime as Time,
      to: endTime as Time,
    });

    return () => {
      chart.remove();
    };
  }, [
    chartData,
    outcome_count,
    outcome_messages,
    colors,
    selectedRange,
    currentState,
    tradingEnd,
  ]);

  const statusMessage = React.useMemo(() => {
    if (swapError) return `Error loading swap data: ${swapError.message}`;
    if (stateError) return `Error loading state data: ${stateError.message}`;

    if (currentState === 0 || !tradingStart)
      return "Trading period not started";
    if (currentState === 2 || (tradingEnd && winning_outcome != null))
      return winning_outcome
        ? `Trading period finished, winning outcome is: ${outcome_messages[Number(winning_outcome)]}`
        : "Trading period finished";
    if (currentState === 1 && chartData.length <= 1)
      return "No trading activity yet";
    return "";
  }, [
    currentState,
    tradingStart,
    tradingEnd,
    chartData,
    swapError,
    stateError,
  ]);
  return (
    <div className="w-full py-0 my-0">
      {(tradingStart || tradingEnd) && !swapError && !stateError && (
        <div className="flex flex-col md:flex-row justify-between items-center gap-4 mb-2">
          <div>
            <TwapLegend
              twaps={twaps}
              twap_threshold={twap_threshold}
              outcomeMessages={outcome_messages}
              asset_decimals={asset_decimals}
              stable_decimals={stable_decimals}
            />
          </div>
          <TimeRangeSelector
            selectedRange={selectedRange}
            onRangeSelect={handleRangeSelect}
          />
        </div>
      )}
      <div className="h-106 relative" style={{ overflow: "hidden" }}>
        {swapError || stateError ? (
          <div className="h-full flex items-center justify-center text-red-500">
            {statusMessage}
          </div>
        ) : chartData.length > 1 ? (
          <div
            ref={chartContainerRef}
            style={{ width: "100%", height: "100%" }}
          />
        ) : (
          <div className="h-full flex items-center justify-center">
            {statusMessage}
          </div>
        )}
      </div>
      {(tradingStart || tradingEnd) && !swapError && !stateError && (
        <CustomLegend payload={legendPayload} />
      )}
      {statusMessage && chartData.length > 1 && !swapError && !stateError && (
        <div className="text-center mt-2 ">{statusMessage}</div>
      )}
    </div>
  );
};

export default MarketPriceChart;
