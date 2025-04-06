// imageUtils.ts
import sharp from 'sharp';
import path from 'path';
import fs from 'fs/promises';

export async function processAndGetBase64Icon(iconCachePath: string | null, daoId: string): Promise<string | null> {
    if (!iconCachePath) {
        return null;
    }

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
            .flatten({ background: { r: 255, g: 255, b: 255 } }) // White background
            .jpeg({ quality: 80, mozjpeg: true }) // Consistent output format
            .toBuffer();

        return `data:image/jpeg;base64,${processedBuffer.toString('base64')}`;
    } catch (error) {
        console.error(`Error processing icon for dao ${daoId}:`, error);
        return null;
    }
}