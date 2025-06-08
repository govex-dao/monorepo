import React from "react";
import { RedeemTokensButton } from "./RedeemTokensButton";
import { TokenInfo } from "./TradeForm";
import { getOutcomeColor } from "@/utils/outcomes";

interface TokenSectionProps {
  proposalId: string;
  outcomeMessages: string[];
  winning_outcome: string | null;
  current_state: number;
  escrow: string;
  asset_type: string;
  stable_type: string;
  outcome_count: string;
  asset_symbol: string;
  stable_symbol: string;
  tokens: TokenInfo[];
  groupedTokens: any[];
  isLoading: boolean;
  error: Error | null;
}

const TokenSection: React.FC<TokenSectionProps> = ({
  proposalId,
  outcomeMessages,
  winning_outcome,
  current_state,
  escrow,
  asset_type,
  stable_type,
  outcome_count,
  asset_symbol,
  stable_symbol,
  tokens,
  groupedTokens,
  isLoading,
  error,
}) => {
  return (
    <div className="space-y-4 p-6">
      <div className="flex flex-col gap-4">
        <div className="flex items-center justify-between">
          <h3 className="text-sm font-semibold uppercase text-gray-300">
            Your Tokens
          </h3>
          <span className="text-xs text-gray-500">
            {outcome_count} outcomes
          </span>
        </div>
      </div>

      {isLoading ? (
        <div className="text-gray-400 p-8 text-center bg-gray-900/50 border border-gray-800/50 rounded-lg shadow-md">
          <p className="text-sm">Loading your tokens...</p>
        </div>
      ) : error ? (
        <div className="text-red-400 p-8 text-center bg-gray-900/50 border border-gray-800/50 rounded-lg shadow-md">
          <p className="text-sm">Error loading tokens: {error.message}</p>
        </div>
      ) : groupedTokens.length > 0 ? (
        <div className="bg-gray-900/50 border border-gray-800/50 rounded-lg shadow-md">
          <RedeemTokensButton
            proposalId={proposalId}
            userTokens={tokens}
            winning_outcome={winning_outcome}
            current_state={current_state}
            escrow={escrow}
            asset_type={asset_type}
            stable_type={stable_type}
            outcome_count={outcome_count}
          />
          <div className="overflow-x-auto rounded-lg">
            <table className="w-full">
              <thead>
                <tr className="text-xs text-gray-400 border-b border-gray-800 bg-gray-900/70">
                  <th className="text-left py-3.5 px-4 font-medium">Outcome</th>
                  <th className="text-right py-3.5 px-4 font-medium">
                    {asset_symbol}
                  </th>
                  <th className="text-right py-3.5 px-4 font-medium">
                    {stable_symbol}
                  </th>
                </tr>
              </thead>
              <tbody>
                {groupedTokens.map((token) => {
                  const outcomeColor = getOutcomeColor(token.outcome);

                  return (
                    <tr
                      key={`${token.outcome}-${token.assetBalance}-${token.stableBalance}`}
                      className="text-sm border-b border-gray-800/70 hover:bg-gray-800/50 transition-colors"
                    >
                      <td className="py-3.5 px-4">
                        <span
                          className={`px-2.5 py-1 rounded text-xs font-medium border ${outcomeColor.bg} ${outcomeColor.text} ${outcomeColor.border}`}
                        >
                          {outcomeMessages[token.outcome] ||
                            `Outcome ${token.outcome}`}
                        </span>
                      </td>
                      <td className="py-3.5 px-4 text-right text-gray-200">
                        <span className="font-medium">
                          {token.assetBalanceFormatted}
                        </span>
                      </td>
                      <td className="py-3.5 px-4 text-right text-gray-200">
                        <span className="font-medium">
                          {token.stableBalanceFormatted}
                        </span>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      ) : (
        <div className="text-gray-400 p-8 text-center bg-gray-900/50 border border-gray-800/50 rounded-lg shadow-md">
          <p className="text-sm">You don't have any tokens for this proposal</p>
        </div>
      )}
    </div>
  );
};

export default TokenSection;
