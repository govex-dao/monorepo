import { CONSTANTS, QueryKey } from "@/constants";
import { useSuiTransaction } from "@/hooks/useSuiTransaction";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { Transaction } from "@mysten/sui/transactions";
import { useMutation, useQueryClient } from "@tanstack/react-query";

export function useWithdrawProposerLiquidityMutation() {
  const currentAccount = useCurrentAccount();
  const { executeTransaction } = useSuiTransaction();
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
        ],
        typeArguments: [`0x${assetType}`, `0x${stableType}`],
      });

      await executeTransaction(
        txb,
        {
          onSuccess: () => {
            setTimeout(() => {
              queryClient.invalidateQueries({ queryKey: [QueryKey.Proposals] });
            }, 10_000);
          },
        },
        {
          loadingMessage: "Withdrawing liquidity...",
          successMessage: "Liquidity withdrawn successfully!",
          errorMessage: (error) => {
            if (error.message?.includes("Rejected from user")) {
              return "Transaction cancelled by user";
            } else if (error.message?.includes("Insufficient gas")) {
              return "Insufficient SUI for gas fees";
            }
            return `Failed to withdraw liquidity: ${error.message}`;
          },
        },
      );
    },
  });
}
