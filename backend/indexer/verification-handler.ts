import { SuiEvent } from '@mysten/sui/client';
import { Prisma } from '@prisma/client';
import { prisma } from '../db';

interface VerificationData {
    dao_id: string;
    verification_id: string;
    attestation_url: string;
    verified: boolean;
    validator: string;
    timestamp: string;
    reject_reason: string;
}

function safeBigInt(value: string | undefined | null, defaultValue: bigint = 0n): bigint {
    if (!value) return defaultValue;
    try {
        return BigInt(value);
    } catch {
        return defaultValue;
    }
}

function validateVerificationData(data: any): data is VerificationData {
    const requiredFields = [
        'dao_id',
        'verification_id',
        'attestation_url',
        'verified',
        'validator',
        'timestamp',
        'reject_reason'
    ];

    const missingFields = requiredFields.filter(field => data[field] === undefined);
    if (missingFields.length > 0) {
        console.error('Missing required fields:', missingFields);
        return false;
    }

    if (typeof data.dao_id !== 'string' ||
        typeof data.attestation_url !== 'string' ||
        typeof data.verified !== 'boolean' ||
        typeof data.validator !== 'string' ||
        typeof data.reject_reason !== 'string') {
        console.error('Invalid field types in verification data:', data);
        return false;
    }
    
    try {
        BigInt(data.timestamp);
    } catch {
        console.error('Invalid timestamp value:', data.timestamp);
        return false;
    }

    return true;
}

export const handleVerifications = async (events: SuiEvent[], type: string) => {
    console.log(`Found ${events.length} events for ${type}`);
    
    // Map to store latest verification per DAO
    const latestVerifications = new Map<string, {
        data: VerificationData;
        timestamp: bigint;
    }>();

    console.log('Processing and validating events...');

    // First pass: collect all valid events and keep only latest per DAO
    for (const event of events) {
        try {
            const eventType = event.type.split('::').pop();
            
            if (!eventType?.includes('DAOReviewed')) {
                console.warn(`Skipping non-Reviewed event: ${event.type}`);
                continue;
            }

            if (!event.type.startsWith(type)) {
                console.error('Invalid event module origin:', event.type);
                continue;
            }

            const data = event.parsedJson as VerificationData;
            
            if (!validateVerificationData(data)) {
                console.error('Invalid Verification event data:', data);
                continue;
            }

            const timestamp = safeBigInt(data.timestamp);
            const currentLatest = latestVerifications.get(data.dao_id);

            if (!currentLatest || timestamp > currentLatest.timestamp) {
                console.log(`Found ${currentLatest ? 'newer' : 'new'} verification for DAO ${data.dao_id}:`, {
                    timestamp: timestamp.toString(),
                    verified: data.verified,
                    previousTimestamp: currentLatest?.timestamp.toString()
                });
                
                latestVerifications.set(data.dao_id, {
                    data,
                    timestamp
                });
            }
        } catch (error) {
            console.error('Error pre-processing event:', error);
            console.error('Event data:', event);
            continue;
        }
    }

    // Convert to array and sort by DAO ID for consistent processing
    const verificationArray = Array.from(latestVerifications.values())
        .sort((a, b) => a.data.dao_id.localeCompare(b.data.dao_id));

    console.log(`Processing ${verificationArray.length} latest verifications...`);

    // Process in batches
    const BATCH_SIZE = 10;
    for (let i = 0; i < verificationArray.length; i += BATCH_SIZE) {
        const batch = verificationArray.slice(i, i + BATCH_SIZE);
        const batchNumber = Math.floor(i / BATCH_SIZE) + 1;
        const totalBatches = Math.ceil(verificationArray.length / BATCH_SIZE);
        
        console.log(`Processing batch ${batchNumber}/${totalBatches}`);

        try {
            await prisma.$transaction(async (tx) => {
                for (const verification of batch) {
                    const { data, timestamp } = verification;
                    const daoId = data.dao_id;

                    try {
                        console.log(`Processing verification for DAO ${daoId}:`, {
                            timestamp: timestamp.toString(),
                            verified: data.verified
                        });

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

                        await tx.daoVerificationRequest.updateMany({
                            where: {
                                dao_id: daoId,
                                verification_id: data.verification_id,
                                status: 'pending'
                            },
                            data: {
                                status: data.verified ? 'accepted' : 'rejected'
                            }
                        });

                        // Upsert verification state
                        await tx.daoVerification.upsert({
                            where: { dao_id: daoId },
                            create: {
                                dao_id: daoId,
                                verification_id: data.verification_id,
                                verified: data.verified,
                                validator: data.validator,
                                attestation_url: data.attestation_url,
                                timestamp,
                                reject_reason: data.reject_reason
                            },
                            update: {
                                verification_id: data.verification_id,
                                verified: data.verified,
                                validator: data.validator,
                                attestation_url: data.attestation_url,
                                timestamp,
                                reject_reason: data.reject_reason
                            }
                        });

                        console.log(`Successfully processed verification for DAO ${daoId}`);
                    } catch (error) {
                        if (error instanceof Prisma.PrismaClientKnownRequestError) {
                            console.error('Database error processing verification:', {
                                code: error.code,
                                message: error.message,
                                dao_id: daoId
                            });
                            
                            if (error.code === 'P2002') {
                                // Handle unique constraint violations
                                console.warn('Concurrent verification update detected - retrying');
                                // Let the transaction retry handle it
                                throw error;
                            }
                        }
                        throw error; // Re-throw other errors to be caught by transaction
                    }
                }
            }, {
                timeout: 30000 // 30 second timeout
            });
            console.log(`Successfully processed batch ${batchNumber}/${totalBatches}`);
        } catch (error) {
            console.error(`Failed to process batch ${batchNumber}/${totalBatches}:`, error);
            if (error instanceof Prisma.PrismaClientKnownRequestError) {
                console.error('Batch processing error:', {
                    code: error.code,
                    message: error.message,
                    batch_number: batchNumber
                });
            }
            console.error('Failed batch data:', JSON.stringify(batch, null, 2));
            continue; // Continue with next batch instead of throwing
        }
    }

    console.log('Verification processing completed');
};

export type { VerificationData };