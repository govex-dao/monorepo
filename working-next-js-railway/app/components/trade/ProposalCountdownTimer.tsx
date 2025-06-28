// src/components/ProposalCountdownTimer.tsx
import React, { useState, useEffect, useMemo } from "react";

// Define or import StateHistory if it's in a shared types file
interface StateHistory {
  id: number;
  proposal_id: string;
  old_state: number;
  new_state: number;
  timestamp: string; // Milliseconds as string e.g. "1678886400000"
}

interface ProposalCountdownTimerProps {
  currentState: number;
  createdAt: string; // Proposal creation timestamp (milliseconds as string)
  reviewPeriodMs: string; // Duration of pre-market/review period (milliseconds as string)
  tradingPeriodMs?: string; // Duration of trading period (milliseconds as string), optional
  stateHistory: StateHistory[];
}

const PRE_MARKET = 0;
const TRADING_STARTED = 1;
const FINALIZED = 2;

// Formats remaining time as DDd HHh MMm SSs
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

const ProposalCountdownTimer: React.FC<ProposalCountdownTimerProps> = ({
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
    // Explicitly declare newAdditionalMessage here for clarity within useEffect scope
    let newAdditionalMessageOnEnd: string | null = null;

    if (currentState === FINALIZED) {
      showTimer = false;
    } else if (currentState === PRE_MARKET) {
      if (!isNaN(parsedCreatedAtMs) && !isNaN(parsedReviewPeriodMs)) {
        targetTimeMs = parsedCreatedAtMs + parsedReviewPeriodMs;
        currentTimerLabel = "Trading Starts In:";
        newAdditionalMessageOnEnd = "Ready to initialize trading";
        showTimer = true;
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
        // Find the timestamp for the actual transition to TRADING_STARTED state
        const tradingStartEvent = [...stateHistory] // Create a shallow copy before sorting
          .sort((a, b) => Number(b.timestamp) - Number(a.timestamp)) // Sort descending by time
          .find((event) => event.new_state === TRADING_STARTED); // Find the latest

        if (tradingStartEvent && tradingStartEvent.timestamp) {
          const actualTradingStartTimeMs = Number(tradingStartEvent.timestamp);
          if (!isNaN(actualTradingStartTimeMs)) {
            targetTimeMs = actualTradingStartTimeMs + parsedTradingPeriodMs;
            currentTimerLabel = "Trading Ends In:";
            newAdditionalMessageOnEnd = "Ready to finalize";
            showTimer = true;
          } else {
            console.warn(
              "Invalid timestamp for TRADING_STARTED event in stateHistory.",
            );
            showTimer = false;
          }
        } else {
          console.warn(
            "TRADING_STARTED event not found or invalid in stateHistory. Cannot calculate trading end time.",
          );
          showTimer = false;
        }
      } else {
        // Trading period not defined, invalid, or zero.
        // The "Ends In" timer cannot be shown.
        showTimer = false;
        if (parsedTradingPeriodMs === null) {
          console.warn(
            "Trading period (tradingPeriodMs) is not provided for TRADING_STARTED state. 'Ends in' timer will be hidden.",
          );
        } else {
          console.warn(
            "Trading period (tradingPeriodMs) is zero or invalid for TRADING_STARTED state. 'Ends in' timer will be hidden.",
          );
        }
      }
    } else {
      showTimer = false; // Hide for any other unknown/unhandled states
    }

    setIsTimerVisible(showTimer);
    setLabel(currentTimerLabel);
    setAdditionalMessage(null); // Reset on each effect run before timer logic

    if (showTimer && targetTimeMs !== null) {
      const updateTimer = () => {
        const now = Date.now();
        const remaining = Math.max(0, targetTimeMs! - now);
        setTimeLeft(remaining);

        if (remaining === 0) {
          setAdditionalMessage(newAdditionalMessageOnEnd);
        } else {
          setAdditionalMessage(null); // Clear message if time is still running
        }
      };

      updateTimer(); // Initial call
      const intervalId = setInterval(updateTimer, 1000);
      return () => clearInterval(intervalId); // Cleanup interval
    } else {
      // If timer is not shown or targetTimeMs is null for a state that should have one
      setTimeLeft(0);
      if (showTimer && targetTimeMs === null) {
        // e.g. TRADING_STARTED but issue with history
        setAdditionalMessage("Cannot determine target time.");
      }
    }
  }, [
    currentState,
    parsedCreatedAtMs,
    parsedReviewPeriodMs,
    parsedTradingPeriodMs,
    stateHistory, // Essential dependency
  ]);

  if (!isTimerVisible) {
    return null; // Hide timer completely
  }

  return (
    <div className="text-center">
      {" "}
      {/* Removed border, background, shadow for transparent bg & no box */}
      <p className="text-xs text-gray-400 mb-0.5">{label}</p>
      <p className="text-2xl font-mono font-semibold text-gray-400 tracking-wide">
        {" "}
        {/* Time color changed to blue */}
        {formatRemainingTime(timeLeft)}
      </p>
      {additionalMessage && (
        <p className="text-xs text-blue-200 mt-1">
          {/* Text color changed to slightly grayy white */}
          {additionalMessage}
        </p>
      )}
    </div>
  );
};

export default ProposalCountdownTimer;
