import { useCurrentAccount } from "@mysten/dapp-kit";
import { Transaction } from "@mysten/sui/transactions";
import { useMutation } from "@tanstack/react-query";
import { useTransactionExecution } from "@/hooks/useTransactionExecution";
import toast from "react-hot-toast";
import { CONSTANTS } from "../../constants";

export function useMintTestnetCoins() {
  const account = useCurrentAccount();
  const executeTransaction = useTransactionExecution();

  return useMutation({
    mutationFn: async () => {
      if (!account?.address) {
        throw new Error("Please connect your wallet first!");
      }
      const loadingToast = toast.loading("Preparing transaction...");
      const walletApprovalTimeout = setTimeout(() => {
        toast.error("Wallet approval timeout - no response after 1 minute", {
          id: loadingToast,
          duration: 5000,
        });
      }, 60000);
      const txb = new Transaction();
      txb.setGasBudget(50000000);

      // Mint asset coins
      txb.moveCall({
        target: `${CONSTANTS.assetPackage}::my_asset::mint`,
        arguments: [
          txb.object(CONSTANTS.assetTreasury),
          txb.pure.u64(10000000),
          txb.pure.address(account.address),
        ],
      });

      // Mint stable coins
      txb.moveCall({
        target: `${CONSTANTS.stablePackage}::my_stable::mint`,
        arguments: [
          txb.object(CONSTANTS.stableTreasury),
          txb.pure.u64(10000000),
          txb.pure.address(account.address),
        ],
      });

      // Show loading toast while transaction is processing

      toast.loading("Minting testnet coins...", { id: loadingToast });

      try {
        const result = await executeTransaction(txb);

        return result;
      } catch (error) {
        console.error(
          error instanceof Error ? error.message : "Transaction failed",
        );
      } finally {
        toast.dismiss(loadingToast);
        clearTimeout(walletApprovalTimeout);
      }
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
