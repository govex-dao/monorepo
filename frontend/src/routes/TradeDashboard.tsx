import { Link, useSearchParams } from "react-router-dom";
import { useState, useRef } from "react";
import { useQuery } from "@tanstack/react-query";
import { CONSTANTS, QueryKey } from "@/constants";
import { Theme, Tooltip, DropdownMenu, Checkbox } from "@radix-ui/themes";
import { constructUrlSearchParams } from "@/utils/helpers";
import { VerifiedIcon } from "@/components/icons/VerifiedIcon";
import { ChevronDownIcon } from "@radix-ui/react-icons";
import UnifiedSearch from "@/components/UnifiedSearch.tsx";
import UnverifiedIcon from "@/components/icons/UnverifiedIcon";
import { DaoIcon } from "@/components/DaoIcon";
import { ProposalStatus } from "@/components/ProposalStatus";

interface ApiProposal {
  id: number;
  proposal_id: string;
  dao_id: string;
  dao_name: string;
  dao_icon: string | null;
  asset_type: string;
  stable_type: string;
  proposer: string;
  title: string;
  created_at: string;
  state_history_count: number;
  current_state: number;
  market_state_id: string;
  asset_value: string;
  stable_value: string;
  dao_verified: boolean;
  winning_outcome: string | null;
}

const stateOptions = [
  { label: "Pre-market", value: "PRE-MARKET" },
  { label: "Trading", value: "TRADING" },
  { label: "Finished", value: "FINISHED" },
];

const getStateLabel = (state: number | null): string => {
  switch (state) {
    case 0:
      return "PRE-MARKET";
    case 1:
      return "TRADING";
    case 2:
      return "FINISHED";
    default:
      return "PRE-MARKET";
  }
};

interface ProposalCardProps {
  proposal: ApiProposal;
}

function ProposalCard({ proposal }: ProposalCardProps) {
  return (
    <Link to={`/trade/${proposal.market_state_id}`} className="block">
      <div className="group bg-gray-800 rounded-lg shadow-sm border border-gray-700 p-5 hover:shadow-md hover:bg-gray-700 hover:border-gray-600 group-hover:text-white transition">
        <div className="flex justify-between items-start mb-4">
          <Tooltip
            content={
              <p
                className="text-sm text-gray-100 max-w-xl"
                style={{
                  backgroundColor: "#1f2937",
                  border: "1px solid #374151",
                  boxShadow: "0 2px 4px rgba(0,0,0,0.1)",
                  padding: "8px",
                  borderRadius: "6px",
                  outline: "none",
                }}
              >
                {proposal.title}
              </p>
            }
            style={{
              outline: "none",
            }}
          >
            <h3
              className="text-lg font-semibold text-gray-100 line-clamp-2 leading-tight h-10 mr-1 overflow-hidden max-w-[180px]"
              style={{ height: "2.7rem" }}
            >
              {proposal.title}
            </h3>
          </Tooltip>
          <ProposalStatus
            state={proposal.current_state}
            winningOutcome={proposal.winning_outcome}
          />
        </div>

        <div className="flex flex-col">
          <div className="flex items-center gap-2">
            <div className="flex items-center gap-1">
              <DaoIcon
                icon={proposal.dao_icon}
                name={proposal.dao_name}
                size="md"
              />
              <span className="text-gray-200 truncate font-medium transition-colors group-hover:text-white ">
                {proposal.dao_name}
              </span>
            </div>
            {proposal.dao_verified ? (
              <VerifiedIcon className="ml-1 flex-shrink-0" />
            ) : (
              <UnverifiedIcon className="ml-1 flex-shrink-0" />
            )}
          </div>
        </div>
      </div>
    </Link>
  );
}

export function TradeDashboard() {
  const [selectedStates, setSelectedStates] = useState<string[]>(
    stateOptions.map((option) => option.value),
  );
  const [isOpen, setIsOpen] = useState(false);
  const closeTimeoutRef = useRef<NodeJS.Timeout>();
  const [searchParams] = useSearchParams();
  const daoid = searchParams.get("dao");
  const endpoint = daoid ? `dao/${daoid}/proposals` : "proposals";

  const {
    data: proposalsData,
    isLoading,
    error,
  } = useQuery({
    queryKey: [QueryKey.Proposals, daoid],
    queryFn: async () => {
      const url =
        CONSTANTS.apiEndpoint +
        endpoint +
        constructUrlSearchParams({
          limit: "10",
          ...(daoid ? { dao_id: daoid } : {}),
        });

      const response = await fetch(url);
      if (!response.ok) {
        throw new Error(`API error: ${response.statusText}`);
      }

      return response.json();
    },
  });

  const filteredProposals = proposalsData?.data?.filter(
    (proposal: ApiProposal) =>
      selectedStates.includes(getStateLabel(proposal.current_state)),
  );

  const handleStateToggle = (value: string) => {
    setSelectedStates((prev: string[]) => {
      const isSelected = prev.includes(value);
      if (isSelected) {
        return prev.filter((state: string) => state !== value);
      } else {
        return [...prev, value];
      }
    });

    // Clear any existing timeout
    if (closeTimeoutRef.current) {
      clearTimeout(closeTimeoutRef.current);
    }

    // Set a new timeout
    closeTimeoutRef.current = setTimeout(() => {
      setIsOpen(false);
    }, 1000);
  };

  if (isLoading) {
    return (
      <div className="w-full p-6 text-center text-gray-400">
        Loading proposals...
      </div>
    );
  }

  if (error) {
    return (
      <div className="w-full p-6 text-center text-red-400">
        Error loading proposals: {error.message}
      </div>
    );
  }

  return (
    <Theme appearance="dark" className="flex flex-col items-center flex-grow">
      <div className="w-full px-6 py-6 pb-6 pt-0 max-w-7xl">
        <div className="flex flex-col md:flex-row md:justify-end gap-4">
          <UnifiedSearch />
          <DropdownMenu.Root open={isOpen} onOpenChange={setIsOpen}>
            <DropdownMenu.Trigger className="w-fit self-end">
              <button className="flex items-center gap-2 px-4 py-2 bg-gray-800 border border-gray-700 rounded-lg text-gray-200 text-sm">
                Filter by state
                <ChevronDownIcon />
              </button>
            </DropdownMenu.Trigger>
            <DropdownMenu.Content className="bg-gray-800 border border-gray-700 rounded-lg p-2">
              {stateOptions.map((option) => (
                <DropdownMenu.Item
                  key={option.value}
                  className="flex items-center gap-3 px-1 py-1 text-gray-200 text-base cursor-pointer hover:bg-gray-700 rounded w-full focus:bg-transparent active:bg-transparent data-[highlighted]:bg-transparent data-[state=checked]:bg-transparent radix-highlighted:bg-transparent"
                  onClick={(e) => {
                    e.preventDefault();
                    handleStateToggle(option.value);
                  }}
                  onSelect={(e) => {
                    // Prevent the dropdown from closing
                    e.preventDefault();
                  }}
                >
                  <div className="flex items-center gap-3 w-full">
                    <Checkbox
                      checked={selectedStates.includes(option.value)}
                      className="data-[state=checked]:bg-blue-600"
                    />
                    <span>{option.label}</span>
                  </div>
                </DropdownMenu.Item>
              ))}
            </DropdownMenu.Content>
          </DropdownMenu.Root>
        </div>
        <div className="grid grid-cols-1 sm:grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-3 2xl:grid-cols-4 gap-6 mt-4">
          {filteredProposals?.map((proposal: ApiProposal) => (
            <ProposalCard key={proposal.id} proposal={proposal} />
          ))}
        </div>
        {(!filteredProposals || filteredProposals.length === 0) && (
          <div className="text-center text-gray-400 mt-8">
            No proposals found
          </div>
        )}
      </div>
    </Theme>
  );
}

export default TradeDashboard;
