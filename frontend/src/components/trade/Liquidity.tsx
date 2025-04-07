import React from "react";
import { WithdrawProposerLiquidityButton } from "./WithdrawProposerLiquidityButton";
import { TokenInfo } from "./TradeForm";

interface LiquidityProps {
  userTokens: TokenInfo[];
  winning_outcome: number | null;
  current_state: number;
  escrow: string;
  asset_type: string;
  stable_type: string;
  proposalId: string;
}

const Liquidity: React.FC<LiquidityProps> = ({
  winning_outcome,
  current_state,
  escrow,
  asset_type,
  stable_type,
  proposalId,
}) => {
  return (
    <div className="p-6">
      {winning_outcome !== null ? (
        <WithdrawProposerLiquidityButton
          proposalId={proposalId}
          escrow={escrow}
          asset_type={asset_type}
          stable_type={stable_type}
          winning_outcome={winning_outcome}
          current_state={current_state}
        />
      ) : (
        <div>No liquidity operation available</div>
      )}
    </div>
  );
};

export default Liquidity;
