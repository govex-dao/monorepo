import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";
import { CONSTANTS } from "@/constants";

export const PROPOSAL_CONSTANTS = {
  TWAP_START_DELAY: 30000,
  TWAP_STEP_MAX: 9999999,
};

export interface CreateProposalData {
  title: string;
  description: string;
  metadata: string;
  outcomeMessages: string[];
  daoObjectId: string;
  assetType: string;
  stableType: string;
  minAssetAmount: string;
  minStableAmount: string;
  senderAddress: string;
}

export async function createProposalTransaction(
  formData: CreateProposalData,
  initialAmounts: number[] | null,
  packageId: string,
) {
  try {
    const client = new SuiClient({ url: getFullnodeUrl(CONSTANTS.network) });
    // Fetch all coins of both types
    const [assetCoins, stableCoins] = await Promise.all([
      client.getCoins({
        owner: formData.senderAddress,
        coinType: `0x${formData.assetType}`,
      }),
      client.getCoins({
        owner: formData.senderAddress,
        coinType: `0x${formData.stableType}`,
      }),
    ]);

    const txb = new Transaction();
    const isMainnet = CONSTANTS.network === "mainnet";
    const splitAmount = isMainnet ? 20_000_000_000 : 10_000;
    const gasBudget = isMainnet ? 20_500_000_000 : 1_000_000_000;
    txb.setGasBudget(gasBudget);

    const [paymentCoin] = txb.splitCoins(txb.gas, [txb.pure.u64(splitAmount)]);

    // Helper to prepare coins
    async function prepareCoin(
      coins: { data: { coinObjectId: string; balance: string }[] },
      minAmount: string,
      coinType: string,
    ) {
      if (!coins.data.length) {
        throw new Error(`No ${coinType} coins available`);
      }

      const minAmountBig = BigInt(minAmount);
      const sortedCoins = [...coins.data].sort((a, b) =>
        Number(BigInt(b.balance) - BigInt(a.balance)),
      );

      // Check if largest coin meets requirements
      if (BigInt(sortedCoins[0].balance) >= minAmountBig) {
        const [splitCoin] = txb.splitCoins(
          txb.object(sortedCoins[0].coinObjectId),
          [txb.pure.u64(minAmount)],
        );
        return splitCoin;
      }

      // We need to merge multiple coins
      let totalBalance = 0n;
      const coinsToMerge = [];

      for (const coin of sortedCoins) {
        totalBalance += BigInt(coin.balance);
        coinsToMerge.push(coin.coinObjectId);

        if (totalBalance >= minAmountBig) {
          break;
        }
      }

      if (totalBalance < minAmountBig) {
        throw new Error(
          `Insufficient ${coinType} balance. Required: ${minAmount}, Available: ${totalBalance}`,
        );
      }

      // Create primary coin first
      const primaryCoin = txb.object(coinsToMerge[0]);

      // Merge additional coins if needed
      if (coinsToMerge.length > 1) {
        txb.mergeCoins(
          primaryCoin,
          coinsToMerge.slice(1).map((id) => txb.object(id)),
        );
      }

      // Split the exact amount needed
      const [splitCoin] = txb.splitCoins(primaryCoin, [
        txb.pure.u64(minAmount),
      ]);
      return splitCoin;
    }

    // Create proposal using string arguments directly
    // First calculate max values for asset and stable amounts
    const getMaxAmounts = (
      amounts: number[],
    ): { maxAsset: number; maxStable: number } => {
      let maxAsset = 0;
      let maxStable = 0;
      for (let i = 0; i < amounts.length; i += 2) {
        maxAsset = Math.max(maxAsset, amounts[i]);
        maxStable = Math.max(maxStable, amounts[i + 1]);
      }
      return { maxAsset, maxStable };
    };

    // Get max amounts from initial amounts
    const { maxAsset, maxStable } = initialAmounts
      ? getMaxAmounts(initialAmounts)
      : { maxAsset: 10000, maxStable: 10000 };

    // Prepare coins with max amounts
    const [preparedAssetCoin, preparedStableCoin] = await Promise.all([
      prepareCoin(assetCoins, maxAsset.toString(), `0x${formData.assetType}`),
      prepareCoin(
        stableCoins,
        maxStable.toString(),
        `0x${formData.stableType}`,
      ),
    ]);

    txb.moveCall({
      target: `${packageId}::dao::create_proposal`,
      typeArguments: [`0x${formData.assetType}`, `0x${formData.stableType}`],
      arguments: [
        txb.object(formData.daoObjectId),
        txb.object(CONSTANTS.futarchyPaymentManagerId),
        paymentCoin,
        txb.pure.u64(formData.outcomeMessages.length),
        preparedAssetCoin,
        preparedStableCoin,
        txb.pure.string(formData.title),
        txb.pure.string(formData.description),
        txb.pure.string(formData.metadata),
        txb.pure.vector("string", formData.outcomeMessages),
        initialAmounts
          ? txb.pure.option("vector<u64>", initialAmounts)
          : txb.pure.option("vector<u64>", null),
        txb.object("0x6"),
      ],
    });

    return txb;
  } catch (error) {
    console.error(
      error instanceof Error
        ? error.message
        : "Failed to create proposal transaction",
    );

    throw error; // Re-throw to allow caller to handle the error if needed
  }
}

// Helper function to use in forms
export async function getAvailableBalance(
  address: string,
  coinType: string,
  network: "mainnet" | "testnet" | "devnet" | "localnet",
): Promise<bigint> {
  const client = new SuiClient({ url: getFullnodeUrl(network) });

  const coins = await client.getCoins({
    owner: address,
    coinType: coinType,
  });

  return coins.data.reduce((total, coin) => total + BigInt(coin.balance), 0n);
}
