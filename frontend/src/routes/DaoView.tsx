import { useParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { CONSTANTS } from "@/constants";
import {
  Card,
  Heading,
  Text,
  Button,
  Flex,
  Badge,
  Dialog,
} from "@radix-ui/themes";
import { SEOMetadata } from "@/components/SEOMetadata";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { ExplorerLink } from "@/components/ExplorerLink";
import { VerifiedIcon } from "@/components/icons/VerifiedIcon";
import CreateProposalForm from "@/components/daos/CreateProposalForm";
import VerifyDaoForm from "@/components/daos/VerifyDaoForm";
import { useState } from "react";
import { DaoIcon } from "@/components/DaoIcon";
import { ProposalCard } from "@/components/daos/ProposalCard";
import { TokenCard } from "@/components/daos/TokenCard";
import { formatPeriod } from "@/utils/time";
import { Tooltip } from "@/components/Tooltip";

interface DaoData {
  dao_id: string;
  minAssetAmount: string;
  minStableAmount: string;
  timestamp: string;
  assetType: string;
  stableType: string;
  dao_name: string;
  dao_icon: string;
  icon_url: string;
  icon_cache_path: string | null;
  review_period_ms: string;
  trading_period_ms: string;
  asset_decimals: number;
  stable_decimals: number;
  asset_symbol: string;
  stable_symbol: string;
  asset_icon_url: string;
  asset_name: string;
  stable_icon_url: string;
  stable_name: string;
  verification?: {
    verified: boolean;
  };
  proposal_count?: number;
  active_proposals?: number;
  amm_twap_initial_observation: string;
  amm_twap_start_delay: string;
  amm_twap_step_max: string;
  twap_threshold: string;
}

interface Proposal {
  id: number;
  proposal_id: string;
  title: string;
  details: string;
  created_at: string;
  current_state: number;
  proposer: string;
  outcome_count: string;
  outcome_messages: string[];
  winning_outcome: string;
}

const TWAP_BASIS_POINTS = 100_000;

const DaoInfoCards = ({
  dao,
  daoInformations,
  twapInformations,
}: {
  dao: DaoData;
  daoInformations: Array<{ label: string; value: React.ReactNode }>;
  twapInformations: Array<{
    label: string;
    value: React.ReactNode;
    description: string;
  }>;
}) => (
  <div className="space-y-4">
    <Card className="p-4 bg-gray-900/50 border border-gray-800/50 shadow-lg rounded-xl">
      <Heading size="2" className="mb-3 text-gray-200">
        Infos
      </Heading>
      <Flex direction="column" gap="2" className="text-gray-100">
        {daoInformations.map(
          ({ label, value }) =>
            value && (
              <Flex
                key={label}
                align="center"
                justify="between"
                className="py-1 border-b border-gray-800/50"
              >
                <Text weight="bold" size="2" className="text-gray-400">
                  {label}
                </Text>
                {value}
              </Flex>
            ),
        )}
      </Flex>
    </Card>

    <Card className="p-4 bg-gray-900/50 border border-gray-800/50 shadow-lg rounded-xl">
      <Heading size="2" className="mb-3 text-gray-200">
        TWAP Configuration
      </Heading>
      <Flex direction="column" gap="2" className="text-gray-100">
        {twapInformations.map(({ label, value, description }) => (
          <Tooltip key={label} content={description}>
            <Flex
              align="center"
              justify="between"
              className="py-1 border-b border-gray-800/50"
            >
              <Text weight="bold" size="2" className="text-gray-400">
                {label}
              </Text>
              {value}
            </Flex>
          </Tooltip>
        ))}
      </Flex>
    </Card>

    <Card className="p-4 bg-gray-900/50 border border-gray-800/50 shadow-lg rounded-xl">
      <Heading size="2" className="mb-3 text-gray-200">
        Tokens
      </Heading>
      <Flex className="" gap="3">
        <div className="flex-1">
          <TokenCard
            name={dao.asset_name}
            symbol={dao.asset_symbol}
            type="asset"
            iconUrl={dao.asset_icon_url}
            decimals={dao.asset_decimals}
            minAmount={dao.minAssetAmount}
            tokenType={dao.assetType}
          />
        </div>

        <div className="flex-1">
          <TokenCard
            name={dao.stable_name}
            symbol={dao.stable_symbol}
            type="stable"
            iconUrl={dao.stable_icon_url}
            decimals={dao.stable_decimals}
            minAmount={dao.minStableAmount}
            tokenType={dao.stableType}
          />
        </div>
      </Flex>
    </Card>
  </div>
);

const adjustPriceValue = (
  value: number,
  asset_decimals: number,
  stable_decimals: number,
): string => {
  const adjustedValue =
    (value / 1_000_000_000_000) *
    Math.pow(10, asset_decimals - stable_decimals);
  return adjustedValue.toFixed(10).replace(/\.?0+$/, "");
};

export function DaoView() {
  const { daoId } = useParams();
  const account = useCurrentAccount();
  const [showCreateProposal, setShowCreateProposal] = useState(false);
  const [showVerifyDao, setShowVerifyDao] = useState(false);
  const [showInfo, setShowInfo] = useState(false);

  const {
    data: dao,
    isLoading,
    error,
  } = useQuery<DaoData>({
    queryKey: ["dao", daoId],
    queryFn: async () => {
      if (!daoId) throw new Error("No DAO ID provided");
      const response = await fetch(
        `${CONSTANTS.apiEndpoint}daos?dao_id=${encodeURIComponent(daoId)}`,
      );
      if (!response.ok) throw new Error("Failed to fetch DAO data");
      const data = await response.json();
      return data.data[0];
    },
    enabled: !!daoId,
    staleTime: 5 * 60 * 1000, // 5 minutes
  });

  const { data: proposals, isLoading: isLoadingProposals } = useQuery<
    Proposal[]
  >({
    queryKey: ["proposals", daoId],
    queryFn: async () => {
      if (!daoId) throw new Error("No DAO ID provided");
      const response = await fetch(
        `${CONSTANTS.apiEndpoint}proposals?dao_id=${encodeURIComponent(daoId)}`,
      );
      if (!response.ok) throw new Error("Failed to fetch proposals");
      const data = await response.json();
      return data.data;
    },
    enabled: !!daoId,
    staleTime: 2 * 60 * 1000,
  });

  if (isLoading) {
    return (
      <Flex justify="center" align="center" className="p-8 h-64 text-gray-300">
        <Text size="3">Loading DAO information...</Text>
      </Flex>
    );
  }

  if (error || !dao) {
    return (
      <Flex justify="center" align="center" className="p-8 h-64">
        <Card className="p-6 bg-red-900/20 border border-red-800/50 text-red-300">
          <Text size="3">Error loading DAO information</Text>
        </Card>
      </Flex>
    );
  }

  const formattedReviewPeriod = formatPeriod(dao.review_period_ms);
  const formattedTradingPeriod = formatPeriod(dao.trading_period_ms);

  const daoInformations = [
    { label: "DAO ID", value: <ExplorerLink id={dao.dao_id} type="object" /> },
    {
      label: "Review Period",
      value: <Text size="2">{formattedReviewPeriod}</Text>,
    },
    {
      label: "Trading Period",
      value: <Text size="2">{formattedTradingPeriod}</Text>,
    },
  ].filter(Boolean);

  const twapInformations = [
    {
      label: "Initial Price Observation",
      value: (
        <Text size="2">
          $
          {adjustPriceValue(
            Number(dao.amm_twap_initial_observation),
            dao.asset_decimals,
            dao.stable_decimals,
          )}
        </Text>
      ),
      description: "Starting price point for TWAP calculations",
    },
    {
      label: "Start Delay",
      value: <Text size="2">{formatPeriod(dao.amm_twap_start_delay)}</Text>,
      description: "Delay before TWAP tracking begins",
    },
    {
      label: "Max Step Interval",
      value: (
        <Text size="2">
          $
          {adjustPriceValue(
            Number(dao.amm_twap_step_max),
            dao.asset_decimals,
            dao.stable_decimals,
          )}
        </Text>
      ),
      description: "Maximum time between price observations",
    },
    {
      label: "TWAP Threshold",
      value: (
        <Text size="2">
          {Number(
            BigInt(dao.twap_threshold || 0) / BigInt(TWAP_BASIS_POINTS / 100),
          ).toFixed(2)}
          %
        </Text>
      ),
      description: "Threshold for the TWAP to be executed",
    },
  ].filter(Boolean);

  return (
    <div className="p-6 max-w-6xl mx-auto">
      <SEOMetadata
        dao={dao ? {
          id: dao.dao_id,
          name: dao.dao_name,
          iconUrl: dao.icon_url || dao.icon_cache_path || undefined,
          verified: dao.verification?.verified,
          assetSymbol: dao.asset_symbol,
          stableSymbol: dao.stable_symbol,
          proposalCount: proposals?.length || 0,
          timestamp: dao.timestamp
        } : undefined}
      />
      {/* Header Section */}
      <div className="relative flex flex-wrap items-end justify-between w-full mt-24">
        <div className="h-48 w-full absolute -z-20 -top-32 rounded-xl bg-gradient-to-r from-indigo-900/40 to-purple-900/40 overflow-hidden" />
        <div className="sm:ml-4 flex items-end flex-wrap">
          <DaoIcon
            className="flex rounded-xl overflow-hidden border-4 shadow-lg "
            size="xl"
            icon={dao.icon_url}
            name={dao.dao_name}
          />
          <div className="ml-6 mb-1">
            <Flex align="center" gap="2">
              <div>
                <Heading size="7" className="text-gray-100">
                  {dao.dao_name}
                </Heading>
              </div>
              {dao.verification?.verified ? (
                <Badge color="blue" className="flex items-center gap-1">
                  <VerifiedIcon className="w-4 h-4" />
                  <Text size="1">Verified</Text>
                </Badge>
              ) : (
                <Button
                  size="1"
                  variant="outline"
                  className="border-blue-700 text-blue-300 hover:bg-blue-900/20 cursor-pointer"
                  onClick={() => setShowVerifyDao(true)}
                >
                  Get Verified
                </Button>
              )}
            </Flex>
            <Text size="2" className="text-gray-400">
              Created{" "}
              {new Date(Number(dao.timestamp)).toLocaleDateString(undefined, {
                year: "numeric",
                month: "long",
                day: "numeric",
              })}
            </Text>
          </div>
        </div>
        <Button
          size="3"
          className="bg-indigo-600 hover:bg-indigo-700 text-white cursor-pointer w-full sm:w-fit my-4"
          onClick={() => setShowCreateProposal(true)}
        >
          Create Proposal
        </Button>
      </div>

      {/* Main Content */}
      <div className="mt-4 sm:mt-8 grid grid-cols-1 lg:grid-cols-12 gap-3 sm:gap-6">
        {/* Left Column */}
        <div className="lg:col-span-4">
          {/* Mobile Collapsible Section */}
          <div className="lg:hidden">
            <button
              onClick={() => setShowInfo(!showInfo)}
              className="w-full py-2 -my-2 transition-all duration-200 shadow-sm hover:shadow-md transform"
            >
              <Flex justify="between" align="center">
                <Heading size="4" className="text-gray-200">
                  DAO Informations
                </Heading>
                <Text
                  size="2"
                  className={`text-gray-400 transition-transform duration-200 ${showInfo ? "rotate-180" : ""}`}
                >
                  ▼
                </Text>
              </Flex>
            </button>
            <div
              className={`overflow-hidden transition-all duration-200 ${showInfo ? "max-h-[2000px] mt-2" : "max-h-0"}`}
            >
              <DaoInfoCards
                dao={dao}
                daoInformations={daoInformations}
                twapInformations={twapInformations}
              />
            </div>
          </div>

          {/* Desktop Sections */}
          <div className="hidden lg:block space-y-3">
            <DaoInfoCards
              dao={dao}
              daoInformations={daoInformations}
              twapInformations={twapInformations}
            />
          </div>
        </div>

        {/* Right Column */}
        <div className="lg:col-span-8 space-y-6">
          <Flex className="" direction="column">
            <Flex justify="between" align="center" className="mb-6">
              <Heading size="4" className="text-gray-200">
                Proposals
              </Heading>
              <Text size="2" className="text-gray-400">
                {proposals?.length || 0} total
              </Text>
            </Flex>
            {isLoadingProposals ? (
              <div className="text-center py-8 text-gray-400">
                <Text size="2">Loading proposals...</Text>
              </div>
            ) : proposals && proposals.length > 0 ? (
              <div className="space-y-3">
                {proposals.map((proposal) => (
                  <ProposalCard
                    key={proposal.proposal_id}
                    proposal={proposal}
                    variant={
                      proposal.current_state === 2 ? "finalized" : "active"
                    }
                  />
                ))}
              </div>
            ) : (
              <div className="bg-gray-800/30 rounded-lg border border-gray-700/20 p-8">
                <Flex
                  direction="column"
                  align="center"
                  gap="4"
                  className="text-center"
                >
                  <div className="w-12 h-12 rounded-full bg-gray-800/50 border border-gray-700/50 flex items-center justify-center">
                    <svg
                      className="w-6 h-6 text-gray-500"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        strokeLinecap="round"
                        strokeLinejoin="round"
                        strokeWidth={1.5}
                        d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
                      />
                    </svg>
                  </div>
                  <Text size="3" weight="medium" className="text-gray-200">
                    No proposals yet
                  </Text>
                  <Text size="2" className="text-gray-400 max-w-md">
                    This DAO hasn't created any proposals yet. Be the first to
                    start a discussion and shape the future of this community.
                  </Text>
                  <Button
                    size="2"
                    variant="soft"
                    color="blue"
                    className="mt-2 cursor-pointer"
                    onClick={() => setShowCreateProposal(true)}
                  >
                    Create First Proposal
                  </Button>
                </Flex>
              </div>
            )}
          </Flex>
        </div>
      </div>

      {/* Render modal dialogs for creating proposals and verifying DAOs */}
      {[
        {
          open: showCreateProposal,
          onOpenChange: setShowCreateProposal,
          title: `Create New Proposal for ${dao?.dao_name}`,
          content: (
            <CreateProposalForm
              walletAddress={account?.address ?? ""}
              daoIdFromUrl={daoId}
            />
          ),
        },
        {
          open: showVerifyDao,
          onOpenChange: setShowVerifyDao,
          title: "Get DAO Verified",
          content: <VerifyDaoForm />,
        },
      ].map(({ open, onOpenChange, title, content }, index) => (
        <Dialog.Root key={index} open={open} onOpenChange={onOpenChange}>
          <Dialog.Content className="max-w-4xl bg-gray-900 border border-gray-800">
            <Dialog.Title className="text-gray-200">{title}</Dialog.Title>
            <div className="mt-4">{content}</div>
          </Dialog.Content>
        </Dialog.Root>
      ))}
    </div>
  );
}
