import { SuiEvent } from '@mysten/sui/client';
import { Prisma } from '@prisma/client';
import { prisma } from '../db';
import { CONFIG } from '../config';
import { sendDiscordWebhook } from './discord-webhook';

interface ProposalCreated {
    proposal_id: string;
    dao_id: string;
    proposer: string;
    outcome_count: string;
    outcome_messages: string[];  // Simple vector of strings now
    created_at: string;
    market_state_id: string;
    escrow_id: string;
    asset_value: string;
    stable_value: string;
    asset_type: string;
    stable_type: string;
    title: string;
    details: string;
    metadata: string;
    package_id: string;
    review_period_ms: string;
    trading_period_ms: string;
    initial_outcome_amounts: string[] | null;  // Handle Option<vector<u64>>
    twap_start_delay: string;
    twap_initial_observation: string;
    twap_step_max: string;
    twap_threshold: string;
    oracle_ids: string[];
}

// Helper to safely convert string to BigInt
function safeBigInt(value: string | undefined | null, defaultValue: bigint = 0n): bigint {
    if (!value) return defaultValue;
    try {
        return BigInt(value);
    } catch {
        return defaultValue;
    }
}

// Custom serializer for BigInt values
function serializeBigInt(key: string, value: any): any {
    if (typeof value === 'bigint') {
        return value.toString();
    }
    return value;
}

// Send Discord webhook notification for new proposal
async function sendDiscordNotification(proposal: ProposalNotificationPayload): Promise<void> {
    if (!CONFIG.DISCORD_WEBHOOK_URL) {
        console.log('Discord webhook URL not configured, skipping notification');
        return;
    }

    try {
        const networkLabel = CONFIG.NETWORK === 'mainnet' ? '🌐 Mainnet' : '🧪 Testnet';
        
        const embed = {
            title: `${networkLabel} - New Proposal: ${proposal.title}`,
            color: CONFIG.NETWORK === 'mainnet' ? 0x0099ff : 0x00ff00, // Blue for mainnet, green for testnet
            author: {
                name: proposal.dao_name || 'Unknown Org'
                // icon_url will be set by discord-webhook.ts if attachment succeeds
            },
            fields: [
                {
                    name: 'Verified:',
                    value: proposal.is_verified ? '✅ Verified' : '⚠️ Unverified',
                    inline: true
                },
                {
                    name: 'Title:',
                    value: proposal.title,
                    inline: false
                },
                {
                    name: 'Proposal Type:',
                    value: "Memo",
                    inline: false
                },
                {
                    name: 'Outcomes:',
                    value: proposal.outcome_messages.join('\n'),
                    inline: false
                }
            ],
            timestamp: new Date().toISOString()
        };

        await sendDiscordWebhook({
            webhookUrl: CONFIG.DISCORD_WEBHOOK_URL,
            embed,
            attachmentPath: proposal.dao_icon_cache_path,
            attachmentFilename: `dao-icon-${proposal.proposal_id}`
        });

        console.log(`Discord notification sent for proposal ${proposal.proposal_id} on ${CONFIG.NETWORK}`);
    } catch (error) {
        console.error('Error sending Discord notification:', error);
    }
}

// Validate required fields in proposal data
function validateProposalData(data: unknown): data is ProposalCreated {
    if (!data || typeof data !== 'object') return false;
  
    const requiredFields = [
        'proposal_id', 'dao_id', 'proposer', 'market_state_id',
        'outcome_count', 'outcome_messages', 'created_at', 'escrow_id',
        'asset_value', 'stable_value', 'asset_type',
        'stable_type', 'title', 'details', 'metadata',
        'review_period_ms', 'trading_period_ms', 'initial_outcome_amounts',
        'twap_start_delay', 'twap_step_max', 'twap_threshold', 'oracle_ids'
    ];
  
    return requiredFields.every(field => {
        const hasField = field in data;
        if (!hasField) console.error(`Missing required field: ${field}`);
        return hasField;
    });
}

// Convert proposal data to database format
function formatProposalData(data: ProposalCreated): Prisma.ProposalCreateInput {
    const outcomeCount = Number(data.outcome_count); 
    return {
        proposal_id: data.proposal_id,
        market_state_id: data.market_state_id,
        dao: {
            connect: {
                dao_id: data.dao_id
            }
        },
        proposer: data.proposer,
        outcome_count: safeBigInt(data.outcome_count),
        outcome_messages: JSON.stringify(data.outcome_messages), // Just stringify the array of strings
        created_at: safeBigInt(data.created_at),
        escrow_id: data.escrow_id,
        asset_value: safeBigInt(data.asset_value),
        stable_value: safeBigInt(data.stable_value),
        asset_type: data.asset_type,
        stable_type: data.stable_type,
        title: data.title,
        details: data.details,
        metadata: data.metadata,
        package_id: CONFIG.FUTARCHY_CONTRACT.packageId,
        current_state: 0,
        state_history: { create: [] },
        review_period_ms: safeBigInt(data.review_period_ms),
        trading_period_ms: safeBigInt(data.trading_period_ms),
        initial_outcome_amounts: data.initial_outcome_amounts ? JSON.stringify(data.initial_outcome_amounts) : null,
        twap_start_delay: safeBigInt(data.twap_start_delay),
        twap_initial_observation: safeBigInt(data.twap_initial_observation),
        twap_step_max: safeBigInt(data.twap_step_max),
        twap_threshold: safeBigInt(data.twap_threshold),
        twapHistory: {
            create: Array.from({ length: outcomeCount }, (_, i) => ({
                outcome: i,
                twap: null,
                timestamp: safeBigInt(data.created_at),
                oracle_id: data.oracle_ids[i]
            }))
        }

    };
}

// Process a batch of proposals
async function processBatch(
    proposals: Array<Prisma.ProposalCreateInput>,
    batchIndex: number
): Promise<void> {
    try {
        await prisma.$transaction(async (tx) => {
            for (const proposal of proposals) {
                console.log('Processing proposal:', proposal.proposal_id);
                
                // Use JSON.stringify with custom serializer for logging
                const logData = JSON.stringify(proposal, serializeBigInt, 2);
                console.log('Proposal data:', logData);
                
                const existingProposal = await tx.proposal.findUnique({
                    where: { proposal_id: proposal.proposal_id },
                    select: { current_state: true }
                });
                
                if (!existingProposal) {
                    // Create new proposal with initial state 0
                    await tx.proposal.create({
                        data: proposal
                    });
                    
                    // Fetch DAO name from database
                    // If proposal.dao is a connect object, get the dao_id from it
                    // Otherwise, use the direct dao_id field from proposal
                    const daoId = typeof proposal.dao === 'object' && proposal.dao?.connect?.dao_id 
                        ? proposal.dao.connect.dao_id 
                        : (proposal as any).dao_id || '';
                    
                    const dao = await tx.dao.findUnique({
                        where: { dao_id: daoId },
                        select: { 
                            dao_name: true,
                            icon_cache_path: true,
                            icon_url: true,
                            verification: {
                                select: {
                                    verified: true
                                }
                            }
                        }
                    });
                    
                    // Send Discord notification for new proposal
                    // Note: We'll need to reconstruct the ProposalCreated data with minimal fields
                    const proposalData: ProposalNotificationPayload = {
                        proposal_id: proposal.proposal_id,
                        dao_name: dao?.dao_name || 'Unknown DAO',
                        dao_icon_cache_path: dao?.icon_cache_path || null,
                        dao_icon_url: dao?.icon_url || null,
                        title: proposal.title,
                        details: proposal.details,
                        outcome_messages: JSON.parse(proposal.outcome_messages as string),
                        created_at: proposal.created_at.toString(),
                    };

                    // Send notification asynchronously (don't wait for it)
                    sendDiscordNotification(proposalData).catch(error =>
                        console.error('Failed to send Discord notification:', error)
                    );
                } else {
                    // Update proposal but preserve current_state
                    const { current_state, twapHistory, ...updateData } = proposal;
                    await tx.proposal.update({
                        where: { proposal_id: proposal.proposal_id },
                        data: updateData
                    });
                }
            }
        }, {
            timeout: 30000 // 30 second timeout
        });
        console.log(`Successfully processed batch ${batchIndex}`);
    } catch (error) {
        console.error(`Failed to process batch ${batchIndex}:`, error);
        throw error;
    }
}

export async function handleProposalObjects(events: SuiEvent[], type: string): Promise<void> {
    const proposals: Array<Omit<Prisma.ProposalCreateInput, 'state_history'>> = [];
    const BATCH_SIZE = 10;

    // Process all events
    for (const event of events) {
        try {
            const eventType = event.type.split('::').pop();
            
            if (!eventType?.includes('ProposalCreated')) {
                console.warn(`Skipping non-proposal event: ${event.type}`);
                continue;
            }

            if (!validateProposalData(event.parsedJson)) {
                console.error('Invalid proposal data:', 
                    JSON.stringify(event.parsedJson, serializeBigInt, 2));
                continue;
            }

            const formattedProposal = formatProposalData(event.parsedJson as ProposalCreated);
            proposals.push(formattedProposal);
        } catch (error) {
            console.error('Error processing event:', error);
            console.error('Event data:', 
                JSON.stringify(event, serializeBigInt, 2));
        }
    }

    // Process in batches
    for (let i = 0; i < proposals.length; i += BATCH_SIZE) {
        const batch = proposals.slice(i, i + BATCH_SIZE);
        const batchIndex = Math.floor(i / BATCH_SIZE);
        await processBatch(batch, batchIndex);
    }
}

function serializeBigInts(obj: any): any {
    if (obj === null || obj === undefined) {
        return obj;
    }
  
    if (typeof obj === 'bigint') {
        return obj.toString();
    }
  
    if (Array.isArray(obj)) {
        return obj.map(item => serializeBigInts(item));
    }
  
    if (typeof obj === 'object') {
        const serialized: { [key: string]: any } = {};
        for (const [key, value] of Object.entries(obj)) {
            serialized[key] = serializeBigInts(value);
        }
        return serialized;
    }
  
    return obj;
}