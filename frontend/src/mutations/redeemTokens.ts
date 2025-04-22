import { CONSTANTS, QueryKey } from "@/constants";
import { useTransactionExecution } from "@/hooks/useTransactionExecution";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import toast from "react-hot-toast";
import { Transaction } from "@mysten/sui/transactions";
import { useCurrentAccount } from "@mysten/dapp-kit";

interface RedeemTokensParams {
  proposalId: string;
  userTokens: {
    id: string;
    outcome: number;
    balance: string;
    asset_type: number;
  }[];
  winning_outcome: string | null;
  current_state: number;
  escrow: string;
  asset_type: string;
  stable_type: string;
  outcome_count: string;
}

/**
 * Builds and executes a PTB to redeem tokens.
 * When a winning outcome exists, calls the appropriate redeem_winning method.
 * Otherwise, for complete set redemption:
 *
 * 1. For each outcome, if multiple tokens exist, they are merged using
 *    conditional_token::merge_many_entry.
 * 2. The minimum (common) balance across outcomes is determined.
 * 3. For outcomes with excess tokens, conditional_token::split_entry is called
 *    to reduce the balance to the common amount.
 * 4. Finally, the complete set redemption is triggered.
 */
export function useRedeemTokensMutation() {
  const currentAccount = useCurrentAccount();
  const executeTransaction = useTransactionExecution();
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: async ({
      proposalId,
      userTokens,
      winning_outcome,
      escrow,
      asset_type,
      stable_type,
      outcome_count,
    }: RedeemTokensParams) => {
      if (!currentAccount?.address) {
        throw new Error("Wallet not connected");
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

      if (winning_outcome !== null) {
        // Split winning tokens by asset type
        const winningOutcome = parseInt(winning_outcome, 10);
        const winningTokensByType = {
          asset: userTokens.filter(
            (t) => t.outcome === winningOutcome && t.asset_type === 0,
          ),
          stable: userTokens.filter(
            (t) => t.outcome === winningOutcome && t.asset_type === 1,
          ),
        };

        // Handle asset tokens if present
        if (winningTokensByType.asset.length > 0) {
          let tokenToRedeem = winningTokensByType.asset[0].id;
          if (winningTokensByType.asset.length > 1) {
            const [baseToken, ...restTokens] = winningTokensByType.asset;
            txb.moveCall({
              target: `${CONSTANTS.futarchyPackage}::conditional_token::merge_many_entry`,
              arguments: [
                txb.object(baseToken.id),
                txb.makeMoveVec({
                  elements: restTokens.map((t) => txb.object(t.id)),
                }),
                txb.object("0x6"),
              ],
            });
            tokenToRedeem = baseToken.id;
          }

          txb.moveCall({
            target: `${CONSTANTS.futarchyPackage}::liquidity_interact::redeem_winning_tokens_asset_entry`,
            arguments: [
              txb.object(proposalId),
              txb.object(escrow),
              txb.object(tokenToRedeem),
              txb.object("0x6"),
            ],
            typeArguments: [`0x${asset_type}`, `0x${stable_type}`],
          });
        }

        // Handle stable tokens if present
        if (winningTokensByType.stable.length > 0) {
          let tokenToRedeem = winningTokensByType.stable[0].id;
          if (winningTokensByType.stable.length > 1) {
            const [baseToken, ...restTokens] = winningTokensByType.stable;
            txb.moveCall({
              target: `${CONSTANTS.futarchyPackage}::conditional_token::merge_many_entry`,
              arguments: [
                txb.object(baseToken.id),
                txb.makeMoveVec({
                  elements: restTokens.map((t) => txb.object(t.id)),
                }),
                txb.object("0x6"),
              ],
            });
            tokenToRedeem = baseToken.id;
          }

          txb.moveCall({
            target: `${CONSTANTS.futarchyPackage}::liquidity_interact::redeem_winning_tokens_stable_entry`,
            arguments: [
              txb.object(proposalId),
              txb.object(escrow),
              txb.object(tokenToRedeem),
              txb.object("0x6"),
            ],
            typeArguments: [`0x${asset_type}`, `0x${stable_type}`],
          });
        }
      } else {
        // Complete Set Redemption
        const tokensByType = {
          asset: userTokens.filter((t) => t.asset_type === 0),
          stable: userTokens.filter((t) => t.asset_type === 1),
        };

        // Handle asset tokens complete set
        if (tokensByType.asset.length > 0) {
          const assetTokensByOutcome = new Array(parseInt(outcome_count, 10))
            .fill(null)
            .map((_, i) => tokensByType.asset.filter((t) => t.outcome === i));

          let completeSetTokens: string[] = [];
          let commonAmount: bigint | undefined;

          // Process each outcome's asset tokens
          for (let i = 0; i < assetTokensByOutcome.length; i++) {
            const tokensForOutcome = assetTokensByOutcome[i];
            if (tokensForOutcome.length === 0) continue;

            let tokenId = tokensForOutcome[0].id;
            if (tokensForOutcome.length > 1) {
              const [baseToken, ...restTokens] = tokensForOutcome;
              txb.moveCall({
                target: `${CONSTANTS.futarchyPackage}::conditional_token::merge_many_entry`,
                arguments: [
                  txb.object(baseToken.id),
                  txb.makeMoveVec({
                    elements: restTokens.map((t) => txb.object(t.id)),
                  }),
                  txb.object("0x6"),
                ],
              });
              tokenId = baseToken.id;
            }

            const outcomeBalance = tokensForOutcome.reduce(
              (sum, t) => sum + BigInt(t.balance),
              0n,
            );
            if (commonAmount === undefined || outcomeBalance < commonAmount) {
              commonAmount = outcomeBalance;
            }
            completeSetTokens.push(tokenId);
          }

          // First pass: merge tokens and find common amount
          // Second pass: split tokens if needed to match common amount
          if (commonAmount !== undefined) {
            for (let i = 0; i < completeSetTokens.length; i++) {
              const tokenId = completeSetTokens[i];
              const outcomeTokens = assetTokensByOutcome[i];
              const tokenBalance = outcomeTokens.reduce(
                (sum, t) => sum + BigInt(t.balance),
                0n,
              );

              if (tokenBalance > commonAmount) {
                txb.moveCall({
                  target: `${CONSTANTS.futarchyPackage}::conditional_token::split_entry`,
                  arguments: [
                    txb.object(tokenId),
                    txb.pure.u64(tokenBalance - commonAmount),
                    txb.object("0x6"),
                  ],
                });
                // Token ID stays the same after split
              }
            }
          }

          if (completeSetTokens.length === parseInt(outcome_count, 10)) {
            txb.moveCall({
              target: `${CONSTANTS.futarchyPackage}::liquidity_interact::redeem_complete_set_asset_entry`,
              arguments: [
                txb.object(proposalId),
                txb.object(escrow),
                txb.makeMoveVec({
                  elements: completeSetTokens.map((id) => txb.object(id)),
                }),
                txb.object("0x6"),
              ],
              typeArguments: [`0x${asset_type}`, `0x${stable_type}`],
            });
          }
        }

        // Handle stable tokens complete set
        if (tokensByType.stable.length > 0) {
          const stableTokensByOutcome = new Array(parseInt(outcome_count, 10))
            .fill(null)
            .map((_, i) => tokensByType.stable.filter((t) => t.outcome === i));

          let completeSetTokens: string[] = [];
          let commonAmount: bigint | undefined;

          // Process each outcome's stable tokens
          for (let i = 0; i < stableTokensByOutcome.length; i++) {
            const tokensForOutcome = stableTokensByOutcome[i];
            if (tokensForOutcome.length === 0) continue;

            let tokenId = tokensForOutcome[0].id;
            if (tokensForOutcome.length > 1) {
              const [baseToken, ...restTokens] = tokensForOutcome;
              txb.moveCall({
                target: `${CONSTANTS.futarchyPackage}::conditional_token::merge_many_entry`,
                arguments: [
                  txb.object(baseToken.id),
                  txb.makeMoveVec({
                    elements: restTokens.map((t) => txb.object(t.id)),
                  }),
                  txb.object("0x6"),
                ],
              });
              tokenId = baseToken.id;
            }

            const outcomeBalance = tokensForOutcome.reduce(
              (sum, t) => sum + BigInt(t.balance),
              0n,
            );
            if (commonAmount === undefined || outcomeBalance < commonAmount) {
              commonAmount = outcomeBalance;
            }
            completeSetTokens.push(tokenId);
          }

          // Second pass: split tokens if needed to match common amount
          if (commonAmount !== undefined) {
            for (let i = 0; i < completeSetTokens.length; i++) {
              const tokenId = completeSetTokens[i];
              const outcomeTokens = stableTokensByOutcome[i];
              const tokenBalance = outcomeTokens.reduce(
                (sum, t) => sum + BigInt(t.balance),
                0n,
              );

              if (tokenBalance > commonAmount) {
                txb.moveCall({
                  target: `${CONSTANTS.futarchyPackage}::conditional_token::split_entry`,
                  arguments: [
                    txb.object(tokenId),
                    txb.pure.u64(tokenBalance - commonAmount),
                    txb.object("0x6"),
                  ],
                });
                // Token ID stays the same after split
              }
            }
          }

          if (completeSetTokens.length === parseInt(outcome_count, 10)) {
            txb.moveCall({
              target: `${CONSTANTS.futarchyPackage}::liquidity_interact::redeem_complete_set_stable_entry`,
              arguments: [
                txb.object(proposalId),
                txb.object(escrow),
                txb.makeMoveVec({
                  elements: completeSetTokens.map((id) => txb.object(id)),
                }),
                txb.object("0x6"),
              ],
              typeArguments: [`0x${asset_type}`, `0x${stable_type}`],
            });
          }
        }
      }

      toast.loading("Redeeming tokens...", { id: loadingToast });
      try {
        const result = await executeTransaction(txb);
        if (
          result &&
          result.digest &&
          "effects" in result &&
          result.effects?.status?.status === "success"
        ) {
          queryClient.invalidateQueries({ queryKey: [QueryKey.Proposals] });
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
