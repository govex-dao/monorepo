import sharp from 'sharp';

export async function validateAndCompressImage(buffer: Buffer): Promise<Buffer | null> {
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
