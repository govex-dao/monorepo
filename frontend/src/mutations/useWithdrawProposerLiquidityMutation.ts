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
      const loadingToast = toast.loading("Preparing transaction...");
      const walletApprovalTimeout = setTimeout(() => {
        toast.error("Wallet approval timeout - no response after 1 minute", {
          id: loadingToast,
          duration: 5000,
        });
      }, 60000);
      const txb = new Transaction();
      txb.setGasBudget(50000000);

      // Call the on-chain method: empty_all_amm_liquidity
      txb.moveCall({
        target: `${CONSTANTS.futarchyPackage}::liquidity_interact::empty_all_amm_liquidity`,
        arguments: [
          txb.object(proposalId),
          txb.object(escrowId),
          txb.pure.u64(winning_outcome)
        ],
        typeArguments: [`0x${assetType}`, `0x${stableType}`],
      });

      toast.loading("Withdrawing liquidity...", { id: loadingToast });

      try {
        const result = await executeTransaction(txb);

        if (
          result &&
          "effects" in result &&
          result.effects?.status?.status === "success"
        ) {
          setTimeout(() => {
            queryClient.invalidateQueries({ queryKey: [QueryKey.Proposals] });
          }, 10_000);
        }
        return result;
      } catch (error: any) {
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
