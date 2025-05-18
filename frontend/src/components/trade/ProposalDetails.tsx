import React from "react";
import { AdvanceStateButton } from "../daos/AdvanceStateButton";
import MessageDecoder from "../converter";
import { ClipboardIcon } from "@radix-ui/react-icons";
import toast from "react-hot-toast";

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
  proposer: string;
  outcome_count: string;
  outcome_messages: string[];
  created_at: string;
  escrow_id: string;
  asset_value: string;
  stable_value: string;
  asset_type: string;
  stable_type: string;
  current_state: number;
  state_history: StateHistory[];
  winning_outcome: string | null;
}

interface ProposalDetailsProps {
  proposal: ApiProposal;
  outcomeMessages: any[];
}

const getStateLabel = (state: number | null): string => {
  switch (state) {
    case 0:
      return "Pre-market";
    case 1:
      return "Trading Started";
    case 2:
      return "Finalized";
    default:
      return "Pre-market";
  }
};

const ProposalDetails: React.FC<ProposalDetailsProps> = ({
  proposal,
  outcomeMessages,
}) => {
  return (
    <div className="rounded-lg shadow-lg">
      <div className="px-8 pb-8">
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6 text-gray-400">
          <div className="space-y-4">
            <div className="mb-4">
              <AdvanceStateButton
                proposalId={proposal.proposal_id}
                escrowId={proposal.escrow_id}
                assetType={proposal.asset_type}
                stableType={proposal.stable_type}
                daoId={proposal.dao_id}
                proposalState={proposal.current_state}
                winningOutcome={proposal.winning_outcome}
              />
            </div>
            <div className="flex justify-between">
              <span>TWAP Threshold</span>
              <span className="font-medium text-gray-200">
                {(Number(proposal.twap_threshold) / 1000).toFixed(2)}%
              </span>
            </div>
            <div className="flex justify-between">
              <span>Proposal ID</span>
              <div className="flex items-center space-x-2">
                <span className="font-medium text-gray-200">
                  {proposal?.proposal_id.slice(0, 6)}...
                  {proposal?.proposal_id.slice(-4)}
                </span>
                <button
                  onClick={() => {
                    navigator.clipboard.writeText(proposal?.proposal_id);
                    toast.success("Proposal ID copied to clipboard");
                  }}
                  className="hover:text-gray-200 transition-colors"
                >
                  <ClipboardIcon className="w-4 h-4" />
                </button>
              </div>
            </div>
            <div>
              <div className="space-y-3">
                <div className="flex justify-between">
                  <span>DAO ID</span>
                  <div className="flex items-center space-x-2">
                    <span className="font-medium text-gray-200">
                      {proposal.dao_id.slice(0, 6)}...
                      {proposal.dao_id.slice(-4)}
                    </span>
                    <button
                      onClick={() => {
                        navigator.clipboard.writeText(proposal.dao_id);
                        toast.success("DAO ID copied to clipboard");
                      }}
                      className="hover:text-gray-200 transition-colors"
                    >
                      <ClipboardIcon className="w-4 h-4" />
                    </button>
                  </div>
                </div>
                <div className="flex justify-between">
                  <span>Proposer</span>
                  <div className="flex items-center space-x-2">
                    <span className="font-medium text-gray-200">
                      {proposal.proposer.slice(0, 6)}...
                      {proposal.proposer.slice(-4)}
                    </span>
                    <button
                      onClick={() => {
                        navigator.clipboard.writeText(proposal.proposer);
                        toast.success("Proposer address copied to clipboard");
                      }}
                      className="hover:text-gray-200 transition-colors"
                    >
                      <ClipboardIcon className="w-4 h-4" />
                    </button>
                  </div>
                </div>
                <div className="flex justify-between">
                  <span>Created At</span>
                  <span className="font-medium text-gray-200">
                    {new Date(Number(proposal.created_at)).toLocaleString()}
                  </span>
                </div>

                <div className="space-y-3">
                  <div className="flex justify-between">
                    <span>Outcome Count </span>
                    <span className="font-medium text-gray-200">
                      {proposal.outcome_count}
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div className="space-y-4">
            <div>
              <h3 className="text-sm uppercase mb-2 text-gray-300">
                State History
              </h3>
              <div className="space-y-2 ">
                {proposal.state_history?.map(
                  (history: StateHistory, index: number) => (
                    <div
                      key={`${history.id}-${index}`}
                      className="bg-gray-900 p-3 rounded"
                    >
                      <p className="text-gray-200">
                        {getStateLabel(history.new_state)}
                      </p>
                      <p className="text-gray-400 text-sm">
                        {new Date(Number(history.timestamp)).toLocaleString()}
                      </p>
                    </div>
                  ),
                )}
                {(!proposal.state_history ||
                  proposal.state_history.length === 0) && (
                  <div className="text-gray-400">No state changes recorded</div>
                )}
              </div>
            </div>

            {outcomeMessages.length > 0 && (
              <div>
                <h3 className="text-sm uppercase mb-2 text-gray-300">
                  Outcomes
                </h3>
                <MessageDecoder messages={outcomeMessages} />
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
};

export default ProposalDetails;
