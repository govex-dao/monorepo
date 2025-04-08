import React, { useMemo } from "react";
import { RedeemTokensButton } from "./RedeemTokensButton";

interface TokenSectionProps {
  userTokens: {
    id: string;
    outcome: number;
    balance: string;
    asset_type: number;
  }[];
  outcomeMessages: string[];
  winning_outcome: string | null;
  current_state: number;
  escrow: string;
  asset_type: string;
  stable_type: string;
  outcome_count: string;
  asset_decimals: number;
  stable_decimals: number;
  asset_symbol: string;
  stable_symbol: string;
}

interface GroupedToken {
  outcome: number;
  assetBalance: string;
  stableBalance: string;
  assetBalanceFormatted: string;
  stableBalanceFormatted: string;
}

const TokenSection: React.FC<TokenSectionProps> = ({
  userTokens,
  outcomeMessages,
  winning_outcome,
  current_state,
  escrow,
  asset_type,
  stable_type,
  outcome_count,
  asset_decimals = 9,
  stable_decimals = 9,
  asset_symbol = "Asset",
  stable_symbol = "Stable",
}) => {
  const [assetScale, stableScale] = useMemo(() => [
    10 ** asset_decimals, 
    10 ** stable_decimals
  ], [asset_decimals, stable_decimals]);

  const groupedByOutcome = useMemo<GroupedToken[]>(() => {
    const outcomeMap = new Map<
      number,
      { assetBalance: bigint; stableBalance: bigint }
    >();

    userTokens.forEach((token) => {
      if (!outcomeMap.has(token.outcome)) {
        outcomeMap.set(token.outcome, { assetBalance: 0n, stableBalance: 0n });
      }
      const group = outcomeMap.get(token.outcome)!;
      if (token.asset_type === 0) {
        group.assetBalance += BigInt(token.balance);
      } else {
        group.stableBalance += BigInt(token.balance);
      }
    });

    return Array.from(outcomeMap.entries())
      .sort(([aOutcome], [bOutcome]) => aOutcome - bOutcome)
      .map(([outcome, balances]) => {
        // Convert raw balances to human-readable format with proper decimals
        const assetBalanceRaw = balances.assetBalance.toString();
        const stableBalanceRaw = balances.stableBalance.toString();
        
        // Format with proper decimals
        const assetBalanceFormatted = (Number(assetBalanceRaw) / Number(assetScale)).toFixed(asset_decimals);
        const stableBalanceFormatted = (Number(stableBalanceRaw) / Number(stableScale)).toFixed(stable_decimals);
        
        return {
          outcome,
          assetBalance: assetBalanceRaw,
          stableBalance: stableBalanceRaw,
          assetBalanceFormatted,
          stableBalanceFormatted,
        };
      });
  }, [userTokens, assetScale, stableScale, asset_decimals, stable_decimals]);

  return (
    <div className="space-y-2 px-6">
      {groupedByOutcome.length > 0 ? (
        <>
          <RedeemTokensButton
            userTokens={userTokens}
            winning_outcome={winning_outcome}
            current_state={current_state}
            escrow={escrow}
            asset_type={asset_type}
            stable_type={stable_type}
            outcome_count={outcome_count}
          />
          <div className="pl-1 text-gray-300">
            <div className="grid grid-cols-3 gap-4 mb-2 font-semibold">
              <span>Outcome</span>
              <span>{asset_symbol}</span>
              <span>{stable_symbol}</span>
            </div>
            {groupedByOutcome.map((token) => (
              <div key={token.outcome} className="grid grid-cols-3 gap-4 mb-1">
                <span>
                  {outcomeMessages[token.outcome] || `Outcome ${token.outcome}`}
                </span>
                <span>{token.assetBalanceFormatted}</span>
                <span>{token.stableBalanceFormatted}</span>
              </div>
            ))}
          </div>
        </>
      ) : (
        <div className="text-gray-400 pl-4">No tokens found</div>
      )}
    </div>
  );
};

export default TokenSection;
