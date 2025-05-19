import { useState, useEffect, useCallback } from "react";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { SuiClient } from "@mysten/sui/client";
import { getFullnodeUrl } from "@mysten/sui/client";
import { CONSTANTS } from "@/constants";

interface TokenBalanceProps {
  type: string;
  scale: number;
  network?: "testnet" | "mainnet" | "devnet" | "localnet";
}

const DECIMALS_TO_DISPLAY = 6;

// Cache to store balances by account and token type
const MAX_CACHE_SIZE = 50; // Maximum number of items in the cache
const ITEM_TTL = 30000;

// The actual cache store. Using a Map preserves insertion order,
// which helps us identify the least recently used item.
const _balanceCacheLRU = new Map<
  string,
  { balance: string; timestamp: number }
>();

/**
 * Retrieves an item from the LRU cache.
 * If the item exists and is not expired (within ITEM_TTL), it's marked as
 * recently used (by re-inserting it) and returned.
 * Otherwise, it's removed from the cache and undefined is returned.
 */
function getFromCache(
  key: string,
): { balance: string; timestamp: number } | undefined {
  const item = _balanceCacheLRU.get(key);
  if (item) {
    if (Date.now() - item.timestamp > ITEM_TTL) {
      _balanceCacheLRU.delete(key); // Item is stale, remove it
      return undefined;
    }
    // Mark as recently used: delete and then set again to move it to the end of the Map.
    _balanceCacheLRU.delete(key);
    _balanceCacheLRU.set(key, item);
    return item;
  }
  return undefined;
}

/**
 * Adds or updates an item in the LRU cache.
 * If the cache exceeds MAX_CACHE_SIZE, the least recently used item is evicted.
 * The new/updated item is marked as the most recently used.
 */
function setToCache(
  key: string,
  value: { balance: string; timestamp: number },
): void {
  if (_balanceCacheLRU.has(key)) {
    // If key exists, delete to re-insert it at the end (MRU)
    _balanceCacheLRU.delete(key);
  }
  _balanceCacheLRU.set(key, value);

  // Evict least recently used if cache exceeds max size
  if (_balanceCacheLRU.size > MAX_CACHE_SIZE) {
    // The first key in the Map's iteration order is the oldest (least recently used)
    const oldestKey = _balanceCacheLRU.keys().next().value;
    if (oldestKey) {
      _balanceCacheLRU.delete(oldestKey);
    }
  }
}
// --- End LRU Cache Implementation ---

/**
 * Custom hook to fetch a token balance
 * @returns {Object} Object containing token balance as formatted string, loading state, and refresh function
 */
export function useTokenBalance({
  type,
  scale,
  network = CONSTANTS.network,
}: TokenBalanceProps) {
  const [balance, setBalance] = useState<string>("0");
  const [isLoading, setIsLoading] = useState<boolean>(false);
  const account = useCurrentAccount();

  const cacheKey = account
    ? `${account.address}-${type}-${network}`
    : undefined;

  const fetchBalance = useCallback(
    async (forceRefresh = false) => {
      if (!account) return;

      // Check cache first if not forcing refresh
      if (!forceRefresh && cacheKey) {
        const cachedData = getFromCache(cacheKey); // getFromCache handles TTL and LRU update
        if (cachedData) {
          // If data is returned, it's fresh enough
          setBalance(cachedData.balance);
          return;
        }
      }

      setIsLoading(true);

      try {
        const client = new SuiClient({ url: getFullnodeUrl(network) });

        const coins = await client.getCoins({
          owner: account.address,
          coinType: `0x${type}`,
        });

        const totalBalance = coins.data.reduce(
          (sum, coin) => sum + BigInt(coin.balance),
          0n,
        );

        const precisionFactor = BigInt(10 ** DECIMALS_TO_DISPLAY);
        const valueWithPrecision =
          (totalBalance * precisionFactor) / BigInt(scale);
        const numericValue =
          Number(valueWithPrecision) / Number(precisionFactor);
        const formattedBalance = numericValue.toFixed(DECIMALS_TO_DISPLAY);
        setBalance(formattedBalance);
        // Update cache
        if (cacheKey) {
          setToCache(cacheKey, {
            balance: formattedBalance,
            timestamp: Date.now(),
          });
        }
      } catch (error) {
        console.error("Error fetching balance:", error);
        setBalance("0");
      } finally {
        setIsLoading(false);
      }
    },
    [account, network, scale, type, cacheKey],
  );

  useEffect(() => {
    // Initialize from cache or fetch if needed
    const cachedData = cacheKey ? getFromCache(cacheKey) : null; // Use getFromCache to respect TTL & update LRU
    if (cachedData) {
      setBalance(cachedData.balance);
      // The periodic refresh (setInterval) will handle subsequent updates.
    } else {
      fetchBalance(false); // Fetch if not in cache or if cache item was stale
    }

    // Set up periodic refresh every 5 minutes
    const intervalId = setInterval(() => {
      fetchBalance(true);
    }, 300000);

    return () => {
      clearInterval(intervalId);
    };
  }, [account, type, network, scale, fetchBalance, cacheKey]);

  return { balance, isLoading, refreshBalance: () => fetchBalance(true) };
}
