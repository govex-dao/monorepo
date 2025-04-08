import { useState, useEffect } from 'react';
import { useCurrentAccount } from "@mysten/dapp-kit";
import { SuiClient } from '@mysten/sui/client';
import { getFullnodeUrl } from '@mysten/sui/client';
import { CONSTANTS } from "@/constants";

interface TokenBalancesProps {
  assetType: string;
  stableType: string;
  assetScale: number;
  stableScale: number;
  network?: "testnet" | "mainnet" | "devnet" | "localnet";
}

/**
 * Custom hook to fetch both asset and stable token balances
 * @returns {Object} Object containing asset and stable balances as formatted strings
 */
export function useTokenBalances({
  assetType,
  stableType,
  assetScale,
  stableScale,
  network = CONSTANTS.network
}: TokenBalancesProps) {
  const [assetBalance, setAssetBalance] = useState<string>('0');
  const [stableBalance, setStableBalance] = useState<string>('0');
  const account = useCurrentAccount();

  useEffect(() => {
    const fetchBalances = async () => {
      if (!account) return;

      try {
        const client = new SuiClient({ url: getFullnodeUrl(network) });

        // Fetch asset balance
        const assetCoins = await client.getCoins({
          owner: account.address,
          coinType: `0x${assetType}`
        });

        const totalAssetBalance = assetCoins.data.reduce(
          (sum, coin) => sum + BigInt(coin.balance), 0n
        );

        const formattedAssetBalance = (Number(totalAssetBalance) / Number(assetScale)).toFixed(6);
        setAssetBalance(formattedAssetBalance);

        // Fetch stable balance
        const stableCoins = await client.getCoins({
          owner: account.address,
          coinType: `0x${stableType}`
        });

        const totalStableBalance = stableCoins.data.reduce(
          (sum, coin) => sum + BigInt(coin.balance), 0n
        );

        const formattedStableBalance = (Number(totalStableBalance) / Number(stableScale)).toFixed(6);
        setStableBalance(formattedStableBalance);
      } catch (error) {
        console.error('Error fetching balances:', error);
        setAssetBalance('0');
        setStableBalance('0');
      }
    };

    fetchBalances();
  }, [account, assetType, stableType, network, assetScale, stableScale]);

  return { assetBalance, stableBalance };
} 