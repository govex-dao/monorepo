import { useState, useEffect } from 'react';
import { SuiClient, getFullnodeUrl } from '@mysten/sui/client';
import { TokenInfo } from '../components/trade/TradeForm';
import { CONSTANTS } from "@/constants";
import { SuiObjectResponse } from '@mysten/sui/client';

const packageId = CONSTANTS.futarchyPackage;
const client = new SuiClient({ url: getFullnodeUrl(CONSTANTS.network) });

interface UseTokenEventsOptions {
  proposalId: string;
  address?: string;
  assetType?: string | null;
  enabled?: boolean;
}

export function useTokenEvents({ proposalId, address, assetType, enabled = true }: UseTokenEventsOptions) {
  const [tokens, setTokens] = useState<TokenInfo[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    if (!enabled || !address || !proposalId) return;

    const fetchTokens = async () => {
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
              StructType: tokenType
            },
            options: {
              showType: true,
              showContent: true,
              showDisplay: true
            }
          });

          const pageTokens = objects.data
            .filter((obj: SuiObjectResponse) => {
              if (!obj.data?.content || obj.data.content.dataType !== 'moveObject') return false;
              const content = obj.data.content as any;
              if (content.fields.market_id !== proposalId) return false;
              if (assetType && content.fields.asset_type !== Number(assetType)) return false;
              return true;
            })
            .map((obj: SuiObjectResponse) => {
              const content = obj.data?.content as any;
              return {
                id: obj.data?.objectId || '',
                balance: content.fields.balance,
                outcome: content.fields.outcome,
                asset_type: content.fields.asset_type
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
        setTokens(dedupedTokens);
      } catch (err) {
        setError(err instanceof Error ? err : new Error('Failed to fetch tokens'));
        console.error('Error fetching tokens:', err);
      } finally {
        setIsLoading(false);
      }
    };

    fetchTokens();
  }, [proposalId, address, assetType, enabled]);

  return { tokens, isLoading, error };
}