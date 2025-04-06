import { useWithdrawProposerLiquidityMutation } from "@/mutations/useWithdrawProposerLiquidityMutation.ts";

interface WithdrawProposerLiquidityButtonProps {
  proposalId: string;
  escrow: string;
  asset_type: string;
  stable_type: string;
  winning_outcome: number;
  current_state: number;
}

export function WithdrawProposerLiquidityButton({
  proposalId,
  escrow,
  asset_type,
  stable_type,
  winning_outcome,
  current_state,
}: WithdrawProposerLiquidityButtonProps) {
  const withdrawLiquidity = useWithdrawProposerLiquidityMutation();

  // Render only when current_state is exactly 2.
  if (current_state !== 2) {
    return null;
  }

  const buttonStyle =
    "px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-full text-sm font-medium disabled:opacity-50 disabled:cursor-not-allowed transition-colors";

  const handleWithdraw = async () => {
    try {
      await withdrawLiquidity.mutateAsync({
        proposalId,
        escrowId: escrow,
        assetType: asset_type,
        stableType: stable_type,
        winning_outcome,
      });
    } catch (error) {
      console.error("Error withdrawing liquidity:", error);
    }
  };

  return (
    <button
      onClick={handleWithdraw}
      disabled={withdrawLiquidity.isPending}
      className={buttonStyle}
    >
      {withdrawLiquidity.isPending ? "Withdrawing..." : "Withdraw Proposer Liquidity"}
    </button>
  );
}
