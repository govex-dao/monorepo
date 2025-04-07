import { CONSTANTS, QueryKey } from "@/constants";
import { useTransactionExecution } from "@/hooks/useTransactionExecution";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { Transaction } from "@mysten/sui/transactions";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import toast from "react-hot-toast";

export function useWithdrawProposerLiquidityMutation() {
  const currentAccount = useCurrentAccount();
  const executeTransaction = useTransactionExecution();
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: async ({
      proposalId,
      escrowId,
      assetType,
      stableType,
      winning_outcome,
    }: {
      proposalId: string;
      escrowId: string;
      assetType: string;
      stableType: string;
      winning_outcome: number;
    }) => {
      if (!currentAccount?.address)
        throw new Error("You need to connect your wallet!");

      const txb = new Transaction();
      txb.setGasBudget(50000000);

      // Call the on-chain method: empty_all_amm_liquidity
      txb.moveCall({
        target: `${CONSTANTS.futarchyPackage}::liquidity_interact::empty_all_amm_liquidity`,
        arguments: [
          txb.object(proposalId),
          txb.object(escrowId),
          txb.pure.u64(winning_outcome),
          txb.object("0x6"),
        ],
        typeArguments: [`0x${assetType}`, `0x${stableType}`],
      });

      const loadingToast = toast.loading("Withdrawing liquidity...");

      try {
        const result = await executeTransaction(txb);
        toast.dismiss(loadingToast);

        if (
          result &&
          "effects" in result &&
          result.effects?.status?.status === "success"
        ) {
          toast.success("Liquidity withdrawn successfully!");
          setTimeout(() => {
            queryClient.invalidateQueries({ queryKey: [QueryKey.Proposals] });
          }, 10_000);
        } else {
          toast.error("Failed to withdraw liquidity: Transaction failed");
        }
        return result;
      } catch (error: any) {
        toast.dismiss(loadingToast);
        throw error;
      }
    },
    onError: (error: any) => {
      toast.error(`Failed to withdraw liquidity: ${error.message}`);
    },
  });
}
