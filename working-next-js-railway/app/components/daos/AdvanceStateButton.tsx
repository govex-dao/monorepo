// components/AdvanceStateButton.tsx
import { useAdvanceStateMutation } from '../../mutations/advanceState';
import { useCurrentAccount } from "@mysten/dapp-kit";
import toast from "react-hot-toast";

interface StateHistory {
  id: number;
  proposal_id: string;
  old_state: number;
  new_state: number;
  timestamp: string;
}

interface AdvanceStateButtonProps {
  proposalId: string;
  escrowId: string;
  assetType: string;
  stableType: string;
  daoId: string;
  proposalState: number;
  winningOutcome: string | null;
  createdAt: string;
  reviewPeriodMs: string;
  tradingPeriodMs?: string;
  stateHistory: StateHistory[];
}

export function AdvanceStateButton({
  proposalId,
  escrowId,
  assetType, // Default value, replace with your default
  stableType, // Default value, replace with your default
  daoId,
  proposalState,
  winningOutcome,
  createdAt,
  reviewPeriodMs,
  tradingPeriodMs,
  stateHistory,
}: AdvanceStateButtonProps) {
  const advanceState = useAdvanceStateMutation();
  const currentAccount = useCurrentAccount();

  const getButtonText = (state: number) => {
    switch (state) {
      case 0:
        return "Initialize trading";
      case 1:
        return "Finalize proposal";
      case 2:
        return "Execute proposal";
    }
  };

  // Determine if button should be shown based on state and timing
  const shouldShowButton = () => {
    const now = Date.now();

    if (proposalState === 0) {
      // State 0: Show if current time > review_period_ms + created_at
      const createdAtMs = Number(createdAt);
      const reviewPeriodMsNum = Number(reviewPeriodMs);
      if (!isNaN(createdAtMs) && !isNaN(reviewPeriodMsNum)) {
        return now > createdAtMs + reviewPeriodMsNum;
      }
      return false;
    } else if (proposalState === 1) {
      // State 1: Show if current time > timestamp moved from state 0 to 1 + trading_period_ms
      if (!tradingPeriodMs) return false;

      const tradingStartEvent = stateHistory
        .filter((event) => event.new_state === 1)
        .sort((a, b) => Number(b.timestamp) - Number(a.timestamp))[0];

      if (tradingStartEvent) {
        const tradingStartMs = Number(tradingStartEvent.timestamp);
        const tradingPeriodMsNum = Number(tradingPeriodMs);
        if (!isNaN(tradingStartMs) && !isNaN(tradingPeriodMsNum)) {
          return now > tradingStartMs + tradingPeriodMsNum;
        }
      }
      return false;
    } else if (proposalState === 2) {
      // State 2: Show only if there is no winning outcome
      return winningOutcome === null;
    }

    return false;
  };

  if (!shouldShowButton()) {
    return null;
  }

  const getButtonStyle = (state: number) => {
    switch (state) {
      case 0:
        return "bg-green-700 text-green-100 hover:bg-green-600";
      case 2:
        return "bg-blue-700 text-blue-100 hover:bg-blue-600";
      default:
        return "bg-red-800 text-red-100 hover:bg-red-700";
    }
  };

  const handleAdvanceState = async () => {
    if (!currentAccount) {
      const action = proposalState === 2 ? "execute" : "advance";
      toast.error(`Please connect your wallet to ${action} the proposal`);
      return;
    }

    try {
      await advanceState.mutateAsync({
        proposalId,
        escrowId,
        assetType,
        stableType,
        daoId,
        proposalState,
      });
    } catch (error) {
      console.error("Error advancing state:", error);
    }
  };

  const baseButtonStyle =
    "px-4 py-2 rounded-full text-sm font-medium disabled:opacity-50 disabled:cursor-not-allowed transition-colors";
  const stateStyle = getButtonStyle(proposalState);

  return (
    <button
      onClick={handleAdvanceState}
      disabled={advanceState.isPending}
      className={`${baseButtonStyle} ${stateStyle}`}
    >
      {advanceState.isPending ? "Advancing..." : getButtonText(proposalState)}
    </button>
  );
}

export default AdvanceStateButton;
