import { useQuery, useQueryClient } from "@tanstack/react-query";
import { SuiClient, getFullnodeUrl, SuiObjectResponse } from "@mysten/sui/client";
import { CONSTANTS, QueryKey } from "@/constants";
import { useMemo } from "react";

const packageId = CONSTANTS.futarchyPackage;
const client = new SuiClient({ url: getFullnodeUrl(CONSTANTS.network) });

export interface TokenInfo {
  id: string;
  balance: string;
  outcome: number;
  asset_type: number;
}

interface GroupedToken {
  outcome: number;
  assetBalance: string;
  stableBalance: string;
  assetBalanceFormatted: string;
  stableBalanceFormatted: string;
}

interface UseTokenEventsOptions {
  proposalId: string;
  address?: string;
  assetType?: string | null;
  enabled?: boolean;
  asset_decimals?: number;
  stable_decimals?: number;
}

async function fetchTokens(
  address: string,
  proposalId: string,
  assetType?: string | null
): Promise<TokenInfo[]> {
  console.log("Fetching tokens for:", { address, proposalId, assetType });
  
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
        if (!obj.data?.content || obj.data.content.dataType !== "moveObject")
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

  // Deduplicate tokens by ID
  return Array.from(
    new Map(allTokens.map((token) => [token.id, token])).values()
  );
}

export function useTokenEventsQuery({
  proposalId,
  address,
  assetType,
  enabled = true,
  asset_decimals = 9,
  stable_decimals = 9,
}: UseTokenEventsOptions) {
  const queryClient = useQueryClient();
  
  const queryKey = [
    QueryKey.Tokens,
    proposalId,
    address,
    assetType ?? "all",
  ];

  const { data: tokens = [], ...query } = useQuery({
    queryKey,
    queryFn: () => {
      if (!address || !proposalId) {
        return [];
      }
      return fetchTokens(address, proposalId, assetType);
    },
    enabled: enabled && !!address && !!proposalId,
    staleTime: 30 * 1000, // Consider data stale after 30 seconds
    gcTime: 5 * 60 * 1000, // Keep in cache for 5 minutes
    refetchOnWindowFocus: false,
    refetchOnMount: true,
    retry: 3, // Retry failed requests
    retryDelay: (attemptIndex) => Math.min(1000 * 2 ** attemptIndex, 30000), // Exponential backoff
  });

  const [assetScale, stableScale] = useMemo(
    () => [10 ** asset_decimals, 10 ** stable_decimals],
    [asset_decimals, stable_decimals]
  );

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
          decimals: number
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
            asset_decimals
          ),
          stableBalanceFormatted: formatBalance(
            balances.stable,
            stableScale,
            stable_decimals
          ),
        };
      });
  }, [tokens, assetScale, stableScale, asset_decimals, stable_decimals]);

  // Provide a manual refresh function that invalidates the query
  const refreshTokens = () => {
    queryClient.invalidateQueries({ queryKey });
  };

  return {
    ...query,
    tokens,
    groupedTokens,
    error: query.error as Error | null,
    refreshTokens, // Keep for backward compatibility, but not needed in most cases
  };
}

// Export a hook to invalidate token queries from anywhere
export function useInvalidateTokens() {
  const queryClient = useQueryClient();
  
  return {
    invalidateTokens: (proposalId?: string, address?: string) => {
      if (proposalId && address) {
        // Invalidate specific tokens
        queryClient.invalidateQueries({
          queryKey: [QueryKey.Tokens, proposalId, address],
        });
      } else if (proposalId) {
        // Invalidate all tokens for a proposal
        queryClient.invalidateQueries({
          queryKey: [QueryKey.Tokens, proposalId],
        });
      } else {
        // Invalidate all token queries
        queryClient.invalidateQueries({
          queryKey: [QueryKey.Tokens],
        });
      }
    },
  };
}