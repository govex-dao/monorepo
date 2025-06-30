"use client";

import { useParams } from "next/navigation";
import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { CONSTANTS, QueryKey } from "../constants";
import { useState, useEffect } from "react";
import { Theme } from "@radix-ui/themes";
import MarketPriceChartWrapper from "../components/trade/MarketPriceChartWrapper";
import TradeForm from "../components/trade/TradeForm";
import { VerifiedIcon } from "../components/icons/VerifiedIcon";
import TabSection from "../components/trade/TabSection";
import { useTokenEvents } from "../hooks/useTokenEvents";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { useSwapEvents } from "../hooks/useSwapEvents";
import UnverifiedIcon from "../components/icons/UnverifiedIcon";
import ProposalStateManager from "../components/trade/ProposalStateManager";
import { DaoIcon } from "../components/DaoIcon";
import { getOutcomeColors } from "../utils/outcomeColors";

interface StateHistory {
  id: number;
  proposal_id: string;
  old_state: number;
  new_state: number;
  timestamp: string;
}

interface ApiProposal {
  id: number;
  proposal_id: string;
  market_state_id: string;
  dao_id: string;
  dao_name: string;
  dao_icon: string | null;
  dao_verified: boolean; // Added dao_verified field
  dao: {
    // Added dao object
    minAssetAmount: string;
    minStableAmount: string;
    dao_name: string;
    assetType: string;
    stableType: string;
    icon_url?: string;
    icon_cache_path?: string;
    asset_symbol: string;
    stable_symbol: string;
    asset_decimals: number;
    stable_decimals: number;
  };
  winning_outcome: string | null;
  proposer: string;
  outcome_count: string;
  outcome_messages: string[];
  title: string;
  details: string;
  metadata: string;
  created_at: string;
  escrow_id: string;
  asset_value: string;
  stable_value: string;
  asset_type: string;
  stable_type: string;
  current_state: number;
  state_history: StateHistory[];
  review_period_ms: string; // Using string since other number fields are strings
  trading_period_ms: string; // Using string since other number fields are strings
  initial_outcome_amounts?: string[]; // Optional array of strings
  twap_initial_observation: string;
  twap_start_delay: string; // Using string since other number fields are strings
  twap_step_max: string; // Using string since other number fields are strings
  twap_threshold: string;
  twaps: string[] | null;
  package_id: string;
}

// const getStateLabel = (state: number | null): string => {
//   switch (state) {
//     case 0:
//       return 'In pre-trading period';
//     case 1:
//       return 'In trading period';
//     case 2:
//       return 'Trading has finished';
//     default:
//       return 'In review period';
//   }
// };

// const getStateColor = (state: number | null): string => {
//   switch (state) {
//     case 0:
//       return 'bg-yellow-700 text-yellow-100';
//     case 1:
//       return 'bg-green-700 text-green-100';
//     case 2:
//       return 'bg-red-800 text-red-100';
//     default:
//       return 'bg-gray-700 text-gray-100';
//   }
// };

// Define the custom hook outside of the component.
const useWindowWidth = () => {
  const [width, setWidth] = useState<number>(typeof window !== 'undefined' ? window.innerWidth : 1200);

  useEffect(() => {
    if (typeof window !== 'undefined') {
      setWidth(window.innerWidth);
      const handleResize = () => setWidth(window.innerWidth);
      window.addEventListener("resize", handleResize);
      return () => window.removeEventListener("resize", handleResize);
    }
  }, []);
  return width;
};

export function ProposalView() {
  const account = useCurrentAccount();
  const params = useParams();
  const proposalId = Array.isArray(params.proposalId) ? params.proposalId[0] : params.proposalId;
  const windowWidth = useWindowWidth();

  const {
    data: proposal,
    isLoading,
    error,
  } = useQuery<ApiProposal>({
    queryKey: [QueryKey.ProposalDetail, proposalId],
    queryFn: async () => {
      const response = await fetch(
        `${CONSTANTS.apiEndpoint}proposals/${proposalId}`,
      );
      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(
          errorData.message || `API error: ${response.statusText}`,
        );
      }
      return response.json();
    },
  });

  const {
    tokens,
    groupedTokens,
    isLoading: tokensLoading,
    error: tokensError,
    refreshTokens,
  } = useTokenEvents({
    proposalId: proposal?.proposal_id || "",
    address: account?.address,
    assetType: null,
    enabled: !!account?.address && !!proposal?.proposal_id,
    asset_decimals: proposal?.dao.asset_decimals,
    stable_decimals: proposal?.dao.stable_decimals,
  });

  // Call useSwapEvents unconditionally, but disable fetching until proposal is available.
  const { data: swapEvents, error: swapError } = useSwapEvents(
    proposal?.proposal_id ?? "",
    {
      enabled: !!proposal?.proposal_id,
    },
  );



  // Early returns (all hooks have already been called).
  if (isLoading) {
    return (
      <div className="w-full p-6 text-center text-gray-400">
        Loading proposal...
      </div>
    );
  }

  if (error) {
    return (
      <div className="w-full p-6 text-center text-red-400">
        Error loading proposal: {error.message}
      </div>
    );
  }

  if (!proposal) {
    return (
      <div className="w-full p-6 text-center text-gray-400">
        Proposal not found
      </div>
    );
  }

  const TRADEFORM_MAX_WIDTH = 700;
  const CHART_MIN_WIDTH = 600;
  const GAP = 20;
  const inlineBreakpoint = TRADEFORM_MAX_WIDTH + CHART_MIN_WIDTH + GAP; // e.g., 1320px
  const isInlineLayout = windowWidth >= inlineBreakpoint;
  const outcomeColors = getOutcomeColors(Number(proposal.outcome_count));

  return (
    <Theme appearance="dark" className="flex flex-col flex-1">
      <h1 className="text-3xl font-bold mt-4 pr-6 pl-7 flex flex-row flex-wrap items-center gap-x-1 gap-y-1">
        {/* DAO Name and Icon Link */}
        <Link
          href={`/dao/${proposal.dao_id}`}
          // Use inline-flex to make the link a flex container itself
          className="hover:opacity-80 group inline-flex items-center gap-2"
        >
          <DaoIcon
            icon={proposal.dao_icon}
            name={proposal.dao_name}
            size="lg"
            className="flex-shrink-0" // Prevent icon from shrinking
          />
          <span className="text-gray-400 group-hover:text-white group-hover:underline">
            {proposal.dao_name}
          </span>
        </Link>

        {/* Verification Status Icon */}
        {/* The flex-shrink-0 class is crucial to maintain icon size */}
        <span className="flex-shrink-0 mt-2">
          {proposal.dao_verified ? (
            <VerifiedIcon size={24} />
          ) : (
            <UnverifiedIcon size={24} />
          )}
        </span>

        {/* Colon (now a separate, gray element) */}
        <span className="text-gray-400">:</span>

        {/* Proposal Title (now without the colon) */}
        <span>{proposal.title}</span>
      </h1>
      <div className="px-4 sm:px-6 mt-3 mb-2">
        {" "}
        {/* Added responsive padding and adjusted margins */}
        <ProposalStateManager
          currentState={proposal.current_state}
          createdAt={proposal.created_at}
          reviewPeriodMs={proposal.review_period_ms}
          tradingPeriodMs={proposal.trading_period_ms}
          stateHistory={proposal.state_history || []}
        />
      </div>
      <div className="flex-1 overflow-hidden p-4">
        <div
          className={
            isInlineLayout
              ? "flex items-start space-x-4"
              : "flex flex-col space-y-4"
          }
        >
          {/* MarketPriceChart is now on the left */}
          <div className={isInlineLayout ? "w-3/4" : "w-full"}>
            <MarketPriceChartWrapper
              proposalId={proposal.proposal_id}
              assetValue={proposal.asset_value}
              stableValue={proposal.stable_value}
              asset_decimals={proposal.dao.asset_decimals}
              stable_decimals={proposal.dao.stable_decimals}
              currentState={proposal.current_state}
              outcome_count={proposal.outcome_count}
              outcome_messages={proposal.outcome_messages}
              initial_outcome_amounts={proposal.initial_outcome_amounts}
              twaps={proposal.twaps}
              twap_threshold={proposal.twap_threshold}
              winning_outcome={proposal.winning_outcome}
              swapEvents={swapEvents}
              swapError={swapError ?? undefined}
            />
          </div>
          {/* TradeForm is now on the right */}
          <div className={isInlineLayout ? "w-1/4 px-6" : "w-full"}>
            {proposal.current_state === 1 ? (
              <TradeForm
                proposalId={proposal.proposal_id}
                escrowId={proposal.escrow_id}
                outcomeCount={proposal.outcome_count}
                assetType={proposal.asset_type}
                stableType={proposal.stable_type}
                packageId={proposal.package_id}
                outcome_messages={proposal.outcome_messages}
                asset_symbol={proposal.dao.asset_symbol}
                stable_symbol={proposal.dao.stable_symbol}
                initial_outcome_amounts={proposal.initial_outcome_amounts}
                asset_value={proposal.asset_value}
                stable_value={proposal.stable_value}
                asset_decimals={proposal.dao.asset_decimals}
                stable_decimals={proposal.dao.stable_decimals}
                swapEvents={swapEvents}
                tokens={tokens}
                refreshTokens={refreshTokens}
              />
            ) : (
              <div className="flex flex-col items-center justify-center h-full">
                {proposal.current_state === 2 &&
                  proposal.winning_outcome != null && (
                    <div className="p-6 rounded-lg bg-gray-900 border border-gray-800 text-center shadow-lg w-full max-w-sm">
                      <h2 className="text-2xl font-semibold text-gray-300">
                        <span
                          className="block text-3xl font-bold mb-2"
                          style={{
                            color:
                              outcomeColors[Number(proposal.winning_outcome)],
                          }}
                        >
                          {
                            proposal.outcome_messages[
                            Number(proposal.winning_outcome)
                            ]
                          }
                        </span>
                        is the Winning Outcome.
                      </h2>
                      <p className="text-gray-300">
                        The trading period for this proposal has ended.
                      </p>
                    </div>
                  )}
              </div>
            )}
          </div>
        </div>
        <TabSection
          proposal={proposal}
          outcomeMessages={proposal.outcome_messages}
          details={proposal.details}
          asset_symbol={proposal.dao.asset_symbol}
          stable_symbol={proposal.dao.stable_symbol}
          tokens={tokens}
          groupedTokens={groupedTokens}
          isLoading={tokensLoading}
          error={tokensError}
          swapEvents={swapEvents}
          assetScale={Math.pow(10, proposal.dao.asset_decimals)}
          stableScale={Math.pow(10, proposal.dao.stable_decimals)}
        />
      </div>
    </Theme>
  );
}

export default ProposalView;
