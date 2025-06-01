import { useParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { CONSTANTS, QueryKey } from "@/constants";
import { useState, useEffect } from "react";
import { Theme } from "@radix-ui/themes";
import MarketPriceChart from "../components/trade/MarketPriceChart.tsx";
import TradeForm from "../components/trade/TradeForm.tsx";
import { VerifiedIcon } from "@/components/icons/VerifiedIcon.tsx";
import TabSection from "../components/trade/TabSection";
import { useTokenEvents } from "../hooks/useTokenEvents";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { useSwapEvents } from "@/hooks/useSwapEvents";
import UnverifiedIcon from "@/components/icons/UnverifiedIcon.tsx";
import ProposalCountdownTimer from "@/components/trade/ProposalCountdownTimer";

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
  const [width, setWidth] = useState<number>(window.innerWidth);

  useEffect(() => {
    const handleResize = () => setWidth(window.innerWidth);
    window.addEventListener("resize", handleResize);
    return () => window.removeEventListener("resize", handleResize);
  }, []);
  return width;
};

export function ProposalView() {
  // Call hooks at the very top of the component.
  const account = useCurrentAccount();
  const { proposalId } = useParams<{ proposalId: string }>();
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

  // Wait for proposal to load before fetching tokens.
  const { tokens } = useTokenEvents({
    proposalId: proposal?.proposal_id ?? "",
    address: account?.address,
    assetType: null,
    enabled: !!account?.address && !!proposal?.proposal_id,
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

  return (
    <Theme appearance="dark" className="flex flex-col flex-1">
      <h1 className="text-3xl font-bold mt-4 pl-6 pr-6">
        {proposal.dao_icon ? (
          <img
            src={proposal.dao_icon}
            alt={`${proposal.dao_name} icon`}
            className="w-9 h-9 -mt-1 rounded-full inline-block mr-2 object-cover border-2 border-gray-700"
            onError={(e) => {
              e.currentTarget.src = "/fallback-icon.png";
            }}
          />
        ) : (
          <div className="w-9 h-9 rounded-full bg-gray-700 inline-block mr-2 border-2 border-gray-700" />
        )}
        <span className="text-gray-400">{proposal.dao_name}</span>
        {proposal.dao_verified ? (
          <VerifiedIcon
            className="ml-1 inline-flex items-center align-middle"
            size={24}
          />
        ) : (
          <UnverifiedIcon
            className="ml-1 inline-flex items-center align-middle"
            size={24}
          />
        )}
        {": "}
        {proposal.title}
      </h1>
      <div className="px-4 sm:px-6 mt-3 mb-2">
        {" "}
        {/* Added responsive padding and adjusted margins */}
        <ProposalCountdownTimer
          currentState={proposal.current_state}
          createdAt={proposal.created_at}
          reviewPeriodMs={proposal.review_period_ms}
          tradingPeriodMs={proposal.trading_period_ms} // Pass directly, component handles if undefined
          stateHistory={proposal.state_history || []} // Ensure stateHistory is always an array
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
            <MarketPriceChart
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
                packageId={CONSTANTS.futarchyPackage}
                tokens={tokens}
                outcome_messages={proposal.outcome_messages}
                asset_symbol={proposal.dao.asset_symbol}
                stable_symbol={proposal.dao.stable_symbol}
                initial_outcome_amounts={proposal.initial_outcome_amounts}
                asset_value={proposal.asset_value}
                stable_value={proposal.stable_value}
                asset_decimals={proposal.dao.asset_decimals}
                stable_decimals={proposal.dao.stable_decimals}
                swapEvents={swapEvents}
              />
            ) : (
              <div className="flex flex-col items-center justify-center h-full">
                <h1 className="text-center text-1xl font-bold">
                  {proposal.current_state === 0
                    ? null
                    : proposal.current_state === 2
                      ? "Trading finished"
                      : ""}
                </h1>
              </div>
            )}
          </div>
        </div>
        <TabSection
          proposal={proposal}
          outcomeMessages={proposal.outcome_messages}
          userTokens={tokens}
          details={proposal.details}
          asset_symbol={proposal.dao.asset_symbol}
          stable_symbol={proposal.dao.stable_symbol}
          asset_decimals={proposal.dao.asset_decimals}
          stable_decimals={proposal.dao.stable_decimals}
        />
      </div>
    </Theme>
  );
}

export default ProposalView;
