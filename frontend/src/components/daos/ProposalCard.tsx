import { Link } from "react-router-dom";
import { Flex, Text } from "@radix-ui/themes";
import { ProposalStatus } from "@/components/ProposalStatus";

interface ProposalCardProps {
    proposal: {
        proposal_id: string;
        title: string;
        details: string;
        created_at: string;
        current_state: number;
        winning_outcome: string;
    };
    variant?: "active" | "finalized";
}

export function ProposalCard({ proposal, variant = "active" }: ProposalCardProps) {
    const isFinalized = variant === "finalized";
    const isPremarket = proposal.current_state === 0;
    const isTrading = proposal.current_state === 1;

    const baseClasses = "block p-4 rounded-lg border transition-all duration-200";

    let variantClasses = "";
    let titleClasses = "";
    let detailsClasses = "";

    if (isFinalized) {
        variantClasses = "bg-gray-800/30 hover:bg-gray-800/40 border-gray-700/20 hover:border-gray-600/30";
        titleClasses = "text-gray-100";
        detailsClasses = "text-gray-500";
    } else if (isPremarket) {
        variantClasses = "bg-gray-800/20 hover:bg-gray-800/30 border-dashed border-2 border-gray-700/50 hover:border-gray-600/70";
        titleClasses = "text-gray-100";
        detailsClasses = "text-gray-400";
    } else if (isTrading) {
        variantClasses = "bg-gray-800/80 hover:bg-gray-800 border border-gray-600/50 hover:border-gray-500/70";
        titleClasses = "text-gray-100";
        detailsClasses = "text-gray-300";
    } else {
        // Default active state
        variantClasses = "bg-gray-800/70 hover:bg-gray-800 border-gray-700/50 hover:border-gray-600/50";
        titleClasses = "text-gray-200";
        detailsClasses = "text-gray-400";
    }

    return (
        <Link
            to={`/trade/${proposal.proposal_id}`}
            className={`${baseClasses} ${variantClasses}`}
        >
            <Flex justify="between" align="start">
                <div className="flex-1">
                    <Flex gap="2" align="center">
                        {isTrading && (
                            <div className="relative">
                                <div className="w-2 h-2 rounded-full bg-blue-500" />
                                <div className="absolute inset-0 rounded-full bg-blue-500 animate-ping opacity-75" />
                            </div>
                        )}
                        <Text
                            weight="bold"
                            size="3"
                            className={titleClasses}
                        >
                            {proposal.title}
                        </Text>

                    </Flex>
                    <Text
                        size="2"
                        className={`${detailsClasses} mt-1 line-clamp-2`}
                    >
                        {proposal.details}
                    </Text>
                    <Text size="1" className="text-gray-500 mt-2">
                        {new Date(
                            Number(proposal.created_at),
                        ).toLocaleDateString()}
                    </Text>
                </div>
                <ProposalStatus
                    state={proposal.current_state}
                    winningOutcome={proposal.winning_outcome}
                    variant="soft"
                />
            </Flex>
        </Link>
    );
} 