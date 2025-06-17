import { useState, useCallback, useRef, useEffect } from "react";
import { useSignAndExecuteTransaction, useSuiClient } from "@mysten/dapp-kit";
import { Transaction } from "@mysten/sui/transactions";
import toast from "react-hot-toast";
import { CONSTANTS } from "@/constants";

export interface TransactionCallbacks {
  onSuccess?: (result: any) => void;
  onError?: (error: Error) => void;
  onSettled?: () => void;
}

export interface TransactionOptions {
  loadingMessage?: string;
  successMessage?: string | ((result: any) => React.ReactNode);
  errorMessage?: string | ((error: Error) => string);
  showExplorerLink?: boolean;
  toastDuration?: number;
}

const defaultOptions: TransactionOptions = {
  loadingMessage: "Preparing transaction...",
  successMessage: "Transaction successful!",
  showExplorerLink: true,
  toastDuration: 5000,
};

export function useSuiTransaction() {
  const [isLoading, setIsLoading] = useState(false);
  const isMountedRef = useRef(true);
  const client = useSuiClient();

  useEffect(() => {
    return () => {
      isMountedRef.current = false;
    };
  }, []);

  const { mutate: signAndExecute } = useSignAndExecuteTransaction({
    execute: async ({ bytes, signature }) =>
      await client.executeTransactionBlock({
        transactionBlock: bytes,
        signature,
        options: {
          showRawEffects: true,
          showEffects: true,
          showObjectChanges: true,
        },
      }),
  });

  const executeTransaction = useCallback(
    async (
      transaction: Transaction,
      callbacks?: TransactionCallbacks,
      options?: TransactionOptions,
    ) => {
      const opts = { ...defaultOptions, ...options };
      const loadingToast = toast.loading(opts.loadingMessage!);

      setIsLoading(true);

      // Set up timeout for wallet response
      const timeoutId = setTimeout(() => {
        if (isMountedRef.current) {
          toast.dismiss(loadingToast);
          toast.error(
            "Transaction timeout - wallet did not respond. Please try again.",
            {
              duration: 5000,
            },
          );
          setIsLoading(false);
        }
      }, 30000); // 30 second timeout

      signAndExecute(
        { transaction },
        {
          onSettled: () => {
            clearTimeout(timeoutId);
            toast.dismiss(loadingToast);
            if (isMountedRef.current) {
              setIsLoading(false);
            }
            callbacks?.onSettled?.();
          },
          onSuccess: (result) => {
            clearTimeout(timeoutId);
            if (result.effects?.status.status === "success") {
              const successContent =
                typeof opts.successMessage === "function"
                  ? opts.successMessage(result)
                  : opts.successMessage;

              if (opts.showExplorerLink) {
                toast.success(
                  <div>
                    {successContent}
                    <a
                      href={`https://suiscan.xyz/${CONSTANTS.network}/tx/${result.digest}`}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="underline ml-2"
                    >
                      View transaction
                    </a>
                  </div>,
                  { duration: opts.toastDuration },
                );
              } else {
                toast.success(successContent as string, {
                  duration: opts.toastDuration,
                });
              }

              callbacks?.onSuccess?.(result);
            } else {
              // Transaction was submitted but failed during execution
              const errorMessage =
                result.effects?.status.error ||
                "Transaction failed during execution";

              let displayError = errorMessage;

              // Parse Move abort errors
              if (
                errorMessage.includes("Move abort") ||
                errorMessage.includes("MOVE_ABORT")
              ) {
                const abortCodeMatch = errorMessage.match(/abort code (\d+)/);
                const locationMatch = errorMessage.match(/in ([^(]+)/);

                if (abortCodeMatch) {
                  displayError = `Transaction aborted with code ${abortCodeMatch[1]}`;
                  if (locationMatch) {
                    displayError += ` in ${locationMatch[1].trim()}`;
                  }
                }
              }

              if (opts.showExplorerLink) {
                toast.error(
                  <div>
                    {displayError}
                    <a
                      href={`https://suiscan.xyz/${CONSTANTS.network}/tx/${result.digest}`}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="underline ml-2"
                    >
                      View details
                    </a>
                  </div>,
                  { duration: opts.toastDuration },
                );
              } else {
                toast.error(displayError, { duration: opts.toastDuration });
              }

              const error = new Error(displayError);
              callbacks?.onError?.(error);
            }
          },
          onError: (error) => {
            clearTimeout(timeoutId);
            let errorMsg = "Transaction failed";

            // Handle common error scenarios
            if (error.message?.includes("Rejected from user")) {
              errorMsg = "Transaction cancelled";
            } else if (error.message?.includes("Insufficient gas")) {
              errorMsg = "Insufficient SUI for gas fees";
            } else if (error.message?.includes("InsufficientBalance")) {
              errorMsg = "Insufficient balance";
            } else if (error.message) {
              errorMsg = error.message;
            }

            const displayError =
              typeof opts.errorMessage === "function"
                ? opts.errorMessage(error)
                : opts.errorMessage || errorMsg;

            toast.error(displayError);
            callbacks?.onError?.(error);
          },
        },
      );
    },
    [signAndExecute],
  );

  return {
    executeTransaction,
    isLoading,
  };
}
