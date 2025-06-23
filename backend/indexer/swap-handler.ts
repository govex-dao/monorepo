import { SuiEvent } from '@mysten/sui/client';
import { Prisma } from '@prisma/client';
import { prisma } from '../db';

interface SwapEventData {
    market_id: string;
    outcome: number;
    is_buy: boolean;
    amount_in: string;
    amount_out: string;
    price_impact: string;
    price: string;
    sender: string;
    timestamp: string;
    asset_reserve: string;
    stable_reserve: string;
}

function safeBigInt(value: string | undefined | null, defaultValue: bigint = 0n): bigint {
    if (!value) return defaultValue;
    try {
        return BigInt(value);
    } catch {
        return defaultValue;
    }
}

function validateSwapEventData(data: any): data is SwapEventData {
    const requiredFields = [
        'market_id',
        'outcome',
        'is_buy',
        'amount_in',
        'amount_out',
        'price_impact',
        'price',
        'sender',
        'timestamp',
        'asset_reserve',
        'stable_reserve'
    ];

    // Check for undefined fields
    const missingFields = requiredFields.filter(field => data[field] === undefined);
    if (missingFields.length > 0) {
        console.error('Missing required fields:', missingFields);
        return false;
    }

    // Validate numeric fields
    if (!Number.isInteger(data.outcome)) {
        console.error('Invalid outcome:', data.outcome);
        return false;
    }

    // Validate u8 range for outcome
    if (data.outcome < 0 || data.outcome > 255) {
        console.error('outcome out of u8 range:', data.outcome);
        return false;
    }

    // Validate boolean field
    if (typeof data.is_buy !== 'boolean') {
        console.error('Invalid is_buy value:', data.is_buy);
        return false;
    }

    // Validate string fields can be converted to BigInt
    const bigIntFields = ['amount_in', 'amount_out', 'price_impact', 'price', 'timestamp', 'asset_reserve', 'stable_reserve'];
    for (const field of bigIntFields) {
        try {
            BigInt(data[field]);
        } catch {
            console.error(`Invalid BigInt value for ${field}:`, data[field]);
            return false;
        }
    }

    return true;
}

export const handleSwapEvents = async (events: SuiEvent[], type: string) => {
    const swapEvents: Array<Prisma.SwapEventCreateInput> = [];
    console.log(`Processing ${events.length} events for ${type}`);

    // Process all events
    for (const event of events) {
        try {
            const eventType = event.type.split('::').pop();
            
            if (!eventType?.includes('Swap')) {
                console.warn(`Skipping non-Swap event: ${event.type}`);
                continue;
            }

            if (!event.type.startsWith(type)) {
                console.error('Invalid event module origin:', event.type);
                continue;
            }

            const data = event.parsedJson as SwapEventData;
            console.log('Processing event data:', data);
            
            // Validate all required fields are present
            if (!validateSwapEventData(data)) {
                console.error('Invalid Swap event data:', data);
                continue;
            }

            swapEvents.push({
                market_id: String(data.market_id),
                outcome: Number(data.outcome),
                is_buy: Boolean(data.is_buy),
                amount_in: safeBigInt(data.amount_in),
                amount_out: safeBigInt(data.amount_out),
                price_impact: safeBigInt(data.price_impact),
                price: safeBigInt(data.price),
                sender: String(data.sender),
                timestamp: safeBigInt(data.timestamp),
                asset_reserve: safeBigInt(data.asset_reserve),
                stable_reserve: safeBigInt(data.stable_reserve)
            });
        } catch (error) {
            console.error('Error processing event:', error);
            console.error('Event data:', event);
            continue;
        }
    }

    // Process in batches of 10
    const BATCH_SIZE = 10;
    for (let i = 0; i < swapEvents.length; i += BATCH_SIZE) {
        const batch = swapEvents.slice(i, i + BATCH_SIZE);
        try {
            await prisma.$transaction(async (tx) => {
                for (const swap of batch) {
                    console.log('Processing Swap:', {
                        market: swap.market_id,
                        outcome: swap.outcome,
                        sender: swap.sender,
                        timestamp: swap.timestamp.toString()
                    });
                    
                    await tx.swapEvent.create({
                        data: swap
                    });
                }
            }, {
                timeout: 30000 // 30 second timeout
            });
            console.log(`Successfully processed batch ${i / BATCH_SIZE + 1} of ${Math.ceil(swapEvents.length / BATCH_SIZE)}`);
        } catch (error) {
            if (error instanceof Prisma.PrismaClientKnownRequestError) {
                console.error(`Database error in batch ${i / BATCH_SIZE + 1}:`, error);
            } else {
                console.error(`Failed to process batch ${i / BATCH_SIZE + 1}:`, error);
            }
            console.error('Failed batch data:', JSON.stringify(batch, null, 2));
            throw error;
        }
    }
};

// Export types for use in tests or other modules
export type { SwapEventData };