import { SuiEvent } from '@mysten/sui/client';
import { Prisma } from '@prisma/client';
import { prisma } from '../db';
import { safeBigInt } from '../utils/bigint';

interface VerificationRequestData {
    dao_id: string;
    requester: string;
    attestation_url: string;
    timestamp: string;
    verification_id: string;
}

function validateVerificationRequestData(data: any): data is VerificationRequestData {
    const requiredFields = [
        'dao_id',
        'requester',
        'attestation_url',
        'timestamp',
        'verification_id' 
    ];

    // Check for undefined fields
    const missingFields = requiredFields.filter(field => data[field] === undefined);
    if (missingFields.length > 0) {
        console.error('Missing required fields:', missingFields);
        return false;
    }

    // Validate string fields
    if (typeof data.dao_id !== 'string' || 
        typeof data.requester !== 'string' || 
        typeof data.attestation_url !== 'string' ||
        typeof data.verification_id !== 'string') {
        console.error('Invalid string fields:', data);
        return false;
    }

    // Validate timestamp can be converted to BigInt
    try {
        BigInt(data.timestamp);
    } catch {
        console.error('Invalid timestamp value:', data.timestamp);
        return false;
    }

    return true;
}

export const handleVerificationRequests = async (events: SuiEvent[], type: string) => {
    const verificationRequests: Array<{
        data: VerificationRequestData;
        timestamp: bigint;
    }> = [];
    console.log(`Processing ${events.length} events for ${type}`);

    // First pass: validate and collect all valid events
    for (const event of events) {
        try {
            const eventType = event.type.split('::').pop();
            
            if (!eventType?.includes('VerificationRequested')) {
                console.warn(`Skipping non-VerificationRequested event: ${event.type}`);
                continue;
            }

            if (!event.type.startsWith(type)) {
                console.error('Invalid event module origin:', event.type);
                continue;
            }

            const data = event.parsedJson as VerificationRequestData;
            
            // Validate all required fields are present
            if (!validateVerificationRequestData(data)) {
                console.error('Invalid VerificationRequest event data:', data);
                continue;
            }

            verificationRequests.push({
                data,
                timestamp: safeBigInt(data.timestamp)
            });
        } catch (error) {
            console.error('Error processing event:', error);
            console.error('Event data:', event);
            continue;
        }
    }

    // Sort requests by timestamp for consistent processing
    verificationRequests.sort((a, b) => Number(a.timestamp - b.timestamp));

    // Process in batches of 10
    const BATCH_SIZE = 10;
    for (let i = 0; i < verificationRequests.length; i += BATCH_SIZE) {
        const batch = verificationRequests.slice(i, i + BATCH_SIZE);
        try {
            await prisma.$transaction(async (tx) => {
                for (const request of batch) {
                    const { data, timestamp } = request;
                    const daoId = data.dao_id;

                    console.log('Processing VerificationRequest:', {
                        dao_id: daoId,
                        requester: data.requester,
                        timestamp: timestamp.toString()
                    });

                    try {
                        // First ensure the DAO exists with placeholder data if needed
                        await tx.dao.upsert({
                            where: { dao_id: daoId },
                            create: {
                                dao_id: daoId,
                                minAssetAmount: 0n,
                                minStableAmount: 0n,
                                timestamp,
                                assetType: "pending",
                                stableType: "pending",
                                icon_url: "pending",
                                dao_name: "pending",
                                asset_decimals: 0,
                                stable_decimals: 0,
                                asset_name: "pending",
                                stable_name: "pending",
                                asset_icon_url: "pending",
                                stable_icon_url: "pending",
                                asset_symbol: "pending",
                                stable_symbol: "pending",
                                review_period_ms: 0n,
                                trading_period_ms: 0n,
                                amm_twap_start_delay: 0n,
                                amm_twap_initial_observation: 0n,
                                amm_twap_step_max: 0n,
                                twap_threshold: 0n,
                                description: "pending"
                            },
                            update: {} // Don't update existing DAOs
                        });
                        
                        // Check if verification already exists for this verification_id
                        const existingVerification = await tx.daoVerification.findFirst({
                            where: {
                                dao_id: daoId,
                                verification_id: data.verification_id
                            }
                        });

                        // Create the verification request with appropriate status
                        await tx.daoVerificationRequest.create({
                            data: {
                                dao_id: daoId,
                                requester: data.requester,
                                attestation_url: data.attestation_url,
                                verification_id: data.verification_id,
                                timestamp,
                                // If verification exists, use its status, otherwise pending
                                status: existingVerification 
                                    ? (existingVerification.verified ? 'accepted' : 'rejected')
                                    : 'pending'
                            }
                        });

                        console.log(`Successfully created verification request for DAO ${daoId} with status: ${
                            existingVerification 
                                ? (existingVerification.verified ? 'accepted' : 'rejected') 
                                : 'pending'
                        }`);
                    } catch (error) {
                        if (error instanceof Prisma.PrismaClientKnownRequestError) {
                            console.error('Database error processing request:', {
                                code: error.code,
                                message: error.message,
                                dao_id: daoId
                            });
                            
                            if (error.code === 'P2002') {
                                console.warn('Duplicate verification request detected - continuing');
                                continue;
                            }
                        }
                        throw error; // Re-throw other errors to be caught by transaction
                    }
                }
            }, {
                timeout: 30000 // 30 second timeout
            });
            console.log(`Successfully processed batch ${i / BATCH_SIZE + 1} of ${Math.ceil(verificationRequests.length / BATCH_SIZE)}`);
        } catch (error) {
            console.error(`Failed to process batch ${i / BATCH_SIZE + 1}:`, error);
            if (error instanceof Prisma.PrismaClientKnownRequestError) {
                console.error('Batch processing error:', {
                    code: error.code,
                    message: error.message,
                    batch_number: i / BATCH_SIZE + 1
                });
            }
            console.error('Failed batch data:', JSON.stringify(batch, null, 2));
            continue; // Continue with next batch instead of throwing
        }
    }
};

export type { VerificationRequestData };