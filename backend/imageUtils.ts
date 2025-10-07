// imageUtils.ts
import sharp from 'sharp';
import path from 'path';
import fs from 'fs/promises';

export async function processAndGetBase64Icon(
    iconCachePath: string | null,
    daoId: string,
    fallbackIconUrl?: string | null
): Promise<string | null> {
    // Try to use cached file first
    if (iconCachePath) {
        try {
            const imagePath = path.join(process.cwd(), 'public', iconCachePath);
            const imageBuffer = await fs.readFile(imagePath);

            // Process image with sharp
            const processedBuffer = await sharp(imageBuffer)
                .rotate() // Handle rotation metadata
                .resize(64, 64, {
                    fit: 'inside',
                    withoutEnlargement: true
                })
                .png({ quality: 90, compressionLevel: 9 }) // Use PNG to preserve transparency
                .toBuffer();

            return `data:image/png;base64,${processedBuffer.toString('base64')}`;
        } catch (error) {
            console.error(`Error processing cached icon for dao ${daoId}, will try fallback:`, error);
        }
    }

    // Fallback to original icon_url if cache doesn't exist
    if (fallbackIconUrl) {
        return fallbackIconUrl;
    }

    return null;
}