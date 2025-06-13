// Cache utilities for managing swap event cache

interface SwapCacheEntry {
    data: any;
    timestamp: number;
}

// Export the cache and TTL so they can be accessed from other modules
export const swapCache = new Map<string, SwapCacheEntry>();
export const SWAP_CACHE_TTL = 5000; // 5 seconds

/**
 * Invalidates all cache entries for a specific proposal/market
 * @param marketId The market/proposal ID to invalidate
 */
export function invalidateSwapCache(marketId: string): void {
    let invalidated = 0;
    
    // Find and delete all cache entries for this market
    const keysToDelete: string[] = [];
    swapCache.forEach((_, key) => {
        if (key.includes(`swaps:${marketId}:`)) {
            keysToDelete.push(key);
        }
    });
    
    keysToDelete.forEach(key => {
        swapCache.delete(key);
        invalidated++;
    });
    
    if (invalidated > 0) {
        console.log(`Invalidated ${invalidated} cache entries for market ${marketId}`);
    }
}

/**
 * Cleans up expired cache entries
 */
export function cleanupExpiredCache(): void {
    const now = Date.now();
    let cleaned = 0;
    const keysToDelete: string[] = [];
    
    swapCache.forEach((entry, key) => {
        if (now - entry.timestamp > SWAP_CACHE_TTL) {
            keysToDelete.push(key);
        }
    });
    
    keysToDelete.forEach(key => {
        swapCache.delete(key);
        cleaned++;
    });
    
    if (cleaned > 0) {
        console.log(`Cleaned ${cleaned} expired swap cache entries. Current cache size: ${swapCache.size}`);
    }
}

/**
 * Gets cache statistics
 */
export function getCacheStats() {
    const now = Date.now();
    let expired = 0;
    let active = 0;
    
    swapCache.forEach((entry) => {
        if (now - entry.timestamp > SWAP_CACHE_TTL) {
            expired++;
        } else {
            active++;
        }
    });
    
    return {
        total: swapCache.size,
        active,
        expired
    };
}