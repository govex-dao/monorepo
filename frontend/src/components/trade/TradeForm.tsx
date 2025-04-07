import { useState, useEffect, useMemo } from "react";
import { useSignAndExecuteTransaction } from "@mysten/dapp-kit";
import { Transaction } from "@mysten/sui/transactions";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { SuiClient } from "@mysten/sui/client";
import { getFullnodeUrl } from "@mysten/sui/client";
import { ConnectButton } from "@mysten/dapp-kit";
import { CONSTANTS } from "@/constants";

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
  console.log(assetScale, stableScale);

  const account = useCurrentAccount();
  const [amount, setAmount] = useState("");
  const [selectedOutcome, setSelectedOutcome] = useState("0");
  const [tradeDirection, setTradeDirection] = useState<
    "assetToStable" | "stableToAsset"
  >("assetToStable");
  const [expectedAmountOut, setExpectedAmountOut] = useState("");
  const [averagePrice, setAveragePrice] = useState<string>("");
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<ErrorMessage>(null);
  const TOLERANCE = 0.01;
  const { mutate: signAndExecute } = useSignAndExecuteTransaction();

  const updateFromAmount = (newAmount: string) => {
    setAmount(newAmount);
    const x = parseFloat(newAmount);
    if (isNaN(x) || x <= 0) return;
    const { asset, stable } = getStartingLiquidity();
    const A = Number(asset) / Number(assetScale);
    const S = Number(stable) / Number(stableScale);
    let expectedOut;
    if (tradeDirection === "assetToStable") {
      // For asset-to-stable, the effective price (in stable per asset) is S/(A+x)
      // Expected stable out = S*x/(A+x)
      expectedOut = (S * x) / (A + x);
    } else {
      // For stable-to-asset, show asset price as stable per asset: (S+x)/A
      // Expected asset out = A*x/(S+x)
      expectedOut = (A * x) / (S + x);
    }
    // Compute the minimum output as the expected output reduced by the tolerance.
    // Round down to the appropriate number of decimal places
    const decimalPlaces =
      tradeDirection === "assetToStable" ? stable_decimals : asset_decimals;
    const scaleFactor = 10 ** decimalPlaces;
    const computedMin =
      Math.floor(expectedOut * (1 - TOLERANCE) * scaleFactor) / scaleFactor;

    // Calculate the effective price based on the user's input amount
    if (x > 0) {
      let effectivePrice;
      if (tradeDirection === "assetToStable") {
        // For asset-to-stable: stable per asset
        effectivePrice = expectedOut / x;
      } else {
        // For stable-to-asset: stable per asset
        effectivePrice = x / expectedOut;
      }
      setAveragePrice(effectivePrice.toPrecision(6));
    }
    setExpectedAmountOut(computedMin.toFixed(decimalPlaces));
  };

  const filteredTokens = useMemo(() => {
    return tokens.filter(
      (t) =>
        t.outcome === parseInt(selectedOutcome) &&
        t.asset_type === (tradeDirection === "assetToStable" ? 0 : 1),
    );
  }, [tokens, selectedOutcome, tradeDirection]);

  // Reset error when inputs change
  useEffect(() => {
    setError(null);
    if (!amount) setAveragePrice("");
  }, [amount, selectedOutcome, tradeDirection]);

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
  }, [tradeDirection, selectedOutcome]);

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

    // For asset to stable, we need asset coins. For stable to asset, we need stable coins
    const coinType =
      tradeDirection === "assetToStable" ? `${assetType}` : `${stableType}`;

    // Get coins based on selected type
    const coins = await client.getCoins({
      owner: account!.address,
      coinType: `0x${coinType}`,
    });

    // Find and merge coins if needed
    const amountBig = amount;
    const sortedCoins = [...coins.data].sort((a, b) =>
      Number(BigInt(b.balance) - BigInt(a.balance)),
    );

    if (sortedCoins.length === 0) {
      throw new Error(
        `No ${tradeDirection === "assetToStable" ? "asset" : "stable"} coins available in wallet`,
      );
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
        throw new Error(
          `Insufficient ${tradeDirection === "assetToStable" ? "asset" : "stable"} balance in wallet`,
        );
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
      const amountScaled =
        tradeDirection === "assetToStable"
          ? BigInt(Math.floor(parseFloat(amount) * Number(assetScale)))
          : BigInt(Math.floor(parseFloat(amount) * Number(stableScale)));

      const expectedAmountOutScaled =
        tradeDirection === "assetToStable"
          ? BigInt(
              Math.floor(parseFloat(expectedAmountOut) * Number(stableScale)),
            )
          : BigInt(
              Math.floor(parseFloat(expectedAmountOut) * Number(assetScale)),
            );

      console.log(
        "trade-amounts (scaled)",
        amountScaled.toString(),
        expectedAmountOutScaled.toString(),
      );
      const txb = new Transaction();
      txb.setGasBudget(1000000000);

      const existingConditionalType =
        tradeDirection === "assetToStable" ? 0 : 1;
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
              ? `${packageId}::swap::create_and_swap_asset_to_stable_with_existing`
              : `${packageId}::swap::create_and_swap_stable_to_asset_with_existing`;

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
        const swapTarget =
          tradeDirection === "assetToStable"
            ? `${packageId}::swap::create_and_swap_asset_to_stable_entry`
            : `${packageId}::swap::create_and_swap_stable_to_asset_entry`;

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
    <div className="rounded-lg">
      {error && <div className="text-red-500 mb-4 text-center">{error}</div>}
      <div className="flex flex-col gap-2 justify-center">
        {/* Toggle for Buy and Sell */}
        <select
          value={selectedOutcome}
          onChange={(e) => setSelectedOutcome(e.target.value)}
          className="p-2 rounded bg-gray-800 text-white w-full"
        >
          {[...Array(parseInt(outcomeCount))].map((_, i) => (
            <option
              key={i}
              value={i}
              // Inline styles for one-line truncation with ellipsis
              style={{
                whiteSpace: "nowrap",
                overflow: "hidden",
                textOverflow: "ellipsis",
              }}
            >
              {outcome_messages[i] || `Outcome ${i}`}
            </option>
          ))}
        </select>

        <div className="flex">
          <button
            type="button"
            onClick={() => setTradeDirection("stableToAsset")}
            className={`flex-1 p-2 rounded-l ${
              tradeDirection === "stableToAsset"
                ? "bg-blue-500 text-white"
                : "bg-gray-800 text-white"
            }`}
          >
            Buy
          </button>
          <button
            type="button"
            onClick={() => setTradeDirection("assetToStable")}
            className={`flex-1 p-2 rounded-r ${
              tradeDirection === "assetToStable"
                ? "bg-blue-500 text-white"
                : "bg-gray-800 text-white"
            }`}
          >
            Sell
          </button>
        </div>

        <div className="flex items-center">
          <span className="mr-2 w-[30%] break-words">
            {tradeDirection === "assetToStable"
              ? `${asset_symbol}:`
              : `${stable_symbol}:`}
          </span>
          <input
            type="number"
            value={amount}
            onChange={(e) => updateFromAmount(e.target.value)}
            placeholder="Amount to swap"
            className="p-2 rounded bg-gray-800 text-white flex-1"
            step={
              tradeDirection === "assetToStable"
                ? 1 / Number(assetScale)
                : 1 / Number(stableScale)
            }
          />
        </div>

        <div className="flex items-center">
          <span className="mr-2 w-[30%] break-words">
            {tradeDirection === "assetToStable"
              ? `${stable_symbol} to receive:`
              : `${asset_symbol} to receive:`}
          </span>
          <input
            type="number"
            value={expectedAmountOut}
            readOnly
            placeholder="Amount to receive"
            className="p-2 rounded bg-gray-700 text-white flex-1"
            // To show with proper decimal places
            step={
              tradeDirection === "assetToStable"
                ? 1 / Number(stableScale)
                : 1 / Number(assetScale)
            }
          />
        </div>

        {amount && averagePrice && (
          <div className="text-blue-400 text-xs text-right mt-1 mb-2">
            Average price: {averagePrice} {stable_symbol}/{asset_symbol}
          </div>
        )}

        {account ? (
          <button
            onClick={handleTrade}
            disabled={isLoading || !amount || !expectedAmountOut}
            className="bg-blue-500 text-white p-2 rounded w-full hover:bg-blue-700"
          >
            {isLoading ? "Processing..." : "Swap"}
          </button>
        ) : (
          <ConnectButton className="bg-blue-500 text-white p-2 rounded w-full hover:bg-blue-700" />
        )}
      </div>
    </div>
  );
};

export default TradeForm;
