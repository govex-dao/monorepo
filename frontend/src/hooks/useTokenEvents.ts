import { useState, useEffect, useCallback, useMemo } from "react";
import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { CONSTANTS } from "@/constants";
import { SuiObjectResponse } from "@mysten/sui/client";
import { TokenInfo } from "@/components/trade/TradeForm";

const packageId = CONSTANTS.futarchyPackage;
const client = new SuiClient({ url: getFullnodeUrl(CONSTANTS.network) });

// Cache configuration
const MAX_CACHE_SIZE = 50;
const ITEM_TTL = 30000; // 30 seconds

// Cache store
const _tokenCacheLRU = new Map<
  string,
  { tokens: TokenInfo[]; timestamp: number }
>();

function getFromCache(
  key: string,
): { tokens: TokenInfo[]; timestamp: number } | undefined {
  const item = _tokenCacheLRU.get(key);
  if (item) {
    if (Date.now() - item.timestamp > ITEM_TTL) {
      _tokenCacheLRU.delete(key);
      return undefined;
    }
    // Mark as recently used
    _tokenCacheLRU.delete(key);
    _tokenCacheLRU.set(key, item);
    return item;
  }
  return undefined;
}

function setToCache(
  key: string,
  value: { tokens: TokenInfo[]; timestamp: number },
): void {
  if (_tokenCacheLRU.has(key)) {
    _tokenCacheLRU.delete(key);
  }
  _tokenCacheLRU.set(key, value);

  if (_tokenCacheLRU.size > MAX_CACHE_SIZE) {
    const oldestKey = _tokenCacheLRU.keys().next().value;
    if (oldestKey) {
      _tokenCacheLRU.delete(oldestKey);
    }
  }
}

interface UseTokenEventsOptions {
  proposalId: string;
  address?: string;
  assetType?: string | null;
  enabled?: boolean;
  asset_decimals?: number;
  stable_decimals?: number;
}

interface GroupedToken {
  outcome: number;
  assetBalance: string;
  stableBalance: string;
  assetBalanceFormatted: string;
  stableBalanceFormatted: string;
}

export function useTokenEvents({
  proposalId,
  address,
  assetType,
  enabled = true,
  asset_decimals = 9,
  stable_decimals = 9,
}: UseTokenEventsOptions) {
  const [tokens, setTokens] = useState<TokenInfo[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<Error | null>(null);

  const [assetScale, stableScale] = useMemo(
    () => [10 ** asset_decimals, 10 ** stable_decimals],
    [asset_decimals, stable_decimals],
  );

  const cacheKey =
    address && proposalId
      ? `${address}-${proposalId}-${assetType ?? "all"}`
      : undefined;

  const fetchTokens = useCallback(
    async (forceRefresh = false) => {
      if (!address || !proposalId) return;

      // Check cache first if not forcing refresh
      if (!forceRefresh && cacheKey) {
        const cachedData = getFromCache(cacheKey);
        if (cachedData) {
          setTokens(cachedData.tokens);
          return;
        }
      }

      setIsLoading(true);
      setError(null);
      try {
        const tokenType = `${packageId}::conditional_token::ConditionalToken`;
        let allTokens: TokenInfo[] = [];
        let hasNextPage = true;
        let cursor: string | null = null;

        while (hasNextPage) {
          const objects = await client.getOwnedObjects({
            owner: address,
            cursor,
            limit: 50,
            filter: {
              StructType: tokenType,
            },
            options: {
              showType: true,
              showContent: true,
              showDisplay: true,
            },
          });

          const pageTokens = objects.data
            .filter((obj: SuiObjectResponse) => {
              if (
                !obj.data?.content ||
                obj.data.content.dataType !== "moveObject"
              )
                return false;
              const content = obj.data.content as any;
              if (content.fields.market_id !== proposalId) return false;
              if (assetType && content.fields.asset_type !== Number(assetType))
                return false;
              return true;
            })
            .map((obj: SuiObjectResponse) => {
              const content = obj.data?.content as any;
              return {
                id: obj.data?.objectId || "",
                balance: content.fields.balance,
                outcome: content.fields.outcome,
                asset_type: content.fields.asset_type,
              };
            });

          allTokens = [...allTokens, ...pageTokens];

          hasNextPage = objects.hasNextPage;
          cursor = objects.nextCursor ?? null;

          if (!hasNextPage || !cursor) break;
        }

        // Deduplicate tokens by id, preserving the first encountered instance
        const dedupedTokens = [];
        const seenIds = new Set();
        for (const token of allTokens) {
          if (!seenIds.has(token.id)) {
            seenIds.add(token.id);
            dedupedTokens.push(token);
          }
        }
        // Update cache
        if (cacheKey) {
          setToCache(cacheKey, {
            tokens: dedupedTokens,
            timestamp: Date.now(),
          });
        }

        // Force a new array reference to ensure React detects the change
        setTokens([...dedupedTokens]);
      } catch (err) {
        setError(
          err instanceof Error ? err : new Error("Failed to fetch tokens"),
        );
        console.error("Error fetching tokens:", err);
      } finally {
        setIsLoading(false);
      }
    },
    [proposalId, address, assetType, cacheKey],
  );

  const groupedTokens = useMemo<GroupedToken[]>(() => {
    const outcomeMap = new Map<
      number,
      { assetBalance: bigint; stableBalance: bigint }
    >();

    tokens.forEach((token) => {
      if (!outcomeMap.has(token.outcome)) {
        outcomeMap.set(token.outcome, { assetBalance: 0n, stableBalance: 0n });
      }
      const group = outcomeMap.get(token.outcome)!;
      if (token.asset_type === 0) {
        group.assetBalance += BigInt(token.balance);
      } else {
        group.stableBalance += BigInt(token.balance);
      }
    });

    const result = Array.from(outcomeMap.entries())
      .sort(([aOutcome], [bOutcome]) => aOutcome - bOutcome)
      .map(([outcome, balances]) => {
        // Convert raw balances to human-readable format with proper decimals
        const assetBalanceRaw = balances.assetBalance.toString();
        const stableBalanceRaw = balances.stableBalance.toString();

        // Format with proper decimals using BigInt arithmetic
        const assetBalanceFormatted =
          (balances.assetBalance / BigInt(assetScale)).toString() +
          "." +
          (balances.assetBalance % BigInt(assetScale))
            .toString()
            .padStart(asset_decimals, "0")
            .slice(0, asset_decimals);

        const stableBalanceFormatted =
          (balances.stableBalance / BigInt(stableScale)).toString() +
          "." +
          (balances.stableBalance % BigInt(stableScale))
            .toString()
            .padStart(stable_decimals, "0")
            .slice(0, stable_decimals);

        return {
          outcome,
          assetBalance: assetBalanceRaw,
          stableBalance: stableBalanceRaw,
          assetBalanceFormatted,
          stableBalanceFormatted,
        };
      });

    return result;
  }, [tokens, assetScale, stableScale, asset_decimals, stable_decimals]);

  useEffect(() => {
    if (!enabled) return;

    // Initialize from cache or fetch if needed
    const cachedData = cacheKey ? getFromCache(cacheKey) : null;
    if (cachedData) {
      setTokens(cachedData.tokens);
    } else {
      fetchTokens(false);
    }
  }, [proposalId, address, assetType, enabled, fetchTokens, cacheKey]);

  return {
    tokens,
    groupedTokens,
    isLoading,
    error,
    refreshTokens: () => fetchTokens(true),
  };
}
