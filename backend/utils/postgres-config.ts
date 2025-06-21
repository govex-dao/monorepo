// PostgreSQL connection optimizations for Railway
export function getOptimizedDatabaseUrl(baseUrl: string): string {
  if (!baseUrl || baseUrl.includes('file:')) {
    // SQLite URL, return as-is
    return baseUrl;
  }

  // Parse the URL to add query parameters
  const url = new URL(baseUrl);
  
  // Connection pool settings
  url.searchParams.set('connection_limit', '10'); // Max connections
  url.searchParams.set('pool_timeout', '10'); // Wait time for a connection
  
  // PostgreSQL optimizations
  url.searchParams.set('statement_cache_size', '100'); // Cache prepared statements
  url.searchParams.set('pgbouncer', 'true'); // Enable if using PgBouncer
  
  return url.toString();
}

// PostgreSQL-specific optimizations
export const pgOptimizations = {
  // Connection pool settings for Prisma
  connectionPool: {
    connectionLimit: 10, // Railway has connection limits
    maxIdleTime: 30, // Seconds before closing idle connections
    queueTimeout: 10, // Seconds to wait for available connection
  },
  
  // Query optimizations
  querySettings: {
    statementCacheSize: 100, // Number of prepared statements to cache
    multiSchema: false, // Single schema for simplicity
  }
};

// Note: WAL mode is PostgreSQL default since v10
// Railway PostgreSQL already has optimal settings:
// - WAL mode enabled
// - Autovacuum enabled
// - Query planning optimized
// - Connection pooling available