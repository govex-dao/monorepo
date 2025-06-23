# Swap Events Cache Implementation

## Overview
Server-side caching has been implemented for the `/swaps` endpoint to reduce database load and improve response times.

## Implementation Details

### Cache Configuration
- **TTL (Time To Live)**: 5 seconds
- **Scope**: Per-proposal caching (cache key includes market_id)
- **Storage**: In-memory Map data structure
- **Cleanup**: Automatic cleanup of expired entries every 60 seconds

### How It Works

1. **Cache Key Generation**:
   ```typescript
   const cacheKey = `swaps:${marketId}:${JSON.stringify(req.query)}`;
   ```
   - Unique key per proposal and query parameters
   - Only caches requests that include a market_id

2. **Cache Hit Logic**:
   - Check if cache entry exists and is within 5-second TTL
   - Return cached data immediately if valid
   - Log cache hit for monitoring

3. **Cache Miss Logic**:
   - Fetch data from database
   - Store in cache with current timestamp
   - Return fresh data to client

4. **Memory Management**:
   - Background task runs every minute
   - Removes all entries older than 5 seconds
   - Prevents unbounded memory growth

### Benefits

1. **Reduced Database Load**:
   - With 1-second polling: 12 requests/minute → 12 cache hits/minute per user
   - Only 12 database queries/minute total (vs 12 per user)

2. **Improved Response Times**:
   - Cache hits return in <1ms
   - Database queries take 10-50ms

3. **Scalability**:
   - Supports many concurrent users per proposal
   - Linear memory usage based on active proposals

### Monitoring

Check cache statistics:
```bash
curl http://localhost:3000/cache-stats
```

Response:
```json
{
  "cache": {
    "swap": {
      "total": 5,
      "active": 3,
      "expired": 2
    }
  }
}
```

### Future Enhancements

1. **Cache Invalidation on Write**:
   - When indexer processes new swap events, invalidate relevant cache entries
   - Ensures cache consistency with minimal delay

2. **Redis Integration**:
   - For multi-server deployments
   - Persistent cache across server restarts

3. **Configurable TTL**:
   - Environment variable for TTL adjustment
   - Different TTLs for different proposal states