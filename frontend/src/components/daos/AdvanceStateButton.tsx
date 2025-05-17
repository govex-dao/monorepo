// components/AdvanceStateButton.tsx
import { useAdvanceStateMutation } from "@/mutations/advanceState";

interface AdvanceStateButtonProps {
  proposalId: string;
  escrowId: string;
  assetType: string;
  stableType: string;
  daoId: string;
  proposalState: number;
}

export function AdvanceStateButton({
  proposalId,
  escrowId,
  assetType, // Default value, replace with your default
  stableType, // Default value, replace with your default
  daoId,
  proposalState,
}: AdvanceStateButtonProps) {
  const advanceState = useAdvanceStateMutation();

  const getButtonText = (state: number) => {
    switch (state) {
      case 0:
        return "Initialize trading";
      case 1:
        return "Finalize proposal";
      case 2:
        return "Execute proposal";
      case 3:
        return null;
    }
  };

  if (getButtonText(proposalState) === null) {
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
