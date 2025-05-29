import { Link, useParams } from "react-router-dom";
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
import { useCurrentAccount } from "@mysten/dapp-kit";
import { ExplorerLink } from "@/components/ExplorerLink";
import { VerifiedIcon } from "@/components/icons/VerifiedIcon";
import CreateProposalForm from "@/components/daos/CreateProposalForm";
import VerifyDaoForm from "@/components/daos/VerifyDaoForm";
import { useState } from "react";
import { DaoIcon } from "@/components/DaoIcon";
import { ProposalStatus } from "@/components/ProposalStatus";

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
  admin: string;
  verification?: {
    verified: boolean;
  };
  proposal_count?: number;
  active_proposals?: number;
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

export function DaoView() {
  const { daoId } = useParams();
  const account = useCurrentAccount();
  const [showCreateProposal, setShowCreateProposal] = useState(false);
  const [showVerifyDao, setShowVerifyDao] = useState(false);

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

  const isAdmin = account?.address === dao.admin;

  // Format periods in hours and minutes
  const formatPeriod = (periodMs: string) => {
    const totalMinutes = Number(periodMs) / 1000 / 60;
    const hours = Math.floor(totalMinutes / 60);
    const minutes = Math.floor(totalMinutes % 60);

    if (hours > 0) {
      return minutes > 0 ? `${hours}h ${minutes}m` : `${hours}h`;
    } else {
      return `${minutes}m`;
    }
  };

  const formattedReviewPeriod = formatPeriod(dao.review_period_ms);
  const formattedTradingPeriod = formatPeriod(dao.trading_period_ms);

  return (
    <div className="p-6 max-w-6xl mx-auto">
      {/* Header Section */}
      <div className="relative flex flex-wrap items-end justify-between w-full mt-24">
        <div className="h-48 w-full absolute -z-20 -top-32 rounded-xl bg-gradient-to-r from-indigo-900/40 to-purple-900/40 overflow-hidden" />
        <div className="sm:ml-4 flex items-end flex-wrap">
          <DaoIcon className="flex rounded-xl overflow-hidden border-4 shadow-lg " size="xl" icon={dao.icon_url} name={dao.dao_name} />
          <div className="ml-6 mb-4">
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
              {isAdmin && (
                <Badge color="amber" variant="soft">
                  Admin
                </Badge>
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
      <div className="mt-10 grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Left Column */}
        <div className="lg:col-span-1 space-y-6">
          <Card className="p-5 bg-gray-900/50 border border-gray-800/50 shadow-lg rounded-xl">
            <Heading size="3" className="mb-4 text-gray-200">
              DAO Information
            </Heading>
            <Flex direction="column" gap="3" className="text-gray-100">
              <Flex
                align="center"
                justify="between"
                className="py-2 border-b border-gray-800/50"
              >
                <Text weight="bold" size="2" className="text-gray-400">
                  DAO ID
                </Text>
                <ExplorerLink id={dao.dao_id} />
              </Flex>

              {dao.admin && (
                <Flex
                  align="center"
                  justify="between"
                  className="py-1 border-b border-gray-800/50"
                >
                  <Text weight="bold" size="2" className="text-gray-400">
                    Admin
                  </Text>
                  <Flex align="center" gap="2">
                    <ExplorerLink id={dao.admin} isAddress />
                  </Flex>
                </Flex>
              )}

              <Flex
                align="center"
                justify="between"
                className="py-1 border-b border-gray-800/50"
              >
                <Text weight="bold" size="2" className="text-gray-400">
                  Review Period
                </Text>
                <Text size="2">{formattedReviewPeriod}</Text>
              </Flex>

              <Flex
                align="center"
                justify="between"
                className="py-1 border-b border-gray-800/50"
              >
                <Text weight="bold" size="2" className="text-gray-400">
                  Trading Period
                </Text>
                <Text size="2" className="">
                  {formattedTradingPeriod}
                </Text>
              </Flex>
            </Flex>
          </Card>

          <Card className="p-5 bg-gray-900/50 border border-gray-800/50 shadow-lg rounded-xl">
            <Heading size="2" className="mb-4 text-gray-200">
              Token Information
            </Heading>
            <div className="space-y-3">
              {/* Asset Token Card */}
              <div className="p-3 bg-gray-800/70 rounded-lg border border-gray-700/50">
                <Flex align="center" gap="3">
                  <div className="w-8 h-8 rounded-full bg-gradient-to-br from-blue-500/40 to-blue-700/40 flex items-center justify-center shadow-md overflow-hidden flex-shrink-0">
                    {dao.asset_icon_url ? (
                      <img
                        src={dao.asset_icon_url}
                        alt={`${dao.asset_name || dao.asset_symbol} icon`}
                        className="w-full h-full object-cover"
                        onError={(e) => {
                          e.currentTarget.style.display = "none";
                          const fallback = e.currentTarget
                            .nextElementSibling as HTMLElement;
                          if (fallback) fallback.style.display = "flex";
                        }}
                      />
                    ) : null}
                    <div
                      className="w-8 h-8 rounded-full bg-gradient-to-br from-blue-500/40 to-blue-700/40 flex items-center justify-center shadow-md"
                      style={{ display: dao.asset_icon_url ? "none" : "flex" }}
                    >
                      <Text size="1" className="text-blue-300 font-semibold">
                        {dao.asset_symbol?.charAt(0) || "A"}
                      </Text>
                    </div>
                  </div>
                  <div className="flex-1 min-w-0">
                    <Text weight="bold" size="2" className="text-gray-200">
                      {dao.asset_name || dao.asset_symbol}
                    </Text>
                    <Text size="1" className="text-gray-400">
                      • Asset Token
                    </Text>
                    <div className="mt-1">
                      <ExplorerLink id={dao.assetType} isAddress={false} />
                    </div>
                  </div>
                  <div className="relative group flex-shrink-0">
                    <div className="w-5 h-5 rounded-full bg-gray-700 hover:bg-gray-600 flex items-center justify-center cursor-help transition-colors">
                      <Text size="1" className="text-gray-300">
                        i
                      </Text>
                    </div>
                    <div
                      className="absolute right-0 w-48 p-2 bg-gray-800/95 rounded-md shadow-xl border border-gray-700 
                      hidden group-hover:block z-10 text-sm backdrop-blur-sm"
                    >
                      <div className="space-y-1">
                        <Flex justify="between" className="text-gray-300">
                          <Text size="1">Decimals</Text>
                          <Text size="1" weight="bold">
                            {dao.asset_decimals}
                          </Text>
                        </Flex>
                        <Flex justify="between" className="text-gray-300">
                          <Text size="1">Min Amount</Text>
                          <Text size="1" weight="bold">
                            {parseFloat(dao.minAssetAmount) /
                              Math.pow(10, dao.asset_decimals || 0)}{" "}
                            {dao.asset_symbol}
                          </Text>
                        </Flex>
                      </div>
                    </div>
                  </div>
                </Flex>
              </div>

              {/* Stable Token Card */}
              <div className="p-3 bg-gray-800/70 rounded-lg border border-gray-700/50">
                <Flex align="center" gap="3">
                  <div className="w-8 h-8 rounded-full overflow-hidden shadow-md flex-shrink-0">
                    {dao.stable_icon_url ? (
                      <img
                        src={dao.stable_icon_url}
                        alt={`${dao.stable_name || dao.stable_symbol} icon`}
                        className="w-full h-full object-cover"
                        onError={(e) => {
                          e.currentTarget.style.display = "none";
                          const fallback = e.currentTarget
                            .nextElementSibling as HTMLElement;
                          if (fallback) fallback.style.display = "flex";
                        }}
                      />
                    ) : null}
                    <div
                      className="w-8 h-8 rounded-full bg-gradient-to-br from-green-500/40 to-green-700/40 flex items-center justify-center shadow-md"
                      style={{ display: dao.stable_icon_url ? "none" : "flex" }}
                    >
                      <Text size="1" className="text-green-300 font-semibold">
                        {dao.stable_symbol?.charAt(0) || "S"}
                      </Text>
                    </div>
                  </div>
                  <div className="flex-1 min-w-0">
                    <Text weight="bold" size="2" className="text-gray-200">
                      {dao.stable_name || dao.stable_symbol}
                    </Text>
                    <Text size="1" className="text-gray-400">
                      • Stable Token
                    </Text>
                    <div className="mt-1">
                      <ExplorerLink id={dao.stableType} isAddress={false} />
                    </div>
                  </div>
                  <div className="relative group flex-shrink-0">
                    <div className="w-5 h-5 rounded-full bg-gray-700 hover:bg-gray-600 flex items-center justify-center cursor-help transition-colors">
                      <Text size="1" className="text-gray-300">
                        i
                      </Text>
                    </div>
                    <div
                      className="absolute right-0 w-48 p-2 bg-gray-800/95 rounded-md shadow-xl border border-gray-700 
                      hidden group-hover:block z-10 text-sm backdrop-blur-sm"
                    >
                      <div className="space-y-1">
                        <Flex justify="between" className="text-gray-300">
                          <Text size="1">Decimals</Text>
                          <Text size="1" weight="bold">
                            {dao.stable_decimals}
                          </Text>
                        </Flex>
                        <Flex justify="between" className="text-gray-300">
                          <Text size="1">Min Amount</Text>
                          <Text size="1" weight="bold">
                            {parseFloat(dao.minStableAmount) /
                              Math.pow(10, dao.stable_decimals || 0)}{" "}
                            {dao.stable_symbol}
                          </Text>
                        </Flex>
                      </div>
                    </div>
                  </div>
                </Flex>
              </div>
            </div>
          </Card>
        </div>

        {/* Right Column */}
        <div className="lg:col-span-2 space-y-6">
          <Flex className="" direction="column">
            <Flex justify="between" align="center" className="mb-4">
              <Heading size="3" className="text-gray-200">
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
              <div className="space-y-4">
                {proposals.slice(0, 5).map((proposal) => (
                  <Link
                    to={`/trade/${proposal.proposal_id}`}
                    key={proposal.proposal_id}
                    className="block p-4 bg-gray-800/70 hover:bg-gray-800 rounded-lg border border-gray-700/50 hover:border-indigo-600/30 transition-all"
                  >
                    <Flex justify="between" align="start">
                      <div className="flex-1">
                        <Text weight="bold" size="3" className="text-gray-200">
                          {proposal.title}
                        </Text>
                        <Text
                          size="2"
                          className="text-gray-400 mt-1 line-clamp-2"
                        >
                          {proposal.details}
                        </Text>
                        <Flex gap="2" className="mt-2">
                          <ProposalStatus 
                            state={proposal.current_state} 
                            winningOutcome={proposal.winning_outcome}
                            variant="soft"
                          />
                          <Text size="1" className="text-gray-500">
                            {new Date(
                              Number(proposal.created_at),
                            ).toLocaleDateString()}
                          </Text>
                        </Flex>
                      </div>
                    </Flex>
                  </Link>
                ))}
              </div>
            ) : (
              <div className="text-center py-8 text-gray-400">
                <Text size="2">No proposals found</Text>
              </div>
            )}
          </Flex>
        </div>
      </div>

      <Dialog.Root
        open={showCreateProposal}
        onOpenChange={setShowCreateProposal}
      >
        <Dialog.Content className="max-w-4xl bg-gray-900 border border-gray-800">
          <Dialog.Title className="text-gray-200">
            Create New Proposal for {dao?.dao_name}
          </Dialog.Title>
          <div className="mt-4">
            <CreateProposalForm
              walletAddress={account?.address ?? ""}
              daoIdFromUrl={daoId}
            />
          </div>
        </Dialog.Content>
      </Dialog.Root>

      <Dialog.Root open={showVerifyDao} onOpenChange={setShowVerifyDao}>
        <Dialog.Content className="max-w-4xl bg-gray-900 border border-gray-800">
          <Dialog.Title className="text-gray-200">
            Get DAO Verified
          </Dialog.Title>
          <Dialog.Description className="text-gray-400">
            Verify your DAO to build trust with the community
          </Dialog.Description>
          <div className="mt-4">
            <VerifyDaoForm />
          </div>
        </Dialog.Content>
      </Dialog.Root>
    </div>
  );
}