import fs from 'fs/promises';
import path from 'path';
import { logSecurityError } from './security';

interface CachedImage {
  data: string; // base64 encoded image
  timestamp: number;
  size: number;
}

// In-memory cache for frequently accessed images
class ImageCache {
  private cache: Map<string, CachedImage> = new Map();
  private readonly maxCacheSize = 100 * 1024 * 1024; // 100MB max cache size
  private readonly maxAge = 3600 * 1000; // 1 hour cache TTL
  private currentCacheSize = 0;

  /**
   * Get image from cache or load from disk
   */
  async getImage(imagePath: string): Promise<string | null> {
    const cacheKey = imagePath;
    const now = Date.now();

    // Check if in cache and not expired
    const cached = this.cache.get(cacheKey);
    if (cached && (now - cached.timestamp) < this.maxAge) {
      // Move to end (LRU)
      this.cache.delete(cacheKey);
      this.cache.set(cacheKey, cached);
      return cached.data;
    }

    // Not in cache or expired, load from disk
    try {
      const fullPath = path.join(process.cwd(), 'public', imagePath.substring(1));
      const imageBuffer = await fs.readFile(fullPath);
      const base64Data = `data:image/png;base64,${imageBuffer.toString('base64')}`;
      
      // Add to cache
      this.addToCache(cacheKey, base64Data, imageBuffer.length);
      
      return base64Data;
    } catch (err) {
      logSecurityError('readCachedImage', err);
      return null;
    }
  }

  /**
   * Add image to cache with LRU eviction
   */
  private addToCache(key: string, data: string, size: number): void {
    // Remove from cache if already exists
    const existing = this.cache.get(key);
    if (existing) {
      this.currentCacheSize -= existing.size;
      this.cache.delete(key);
    }

    // Evict old entries if needed
    while (this.currentCacheSize + size > this.maxCacheSize && this.cache.size > 0) {
      const firstKey = this.cache.keys().next().value;
      if (firstKey) {
        const firstEntry = this.cache.get(firstKey);
        if (firstEntry) {
          this.currentCacheSize -= firstEntry.size;
          this.cache.delete(firstKey);
        }
      }
    }

    // Add new entry
    this.cache.set(key, {
      data,
      timestamp: Date.now(),
      size
    });
    this.currentCacheSize += size;
  }

  /**
   * Clear expired entries
   */
  cleanupExpired(): void {
    const now = Date.now();
    for (const [key, value] of this.cache.entries()) {
      if (now - value.timestamp > this.maxAge) {
        this.currentCacheSize -= value.size;
        this.cache.delete(key);
      }
    }
  }

  /**
   * Get cache statistics
   */
  getStats() {
    return {
      entries: this.cache.size,
      sizeBytes: this.currentCacheSize,
      sizeMB: (this.currentCacheSize / (1024 * 1024)).toFixed(2)
    };
  }
}

// Singleton instance
export const imageCache = new ImageCache();

// Run cleanup every 5 minutes
setInterval(() => {
  imageCache.cleanupExpired();
}, 5 * 60 * 1000);