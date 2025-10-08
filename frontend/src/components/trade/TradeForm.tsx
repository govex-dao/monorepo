import { useState, useEffect, useMemo } from "react";
import { Transaction } from "@mysten/sui/transactions";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { SuiClient } from "@mysten/sui/client";
import { getFullnodeUrl } from "@mysten/sui/client";
import { ConnectButton } from "@mysten/dapp-kit";
import { CONSTANTS } from "@/constants";
import { calculateSwapBreakdown } from "@/utils/trade/swapBreakdown";
import { SelectDropDown } from "@/components/SelectDropDown";
import TradeInsight from "./swap/TradeInsight";
import TradeDetails from "./swap/TradeDetails";
import toast from "react-hot-toast";
import TradeDirectionToggle, {
  TradeDirectionSwapButton,
} from "./swap/TradeDirectionToggle";
import TokenInputField from "./swap/TokenInputField";
import { useTokenBalance } from "@/hooks/useTokenBalance";
import { SwapBreakdown } from "@/utils/trade/types";
import { useSuiTransaction } from "@/hooks/useSuiTransaction";

const DEFAULT_SLIPPAGE_BPS = 200;

interface SwapEvent {
  price: string;
  timestamp: string;
  is_buy: boolean;
  amount_in: string;
  outcome: number;
  asset_reserve: string; // Added
  stable_reserve: string; // Added
}

interface TradeFormProps {
  proposalId: string;
  escrowId: string;
  outcomeCount: string;
  assetType: string;
  stableType: string;
  packageId: string;
  network?: "testnet" | "mainnet" | "devnet" | "localnet";
  outcome_messages: string[];
  asset_symbol: string;
  stable_symbol: string;
  initial_outcome_amounts?: string[];
  asset_value: string;
  stable_value: string;
  asset_decimals: number;
  stable_decimals: number;
  swapEvents?: SwapEvent[];
  tokens: TokenInfo[];
  refreshTokens: () => void;
}

export interface TokenInfo {
  id: string;
  balance: string;
  outcome: number;
  asset_type: number;
}

const TradeForm: React.FC<TradeFormProps> = ({
  proposalId,
  escrowId,
  outcomeCount,
  assetType,
  stableType,
  packageId,
  network = CONSTANTS.network,
  outcome_messages,
  asset_symbol,
  stable_symbol,
  initial_outcome_amounts,
  asset_value,
  stable_value,
  asset_decimals,
  stable_decimals,
  swapEvents,
  tokens,
  refreshTokens,
}) => {
  const [assetScale, stableScale] = useMemo(
    () => [10 ** asset_decimals, 10 ** stable_decimals],
    [asset_decimals, stable_decimals],
  );
  const account = useCurrentAccount();
  const [amount, setAmount] = useState("");
  const [selectedOutcome, setSelectedOutcome] = useState("0");
  const [isBuy, setIsBuy] = useState(true);
  const [expectedAmountOut, setExpectedAmountOut] = useState("");
  const { executeTransaction, isLoading } = useSuiTransaction();
  const [swapDetails, setSwapDetails] = useState<SwapBreakdown | null>(null);
  const { balance: assetBalance, refreshBalance: refreshAssetBalance } =
    useTokenBalance({
      type: assetType,
      scale: assetScale,
      network,
    });
  const { balance: stableBalance, refreshBalance: refreshStableBalance } =
    useTokenBalance({
      type: stableType,
      scale: stableScale,
      network,
    });

  // Calculate conditional token balance for the "from" side
  const conditionalFromBalance = useMemo(() => {
    const relevantTokens = tokens.filter(
      (t) =>
        t.outcome === parseInt(selectedOutcome) &&
        t.asset_type === (isBuy ? 1 : 0) // 1 for stable, 0 for asset
    );
    const total = relevantTokens.reduce(
      (sum, token) => sum + BigInt(token.balance),
      0n
    );
    const scale = isBuy ? stableScale : assetScale;
    return (Number(total) / Number(scale)).toString();
  }, [tokens, selectedOutcome, isBuy, assetScale, stableScale]);

  const tokenData = {
    stable: {
      name: "stable",
      symbol: stable_symbol,
      scale: stableScale,
      balance: stableBalance,
      conditionalBalance: isBuy ? conditionalFromBalance : "0",
      decimals: stable_decimals,
      type: stableType,
    },
    asset: {
      name: "asset",
      symbol: asset_symbol,
      scale: assetScale,
      balance: assetBalance,
      conditionalBalance: !isBuy ? conditionalFromBalance : "0",
      decimals: asset_decimals,
      type: assetType,
    },
  };

  // Determine from/to tokens based on trade direction
  const fromToken = isBuy ? tokenData.stable : tokenData.asset;
  const toToken = isBuy ? tokenData.asset : tokenData.stable;

  // Calculate combined balance (spot + conditional) with NaN guards
  const combinedFromBalance = (
    (parseFloat(fromToken.balance) || 0) +
    (parseFloat(fromToken.conditionalBalance) || 0)
  ).toString();

  const updateFromAmount = (newAmount: string) => {
    setAmount(newAmount);
    const x = parseFloat(newAmount);
    if (isNaN(x) || x <= 0) {
      setSwapDetails(null);
      setExpectedAmountOut("");
      // Don't reset averagePrice here, let the useEffect handle initial price
      return;
    }

    const { asset, stable } = getStartingLiquidity();
    // Ensure reserves are not zero before calculating
    if (asset === 0n || stable === 0n) {
      toast.error("Pool has zero liquidity for this outcome.");
      setSwapDetails(null);
      setExpectedAmountOut("");
      return;
    }

    // Use floating point numbers for calculation function
    const A = Number(asset) / Number(assetScale);
    const S = Number(stable) / Number(stableScale);

    try {
      // **** PASS isBuy AS isStableToAsset ****
      const breakdown = calculateSwapBreakdown({
        reserveIn: isBuy ? S : A, // If buying (Stable->Asset), reserveIn is Stable
        reserveOut: isBuy ? A : S, // If buying (Stable->Asset), reserveOut is Asset
        amountIn: x,
        slippageBps: DEFAULT_SLIPPAGE_BPS,
        isBuy,
      });

      setSwapDetails(breakdown);
      // Format based on the *output* token's decimals
      setExpectedAmountOut(breakdown.minAmountOut.toFixed(toToken.decimals));
    } catch (error) {
      console.error("Swap calculation error:", error);
      toast.error(
        error instanceof Error ? error.message : "Failed to calculate swap",
      );
      setSwapDetails(null);
      setExpectedAmountOut("");
      // Don't reset averagePrice here on error
    }
  };
  const filteredTokens = useMemo(() => {
    return tokens.filter(
      (t) =>
        t.outcome === parseInt(selectedOutcome) &&
        t.asset_type === (isBuy ? 1 : 0),
    );
  }, [tokens, selectedOutcome, isBuy]);

  // Recalculate calculations when trade direction or outcome changes
  useEffect(() => {
    if (amount) {
      updateFromAmount(amount);
    }
  }, [isBuy, selectedOutcome]);

  // Helper: get the starting liquidity for the selected outcome.
  const getStartingLiquidity = (): { asset: bigint; stable: bigint } => {
    // Convert selectedOutcome to a number for comparison.
    const outcomeIndex = parseInt(selectedOutcome, 10);

    // Filter swap events for those that match the selected outcome.
    if (swapEvents && swapEvents.length > 0) {
      const filteredEvents = swapEvents.filter(
        (event) => event.outcome === outcomeIndex,
      );

      if (filteredEvents.length > 0) {
        // Sort the filtered events by timestamp in ascending order.
        const sortedEvents = filteredEvents.sort(
          (a, b) => Number(a.timestamp) - Number(b.timestamp),
        );
        const lastEvent = sortedEvents[sortedEvents.length - 1];
        return {
          asset: BigInt(lastEvent.asset_reserve),
          stable: BigInt(lastEvent.stable_reserve),
        };
      }
    }

    // Use the initial outcome amounts if available.
    if (
      initial_outcome_amounts &&
      initial_outcome_amounts.length >= (outcomeIndex + 1) * 2
    ) {
      return {
        asset: BigInt(initial_outcome_amounts[outcomeIndex * 2]),
        stable: BigInt(initial_outcome_amounts[outcomeIndex * 2 + 1]),
      };
    }

    // Fallback to default asset and stable values.
    return {
      asset: BigInt(asset_value),
      stable: BigInt(stable_value),
    };
  };

  const handleTradeWithExisting = async (
    txb: Transaction,
    requiredAmount: bigint,
  ) => {
    if (!filteredTokens || filteredTokens.length === 0) {
      throw new Error("No existing tokens available");
    }

    // Filter and calculate totals
    const validTokens = filteredTokens;

    if (validTokens.length === 0) {
      throw new Error("No tokens found for selected outcome and type");
    }

    const totalBalance = validTokens.reduce(
      (sum, token) => sum + BigInt(token.balance),
      0n,
    );

    // First handle any needed merges or splits
    let tokenToSwap = "";
    if (validTokens.length === 0) {
      throw new Error("No tokens found for selected outcome");
    }

    if (validTokens.length > 1) {
      // Merge valid tokens using merge_many_entry
      const [baseToken, ...tokensToMerge] = validTokens;
      txb.moveCall({
        target: `${packageId}::conditional_token::merge_many_entry`,
        arguments: [
          txb.object(baseToken.id),
          txb.makeMoveVec({
            elements: tokensToMerge.map((t) => txb.object(t.id)),
          }),
          txb.object("0x6"),
        ],
      });
      tokenToSwap = baseToken.id;
    } else {
      tokenToSwap = validTokens[0].id;
    }

    // If we need to split because we have more than required
    if (totalBalance > requiredAmount) {
      const amountToSplit = totalBalance - requiredAmount;
      txb.moveCall({
        target: `${packageId}::conditional_token::split_entry`,
        arguments: [
          txb.object(tokenToSwap),
          txb.pure.u64(amountToSplit.toString()),
          txb.object("0x6"),
        ],
      });
    }

    return { tokenToSwap, totalBalance };
  };

  const handleTradeWithNewDeposit = async (
    txb: Transaction,
    amount: bigint,
  ) => {
    const client = new SuiClient({ url: getFullnodeUrl(network) });

    // Get coins based on selected type
    const coins = await client.getCoins({
      owner: account!.address,
      coinType: `0x${fromToken.type}`,
    });

    // Find and merge coins if needed
    // Find and merge coins if needed
    const amountBig = amount; // Assuming 'amount' is already a bigint
    const sortedCoins = [...coins.data].sort((a, b) =>
      Number(BigInt(b.balance) - BigInt(a.balance)),
    );

    if (sortedCoins.length === 0) {
      throw new Error(`No ${fromToken.symbol} coins available in wallet`);
    }

    let coinToUseForSplit; // This will be the TransactionArgument for splitCoins

    if (BigInt(sortedCoins[0].balance) >= amountBig) {
      // If a single coin is sufficient, create a TransactionArgument for it.
      coinToUseForSplit = txb.object(sortedCoins[0].coinObjectId);
    } else {
      // We need to merge coins.
      let totalBalance = 0n;
      const coinsToMergeObjectIds: string[] = []; // Store object IDs for merging

      for (const coin of sortedCoins) {
        totalBalance += BigInt(coin.balance);
        coinsToMergeObjectIds.push(coin.coinObjectId);
        if (totalBalance >= amountBig) break;
      }

      if (totalBalance < amountBig) {
        throw new Error(
          `Insufficient ${fromToken.symbol} balance. Need ${amountBig.toString()}, have ${totalBalance.toString()}`,
        );
      }

      // The first coin in coinsToMergeObjectIds is the destination for the merge.
      // Create a TransactionArgument for this destination coin.
      const destinationCoinArg = txb.object(coinsToMergeObjectIds[0]);
      const sourceCoinArgs = coinsToMergeObjectIds
        .slice(1)
        .map((id) => txb.object(id));

      // Only call mergeCoins if there are actual source coins to merge into the destination.
      if (sourceCoinArgs.length > 0) {
        txb.mergeCoins(destinationCoinArg, sourceCoinArgs);
        // This command schedules the merge. In the transaction plan, `destinationCoinArg`
        // will represent the coin after merging.
      }

      // The coin to use for splitting is this `destinationCoinArg`,
      // which represents the coin that will have funds merged into it.
      coinToUseForSplit = destinationCoinArg;
    }

    // Now, `coinToUseForSplit` is always a TransactionArgument.
    // It correctly refers to either the single coin object or the
    // destination coin object of a merge operation. This is what txb.splitCoins needs.
    const [splitCoin] = txb.splitCoins(coinToUseForSplit, [
      txb.pure.u64(amountBig.toString()),
    ]);

    return splitCoin;
  };

  const handleTrade = async () => {
    if (!account?.address || !amount || !expectedAmountOut) return;

    // Validate inputs are positive numbers
    if (parseFloat(amount) <= 0 || parseFloat(expectedAmountOut) <= 0) {
      toast.error("Amount and expected amount out must be positive numbers");
      return;
    }
    try {
      // Convert from human-readable to blockchain amounts
      const amountScaled = BigInt(
        Math.floor(parseFloat(amount) * Number(fromToken.scale)),
      );
      const expectedAmountOutScaled = BigInt(
        Math.floor(parseFloat(expectedAmountOut) * Number(toToken.scale)),
      );

      const txb = new Transaction();
      txb.setGasBudget(100000000);

      const existingConditionalType = isBuy ? 1 : 0;
      const hasExistingTokens = filteredTokens.some(
        (t) =>
          t.outcome === parseInt(selectedOutcome) &&
          t.asset_type === existingConditionalType,
      );

      if (hasExistingTokens) {
        const { tokenToSwap, totalBalance } = await handleTradeWithExisting(
          txb,
          amountScaled,
        );

        // Handle differently based on whether we have enough existing tokens
        if (totalBalance >= amountScaled) {
          // If we have enough tokens, just do a direct swap
          const swapTarget =
            existingConditionalType === 0
              ? `${packageId}::swap::swap_asset_to_stable_entry`
              : `${packageId}::swap::swap_stable_to_asset_entry`;
          txb.moveCall({
            target: swapTarget,
            typeArguments: [assetType, stableType],
            arguments: [
              txb.object(proposalId),
              txb.object(escrowId),
              txb.pure.u64(selectedOutcome),
              txb.object(tokenToSwap),
              txb.pure.u64(expectedAmountOutScaled.toString()),
              txb.object("0x6"),
            ],
          });
        } else {
          // If we need more tokens, use create_and_swap with the difference
          const splitCoin = await handleTradeWithNewDeposit(
            txb,
            amountScaled - totalBalance,
          );

          const swapTarget =
            existingConditionalType === 0
              ? `${packageId}::swap::create_and_swap_asset_to_stable_with_existing_entry`
              : `${packageId}::swap::create_and_swap_stable_to_asset_with_existing_entry`;

          txb.moveCall({
            target: swapTarget,
            typeArguments: [assetType, stableType],
            arguments: [
              txb.object(proposalId),
              txb.object(escrowId),
              txb.pure.u64(selectedOutcome),
              txb.object(tokenToSwap),
              txb.pure.u64(expectedAmountOutScaled.toString()),
              splitCoin,
              txb.object("0x6"),
            ],
          });
        }
      } else {
        // Handle case with no existing tokens - direct deposit and swap
        const splitCoin = await handleTradeWithNewDeposit(txb, amountScaled);

        // Then create and swap tokens in one step
        const swapTarget = isBuy
          ? `${packageId}::swap::create_and_swap_stable_to_asset_entry`
          : `${packageId}::swap::create_and_swap_asset_to_stable_entry`;

        txb.moveCall({
          target: swapTarget,
          typeArguments: [assetType, stableType],
          arguments: [
            txb.object(proposalId),
            txb.object(escrowId),
            txb.pure.u64(selectedOutcome),
            txb.pure.u64(expectedAmountOutScaled.toString()),
            splitCoin,
            txb.object("0x6"),
          ],
        });
      }

      await executeTransaction(
        txb,
        {
          onSettled: () => {
            // Add delay to allow blockchain to index changes
            setTimeout(() => {
              refreshAssetBalance();
              refreshStableBalance();
              refreshTokens();
            }, 1500);
          },
          onSuccess: () => {
            setAmount("");
            setExpectedAmountOut("");
          },
        },
        {
          loadingMessage: "Preparing swap transaction...",
          successMessage: "Swap successful!",
          errorMessage: (error: Error) => {
            if (error.message?.includes("InsufficientBalance")) {
              return `Insufficient ${fromToken.symbol} balance`;
            }
            return error.message || "Transaction failed"; // Return a default message instead of undefined
          },
        },
      );
    } catch (error) {
      const errorMsg =
        error instanceof Error ? error.message : "An unknown error occurred";
      toast.error(errorMsg);
    }
  };

  return (
    <div className="rounded-lg bg-gray-900 shadow-xl border border-gray-800">
      <div className="flex flex-col gap-2 p-3">
        {/* Outcome Selection using Select component */}
        <SelectDropDown
          value={selectedOutcome}
          onChange={setSelectedOutcome}
          options={[...Array(parseInt(outcomeCount))].map((_, i) => ({
            value: i.toString(),
            label: outcome_messages[i] || `Outcome ${i}`,
          }))}
          label="Select Outcome"
        />

        {/* Buy/Sell Toggle */}
        <TradeDirectionToggle isBuy={isBuy} setIsBuy={setIsBuy} />

        {/* Trade explanation */}
        <TradeInsight
          isBuy={isBuy}
          setIsBuy={setIsBuy}
          selectedOutcome={selectedOutcome}
          outcomeMessages={outcome_messages}
          amount={amount}
          updateFromAmount={updateFromAmount}
          averagePrice={swapDetails?.averagePrice}
          assetScale={assetScale}
          assetSymbol={asset_symbol}
          stableScale={stableScale}
          stableSymbol={stable_symbol}
        />

        {/* From token input */}
        <TokenInputField
          label="From"
          value={amount}
          onChange={updateFromAmount}
          placeholder="0.0"
          symbol={fromToken.symbol}
          balance={combinedFromBalance}
          spotBalance={fromToken.balance}
          conditionalBalance={fromToken.conditionalBalance}
          step={1 / Number(fromToken.scale)}
        />

        {/* Two-way arrow icon */}
        <TradeDirectionSwapButton isBuy={isBuy} setIsBuy={setIsBuy} />

        {/* To token input */}
        <TokenInputField
          label="To"
          value={expectedAmountOut}
          placeholder="0.0"
          symbol={toToken.symbol}
          balance={toToken.balance}
          readOnly={true}
          step={1 / Number(toToken.scale)}
        />

        {/* Details of swap amounts */}
        <TradeDetails
          amount={amount}
          swapDetails={swapDetails}
          assetSymbol={asset_symbol}
          stableSymbol={stable_symbol}
          isBuy={isBuy}
          tolerance={DEFAULT_SLIPPAGE_BPS}
        />

        {/* Action Button */}
        <div className="mt-1">
          {account ? (
            <button
              onClick={handleTrade}
              disabled={isLoading || !amount || !expectedAmountOut}
              className={`w-full py-2.5 px-4 rounded-lg font-medium text-white transition-all duration-200 flex items-center justify-center ${
                isLoading || !amount || !expectedAmountOut
                  ? "bg-gray-700/80 cursor-not-allowed opacity-70"
                  : "bg-blue-600/90 hover:bg-blue-500/90 shadow-md hover:shadow-lg"
              }`}
            >
              {isLoading ? (
                <>
                  <svg
                    className="animate-spin -ml-1 mr-2 h-4 w-4 text-white"
                    xmlns="http://www.w3.org/2000/svg"
                    fill="none"
                    viewBox="0 0 24 24"
                  >
                    <circle
                      className="opacity-25"
                      cx="12"
                      cy="12"
                      r="10"
                      stroke="currentColor"
                      strokeWidth="4"
                    ></circle>
                    <path
                      className="opacity-75"
                      fill="currentColor"
                      d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                    ></path>
                  </svg>
                  Processing...
                </>
              ) : (
                "Swap"
              )}
            </button>
          ) : (
            <ConnectButton className="w-full py-2.5 px-4 rounded-lg font-medium text-white bg-blue-600/90 hover:bg-blue-500/90 transition-all duration-200 shadow-md hover:shadow-lg" />
          )}
        </div>
      </div>
    </div>
  );
};

export default TradeForm;
