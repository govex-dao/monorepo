import * as fs from 'fs/promises';
import * as path from 'path';
import * as crypto from 'crypto';
import { validateImageUrl, validateImageContentType, validateImageSize, logSecurityError } from '../utils/security';
import { processImage, processImageToIcon, ImageProcessOptions } from './ImageProcessor';

const MAX_IMAGE_SIZE = 10 * 1024 * 1024; // 10MB
const CACHE_DIR = path.join(process.cwd(), 'public', 'dao-images');

// Define all required image versions matching database schema
// Note: For OG images (1200x630), you could either:
// 1. Use the 512x512 'large' version and let OG generator upscale/pad it
// 2. Add a separate 'icon_cache_og' field to the database for 1200x630
// 3. Generate OG size on-demand from the cached 512x512 version
const IMAGE_VERSIONS: Record<string, ImageProcessOptions> = {
  icon: { 
    width: 64, 
    height: 64, 
    format: 'png',
    fit: 'contain'
  },
  medium: { 
    width: 256, 
    height: 256, 
    format: 'jpeg',
    fit: 'cover'
  },
  large: { 
    width: 512, 
    height: 512, 
    format: 'jpeg',
    fit: 'cover'
  }
};

export interface CachedImagePaths {
  icon: string | null;
  medium: string | null;
  large: string | null;
}

class ImageService {
  /**
   * Fetches a remote image, validates it, processes it into all required versions,
   * and saves them to the persistent disk cache.
   * Returns an object with paths to all cached versions.
   */
  async fetchAndCacheAllVersions(url: string, identifier: string): Promise<CachedImagePaths> {
    const result: CachedImagePaths = {
      icon: null,
      medium: null,
      large: null
    };

    // Step 1: Use the strong, centralized validator
    const validation = validateImageUrl(url);
    if (!validation.isValid) {
      logSecurityError('ImageService.fetchAndCacheAllVersions.UrlValidation', new Error(validation.error));
      return result;
    }

    try {
      // Ensure the cache directory exists
      await fs.mkdir(CACHE_DIR, { recursive: true });

      // Step 2: Fetch the image with a timeout to prevent hanging
      const response = await fetch(url, { signal: AbortSignal.timeout(10000) });
      if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`);

      // Step 3: Validate content type and size using our security helpers
      const contentType = response.headers.get('content-type');
      if (!validateImageContentType(contentType)) {
        throw new Error(`Invalid content type: ${contentType}`);
      }

      const buffer = Buffer.from(await response.arrayBuffer());
      if (!validateImageSize(buffer.length, MAX_IMAGE_SIZE)) {
        throw new Error('Image size exceeds maximum limit');
      }

      // Step 4: Generate a hash for consistent naming across all versions
      const hash = crypto.createHash('sha256').update(`${identifier}-${url}`).digest('hex').slice(0, 12);

      // Step 5: Generate and save each version
      for (const [versionName, options] of Object.entries(IMAGE_VERSIONS)) {
        try {
          const processedBuffer = await processImage(buffer, options);
          if (processedBuffer) {
            const filename = `${identifier}-${hash}-${versionName}.${options.format}`;
            const filePath = path.join(CACHE_DIR, filename);
            await fs.writeFile(filePath, processedBuffer);
            
            // Store the public path
            result[versionName as keyof CachedImagePaths] = `/dao-images/${filename}`;
            console.log(`Created ${versionName} version: ${filename}`);
          }
        } catch (versionErr) {
          logSecurityError(`ImageService.fetchAndCacheAllVersions.${versionName}`, versionErr);
        }
      }

      return result;
    } catch (err) {
      logSecurityError(`ImageService.fetchAndCacheAllVersions.Process: ${url}`, err);
      return result;
    }
  }

  /**
   * Legacy method for backward compatibility - fetches and caches only the icon version.
   * Returns the local public path to the cached icon.
   */
  async fetchAndCache(url: string, identifier: string): Promise<string | null> {
    const paths = await this.fetchAndCacheAllVersions(url, identifier);
    return paths.icon;
  }
}

export const imageService = new ImageService();