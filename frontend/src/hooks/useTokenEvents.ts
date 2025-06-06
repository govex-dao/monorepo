import { useState, useEffect, useCallback, useMemo } from "react";
import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { CONSTANTS } from "@/constants";
import { SuiObjectResponse } from "@mysten/sui/client";
import { TokenInfo } from "@/components/trade/TradeForm";

const packageId = CONSTANTS.futarchyPackage;
const client = new SuiClient({ url: getFullnodeUrl(CONSTANTS.network) });

interface CacheEntry {
  tokens: TokenInfo[];
  timestamp: number;
}

const tokenCache = new Map<string, CacheEntry>();

const CACHE_TTL = 30000; // 30 seconds

function getFromCache(key: string): TokenInfo[] | undefined {
  const entry = tokenCache.get(key);
  if (entry && Date.now() - entry.timestamp < CACHE_TTL) {
    return entry.tokens;
  }
  return undefined;
}

function setToCache(key: string, tokens: TokenInfo[]): void {
  tokenCache.set(key, { tokens, timestamp: Date.now() });
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

  const cacheKey = useMemo(
    () =>
      address && proposalId
        ? `${address}-${proposalId}-${assetType ?? "all"}`
        : undefined,
    [address, proposalId, assetType],
  );

  const fetchTokens = useCallback(
    async (forceRefresh = false) => {
      if (!address || !proposalId) return;

      if (!forceRefresh && cacheKey) {
        const cachedData = getFromCache(cacheKey);
        if (cachedData) {
          setTokens(cachedData);
          return;
        }
      }

      setIsLoading(true);
      setError(null);
      try {
        const tokenType = `${packageId}::conditional_token::ConditionalToken`;
        let allTokens: TokenInfo[] = [];
        let cursor: string | null = null;

        do {
          const objects = await client.getOwnedObjects({
            owner: address,
            cursor,
            limit: 50,
            filter: { StructType: tokenType },
            options: { showType: true, showContent: true, showDisplay: true },
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
          cursor = objects.nextCursor ?? null;
        } while (cursor);

        const dedupedTokens = Array.from(
          new Map(allTokens.map((token) => [token.id, token])).values(),
        );

        if (cacheKey) setToCache(cacheKey, dedupedTokens);
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

  useEffect(() => {
    if (enabled) fetchTokens(false);
  }, [enabled, fetchTokens, cacheKey]);

  const groupedTokens = useMemo<GroupedToken[]>(() => {
    const outcomeMap = new Map<number, { asset: bigint; stable: bigint }>();

    tokens.forEach((token) => {
      if (!outcomeMap.has(token.outcome)) {
        outcomeMap.set(token.outcome, { asset: 0n, stable: 0n });
      }
      const group = outcomeMap.get(token.outcome)!;
      if (token.asset_type === 0) {
        group.asset += BigInt(token.balance);
      } else {
        group.stable += BigInt(token.balance);
      }
    });

    return Array.from(outcomeMap.entries())
      .sort(([aOutcome], [bOutcome]) => aOutcome - bOutcome)
      .map(([outcome, balances]) => {
        const formatBalance = (
          balance: bigint,
          scale: number,
          decimals: number,
        ) => {
          const whole = (balance / BigInt(scale)).toString();
          const fraction = (balance % BigInt(scale))
            .toString()
            .padStart(decimals, "0")
            .slice(0, decimals);
          return `${whole}.${fraction}`;
        };

        return {
          outcome,
          assetBalance: balances.asset.toString(),
          stableBalance: balances.stable.toString(),
          assetBalanceFormatted: formatBalance(
            balances.asset,
            assetScale,
            asset_decimals,
          ),
          stableBalanceFormatted: formatBalance(
            balances.stable,
            stableScale,
            stable_decimals,
          ),
        };
      });
  }, [tokens, assetScale, stableScale, asset_decimals, stable_decimals]);

  return {
    tokens,
    groupedTokens,
    isLoading,
    error,
    refreshTokens: () => fetchTokens(true),
  };
}
