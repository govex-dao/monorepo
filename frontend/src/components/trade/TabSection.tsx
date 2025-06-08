import React, { useState } from "react";
import TokenSection from "./TokenSection";
import ProposalDetails from "./ProposalDetails";
import { TokenInfo } from "./TradeForm";
import Description from "./Description";
import Liquidity from "./Liquidity";

interface TabSectionProps {
  proposal: any;
  outcomeMessages: any[];
  userTokens: TokenInfo[];
  details: string;
  asset_symbol?: string;
  stable_symbol?: string;
  asset_decimals?: number;
  stable_decimals?: number;
}

const TabSection: React.FC<TabSectionProps> = ({
  proposal,
  outcomeMessages,
  userTokens,
  details,
  asset_symbol = "Asset",
  stable_symbol = "Stable",
  asset_decimals = 9,
  stable_decimals = 9,
}) => {
  const [activeTab, setActiveTab] = useState<
    "tokens" | "description" | "details" | "liquidity"
  >("tokens");

  return (
    <div className="space-y-4">
      <div className="flex border-b border-gray-700">
        <button
          onClick={() => setActiveTab("tokens")}
          className={`px-6 py-3 text-sm font-medium ${
            activeTab === "tokens"
              ? "text-blue-500 border-b-2 border-blue-500"
              : "text-gray-400 hover:text-gray-300"
          }`}
        >
          Your Tokens
        </button>
        <button
          onClick={() => setActiveTab("description")}
          className={`px-6 py-3 text-sm font-medium ${
            activeTab === "description"
              ? "text-blue-500 border-b-2 border-blue-500"
              : "text-gray-400 hover:text-gray-300"
          }`}
        >
          Description
        </button>
        <button
          onClick={() => setActiveTab("details")}
          className={`px-6 py-3 text-sm font-medium ${
            activeTab === "details"
              ? "text-blue-500 border-b-2 border-blue-500"
              : "text-gray-400 hover:text-gray-300"
          }`}
        >
          Advanced Info
        </button>
        <button
          onClick={() => setActiveTab("liquidity")}
          className={`px-6 py-3 text-sm font-medium ${
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
          userTokens={userTokens}
          outcomeMessages={outcomeMessages}
          winning_outcome={proposal.winning_outcome}
          current_state={proposal.current_state}
          escrow={proposal.escrow_id}
          asset_type={proposal.asset_type}
          stable_type={proposal.stable_type}
          outcome_count={proposal.outcome_count}
          asset_decimals={asset_decimals}
          stable_decimals={stable_decimals}
          asset_symbol={asset_symbol}
          stable_symbol={stable_symbol}
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
          userTokens={userTokens}
          winning_outcome={proposal.winning_outcome}
          current_state={proposal.current_state}
          escrow={proposal.escrow_id}
          asset_type={proposal.asset_type}
          stable_type={proposal.stable_type}
          proposalId={proposal.proposal_id}
        />
      )}
    </div>
  );
};

export default TabSection;
