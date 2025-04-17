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

/**
 * Custom hook to fetch a token balance
 * @returns {Object} Object containing token balance as formatted string and loading state
 */
export function useTokenBalance({
  type,
  scale,
  network = CONSTANTS.network,
}: TokenBalanceProps) {
  const [balance, setBalance] = useState<string>("0");
  const [isLoading, setIsLoading] = useState<boolean>(false);
  const account = useCurrentAccount();

  const fetchBalance = useCallback(async () => {
    if (!account) return;
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

      const formattedBalance = Number(totalBalance / BigInt(scale)).toFixed(6);
      setBalance(formattedBalance);
    } catch (error) {
      console.error("Error fetching balance:", error);
      setBalance("0");
    } finally {
      setIsLoading(false);
    }
  }, [account, network, scale, type]);

  useEffect(() => {
    fetchBalance();

    // Set up subscription to listen for balance changes
    const subscribeToBalanceChanges = async () => {
      if (!account) return;

      try {
        const client = new SuiClient({ url: getFullnodeUrl(network) });

        // Subscribe to coin balances for the account
        const unsubscribe = await client.subscribeEvent({
          filter: {
            MoveEventType: `0x2::coin::CoinBalanceChange`,
            Sender: account.address,
          },
          onMessage: () => {
            fetchBalance(); // Refresh balance when changes occur
          },
        });

        // Return cleanup function
        return () => {
          unsubscribe();
        };
      } catch (error) {
        console.error("Error subscribing to balance changes:", error);
      }
    };

    const unsubscribe = subscribeToBalanceChanges();

    return () => {
      // Clean up subscription on unmount
      if (unsubscribe) {
        unsubscribe.then((cleanup) => {
          if (cleanup) cleanup();
        });
      }
    };
  }, [account, type, network, scale, fetchBalance]);

  return { balance, isLoading };
}
