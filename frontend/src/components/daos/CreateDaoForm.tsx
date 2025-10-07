import { useState, useEffect } from "react";
import { Transaction } from "@mysten/sui/transactions";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { useSuiTransaction } from "@/hooks/useSuiTransaction";
import { CONSTANTS } from "../../constants";
import { InfoCircledIcon } from "@radix-ui/react-icons";
import toast from "react-hot-toast";
import CoinTypeInput from "./CoinTypeInput";
import TimeInput from "../TimeInput";

const DEFAULT_ASSET_TYPE = CONSTANTS.assetType;
const DEFAULT_STABLE_TYPE = CONSTANTS.stableType;
const BASIS_POINTS_BIGINT = BigInt("1000000000000");

interface FormData {
  assetType: string;
  stableType: string;
  minAssetAmount: string;
  minStableAmount: string;
  daoName: string;
  imageUrl: string;
  reviewPeriodMs: number;
  tradingPeriodMs: number;
  twapStartDelay: number;
  twapStepMax: string;
  twapInitialObservation: string;
  twapThreshold: number;
}

interface CoinMetadata {
  id: string;
  name: string;
  symbol: string;
  iconUrl?: string;
  decimals: number;
}

const CreateDaoForm = () => {
  const [formData, setFormData] = useState<FormData>({
    assetType: DEFAULT_ASSET_TYPE,
    stableType: DEFAULT_STABLE_TYPE,
    minAssetAmount: "1",
    minStableAmount: "1",
    daoName: "",
    imageUrl: "",
    reviewPeriodMs: 0, // 1 hour in milliseconds
    tradingPeriodMs: 0, // 2 hours in milliseconds
    twapStartDelay: 0,
    twapInitialObservation: "1000000000000",
    twapStepMax: "5000000000",
    twapThreshold: 1,
  });

  const currentAccount = useCurrentAccount();
  const { executeTransaction, isLoading } = useSuiTransaction();
  const [_error, setError] = useState<string | null>(null);
  const [_success, setSuccess] = useState(false);
  const [showAdvanced, setShowAdvanced] = useState(false);
  const [assetMetadata, setAssetMetadata] = useState<CoinMetadata | null>(null);
  const [stableMetadata, setStableMetadata] = useState<CoinMetadata | null>(
    null,
  );
  const [previewImage, setPreviewImage] = useState<string>("");
  const [imageError, setImageError] = useState(false);

  const getChainAmount = (amount: string, decimals: number): bigint => {
    try {
      const cleanAmount = amount.replace(/,/g, "").trim();
      if (cleanAmount === "") {
        return 0n; // Treat empty string as 0 for conversion
      }
      // Validate numeric format (allows for optional decimal point)
      if (!/^\d*(\.\d*)?$/.test(cleanAmount) || cleanAmount === ".") {
        throw new Error(`Invalid numeric string: ${amount}`);
      }

      const parts = cleanAmount.split(".");
      const integerPartStr = parts[0] || "0"; // Handle cases like ".5" -> "0.5"
      const fractionalPartStr = parts[1] || "";

      let result = BigInt(integerPartStr) * 10n ** BigInt(decimals);

      if (fractionalPartStr.length > 0 && decimals > 0) {
        const relevantFractional = fractionalPartStr.slice(0, decimals);
        if (relevantFractional.length > 0) {
          const fractionalBigInt = BigInt(relevantFractional);
          // Scale the fractional part by the remaining decimal places
          // e.g., if decimals=5, relevantFractional="123" (length 3), scale by 10^(5-3)
          result +=
            fractionalBigInt *
            10n ** BigInt(decimals - relevantFractional.length);
        }
      }
      return result;
    } catch (error) {
      const e = error instanceof Error ? error.message : String(error);
      throw new Error(
        `Invalid amount format ("${amount}", dec: ${decimals}): ${e}`,
      );
    }
  };

  useEffect(() => {
    if (
      assetMetadata?.decimals !== undefined &&
      stableMetadata?.decimals !== undefined
    ) {
      try {
        const assetAmountStr = formData.minAssetAmount; // This value comes from the input field
        const stableAmountStr = formData.minStableAmount; // This value comes from the input field

        // Quick validation: ensure amounts are parseable to positive numbers
        // parseFloat is okay here for quick validation before robust BigInt conversion
        const parsedAssetAmount = parseFloat(assetAmountStr.replace(/,/g, ""));
        const parsedStableAmount = parseFloat(
          stableAmountStr.replace(/,/g, ""),
        );

        if (
          isNaN(parsedAssetAmount) ||
          isNaN(parsedStableAmount) ||
          parsedAssetAmount <= 0 ||
          parsedStableAmount <= 0
        ) {
          // If amounts are invalid (e.g., empty, non-numeric, zero/negative), do not attempt calculation.
          return;
        }

        const assetChainAmount = getChainAmount(
          assetAmountStr,
          assetMetadata.decimals,
        );
        const stableChainAmount = getChainAmount(
          stableAmountStr,
          stableMetadata.decimals,
        );

        // Ensure chain amounts are positive, as division by zero or non-positive initial values are problematic.
        if (assetChainAmount <= 0n || stableChainAmount <= 0n) {
          return;
        }

        // Calculate twapInitialObservation (scaled "raw price": stable per asset)
        // This mirrors the AMM's logic: (atomic_stable_amount * BASIS_POINTS) / atomic_asset_amount
        let calculatedInitialObservation =
          (stableChainAmount * BASIS_POINTS_BIGINT) / assetChainAmount;
        if (calculatedInitialObservation < 1n)
          calculatedInitialObservation = 1n; // Min 1

        // Calculate twapStepMax: 2% of twapInitialObservation
        let calculatedStepMax = (calculatedInitialObservation * 2n) / 100n; // (value * 2 / 100) for 2%
        if (calculatedStepMax < 1n) calculatedStepMax = 1n; // Min 1

        setFormData((prev) => ({
          ...prev,
          twapInitialObservation: calculatedInitialObservation.toString(),
          twapStepMax: calculatedStepMax.toString(),
        }));
      } catch (error) {
        console.error("Error auto-calculating TWAP parameters:", error);
      }
    }
  }, [
    assetMetadata,
    stableMetadata,
    formData.minAssetAmount,
    formData.minStableAmount,
  ]);
  // Add this useEffect to handle image preview updates
  useEffect(() => {
    if (formData.imageUrl) {
      setImageError(false);
      const checkImage = async () => {
        try {
          const response = await fetch(formData.imageUrl, { method: "HEAD" });
          const contentLength = response.headers.get("content-length");

          if (contentLength && parseInt(contentLength) > 10 * 1024 * 1024) {
            setImageError(true);
            toast.error(
              "Image size exceeds 10MB limit. Please use a smaller image.",
            );
            return;
          }

          setPreviewImage(formData.imageUrl);
        } catch (error) {
          setImageError(true);
          setPreviewImage("");
        }
      };

      checkImage();
    } else if (assetMetadata?.iconUrl) {
      setPreviewImage(assetMetadata.iconUrl);
    } else {
      setPreviewImage("");
    }
  }, [formData.imageUrl, assetMetadata]);

  const tooltips = {
    assetType:
      "The asset that represents ownership over the DAO. Format: package::module::type",
    stableType:
      "The stable coin to price the asset in. Format: package::module::type",
    minAssetAmount:
      "The minimum amount of the asset the proposer must supply to create a proposal",
    minStableAmount:
      "The minimum amount of the stable coin the proposer must supply to create a proposal",
    daoName: "The name of your DAO",
    imageUrl:
      "If not set this will default to the URL for your asset coin. If your asset coin does not have a URL, set one here.",
    reviewPeriodMs:
      "The period of time in milliseconds between when a proposal is created and trading will begin.",
    tradingPeriodMs: "The trading period in milliseconds",
    assetMetadata:
      "The metadata object ID for the asset coin type selected above",
    stableMetadata:
      "The metadata object ID for the stable coin type selected above",
    twapStartDelay:
      "Delay before TWAP calculations begin (in milliseconds). Must be integer number of minutes. Value will be rounded accordingly.",
    twapStepMax:
      "Maximum price change step size for TWAP price accumulation per a 60s window",
    twapThreshold:
      "% difference by which an outcome must be greater than Reject to pass",
    twapInitialObservation:
      "The starting anchor price for the TWAP calculation",
  };

  const handleInputChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const { name, value } = e.target;
    setFormData((prev) => ({
      ...prev,
      [name]: value,
    }));
  };

  const validateTypeFormat = (value: string) => {
    const regex = /^0x[a-fA-F0-9]+::[a-zA-Z_]+::[A-Z_]+$/;
    return regex.test(value);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!currentAccount?.address) {
      toast.error("Please connect your wallet before creating a DAO.");
      return;
    }

    if (!assetMetadata?.id || !stableMetadata?.id) {
      setError(
        "Valid coin metadata is required for both asset and stable coins",
      );
      return;
    }
    if (!validateTypeFormat(formData.stableType)) {
      setError(
        "Invalid Stable Type format. Expected format: package::module::type",
      );
      return;
    }

    const chainTwapStepMax = BigInt(formData.twapStepMax);
    const chainTwapInitialObservation = BigInt(formData.twapInitialObservation);

    // Validate amounts
    if (!formData.minAssetAmount || !formData.minStableAmount) {
      setError("Amount fields cannot be empty");
      return;
    }

    // Check if amounts are valid numbers
    if (
      isNaN(parseFloat(formData.minAssetAmount)) ||
      isNaN(parseFloat(formData.minStableAmount))
    ) {
      setError("Please enter valid numbers for amounts");
      return;
    }

    let chainAssetAmount: bigint;
    let chainStableAmount: bigint;

    try {
      chainAssetAmount = getChainAmount(
        formData.minAssetAmount,
        assetMetadata.decimals,
      );
      chainStableAmount = getChainAmount(
        formData.minStableAmount,
        stableMetadata.decimals,
      );
    } catch (error) {
      setError("Invalid amount format. Please enter valid numbers.");
      console.error("Chain amount calculation error:", error);
      return;
    }

    setError(null);
    setSuccess(false);

    try {
      const tx = new Transaction();
      const isMainnet = CONSTANTS.network === "mainnet";
      const gasBudget = isMainnet ? 500_000_000 : 500_000_000;
      const splitAmount = isMainnet ? 20_000_000_000 : 10_000;
      tx.setGasBudget(gasBudget);
      const [splitCoin] = tx.splitCoins(tx.gas, [tx.pure.u64(splitAmount)]);
      const chainAdjustedTwapThreshold = formData.twapThreshold * 1000;

      tx.moveCall({
        target: `${CONSTANTS.futarchyPackage}::factory::create_dao`,
        typeArguments: [formData.assetType, formData.stableType],
        arguments: [
          tx.object(CONSTANTS.futarchyFactoryId),
          tx.object(CONSTANTS.futarchyPaymentManagerId),
          splitCoin,
          tx.pure.u64(chainAssetAmount),
          tx.pure.u64(chainStableAmount),
          tx.pure.string(formData.daoName),
          tx.pure.string(formData.imageUrl),
          tx.pure.u64(formData.reviewPeriodMs),
          tx.pure.u64(formData.tradingPeriodMs),
          tx.object(assetMetadata.id),
          tx.object(stableMetadata.id),
          tx.pure.u64(formData.twapStartDelay),
          tx.pure.u64(chainTwapStepMax),
          tx.pure.u128(chainTwapInitialObservation),
          tx.pure.u64(chainAdjustedTwapThreshold),
          tx.pure.string(""),
          tx.object("0x6"),
        ],
      });

      await executeTransaction(
        tx,
        {
          onSuccess: () => {
            setSuccess(true);
            // Reset form on success
            setFormData({
              assetType: DEFAULT_ASSET_TYPE,
              stableType: DEFAULT_STABLE_TYPE,
              minAssetAmount: "1",
              minStableAmount: "1",
              daoName: "",
              imageUrl: "",
              reviewPeriodMs: 0,
              tradingPeriodMs: 0,
              twapStartDelay: 0,
              twapInitialObservation: "1000000000000",
              twapStepMax: "5000000000",
              twapThreshold: 1,
            });
          },
          onError: (error) => {
            setError(error.message);
          },
        },
        {
          loadingMessage: "Creating DAO...",
          successMessage: "DAO created successfully!",
          errorMessage: (error) => {
            if (error.message?.includes("Rejected from user")) {
              return "Transaction cancelled by user";
            } else if (error.message?.includes("Insufficient gas")) {
              return "Insufficient SUI for gas fees";
            }
            return `Failed to create DAO: ${error.message}`;
          },
        },
      );
    } catch (error) {
      // Handle pre-transaction errors (validation, calculation errors)
      const errorMessage =
        error instanceof Error ? error.message : "Transaction failed";
      setError(errorMessage);
      toast.error(errorMessage);
    }
  };

  return (
    <div className="p-6 max-w-2xl mx-auto">
      <form onSubmit={handleSubmit} className="space-y-4">
        <CoinTypeInput
          value={formData.assetType}
          onChange={(value, metadata) => {
            setFormData((prev) => ({ ...prev, assetType: value }));
            if (metadata) setAssetMetadata(metadata);
          }}
          onMetadataChange={setAssetMetadata}
          label="Asset Type"
          tooltipText={tooltips.assetType}
          required
        />
        <CoinTypeInput
          value={formData.stableType}
          onChange={(value, metadata) => {
            setFormData((prev) => ({ ...prev, stableType: value }));
            if (metadata) setStableMetadata(metadata);
          }}
          label="Stable Type"
          tooltipText={tooltips.stableType}
          required
        />
        <div className="space-y-2">
          <div className="flex items-center space-x-2">
            <label className="block text-sm font-medium">
              Min Asset Amount
            </label>
            <div className="relative group">
              <InfoCircledIcon className="w-4 h-4 text-gray-400 hover:text-gray-600 cursor-help" />
              <div className="absolute left-1/2 -translate-x-1/2 bottom-full mb-2 px-3 py-2 bg-gray-900 text-white text-sm rounded-lg opacity-0 group-hover:opacity-100 pointer-events-none transition-opacity duration-200 w-64 z-50">
                {tooltips.minAssetAmount}
              </div>
            </div>
          </div>
          <input
            type="text"
            name="minAssetAmount"
            value={formData.minAssetAmount}
            onChange={handleInputChange}
            className="w-full p-2 border rounded focus:ring-2 focus:ring-blue-500"
            min="0"
            required
          />
        </div>
        <div className="space-y-2">
          <div className="flex items-center space-x-2">
            <label className="block text-sm font-medium">
              Min Stable Amount
            </label>
            <div className="relative group">
              <InfoCircledIcon className="w-4 h-4 text-gray-400 hover:text-gray-600 cursor-help" />
              <div className="absolute left-1/2 -translate-x-1/2 bottom-full mb-2 px-3 py-2 bg-gray-900 text-white text-sm rounded-lg opacity-0 group-hover:opacity-100 pointer-events-none transition-opacity duration-200 w-64 z-50">
                {tooltips.minStableAmount}
              </div>
            </div>
          </div>
          <input
            type="text"
            name="minStableAmount"
            value={formData.minStableAmount}
            onChange={handleInputChange}
            className="w-full p-2 border rounded focus:ring-2 focus:ring-blue-500"
            min="0"
            required
          />
        </div>
        <div className="space-y-2">
          <div className="flex items-center space-x-2">
            <label className="block text-sm font-medium">DAO Name</label>
            <div className="relative group">
              <InfoCircledIcon className="w-4 h-4 text-gray-400 hover:text-gray-600 cursor-help" />
              <div className="absolute left-1/2 -translate-x-1/2 bottom-full mb-2 px-3 py-2 bg-gray-900 text-white text-sm rounded-lg opacity-0 group-hover:opacity-100 pointer-events-none transition-opacity duration-200 w-64 z-50">
                {tooltips.daoName}
              </div>
            </div>
          </div>
          <input
            type="text"
            name="daoName"
            value={formData.daoName}
            onChange={handleInputChange}
            className="w-full p-2 border rounded focus:ring-2 focus:ring-blue-500"
            placeholder="Enter DAO name"
            required
          />
        </div>
        <div className="flex items-center gap-2 mb-4">
          <span className="text-sm font-medium text-gray-200">
            Advanced Settings
          </span>
          <button
            type="button"
            onClick={() => setShowAdvanced(!showAdvanced)}
            className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors ${
              showAdvanced ? "bg-blue-500" : "bg-gray-700"
            }`}
          >
            <span
              className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${
                showAdvanced ? "translate-x-6" : "translate-x-1"
              }`}
            />
          </button>
        </div>
        {/* Advanced configuration section */}
        <div className={`space-y-4 mt-4 ${showAdvanced ? "" : "hidden"}`}>
          <TimeInput
            label="Pre-trading Period"
            tooltip={tooltips.reviewPeriodMs}
            valueMs={formData.reviewPeriodMs}
            onChange={(newValueMs) =>
              setFormData((prev) => ({ ...prev, reviewPeriodMs: newValueMs }))
            }
          />
          <TimeInput
            label="TWAP Start Delay"
            tooltip={tooltips.twapStartDelay}
            valueMs={formData.twapStartDelay}
            onChange={(newValueMs) => {
              let adjustedValue = newValueMs;
              // Ensure value is 0 or a multiple of 60000 (1 minute)
              if (typeof newValueMs === "number" && newValueMs !== 0) {
                adjustedValue = Math.round(newValueMs / 60000) * 60000;
              }
              setFormData((prev) => ({
                ...prev,
                twapStartDelay: adjustedValue,
              }));
            }}
          />
          <TimeInput
            label="Trading Period"
            tooltip={tooltips.tradingPeriodMs}
            valueMs={formData.tradingPeriodMs}
            onChange={(newValueMs) =>
              setFormData((prev) => ({ ...prev, tradingPeriodMs: newValueMs }))
            }
          />

          {/* Other advanced settings remain unchanged */}
          <div className="space-y-2">
            <div className="flex items-center space-x-2">
              <label className="block text-sm font-medium">TWAP Step Max</label>
              <div className="relative group">
                <InfoCircledIcon className="w-4 h-4 text-gray-400 hover:text-gray-600 cursor-help" />
                <div className="absolute left-1/2 -translate-x-1/2 bottom-full mb-2 px-3 py-2 bg-gray-900 text-white text-sm rounded-lg opacity-0 group-hover:opacity-100 pointer-events-none transition-opacity duration-200 w-64 z-50">
                  {tooltips.twapStepMax}
                </div>
              </div>
            </div>
            <div className="relative">
              <input
                type="text"
                name="twapStepMax"
                value={formData.twapStepMax}
                onChange={(e) => {
                  const cleanValue = e.target.value.replace(/[^0-9]/g, "");
                  const value =
                    cleanValue === "0" ? "0" : cleanValue.replace(/^0+/, "");
                  setFormData((prev) => ({ ...prev, twapStepMax: value }));
                }}
                className="w-full p-2 border rounded focus:ring-2 focus:ring-blue-500 pr-8"
                required
              />
            </div>
          </div>

          <div className="space-y-2">
            <div className="flex items-center space-x-2">
              <label className="block text-sm font-medium">
                TWAP Initial Observation
              </label>
              <div className="relative group">
                <InfoCircledIcon className="w-4 h-4 text-gray-400 hover:text-gray-600 cursor-help" />
                <div className="absolute left-1/2 -translate-x-1/2 bottom-full mb-2 px-3 py-2 bg-gray-900 text-white text-sm rounded-lg opacity-0 group-hover:opacity-100 pointer-events-none transition-opacity duration-200 w-64 z-50">
                  {tooltips.twapInitialObservation}
                </div>
              </div>
            </div>
            <div className="relative">
              <input
                type="text"
                name="twapInitialObservation"
                value={formData.twapInitialObservation}
                onChange={(e) => {
                  const cleanValue = e.target.value.replace(/[^0-9]/g, "");
                  const value =
                    cleanValue === "0" ? "0" : cleanValue.replace(/^0+/, "");
                  setFormData((prev) => ({
                    ...prev,
                    twapInitialObservation: value,
                  }));
                }}
                className="w-full p-2 border rounded focus:ring-2 focus:ring-blue-500 pr-8"
                required
              />
            </div>
          </div>

          <div className="space-y-2">
            <div className="flex items-center space-x-2">
              <label className="block text-sm font-medium">
                TWAP Threshold (%)
              </label>
              <div className="relative group">
                <InfoCircledIcon className="w-4 h-4 text-gray-400 hover:text-gray-600 cursor-help" />
                <div className="absolute left-1/2 -translate-x-1/2 bottom-full mb-2 px-3 py-2 bg-gray-900 text-white text-sm rounded-lg opacity-0 group-hover:opacity-100 pointer-events-none transition-opacity duration-200 w-64 z-50">
                  {tooltips.twapThreshold}
                </div>
              </div>
            </div>
            <div className="relative">
              <input
                type="number"
                name="twapThreshold"
                value={Number(formData.twapThreshold).toFixed(3)}
                onChange={(e) => {
                  const value =
                    Math.round(parseFloat(e.target.value) * 1000) / 1000;
                  setFormData((prev) => ({ ...prev, twapThreshold: value }));
                }}
                className="w-full p-2 border rounded focus:ring-2 focus:ring-blue-500 pr-8"
                min="0.001"
                step="0.001"
                required
              />
              <span className="absolute right-3 top-1/2 transform -translate-y-1/2 text-gray-500">
                %
              </span>
            </div>
          </div>

          <div className="space-y-2">
            <div className="flex items-center space-x-2">
              <label className="block text-sm font-medium">
                Overwrite default DAO image with new URL
              </label>
              <div className="relative group">
                <InfoCircledIcon className="w-4 h-4 text-gray-400 hover:text-gray-600 cursor-help" />
                <div className="absolute left-1/2 -translate-x-1/2 bottom-full mb-2 px-3 py-2 bg-gray-900 text-white text-sm rounded-lg opacity-0 group-hover:opacity-100 pointer-events-none transition-opacity duration-200 w-64 z-50">
                  {tooltips.imageUrl}
                </div>
              </div>
            </div>
            <input
              type="text"
              name="imageUrl"
              value={formData.imageUrl}
              onChange={handleInputChange}
              className="w-full p-2 border rounded focus:ring-2 focus:ring-blue-500"
              placeholder="Enter image URL"
            />
          </div>
        </div>

        {/* End of advanced configuration section */}
        {/* Image preview section */}
        <div className="mt-6 space-y-2">
          <h3 className="block text-sm font-medium">Preview DAO Image</h3>
          <div className="w-32 h-32 border rounded-lg overflow-hidden bg-transparent">
            {previewImage && (
              <img
                src={previewImage}
                alt="DAO Preview"
                className="w-full h-full object-cover rounded-lg"
                onError={() => {
                  setImageError(true);
                  setPreviewImage("");
                }}
                onLoad={() => setImageError(false)}
              />
            )}
            {!previewImage && (
              <div className="w-full h-full flex items-center justify-center text-gray-400 bg-gray-50 rounded-lg">
                No image
              </div>
            )}
          </div>
          {imageError && (
            <p className="text-sm text-red-500">
              {formData.imageUrl
                ? "Error: Image is over 10MB or invalid URL"
                : "Failed to load image"}
            </p>
          )}
        </div>
        <button
          type="submit"
          disabled={isLoading}
          className="w-full bg-blue-500 text-white py-2 px-4 rounded hover:bg-blue-600 disabled:bg-blue-300 disabled:cursor-not-allowed"
        >
          {isLoading ? "Creating..." : "Create DAO"}
        </button>
      </form>
    </div>
  );
};

export default CreateDaoForm;
