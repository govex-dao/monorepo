import sharp = require('sharp');
import { logSecurityError } from '../utils/security';

export interface ImageProcessOptions {
  width: number;
  height: number;
  format: 'png' | 'jpeg';
  fit?: 'contain' | 'cover';
}

/**
 * Flexible image processing function that can generate different sizes and formats.
 * @param buffer The input image buffer.
 * @param options Processing options including dimensions and format.
 * @returns A buffer of the processed image, or null if processing fails.
 */
export async function processImage(buffer: Buffer, options: ImageProcessOptions): Promise<Buffer | null> {
  try {
    const pipeline = sharp(buffer, {
      limitInputPixels: 30000 * 30000, // Prevent decompression bombs
      sequentialRead: true,
    });

    // Validate essential metadata before proceeding
    const metadata = await pipeline.metadata();
    if (!metadata.format || !metadata.width || !metadata.height || metadata.width < 1 || metadata.height < 1) {
      throw new Error('Invalid or missing image metadata');
    }

    // Apply rotation and resize
    pipeline
      .rotate() // Auto-rotate based on EXIF data
      .resize(options.width, options.height, {
        fit: options.fit || 'contain',
        background: { r: 0, g: 0, b: 0, alpha: 0 },
        withoutEnlargement: options.fit === 'contain', // Only prevent enlargement for 'contain'
      });

    // Apply format-specific settings
    if (options.format === 'png') {
      return await pipeline
        .png({ quality: 90, compressionLevel: 9 })
        .toBuffer();
    } else {
      return await pipeline
        .jpeg({ quality: 85, progressive: true })
        .toBuffer();
    }
  } catch (err) {
    logSecurityError('ImageProcessor', err);
    return null;
  }
}

/**
 * Legacy function for backward compatibility - generates a 64x64 PNG icon.
 * @param buffer The input image buffer.
 * @returns A buffer of the processed PNG image, or null if processing fails.
 */
export async function processImageToIcon(buffer: Buffer): Promise<Buffer | null> {
  return processImage(buffer, {
    width: 64,
    height: 64,
    format: 'png',
    fit: 'contain'
  });
}