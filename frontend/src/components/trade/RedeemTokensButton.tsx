import { useRedeemTokensMutation } from "@/mutations/redeemTokens";

interface RedeemTokensButtonProps {
  userTokens: {
    id: string;
    outcome: number;
    balance: string;
    asset_type: number;
  }[];
  winning_outcome: string | null;
  current_state: number;
  escrow: string;
  asset_type: string;
  stable_type: string;
  outcome_count: string;
}

export function RedeemTokensButton({
  userTokens,
  winning_outcome,
  current_state,
  escrow,
  asset_type,
  stable_type,
  outcome_count,
}: RedeemTokensButtonProps) {
  const redeemTokens = useRedeemTokensMutation();
  const buttonStyle =
    "px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-full text-sm font-medium disabled:opacity-50 disabled:cursor-not-allowed transition-colors";
    console.log(  userTokens,
      winning_outcome,
      current_state,
      escrow,
      asset_type,
      stable_type,
      outcome_count)
  // Do not render the button if current_state is 0.
  if (current_state === 0) {
    return null;
  }

  // Set button text based on current_state.
  const buttonLabel =
    current_state === 1
      ? "Recombine tokens"
      : current_state >= 2
      ? "Redeem tokens"
      : "";
  console.log(        userTokens,
    winning_outcome,
    current_state,
    escrow,
    asset_type,
    stable_type,
    outcome_count)
  const handleRedeem = async () => {
    try {
      await redeemTokens.mutateAsync({
        userTokens,
        winning_outcome,
        current_state,
        escrow,
        asset_type,
        stable_type,
        outcome_count,
      });
    } catch (error) {
      console.error("Error redeeming tokens:", error);
    }
  };
  console.log(userTokens)
  return (

    <button
      onClick={handleRedeem}
      disabled={redeemTokens.isPending}
      className={buttonStyle}
    >
      {redeemTokens.isPending ? "Redeeming..." : buttonLabel}
    </button>
  );
}
