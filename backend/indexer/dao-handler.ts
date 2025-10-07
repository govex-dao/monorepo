import { SuiEvent } from '@mysten/sui/client';
import { Prisma } from '@prisma/client';
import { prisma } from '../db';
import { imageService } from '../services/ImageService';

// Constants for safety limits
interface DAOCreated {
    dao_id: string;
    min_asset_amount: string;
    min_stable_amount: string;
    timestamp: string;
    asset_type: string;
    stable_type: string;
    icon_url: string;
    dao_name: string;
    asset_decimals: string;
    stable_decimals: string;
    asset_name: string;
    stable_name: string;
    asset_icon_url: string;
    stable_icon_url: string;
    asset_symbol: string;
    stable_symbol: string;
    review_period_ms: string;
    trading_period_ms: string;
    amm_twap_start_delay: string;
    amm_twap_step_max: string;
    amm_twap_initial_observation: string;
    twap_threshold: string;
    description: string;
}




function safeBigInt(value: string | undefined | null, defaultValue: bigint = 0n): bigint {
    if (!value) return defaultValue;
    try {
        return BigInt(value);
    } catch {
        return defaultValue;
    }
}

function validateDAOData(data: any): data is DAOCreated {
    const requiredFields = [
        'dao_id',
        'min_asset_amount',
        'min_stable_amount',
        'timestamp',
        'asset_type',
        'stable_type',
        'icon_url',
        'dao_name',
        'asset_decimals',
        'stable_decimals',
        'asset_name',
        'stable_name',
        'asset_icon_url',
        'stable_icon_url',
        'asset_symbol',
        'stable_symbol',
        'review_period_ms',
        'trading_period_ms',
        'amm_twap_start_delay',
        'amm_twap_step_max',
        'amm_twap_initial_observation',
        'twap_threshold',
        'description'
    ];

    const missingFields = requiredFields.filter(field => !(field in data));

    if (missingFields.length > 0) {
        console.error('Missing required fields:', missingFields);
        return false;
    }
    return true;
}

export const handleDAOObjects = async (events: SuiEvent[], type: string) => {
    const daos: Array<Prisma.DaoCreateInput> = [];

    for (const event of events) {
        try {
            const eventType = event.type.split('::').pop();
            
            if (!eventType?.includes('DAOCreated')) {
                console.warn(`Skipping non-DAO event: ${event.type}`);
                continue;
            }

            const data = event.parsedJson as DAOCreated;
            
            if (!validateDAOData(data)) {
                console.error('Invalid DAO data:', data);
                continue;
            }

            // Loading from same server creating issues os adding quick fix
            if (data.icon_url === "https://www.govex.ai/images/govex-icon.png") {
                data.icon_url = "https://raw.githubusercontent.com/govex-dao/monorepo/refs/heads/main/frontend/public/images/govex-icon.png";
                console.log(`Replaced legacy govex-icon.png URL for DAO ID: ${data.dao_id} with new GitHub URL.`);
            }
            
            // Fetch and cache all image versions (single fetch, 3 outputs)
            const cachedPaths = await imageService.fetchAndCacheAllVersions(data.icon_url, data.dao_id);

            daos.push({
                dao_id: data.dao_id,
                minAssetAmount: safeBigInt(data.min_asset_amount),
                minStableAmount: safeBigInt(data.min_stable_amount),
                timestamp: safeBigInt(data.timestamp),
                assetType: data.asset_type,
                stableType: data.stable_type,
                icon_url: data.icon_url, // Keep original URL for reference
                icon_cache_path: cachedPaths.icon, // 64x64 PNG icon
                icon_cache_medium: cachedPaths.medium, // 256x256 JPEG  
                icon_cache_large: cachedPaths.large, // 512x512 JPEG
                dao_name: data.dao_name,
                asset_decimals: parseInt(data.asset_decimals),
                stable_decimals: parseInt(data.stable_decimals),
                asset_name: data.asset_name,
                stable_name: data.stable_name,
                asset_icon_url: data.asset_icon_url,
                stable_icon_url: data.stable_icon_url,
                asset_symbol: data.asset_symbol,
                stable_symbol: data.stable_symbol,
                review_period_ms: safeBigInt(data.review_period_ms),
                trading_period_ms: safeBigInt(data.trading_period_ms),
                amm_twap_start_delay: safeBigInt(data.amm_twap_start_delay),
                amm_twap_step_max: safeBigInt(data.amm_twap_step_max),
                amm_twap_initial_observation: safeBigInt(data.amm_twap_initial_observation),
                twap_threshold: safeBigInt(data.twap_threshold),
                description: data.description
            });
        } catch (error) {
            console.error('Error processing event:', error);
            console.error('Event data:', event);
            continue;
        }
    }

    const BATCH_SIZE = 10;
    for (let i = 0; i < daos.length; i += BATCH_SIZE) {
        const batch = daos.slice(i, i + BATCH_SIZE);
        try {
            await prisma.$transaction(async (tx) => {
                for (const dao of batch) {
                    console.log('Processing DAO:', dao.dao_id);
                    
                    await tx.dao.upsert({
                        where: { dao_id: dao.dao_id },
                        create: dao,
                        update: dao
                    });
                }
            }, {
                timeout: 30000
            });
            console.log(`Successfully processed batch ${i / BATCH_SIZE}`);
        } catch (error) {
            console.error(`Failed to process batch ${i / BATCH_SIZE}:`, error);
            console.error('Failed batch data:', JSON.stringify(batch, null, 2));
            throw error;
        }
    }
};