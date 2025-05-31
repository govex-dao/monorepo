import React, { useEffect, useRef, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import {
  createChart,
  ISeriesApi,
  Time,
  ColorType,
  TickMarkType,
  PriceScaleMode,
  LineSeries, // Added: Import LineSeries for v5
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
  const seriesRefs = useRef<ISeriesApi<"Line">[]>([]); // Type ISeriesApi<"Line"> remains appropriate
  const [selectedRange, setSelectedRange] = useState("MAX");

  const userTimezoneOffsetSeconds = new Date().getTimezoneOffset() * 60;

  const decimalAdjustmentFactor = Math.pow(
    10,
    asset_decimals - stable_decimals,
  );

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

  const tradingStart = stateChanges?.data?.find(
    (change) => change.old_state === 0 && change.new_state === 1,
  )?.timestamp;

  const tradingEnd = stateChanges?.data?.find(
    (change) => change.old_state === 1 && change.new_state === 2,
  )?.timestamp;

  const getTimeRangeStart = (range: string, endTime: number): number => {
    const originalTradingStartUTC = tradingStart ? Math.floor(new Date(Number(tradingStart)).getTime() / 1000) : 0;
    const adjustedTradingStart = originalTradingStartUTC ? originalTradingStartUTC - userTimezoneOffsetSeconds : endTime;

    switch (range) {
      case "1H":
        return endTime - 3600;
      case "4H":
        return endTime - 4 * 3600;
      case "1D":
        return endTime - 24 * 3600;
      case "MAX":
      default:
        return adjustedTradingStart;
    }
  };

  const handleRangeSelect = (range: string) => {
    setSelectedRange(range);
    if (!chartRef.current) return;

    const originalUTCEndTime =
      currentState === 1
        ? Math.floor(Date.now() / 1000)
        : Math.floor(
            new Date(Number(tradingEnd || Date.now())).getTime() / 1000,
          );

    const adjustedEndTime = originalUTCEndTime - userTimezoneOffsetSeconds;
    const adjustedStartTime = getTimeRangeStart(range, adjustedEndTime);

    chartRef.current.timeScale().setVisibleRange({
      from: adjustedStartTime as Time,
      to: adjustedEndTime as Time,
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

    const resizeObserver = new ResizeObserver((entries) => {
      const { width } = entries[0].contentRect;
      if (chartRef.current) {
        chartRef.current.applyOptions({ width });
        chartRef.current.timeScale().fitContent();
      }
    });

    if (chartContainerRef.current) {
        resizeObserver.observe(chartContainerRef.current);
    }
    
    window.addEventListener("resize", handleResize);
    return () => {
      window.removeEventListener("resize", handleResize);
      if (chartContainerRef.current) { // Ensure current is not null before disconnecting
        resizeObserver.disconnect();
      }
    };
  }, []);


  interface ChartDataPoint {
    time: number;
    [key: `market${number}`]: number;
  }

  const getInitialPrices = () => {
    const numOutcomes = Number(outcome_count);
    const adjustmentFactor = Math.pow(10, asset_decimals - stable_decimals);

    if (
      initial_outcome_amounts &&
      initial_outcome_amounts.length >= numOutcomes * 2
    ) {
      const prices = Array.from({ length: numOutcomes }, (_, i) => {
        const assetAmount = BigInt(initial_outcome_amounts[i * 2] || "0");
        const stableAmount = BigInt(initial_outcome_amounts[i * 2 + 1] || "0");

        if (assetAmount > 0n && stableAmount > 0n) {
          const rawRatio = Number(stableAmount) / Number(assetAmount);
          return rawRatio * adjustmentFactor;
        }
        const fallbackRawRatio =
          BigInt(assetValue) === 0n
            ? 0
            : Number(BigInt(stableValue)) / Number(BigInt(assetValue));
        return fallbackRawRatio * adjustmentFactor;
      });
      return prices;
    }

    const defaultRawRatio =
      BigInt(assetValue) === 0n
        ? 0
        : Number(BigInt(stableValue)) / Number(BigInt(assetValue));
    const defaultPrice = defaultRawRatio * adjustmentFactor;
    return Array(numOutcomes).fill(defaultPrice);
  };

  const initialPrices = getInitialPrices();

const chartData = React.useMemo(() => {
    if (!tradingStart) return []; 

    const getAdjustedTime = (utcSeconds: number): number => utcSeconds - userTimezoneOffsetSeconds;

    const adjustmentFactor = Math.pow(10, asset_decimals - stable_decimals);
    const originalTradingStartUTC = Math.floor(new Date(Number(tradingStart)).getTime() / 1000);

    const priceUpdatesAtEventTime: { time: number; prices: number[] }[] = [];

    if (initialPrices) {
      priceUpdatesAtEventTime.push({
        time: getAdjustedTime(originalTradingStartUTC),
        prices: initialPrices,
      });
    }

    const sortedSwapEvents = swapEvents ? [...swapEvents].sort((a, b) => Number(a.timestamp) - Number(b.timestamp)) : [];
    let lastKnownPricesFromEvents = initialPrices ? [...initialPrices] : Array(Number(outcome_count)).fill(0);

    sortedSwapEvents.forEach((event) => {
      const rawEventPriceOnChain = Number(BigInt(event.price));
      const atomicRatio = rawEventPriceOnChain / 1e12;
      const originalEventTimeUTC = Math.floor(new Date(Number(event.timestamp)).getTime() / 1000);
      const priceValue = atomicRatio * adjustmentFactor;

      const currentEventPrices = [...lastKnownPricesFromEvents];
      currentEventPrices[event.outcome] = priceValue;
      lastKnownPricesFromEvents = currentEventPrices;

      priceUpdatesAtEventTime.push({
        time: getAdjustedTime(originalEventTimeUTC),
        prices: currentEventPrices,
      });
    });
    
    priceUpdatesAtEventTime.sort((a,b) => a.time - b.time);

    const seriesAdjustedStartTime = getAdjustedTime(originalTradingStartUTC);
    const seriesAdjustedEndTime = getAdjustedTime(
      currentState === 1
        ? Math.floor(Date.now() / 1000)
        : tradingEnd
          ? Math.floor(new Date(Number(tradingEnd)).getTime() / 1000)
          : priceUpdatesAtEventTime.length > 0 
            ? priceUpdatesAtEventTime[priceUpdatesAtEventTime.length - 1].time 
            : seriesAdjustedStartTime 
    );

    const FIVE_MIN_SECONDS = 300;
    const finalSampledData: ChartDataPoint[] = [];

    if (priceUpdatesAtEventTime.length > 0 && priceUpdatesAtEventTime[0].time === seriesAdjustedStartTime) {
        finalSampledData.push({
            time: seriesAdjustedStartTime,
            ...Object.fromEntries(
                priceUpdatesAtEventTime[0].prices.map((price, i) => [`market${i}`, price])
            ),
        } as ChartDataPoint);
    } else if (initialPrices) { 
         finalSampledData.push({
            time: seriesAdjustedStartTime,
            ...Object.fromEntries(
                initialPrices.map((price, i) => [`market${i}`, price])
            ),
        } as ChartDataPoint);
    }

    let nextSampleTime = Math.ceil(seriesAdjustedStartTime / FIVE_MIN_SECONDS) * FIVE_MIN_SECONDS;
    if (nextSampleTime < seriesAdjustedStartTime) { 
        nextSampleTime += FIVE_MIN_SECONDS;
    }
    if (finalSampledData.length > 0 && nextSampleTime === finalSampledData[0].time) {
        nextSampleTime += FIVE_MIN_SECONDS;
    }
    
    for (let currentTime = nextSampleTime; currentTime < seriesAdjustedEndTime; currentTime += FIVE_MIN_SECONDS) {
      const relevantPriceUpdate = [...priceUpdatesAtEventTime]
        .reverse()
        .find(update => update.time <= currentTime);

      if (relevantPriceUpdate) {
        finalSampledData.push({
          time: currentTime, 
          ...Object.fromEntries( 
            relevantPriceUpdate.prices.map((price, i) => [`market${i}`, price])
          ),
        } as ChartDataPoint);
      } else if (finalSampledData.length > 0) { 
        finalSampledData.push({
          time: currentTime,
           ...Object.fromEntries(
            Object.keys(finalSampledData[finalSampledData.length-1])
                .filter(k => k.startsWith("market"))
                .map(k => [k, finalSampledData[finalSampledData.length-1][k as keyof ChartDataPoint]])
          ),
        });
      }
    }

    const pricesForFinalPoint = 
      priceUpdatesAtEventTime.length > 0 
        ? priceUpdatesAtEventTime[priceUpdatesAtEventTime.length - 1].prices 
        : initialPrices 
          ? initialPrices 
          : Array(Number(outcome_count)).fill(0);

    const finalPoint: ChartDataPoint = {
        time: seriesAdjustedEndTime,
        ...Object.fromEntries(
            pricesForFinalPoint.map((price, i) => [`market${i}`, price])
        ),
    };

    if (finalSampledData.length === 0 || finalSampledData[finalSampledData.length - 1].time < seriesAdjustedEndTime) {
        finalSampledData.push(finalPoint);
    } else if (finalSampledData[finalSampledData.length - 1].time === seriesAdjustedEndTime) {
        finalSampledData[finalSampledData.length - 1] = finalPoint;
    }
    
    const timeMap = new Map<number, ChartDataPoint>();
    finalSampledData.forEach(point => timeMap.set(point.time, point));
    const uniqueSortedData = Array.from(timeMap.values()).sort((a,b) => a.time - b.time);

    return uniqueSortedData;
  }, [
    swapEvents,
    initialPrices,
    tradingStart,
    tradingEnd,
    decimalAdjustmentFactor, // This was missing in the original dependencies array, added it.
    asset_decimals, // Added for completeness, as it's used in adjustmentFactor
    stable_decimals, // Added for completeness, as it's used in adjustmentFactor
    outcome_count,
    currentState,
    userTimezoneOffsetSeconds,
  ]);

  const colors = React.useMemo(() => {
    const outcomeCount = Number(outcome_count);
    if (outcomeCount === 1) return ["#ef4444"];
    if (outcomeCount === 2) return ["#ef4444", "#22c55e"];
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

  useEffect(() => {
    if (!chartContainerRef.current || !chartData.length) {
      // If chartData is empty, and we have a chart instance, remove it.
      if (chartRef.current) {
        chartRef.current.remove();
        chartRef.current = null;
      }
      return;
    }
    
    // If a chart instance already exists, remove it before creating a new one
    // This can happen if chartData becomes available after an initial empty state
    if (chartRef.current) {
        chartRef.current.remove();
        chartRef.current = null;
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
        tickMarkFormatter: (
          time: Time,
          tickType: TickMarkType,
          locale: string,
        ) => {
          const date = new Date((time as number) * 1000);
          const hours = date.getUTCHours().toString().padStart(2, '0');
          const minutes = date.getUTCMinutes().toString().padStart(2, '0');
          const seconds = date.getUTCSeconds().toString().padStart(2, '0');
          const dayMonthYearDate = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));

          switch (tickType) {
            case TickMarkType.Year:
              return dayMonthYearDate.toLocaleDateString(locale, { year: 'numeric', timeZone: 'UTC' });
            case TickMarkType.Month:
              return dayMonthYearDate.toLocaleDateString(locale, { month: 'short', timeZone: 'UTC' });
            case TickMarkType.DayOfMonth:
              return dayMonthYearDate.toLocaleDateString(locale, { day: 'numeric', month: 'short', timeZone: 'UTC' });
            case TickMarkType.Time:
              return `${hours}:${minutes}`;
            case TickMarkType.TimeWithSeconds:
              return `${hours}:${minutes}:${seconds}`;
            default:
              return `${date.getUTCFullYear()}-${(date.getUTCMonth() + 1).toString().padStart(2, '0')}-${date.getUTCDate().toString().padStart(2, '0')} ${hours}:${minutes}`;
          }
        },
      },
      rightPriceScale: {
        borderColor: "transparent",
        autoScale: true,
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
    seriesRefs.current = Array.from({ length: numOutcomes }, (_, i) => {
      // Updated: Use addSeries with LineSeries type
      const lineSeries = chart.addSeries(LineSeries, {
        color: colors[i],
        lineWidth: 2,
        title: outcome_messages[i],
        priceLineVisible: false,
        priceFormat: {
          type: "price",
          precision: 7,
          minMove: 0.0000001,
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

    const originalUTCEndTime =
      currentState === 1
        ? Math.floor(Date.now() / 1000)
        : Math.floor(
            new Date(Number(tradingEnd || Date.now())).getTime() / 1000,
          );

    const adjustedEndTime = originalUTCEndTime - userTimezoneOffsetSeconds;
    const adjustedStartTime = getTimeRangeStart(selectedRange, adjustedEndTime);

    chart.timeScale().setVisibleRange({
      from: adjustedStartTime as Time,
      to: adjustedEndTime as Time,
    });

    return () => {
      if (chartRef.current) {
        chartRef.current.remove();
        chartRef.current = null;
      }
    };
  }, [
    chartData,
    outcome_count,
    outcome_messages,
    colors,
    selectedRange,
    currentState,
    tradingEnd, // Added tradingEnd to dependency array
    userTimezoneOffsetSeconds, // Added userTimezoneOffsetSeconds to dependency array
    // getTimeRangeStart is defined outside, but depends on tradingStart and userTimezoneOffsetSeconds.
    // Consider if tradingStart needs to be a dep if getTimeRangeStart is memoized or part of this effect.
    // For now, assuming tradingStart doesn't change often enough to warrant re-running this whole effect,
    // as chartData already depends on it.
  ]);

  const statusMessage = React.useMemo(() => {
    if (swapError) return `Error loading swap data: ${swapError.message}`;
    if (stateError) return `Error loading state data: ${stateError.message}`;
    if (currentState === 0 || !tradingStart) return "Trading period not started";
    if (currentState === 2 || (tradingEnd && winning_outcome != null))
      return winning_outcome
        ? `Trading period finished, winning outcome is: ${outcome_messages[Number(winning_outcome)]}`
        : "Trading period finished";
    if (currentState === 1 && chartData.length <= 1) return "No trading activity yet"; // <=1 because initial point might exist
    return "";
  }, [
    currentState,
    tradingStart,
    tradingEnd,
    chartData, // chartData.length dependency
    swapError,
    stateError,
    winning_outcome, // Added winning_outcome
    outcome_messages // Added outcome_messages
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
        ) : chartData.length > 1 || (chartData.length === 1 && tradingStart) ? ( // Show chart if there's at least one data point and trading has started
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
      {statusMessage && (chartData.length > 1 || (chartData.length === 1 && tradingStart)) && !swapError && !stateError && (
        <div className="text-center mt-2 ">{statusMessage}</div>
      )}
    </div>
  );
};

export default MarketPriceChart;