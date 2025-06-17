import React, { useState } from "react";
import TokenSection from "./TokenSection";
import ProposalDetails from "./ProposalDetails";
import Description from "./Description";
import Liquidity from "./Liquidity";
import { TradeHistory } from "./history/TradeHistory";
import { TokenInfo } from "./TradeForm";

interface TabSectionProps {
  proposal: any;
  outcomeMessages: any[];
  details: string;
  asset_symbol?: string;
  stable_symbol?: string;
  tokens: TokenInfo[];
  groupedTokens: any[];
  isLoading: boolean;
  error: Error | null;
  swapEvents?: any[];
  assetScale?: number;
  stableScale?: number;
}

const TabSection: React.FC<TabSectionProps> = ({
  proposal,
  outcomeMessages,
  details,
  asset_symbol = "Asset",
  stable_symbol = "Stable",
  tokens,
  groupedTokens,
  isLoading,
  error,
  swapEvents,
  assetScale = 1,
  stableScale = 1,
}) => {
  const [activeTab, setActiveTab] = useState<
    "tokens" | "description" | "details" | "liquidity" | "activity"
  >("tokens");

  return (
    <div className="space-y-4">
      <div className="flex overflow-x-auto border-b border-gray-700">
        <button
          onClick={() => setActiveTab("tokens")}
          className={`px-6 py-5 text-sm font-medium whitespace-nowrap ${
            activeTab === "tokens"
              ? "text-blue-500 border-b-2 border-blue-500"
              : "text-gray-400 hover:text-gray-300"
          }`}
        >
          Your Tokens
        </button>
        <button
          onClick={() => setActiveTab("description")}
          className={`px-6 py-5 text-sm font-medium whitespace-nowrap ${
            activeTab === "description"
              ? "text-blue-500 border-b-2 border-blue-500"
              : "text-gray-400 hover:text-gray-300"
          }`}
        >
          Description
        </button>
        <button
          onClick={() => setActiveTab("activity")}
          className={`px-6 py-5 text-sm font-medium whitespace-nowrap ${
            activeTab === "activity"
              ? "text-blue-500 border-b-2 border-blue-500"
              : "text-gray-400 hover:text-gray-300"
          }`}
        >
          Activity
        </button>
        <button
          onClick={() => setActiveTab("details")}
          className={`px-6 py-5 text-sm font-medium whitespace-nowrap ${
            activeTab === "details"
              ? "text-blue-500 border-b-2 border-blue-500"
              : "text-gray-400 hover:text-gray-300"
          }`}
        >
          Advanced Info
        </button>
        <button
          onClick={() => setActiveTab("liquidity")}
          className={`px-6 py-5 text-sm font-medium whitespace-nowrap ${
            activeTab === "liquidity"
              ? "text-blue-500 border-b-2 border-blue-500"
              : "text-gray-400 hover:text-gray-300"
          }`}
        >
          Liquidity
        </button>
      </div>

      {activeTab === "tokens" && (
        <TokenSection
          proposalId={proposal.proposal_id}
          outcomeMessages={outcomeMessages}
          winning_outcome={proposal.winning_outcome}
          current_state={proposal.current_state}
          escrow={proposal.escrow_id}
          asset_type={proposal.asset_type}
          stable_type={proposal.stable_type}
          outcome_count={proposal.outcome_count}
          asset_symbol={asset_symbol}
          stable_symbol={stable_symbol}
          tokens={tokens}
          groupedTokens={groupedTokens}
          isLoading={isLoading}
          error={error}
          package_id={proposal.package_id}
        />
      )}
      {activeTab === "description" && <Description details={details} />}
      {activeTab === "details" && (
        <ProposalDetails
          proposal={proposal}
          outcomeMessages={outcomeMessages}
        />
      )}
      {activeTab === "liquidity" && (
        <Liquidity
          // userTokens={tokens}
          winning_outcome={proposal.winning_outcome}
          current_state={proposal.current_state}
          escrow={proposal.escrow_id}
          asset_type={proposal.asset_type}
          stable_type={proposal.stable_type}
          proposalId={proposal.proposal_id}
        />
      )}
      {activeTab === "activity" && (
        <TradeHistory
          swapEvents={swapEvents}
          assetSymbol={asset_symbol}
          stableSymbol={stable_symbol}
          outcomeMessages={outcomeMessages}
          assetScale={assetScale}
          stableScale={stableScale}
          hasStarted={proposal.current_state !== "Pending"}
        />
      )}
    </div>
  );
};

export default TabSection;
