import { SuiEvent } from '@mysten/sui/client';
import { Prisma, PrismaClient } from '@prisma/client';
import { prisma } from '../db';

interface ProposalResult {
    proposal_id: string;
    dao_id: string;
    outcome: string;
    winning_outcome: string;
    timestamp: string;
}

// Use the correct Prisma types from the generated client
type ProposalResultCreate = {
    proposal_id: string;
    dao_id: string;
    outcome: string;
    winning_outcome: bigint;
    timestamp: bigint;
    proposal: {
        connect: {
            proposal_id: string;
        };
    };
};

function safeBigInt(value: string | undefined | null, defaultValue: bigint = 0n): bigint {
    if (!value) return defaultValue;
    try {
        return BigInt(value);
    } catch {
        return defaultValue;
    }
}

function validateResultData(data: any): data is ProposalResult {
    const requiredFields = [
        'proposal_id',
        'dao_id',
        'outcome',
        'winning_outcome',
        'timestamp'
    ];

    // Check for undefined fields
    const missingFields = requiredFields.filter(field => data[field] === undefined);
    if (missingFields.length > 0) {
        console.error('Missing required fields:', missingFields);
        return false;
    }

    // Additional validation could be added here
    // For example, validating winning_outcome is a valid number
    try {
        BigInt(data.winning_outcome);
    } catch {
        console.error('Invalid winning_outcome format:', data.winning_outcome);
        return false;
    }

    return true;
}

export const handleProposalResults = async (events: SuiEvent[], type: string) => {
    const results: ProposalResultCreate[] = [];
    console.log(`Processing ${events.length} result events for ${type}`);

    // Process all events
    for (const event of events) {
        try {
            const eventType = event.type.split('::').pop();
            
            if (!eventType?.includes('ResultSigned')) {
                console.warn(`Skipping non-result event: ${event.type}`);
                continue;
            }

            const data = event.parsedJson as ProposalResult;
            console.log('Processing result event data:', data);
            
            // Validate all required fields are present
            if (!validateResultData(data)) {
                console.error('Invalid result data:', data);
                continue;
            }

            results.push({
                proposal_id: data.proposal_id,
                dao_id: data.dao_id,
                outcome: data.outcome,
                winning_outcome: safeBigInt(data.winning_outcome),
                timestamp: safeBigInt(data.timestamp),
                proposal: {
                    connect: {
                        proposal_id: data.proposal_id
                    }
                }
            });
        } catch (error) {
            console.error('Error processing result event:', error);
            console.error('Event data:', event);
            continue;
        }
    }

    // Process each result individually since we can only have one result per proposal
    for (const result of results) {
        try {
            await prisma.$transaction(async (tx) => {
                const proposalId = result.proposal.connect.proposal_id;
                console.log('Processing result:', {
                    proposal_id: proposalId,
                    outcome: result.outcome,
                    winning_outcome: result.winning_outcome.toString(),
                    timestamp: result.timestamp.toString()
                });

                // Check if proposal exists
                const proposal = await tx.proposal.findUnique({
                    where: { proposal_id: proposalId }
                });

                if (!proposal) {
                    // Create placeholder proposal with nulls if we get result event first
                    await tx.proposal.create({
                        data: {
                            proposal_id: proposalId,
                            market_state_id: proposalId,
                            dao_id: result.dao_id, // Use the dao_id from the result
                            proposer: "pending",
                            outcome_count: 0n,
                            outcome_messages: "[]",
                            created_at: 0n,
                            escrow_id: "pending",
                            asset_value: 0n,
                            stable_value: 0n,
                            asset_type: "pending",
                            stable_type: "pending",
                            title: "pending",
                            details: "pending",
                            metadata: "pending",
                            current_state: null,
                            review_period_ms: 0n,
                            trading_period_ms: 0n,
                            twap_start_delay: 0n,
                            twap_step_max: 0n,
                            twap_threshold: 0n,
                            initial_outcome_amounts: null
                        }
                    });
                }

                // Create the result record
                await tx.proposalResult.upsert({
                    where: {
                        proposal_id: proposalId
                    },
                    update: {
                        outcome: result.outcome,
                        winning_outcome: result.winning_outcome,
                        timestamp: result.timestamp,
                        dao_id: result.dao_id
                    },
                    create: {
                        proposal_id: result.proposal_id,
                        dao_id: result.dao_id,
                        outcome: result.outcome,
                        winning_outcome: result.winning_outcome,
                        timestamp: result.timestamp
                    }
                });
            }, {
                timeout: 30000 // 30 second timeout
            });
            console.log(`Successfully processed result for proposal ${result.proposal.connect.proposal_id}`);
        } catch (error) {
            if (error instanceof Prisma.PrismaClientKnownRequestError) {
                console.error(`Database error processing result:`, error);
            } else {
                console.error(`Failed to process result:`, error);
            }
            console.error('Failed result data:', JSON.stringify(result, null, 2));
            continue;
        }
    }
};

export type { ProposalResult };