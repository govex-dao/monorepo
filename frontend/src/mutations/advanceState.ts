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

      const loadingToast = toast.loading("Preparing transaction...");
      const walletApprovalTimeout = setTimeout(() => {
        toast.error("Wallet approval timeout - no response after 1 minute", {
          id: loadingToast,
          duration: 5000,
        });
      }, 60000);

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

      try {
        toast.loading("Waiting for wallet approval...", { id: loadingToast });
        const result = await executeTransaction(txb);

        // Check if we have a result and it was successful
        if (
          result &&
          "effects" in result &&
          result.effects?.status?.status === "success"
        ) {
          // Wait for backend to update (10 seconds)
          setTimeout(() => {
            queryClient.invalidateQueries({ queryKey: [QueryKey.Proposals] });
          }, 10_000);
        }

        return result;
      } catch (error) {
        // Dismiss loading toast and show error
        console.error(
          error instanceof Error ? error.message : "Transaction failed",
        );
        throw error;
      } finally {
        clearTimeout(walletApprovalTimeout);
        toast.dismiss(loadingToast);
      }
    },

    onError: (error) => {
      toast.error(`Failed to advance state: ${error.message}`);
    },
  });
}
