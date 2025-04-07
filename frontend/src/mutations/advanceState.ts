import { CONSTANTS, QueryKey } from "@/constants";
import { useTransactionExecution } from "@/hooks/useTransactionExecution";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { Transaction } from "@mysten/sui/transactions";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import toast from "react-hot-toast";

/**
 * Builds and executes the PTB to advance the proposal state.
 * Handles success/error states after transaction confirmation.
 */
export function useAdvanceStateMutation() {
  const currentAccount = useCurrentAccount();
  const executeTransaction = useTransactionExecution();
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: async ({
      proposalId,
      escrowId,
      assetType,
      stableType,
      daoId,
      proposalState,
    }: {
      proposalId: string;
      escrowId: string;
      assetType: string;
      stableType: string;
      daoId: string;
      proposalState: number;
    }) => {
      if (!currentAccount?.address)
        throw new Error("You need to connect your wallet!");
      const txb = new Transaction();
      txb.setGasBudget(50000000);
      console.log(
        CONSTANTS.futarchyPackage,
        assetType,
        stableType,
        proposalId,
        escrowId,
        daoId,
      );

      if (proposalState === 0 || proposalState == null) {
        txb.moveCall({
          target: `${CONSTANTS.futarchyPackage}::advance_stage::try_advance_state_entry`,
          arguments: [
            txb.object(proposalId),
            txb.object(escrowId),
            txb.object(CONSTANTS.futarchyPaymentManagerId),
            txb.object("0x6"),
          ],
          typeArguments: [`0x${assetType}`, `0x${stableType}`],
        });
      }

      // If the current proposal state is 1, call sign_result_entry after advancing state
      if (proposalState === 1) {
        txb.moveCall({
          target: `${CONSTANTS.futarchyPackage}::advance_stage::try_advance_state_entry`,
          arguments: [
            txb.object(proposalId),
            txb.object(escrowId),
            txb.object(CONSTANTS.futarchyPaymentManagerId),
            txb.object("0x6"),
          ],
          typeArguments: [`0x${assetType}`, `0x${stableType}`],
        });
      } else if (proposalState === 2) {
        txb.moveCall({
          target: `${CONSTANTS.futarchyPackage}::dao::sign_result_entry`,
          arguments: [
            txb.object(daoId),
            txb.object(proposalId),
            txb.object(escrowId),
            txb.object("0x6"), // TODO: Replace '0xClock' with the proper clock object reference
          ],
          typeArguments: [`0x${assetType}`, `0x${stableType}`],
        });
      }

      // Show loading toast while transaction is processing
      const loadingToast = toast.loading("Advancing state...");

      try {
        const result = await executeTransaction(txb);

        // Dismiss loading toast
        toast.dismiss(loadingToast);

        // Check if we have a result and it was successful
        if (
          result &&
          "effects" in result &&
          result.effects?.status?.status === "success"
        ) {
          toast.success("State advanced successfully!");
          // Wait for backend to update (10 seconds)
          setTimeout(() => {
            queryClient.invalidateQueries({ queryKey: [QueryKey.Proposals] });
          }, 10_000);
        } else {
          // Handle failed transaction
          toast.error("Failed to advance state: Transaction failed");
        }

        return result;
      } catch (error) {
        // Dismiss loading toast and show error
        toast.dismiss(loadingToast);
        throw error;
      }
    },

    onError: (error) => {
      toast.error(`Failed to advance state: ${error.message}`);
    },
  });
}
