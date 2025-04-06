import { SuiEvent } from '@mysten/sui/client';
import { Prisma } from '@prisma/client';
import { prisma } from '../db';

interface ProposalStateChanged {
    proposal_id: string;
    old_state: number;
    new_state: number;
    timestamp: string;
}

type ProposalStateChangeCreate = Prisma.ProposalStateChangeCreateInput & {
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

function validateStateChangeData(data: any): data is ProposalStateChanged {
    const requiredFields = [
        'proposal_id',
        'old_state',
        'new_state',
        'timestamp'
    ];

    // Check for undefined fields
    const missingFields = requiredFields.filter(field => data[field] === undefined);
    if (missingFields.length > 0) {
        console.error('Missing required fields:', missingFields);
        return false;
    }

    // Validate numeric fields
    if (!Number.isInteger(data.old_state)) {
        console.error('Invalid old_state:', data.old_state);
        return false;
    }
    if (!Number.isInteger(data.new_state)) {
        console.error('Invalid new_state:', data.new_state);
        return false;
    }

    // Validate state ranges (assuming states are u8)
    if (data.old_state < 0 || data.old_state > 255) {
        console.error('old_state out of u8 range:', data.old_state);
        return false;
    }
    if (data.new_state < 0 || data.new_state > 255) {
        console.error('new_state out of u8 range:', data.new_state);
        return false;
    }

    return true;
}

export const handleProposalStateChanges = async (events: SuiEvent[], type: string) => {
    const stateChanges: ProposalStateChangeCreate[] = [];
    console.log(`Processing ${events.length} events for ${type}`);

    // Process all events
    for (const event of events) {
        try {
            const eventType = event.type.split('::').pop();
            
            if (!eventType?.includes('ProposalStateChanged')) {
                console.warn(`Skipping non-state-change event: ${event.type}`);
                continue;
            }

            const data = event.parsedJson as ProposalStateChanged;
            console.log('Processing event data:', data);
            
            // Validate all required fields are present
            if (!validateStateChangeData(data)) {
                console.error('Invalid state change data:', data);
                continue;
            }

            stateChanges.push({
                old_state: data.old_state,
                new_state: data.new_state,
                timestamp: safeBigInt(data.timestamp),
                proposal: {
                    connect: {
                        proposal_id: data.proposal_id
                    }
                }
            });
        } catch (error) {
            console.error('Error processing event:', error);
            console.error('Event data:', event);
            continue;
        }
    }

    // Process in batches of 10
    const BATCH_SIZE = 10;
    for (let i = 0; i < stateChanges.length; i += BATCH_SIZE) {
        const batch = stateChanges.slice(i, i + BATCH_SIZE);
        try {
            await prisma.$transaction(async (tx) => {
                for (const change of batch) {
                    const proposalId = change.proposal.connect.proposal_id;
                    console.log('Processing state change:', {
                        proposal_id: proposalId,
                        old_state: change.old_state,
                        new_state: change.new_state,
                        timestamp: change.timestamp.toString()
                    });

                    const proposal = await tx.proposal.findUnique({
                        where: { proposal_id: proposalId }
                    });

                    if (!proposal) {
                        // Create placeholder proposal if it doesn't exist
                        await tx.proposal.create({
                            data: {
                                proposal_id: proposalId,
                                market_state_id: proposalId,  
                                dao_id: "pending",
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
                                current_state: change.new_state,
                                review_period_ms: 0n,
                                trading_period_ms: 0n,
                                twap_start_delay: 0n,
                                twap_step_max: 0n,
                                twap_threshold: 0n,
                                initial_outcome_amounts: null
                            }
                        });
                    }

                    // Create state change record
                    await tx.proposalStateChange.create({
                        data: change
                    });

                    // Get the latest state change for this proposal
                    const latestStateChange = await tx.proposalStateChange.findFirst({
                        where: { proposal_id: proposalId },
                        orderBy: { timestamp: 'desc' }
                    });

                    // Only update if this is the newest state change we've seen
                    if (!latestStateChange || change.timestamp >= latestStateChange.timestamp) {
                        await tx.proposal.update({
                            where: { proposal_id: proposalId },
                            data: { current_state: change.new_state }
                        });
                        console.log(`Updated proposal ${proposalId} state to ${change.new_state}`);
                    } else {
                        console.log(`Skipped outdated state update for proposal ${proposalId}`);
                        console.log(`Current timestamp: ${latestStateChange.timestamp}, incoming: ${change.timestamp}`);
                    }
                }
            }, {
                timeout: 30000 // 30 second timeout
            });
            console.log(`Successfully processed batch ${i / BATCH_SIZE + 1} of ${Math.ceil(stateChanges.length / BATCH_SIZE)}`);
        } catch (error) {
            if (error instanceof Prisma.PrismaClientKnownRequestError) {
                if (error.code === 'P2025') {
                    console.warn('Some proposals not found for state changes');
                    continue;
                }
                console.error(`Database error in batch ${i / BATCH_SIZE + 1}:`, error);
            } else {
                console.error(`Failed to process batch ${i / BATCH_SIZE + 1}:`, error);
            }
            console.error('Failed batch data:', JSON.stringify(batch, null, 2));
            continue; // Continue with next batch instead of throwing
        }
    }
};

export type { ProposalStateChanged };
