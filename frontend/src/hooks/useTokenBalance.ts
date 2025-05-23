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

// Cache to store balances by account and token type
const balanceCache = new Map<string, { balance: string; timestamp: number }>();

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
        const cachedData = balanceCache.get(cacheKey);
        // Use cache if it exists and is less than 30 seconds old
        if (cachedData && Date.now() - cachedData.timestamp < 30000) {
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

        const formattedBalance = Number(totalBalance / BigInt(scale)).toFixed(
          6,
        );
        setBalance(formattedBalance);
        // Update cache
        if (cacheKey) {
          balanceCache.set(cacheKey, {
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
    const cachedData = cacheKey ? balanceCache.get(cacheKey) : null;
    if (cachedData) {
      setBalance(cachedData.balance);
      // Refresh in background if cache is older than 30 seconds
      if (Date.now() - cachedData.timestamp > 30000) {
        fetchBalance(true);
      }
    } else {
      fetchBalance(false);
    }

    // Set up periodic refresh every 5 minutes
    const intervalId = setInterval(() => {
      fetchBalance(true);
    }, 10000);

    return () => {
      clearInterval(intervalId);
    };
  }, [account, type, network, scale, fetchBalance, cacheKey]);

  return { balance, isLoading, refreshBalance: () => fetchBalance(true) };
}
