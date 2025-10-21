import { useCurrentAccount } from "@mysten/dapp-kit";
import { Transaction } from "@mysten/sui/transactions";
import { useMutation } from "@tanstack/react-query";
import { useSuiTransaction } from "@/hooks/useSuiTransaction";
import { CONSTANTS } from "../../constants";

export function useMintTestnetCoins() {
  const account = useCurrentAccount();
  const { executeTransaction } = useSuiTransaction();

  return useMutation({
    mutationFn: async () => {
      if (!account?.address) {
        throw new Error("Please connect your wallet first!");
      }

      const txb = new Transaction();
      txb.setGasBudget(50000000);

      // Mint asset coins
      txb.moveCall({
        target: `${CONSTANTS.assetPackage}::my_asset::mint`,
        arguments: [
          txb.object(CONSTANTS.assetTreasury),
          txb.pure.u64(10000000000),
          txb.pure.address(account.address),
        ],
      });

      // Mint stable coins
      txb.moveCall({
        target: `${CONSTANTS.stablePackage}::my_stable::mint`,
        arguments: [
          txb.object(CONSTANTS.stableTreasury),
          txb.pure.u64(10000000000),
          txb.pure.address(account.address),
        ],
      });

      await executeTransaction(
        txb,
        {},
        {
          loadingMessage: "Minting testnet coins...",
          successMessage:
            "Testnet coins minted successfully! You received 10 ASSET and 10 STABLE tokens.",
          errorMessage: (error) => {
            if (error.message?.includes("Rejected from user")) {
              return "Transaction cancelled by user";
            } else if (error.message?.includes("Insufficient gas")) {
              return "Insufficient SUI for gas fees";
            }
            return `Failed to mint coins: ${error.message}`;
          },
        },
      );
    },
  });
}

interface MintTestnetCoinsProps {
  className?: string;
}

export function MintTestnetCoins({ className = "" }: MintTestnetCoinsProps) {
  const { mutate: mintCoins, isPending } = useMintTestnetCoins();

  return (
    <button
      onClick={() => mintCoins()}
      disabled={isPending}
      className={`px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-full text-sm font-medium disabled:opacity-50 disabled:cursor-not-allowed transition-colors ${className}`}
    >
      {isPending ? "Minting..." : "Mint Testnet Coins"}
    </button>
  );
}

export default MintTestnetCoins;
