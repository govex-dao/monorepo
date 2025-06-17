import { CONSTANTS, QueryKey } from "@/constants";
import { useSuiTransaction } from "@/hooks/useSuiTransaction";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { Transaction } from "@mysten/sui/transactions";
import { useMutation, useQueryClient } from "@tanstack/react-query";

/**
 * Builds and executes the PTB to advance the proposal state.
 * Handles success/error states after transaction confirmation.
 */
export function useAdvanceStateMutation() {
  const currentAccount = useCurrentAccount();
  const { executeTransaction } = useSuiTransaction();
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

      await executeTransaction(
        txb,
        {
          onSuccess: () => {
            // Wait for backend to update (10 seconds)
            setTimeout(() => {
              queryClient.invalidateQueries({ queryKey: [QueryKey.Proposals] });
            }, 10_000);
          },
        },
        {
          loadingMessage: "Advancing proposal state...",
          successMessage: "Proposal state advanced successfully!",
          errorMessage: (error) => {
            if (error.message?.includes("Rejected from user")) {
              return "Transaction cancelled by user";
            } else if (error.message?.includes("Insufficient gas")) {
              return "Insufficient SUI for gas fees";
            }
            return `Failed to advance state: ${error.message}`;
          },
        },
      );
    },
  });
}
