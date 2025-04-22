import { useState, useEffect, useMemo } from "react";
import { useSignAndExecuteTransaction } from "@mysten/dapp-kit";
import { Transaction } from "@mysten/sui/transactions";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { SuiClient } from "@mysten/sui/client";
import { getFullnodeUrl } from "@mysten/sui/client";
import { ConnectButton } from "@mysten/dapp-kit";
import { CONSTANTS } from "@/constants";
import {
  calculateSwapBreakdown,
  SwapBreakdown,
} from "@/utils/trade/calculateSwapBreakdown";
import { SelectDropDown } from "@/components/SelectDropDown";
import TradeInsight from "./swap/TradeInsight";
import TradeDetails from "./swap/TradeDetails";
import TradeDirectionToggle, {
  TradeDirectionSwapButton,
} from "./swap/TradeDirectionToggle";
import TokenInputField from "./swap/TokenInputField";
import { useTokenBalance } from "@/hooks/useTokenBalance";

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
  tokens: TokenInfo[]; // All tokens passed from parent
  outcome_messages: string[];
  asset_symbol: string;
  stable_symbol: string;
  initial_outcome_amounts?: string[];
  asset_value: string;
  stable_value: string;
  asset_decimals: number;
  stable_decimals: number;
  swapEvents?: SwapEvent[];
}

export interface TokenInfo {
  id: string;
  balance: string;
  outcome: number;
  asset_type: number;
}

type ErrorMessage = string | null;
const TradeForm: React.FC<TradeFormProps> = ({
  proposalId,
  escrowId,
  outcomeCount,
  assetType,
  stableType,
  packageId,
  network = CONSTANTS.network,
  tokens,
  outcome_messages,
  asset_symbol,
  stable_symbol,
  initial_outcome_amounts,
  asset_value,
  stable_value,
  asset_decimals,
  stable_decimals,
  swapEvents,
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
  const [averagePrice, setAveragePrice] = useState<string>("");
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<ErrorMessage>(null);
  const TOLERANCE = 0.01;
  const { mutate: signAndExecute } = useSignAndExecuteTransaction();
  const [swapDetails, setSwapDetails] = useState<SwapBreakdown | null>(null);
  const { balance: assetBalance } = useTokenBalance({
    type: assetType,
    scale: assetScale,
    network,
  });
  const { balance: stableBalance } = useTokenBalance({
    type: stableType,
    scale: stableScale,
    network,
  });

  const tokenData = {
    stable: {
      name: "stable",
      symbol: stable_symbol,
      scale: stableScale,
      balance: stableBalance,
      decimals: stable_decimals,
      type: stableType,
    },
    asset: {
      name: "asset",
      symbol: asset_symbol,
      scale: assetScale,
      balance: assetBalance,
      decimals: asset_decimals,
      type: assetType,
    },
  };

  // Determine from/to tokens based on trade direction
  const fromToken = isBuy ? tokenData.stable : tokenData.asset;
  const toToken = isBuy ? tokenData.asset : tokenData.stable;

  const updateFromAmount = (newAmount: string) => {
    setAmount(newAmount);
    setError(null); // Clear error on new input
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
      setError("Pool has zero liquidity for this outcome.");
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
        slippageTolerance: TOLERANCE,
        isStableToAsset: isBuy, // Pass the direction flag
      });

      setSwapDetails(breakdown);
      // Format based on the *output* token's decimals
      setExpectedAmountOut(breakdown.exactAmountOut.toFixed(toToken.decimals));
      // Average price is In/Out, format appropriately
      setAveragePrice(
        breakdown.averagePrice > 0
          ? breakdown.averagePrice.toPrecision(6)
          : "N/A",
      );
    } catch (error) {
      console.error("Swap calculation error:", error);
      setError(
        error instanceof Error ? error.message : "Failed to calculate swap",
      );
      setSwapDetails(null);
      setExpectedAmountOut("");
      // Don't reset averagePrice here on error
    }
  };

  // Update the useEffect that sets the initial price
  useEffect(() => {
    // Calculate initial price whenever relevant state changes
    const { asset, stable } = getStartingLiquidity();
    if (asset > 0n && stable > 0n) {
      // Check both reserves are non-zero
      const A = Number(asset) / Number(assetScale);
      const S = Number(stable) / Number(stableScale);

      // Calculate the initial price (Stable per Asset) S/A
      const initialPrice = S / A;
      // Only set averagePrice if amount is empty, otherwise updateFromAmount handles it
      if (!amount) {
        setAveragePrice(initialPrice.toPrecision(6));
      }
    } else {
      if (!amount) {
        // Only clear if no amount is entered
        setAveragePrice("N/A"); // Indicate no price if reserves are zero
      }
    }
  }, [
    selectedOutcome,
    swapEvents, // Re-run if events change
    // initial_outcome_amounts, // These should be reflected in swapEvents or initial state
    // asset_value, stable_value, // These are fallbacks, covered by getStartingLiquidity
    assetScale,
    stableScale, // Include scales
    amount, // Also re-run if amount changes (to reset initial price if amount is cleared)
  ]);

  const filteredTokens = useMemo(() => {
    return tokens.filter(
      (t) =>
        t.outcome === parseInt(selectedOutcome) &&
        t.asset_type === (isBuy ? 1 : 0),
    );
  }, [tokens, selectedOutcome, isBuy]);

  // Reset error when inputs change
  useEffect(() => {
    setError(null);
    if (!amount) setAveragePrice("");
  }, [amount, selectedOutcome, isBuy]);

  useEffect(() => {
    // Calculate average price whenever liquidity data changes
    const { asset, stable } = getStartingLiquidity();
    if (asset > 0n) {
      // Calculate ratio of scaled stable to scaled asset
      const A = Number(asset) / Number(assetScale);
      const S = Number(stable) / Number(stableScale);

      // Calculate the ratio and format to 6 significant figures
      const ratio = S / A;
      // Format to 6 significant figures
      setAveragePrice(ratio.toPrecision(6));
    } else {
      setAveragePrice("");
    }
  }, [
    selectedOutcome,
    swapEvents,
    initial_outcome_amounts,
    asset_value,
    stable_value,
  ]);

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
    const amountBig = amount;
    const sortedCoins = [...coins.data].sort((a, b) =>
      Number(BigInt(b.balance) - BigInt(a.balance)),
    );

    if (sortedCoins.length === 0) {
      throw new Error(`No ${fromToken.symbol} coins available in wallet`);
    }

    let coinToUse;
    if (BigInt(sortedCoins[0].balance) >= amountBig) {
      coinToUse = sortedCoins[0].coinObjectId;
    } else {
      // Merge coins until we have enough
      let totalBalance = 0n;
      const coinsToMerge = [];

      for (const coin of sortedCoins) {
        totalBalance += BigInt(coin.balance);
        coinsToMerge.push(coin.coinObjectId);
        if (totalBalance >= amountBig) break;
      }

      if (totalBalance < amountBig) {
        throw new Error(`Insufficient ${fromToken.symbol} balance in wallet`);
      }

      coinToUse = txb.mergeCoins(
        txb.object(coinsToMerge[0]),
        coinsToMerge.slice(1).map((id) => txb.object(id)),
      );
    }

    // Split exact amount needed
    const [splitCoin] = txb.splitCoins(txb.object(coinToUse), [
      txb.pure.u64(amountBig.toString()),
    ]);

    return splitCoin;
  };

  const handleTrade = async () => {
    if (!account?.address || !amount || !expectedAmountOut) return;

    console.log("trade-amounts (human readable)", amount, expectedAmountOut);
    // Clear any previous errors
    setError(null);
    // Validate inputs are positive numbers
    if (parseFloat(amount) <= 0 || parseFloat(expectedAmountOut) <= 0) {
      setError("Amount and expected amount out must be positive numbers");
      return;
    }

    try {
      setIsLoading(true);
      // Convert from human-readable to blockchain amounts
      const amountScaled = BigInt(
        Math.floor(parseFloat(amount) * Number(fromToken.scale)),
      );
      const expectedAmountOutScaled = BigInt(
        Math.floor(parseFloat(expectedAmountOut) * Number(toToken.scale)),
      );

      console.log(
        "trade-amounts (scaled)",
        amountScaled.toString(),
        expectedAmountOutScaled.toString(),
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

      await signAndExecute({
        transaction: txb,
      });

      setAmount("");
      setExpectedAmountOut("");
    } catch (error) {
      console.error("Trade error:", error);
      setError(
        error instanceof Error ? error.message : "An unknown error occurred",
      );
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <div className="rounded-lg bg-gray-900 shadow-xl border border-gray-800">
      {error && (
        <div className="text-red-500 mb-4 p-3 bg-red-900/20 border border-red-800/50 rounded-md text-center font-medium">
          {error}
        </div>
      )}
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
          balance={fromToken.balance}
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
          tolerance={TOLERANCE}
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
