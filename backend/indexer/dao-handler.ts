import { SuiEvent } from '@mysten/sui/client';
import { Prisma } from '@prisma/client';
import { prisma } from '../db';
import path from 'path';
import fs from 'fs/promises';
import crypto from 'crypto';
import sharp from 'sharp';

// Constants for safety limits
const MAX_IMAGE_SIZE = 10 * 1024 * 1024; // 10MB
const TARGET_IMAGE_SIZE = 100 * 1024;    // 100KB
const ALLOWED_EXTENSIONS = new Set(['.jpg', '.jpeg', '.png', '.gif', '.webp']);
const ALLOWED_MIME_TYPES = new Set([
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
]);

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

async function validateAndSanitizeUrl(url: string): Promise<URL> {
    try {
        const sanitizedUrl = new URL(url);
        // Only allow HTTPS URLs
        if (sanitizedUrl.protocol !== 'https:') {
            throw new Error('Only HTTPS URLs are allowed');
        }
        return sanitizedUrl;
    } catch (error: unknown) {
        throw new Error(`Invalid URL`);
    }
}

async function validateAndCompressImage(buffer: Buffer): Promise<Buffer | null> {
    try {
        console.log('Starting image validation and compression...');
        console.log(`Input buffer size: ${buffer.length / 1024}KB`);

        // Check for WebP magic numbers
        const isWebP = buffer.length > 12 && 
                      buffer.slice(0, 4).toString() === 'RIFF' && 
                      buffer.slice(8, 12).toString() === 'WEBP';
        
        console.log('Format detection:', {
            isWebP,
            magicBytes: buffer.slice(0, 12).toString()
        });

        const pipeline = sharp(buffer, {
            limitInputPixels: 30000 * 30000,
            sequentialRead: true
        });

        // Convert WebP to PNG before any other processing if detected
        if (isWebP) {
            console.log('WebP detected, converting to PNG first');
            pipeline.png();
        }

        // Log metadata before processing
        const metadata = await pipeline.metadata();
        console.log('Image metadata:', {
            format: metadata.format,
            width: metadata.width,
            height: metadata.height,
            space: metadata.space,
            channels: metadata.channels,
            depth: metadata.depth,
            density: metadata.density,
            hasAlpha: metadata.hasAlpha,
            pages: metadata.pages
        });

        // Validate metadata
        if (!metadata.format || !metadata.width || !metadata.height) {
            console.error('Image validation failed: Missing required metadata', {
                format: metadata.format,
                width: metadata.width,
                height: metadata.height
            });
            return null;
        }

        if (metadata.width < 1 || metadata.height < 1) {
            console.error('Image validation failed: Invalid dimensions', {
                width: metadata.width,
                height: metadata.height
            });
            return null;
        }

        if (metadata.pages !== undefined && metadata.pages > 1) {
            console.error('Image validation failed: Multi-page images not supported', {
                pages: metadata.pages
            });
            return null;
        }

        if (metadata.density !== undefined && metadata.density > 300) {
            console.warn('High image density detected', {
                density: metadata.density
            });
        }

        // This section resizes the image to fit within a 64x64 square, padding
        // with transparency to preserve the aspect ratio, and outputs as PNG.
        console.log('Starting image compression to a 64x64 square PNG...');
        const compressed = await pipeline
            .rotate() // Auto-rotate based on EXIF data
            .resize(64, 64, {
                // 'contain' pads the image to a square, preserving the full logo.
                fit: 'contain',
                // Use a transparent background for padding. This looks best on Discord.
                background: { r: 0, g: 0, b: 0, alpha: 0 },
                withoutEnlargement: true
            })
            // Standardize output to PNG to preserve transparency and quality for icons.
            .png({ quality: 90, compressionLevel: 9 })
            .toBuffer();
        

        console.log('Compression complete:', {
            originalSize: `${(buffer.length / 1024).toFixed(2)}KB`,
            compressedSize: `${(compressed.length / 1024).toFixed(2)}KB`,
            finalDimensions: '64x64',
            finalFormat: 'png'
        });

        return compressed;
    } catch (err) {
        console.error('Image processing error:', {
            error: err instanceof Error ? err.message : 'Unknown error',
            stack: err instanceof Error ? err.stack : undefined,
            bufferSize: buffer.length / 1024 + 'KB'
        });
        return null;
    }
}

async function cacheDAOImage(iconUrl: string, daoId: string): Promise<string | null> {
    try {
        console.log(`Starting image caching for DAO ${daoId}`, {
            url: iconUrl
        });

        // Validate URL
        const sanitizedUrl = await validateAndSanitizeUrl(iconUrl);
        console.log('URL validation passed:', sanitizedUrl.toString());

        // Setup cache directory
        const cacheDir = path.join(process.cwd(), 'public', 'dao-images');
        await fs.mkdir(cacheDir, { recursive: true, mode: 0o755 });
        console.log('Cache directory ensured:', cacheDir);

        // Create filename
        const hash = crypto
            .createHash('sha256')
            .update(`${daoId}-${iconUrl}`)
            .digest('hex')
            .slice(0, 12);

        // Always use .png as we standardize the output format in validateAndCompressImage.
        const filename = `${daoId}-${hash}.png`;
        const filePath = path.join(cacheDir, filename);
        const tempPath = `${filePath}.temp`;
        console.log('File paths generated:', {
            filename,
            filePath,
            tempPath
        });

        // Fetch with timeout
        console.log('Fetching image...');
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 10000);

        try {
            const response = await fetch(sanitizedUrl.toString(), {
                signal: controller.signal,
                headers: {
                    'User-Agent': 'DAOImageCache/1.0'
                }
            });

            console.log('Fetch response:', {
                status: response.status,
                statusText: response.statusText,
                headers: Object.fromEntries(response.headers.entries())
            });

            if (!response.ok) {
                throw new Error(`HTTP error! status: ${response.status}`);
            }

            const contentType = response.headers.get('content-type');
            console.log('Content type:', contentType);

            if (!contentType) {
                throw new Error('Missing content type');
            }

            const [mainType] = contentType.toLowerCase().split(';').map(s => s.trim());
            console.log('Parsed content type:', {
                main: mainType,
                allowed: Array.from(ALLOWED_MIME_TYPES)
            });

            if (!ALLOWED_MIME_TYPES.has(mainType)) {
                throw new Error(`Invalid content type: ${contentType}`);
            }

            const contentLength = response.headers.get('content-length');
            console.log('Content length:', {
                raw: contentLength,
                parsed: contentLength ? parseInt(contentLength) : 'unknown',
                limit: MAX_IMAGE_SIZE
            });

            if (contentLength && parseInt(contentLength) > MAX_IMAGE_SIZE) {
                throw new Error(`Image size exceeds maximum allowed size of 5MB`);
            }

            const arrayBuffer = await response.arrayBuffer();
            let imageBuffer = Buffer.from(arrayBuffer);
            console.log('Image buffer created:', `${imageBuffer.length / 1024}KB`);

            if (imageBuffer.length > MAX_IMAGE_SIZE) {
                throw new Error('File size exceeds maximum allowed size');
            }

            const compressedImage = await validateAndCompressImage(imageBuffer);
            if (!compressedImage) {
                throw new Error('Image validation or compression failed');
            }

            imageBuffer = compressedImage;

            // Write to temporary file
            console.log('Writing to temporary file:', tempPath);
            await fs.writeFile(tempPath, imageBuffer, { mode: 0o644 });

            // Move to final destination
            console.log('Moving to final location:', filePath);
            await fs.rename(tempPath, filePath);

            const finalPath = `/dao-images/${filename}`;
            console.log('Image successfully cached:', finalPath);

            // Cleanup in background
            cleanupOldImages(cacheDir).catch(err => {
                console.error('Background cleanup failed:', err);
            });

            return finalPath;

        } catch (error) {
            console.error('Image processing failed:', {
                error: error instanceof Error ? error.message : 'Unknown error',
                stack: error instanceof Error ? error.stack : undefined
            });
            return null;
        } finally {
            clearTimeout(timeout);
            try {
                await fs.unlink(tempPath);
                console.log('Temporary file cleaned up:', tempPath);
            } catch (err) {
                // Ignore cleanup errors
                console.warn('Failed to cleanup temp file:', {
                    path: tempPath,
                    error: err instanceof Error ? err.message : 'Unknown error'
                });
            }
        }
    } catch (error) {
        console.error(`Failed to cache image for DAO ${daoId}:`, {
            error: error instanceof Error ? error.message : 'Unknown error',
            stack: error instanceof Error ? error.stack : undefined,
            url: iconUrl
        });
        return null;
    }
}

async function cleanupOldImages(
    cacheDir: string, 
    maxAge: number = 180 * 24 * 60 * 60 * 1000 // 7 days
): Promise<void> {
    try {
        const files = await fs.readdir(cacheDir);
        const now = Date.now();

        for (const file of files) {
            const filePath = path.join(cacheDir, file);
            try {
                const stats = await fs.stat(filePath);
                if (now - stats.mtimeMs > maxAge) {
                    await fs.unlink(filePath);
                }
            } catch (error) {
                console.error(`Error processing file ${file}:`, error);
            }
        }
    } catch (error) {
        console.error('Error cleaning up old cached images:', error);
    }
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

            let cachedImagePath = null;
            let finalIconUrl = data.icon_url;
            
            try {
                cachedImagePath = await cacheDAOImage(data.icon_url, data.dao_id);
            } catch (error) {
                finalIconUrl = ''; // Clear the URL if validation/caching fails
            }

            daos.push({
                dao_id: data.dao_id,
                minAssetAmount: safeBigInt(data.min_asset_amount),
                minStableAmount: safeBigInt(data.min_stable_amount),
                timestamp: safeBigInt(data.timestamp),
                assetType: data.asset_type,
                stableType: data.stable_type,
                icon_url: finalIconUrl,
                icon_cache_path: cachedImagePath || null,
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