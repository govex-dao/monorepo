import React, { useState, useEffect, useMemo } from "react";

interface StateHistory {
  id: number;
  proposal_id: string;
  old_state: number;
  new_state: number;
  timestamp: string;
}

interface ProposalStateManagerProps {
  currentState: number;
  createdAt: string;
  reviewPeriodMs: string;
  tradingPeriodMs?: string;
  stateHistory: StateHistory[];
}

const PRE_MARKET = 0;
const TRADING_STARTED = 1;
const FINALIZED = 2;
const EXECUTED = 3;

const formatRemainingTime = (ms: number): string => {
  if (ms <= 0) {
    return "00d 00h 00m 00s";
  }

  const totalSeconds = Math.floor(ms / 1000);
  const days = Math.floor(totalSeconds / (3600 * 24));
  const hours = Math.floor((totalSeconds % (3600 * 24)) / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;

  const d = String(days).padStart(2, "0");
  const h = String(hours).padStart(2, "0");
  const m = String(minutes).padStart(2, "0");
  const s = String(seconds).padStart(2, "0");

  return `${d}d ${h}h ${m}m ${s}s`;
};

const ProposalStateManager: React.FC<ProposalStateManagerProps> = ({
  currentState,
  createdAt,
  reviewPeriodMs: reviewPeriodMsString,
  tradingPeriodMs: tradingPeriodMsString,
  stateHistory,
}) => {
  const [timeLeft, setTimeLeft] = useState<number>(0);
  const [label, setLabel] = useState<string>("");
  const [additionalMessage, setAdditionalMessage] = useState<string | null>(
    null,
  );
  const [isTimerVisible, setIsTimerVisible] = useState<boolean>(false);

  const parsedCreatedAtMs = useMemo(() => Number(createdAt), [createdAt]);
  const parsedReviewPeriodMs = useMemo(
    () => Number(reviewPeriodMsString),
    [reviewPeriodMsString],
  );
  const parsedTradingPeriodMs = useMemo(
    () => (tradingPeriodMsString ? Number(tradingPeriodMsString) : null),
    [tradingPeriodMsString],
  );

  useEffect(() => {
    let targetTimeMs: number | null = null;
    let currentTimerLabel = "";
    let showTimer = false;
    let newAdditionalMessageOnEnd: string | null = null;

    const now = Date.now();

    if (currentState === EXECUTED) {
      showTimer = false;
    } else if (currentState === FINALIZED) {
      showTimer = false;
    } else if (currentState === PRE_MARKET) {
      if (!isNaN(parsedCreatedAtMs) && !isNaN(parsedReviewPeriodMs)) {
        targetTimeMs = parsedCreatedAtMs + parsedReviewPeriodMs;
        const timeRemaining = targetTimeMs - now;

        if (timeRemaining > 0) {
          currentTimerLabel = "Trading Starts In:";
          showTimer = true;
        } else {
          // Time has passed, show button
          newAdditionalMessageOnEnd = "Ready to initialize trading";
          showTimer = false;
        }
      } else {
        console.warn(
          "Invalid createdAt or reviewPeriodMs for PRE_MARKET timer.",
        );
        showTimer = false;
      }
    } else if (currentState === TRADING_STARTED) {
      if (
        parsedTradingPeriodMs !== null &&
        !isNaN(parsedTradingPeriodMs) &&
        parsedTradingPeriodMs > 0
      ) {
        const tradingStartEvent = [...stateHistory]
          .sort((a, b) => Number(b.timestamp) - Number(a.timestamp))
          .find((event) => event.new_state === TRADING_STARTED);

        if (tradingStartEvent && tradingStartEvent.timestamp) {
          const actualTradingStartTimeMs = Number(tradingStartEvent.timestamp);
          if (!isNaN(actualTradingStartTimeMs)) {
            targetTimeMs = actualTradingStartTimeMs + parsedTradingPeriodMs;
            const timeRemaining = targetTimeMs - now;

            if (timeRemaining > 0) {
              currentTimerLabel = "Trading Ends In:";
              showTimer = true;
            } else {
              // Time has passed, show button
              newAdditionalMessageOnEnd = "Ready to finalize";
              showTimer = false;
            }
          } else {
            console.warn(
              "Invalid timestamp for TRADING_STARTED event in stateHistory.",
            );
            showTimer = false;
          }
        } else {
          console.warn(
            "TRADING_STARTED event not found or invalid in stateHistory.",
          );
          showTimer = false;
        }
      } else {
        showTimer = false;
        if (parsedTradingPeriodMs === null) {
          console.warn(
            "Trading period (tradingPeriodMs) is not provided for TRADING_STARTED state.",
          );
        } else {
          console.warn(
            "Trading period (tradingPeriodMs) is zero or invalid for TRADING_STARTED state.",
          );
        }
      }
    } else {
      showTimer = false;
    }

    setIsTimerVisible(showTimer);
    setLabel(currentTimerLabel);
    setAdditionalMessage(showTimer ? null : newAdditionalMessageOnEnd);

    if (showTimer && targetTimeMs !== null) {
      const updateTimer = () => {
        const currentTime = Date.now();
        const remaining = Math.max(0, targetTimeMs! - currentTime);
        setTimeLeft(remaining);

        if (remaining === 0) {
          setAdditionalMessage(newAdditionalMessageOnEnd);
          setIsTimerVisible(false);
        }
      };

      updateTimer();
      const intervalId = setInterval(updateTimer, 1000);
      return () => clearInterval(intervalId);
    } else {
      setTimeLeft(0);
    }
  }, [
    currentState,
    parsedCreatedAtMs,
    parsedReviewPeriodMs,
    parsedTradingPeriodMs,
    stateHistory,
  ]);

  return (
    <div className="text-center">
      {isTimerVisible && (
        <>
          <p className="text-xs text-gray-400 mb-0.5">{label}</p>
          <p className="text-2xl font-mono font-semibold text-gray-400 tracking-wide">
            {formatRemainingTime(timeLeft)}
          </p>
        </>
      )}

      {additionalMessage && (
        <p className="text-xs text-blue-200 mt-1 mb-3">{additionalMessage}</p>
      )}
    </div>
  );
};

export default ProposalStateManager;
