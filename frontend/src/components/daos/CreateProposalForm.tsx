import React, { useState, useEffect } from "react";
import { useQuery } from "@tanstack/react-query";
import { useNavigate } from "react-router-dom";
import { useSignAndExecuteTransaction } from "@mysten/dapp-kit";
import { InfoCircledIcon } from "@radix-ui/react-icons";
import DaoSearchInput from "./DaoSearchInput";
import {
  createProposalTransaction,
  CreateProposalData,
} from "./proposal-transaction";
import { CONSTANTS } from "../../constants";
import { VerifiedIcon } from "../state/VerifiedIcon";
import ReactMarkdown from "markdown-to-jsx";

interface DaoData {
  dao_id: string;
  minAssetAmount: string;
  minStableAmount: string;
  assetType: string;
  stableType: string;
  dao_name: string;
  icon_url: string;
  icon_cache_path: string | null;
  review_period_ms: string;
  trading_period_ms: string;
  asset_decimals: number;
  stable_decimals: number;
  asset_symbol: String;
  stable_symbol: String;
  verification?: {
    verified: boolean;
  };
}

const DEFAULT_FORM_DATA: CreateProposalData = {
  title: "",
  description:
    "# Intro\n\nWalk **all** the dogs twice a day because they have been good.\n\n![Dog](https://upload.wikimedia.org/wikipedia/commons/thumb/c/c8/Black_Labrador_Retriever_-_Male_IMG_3323.jpg/1280px-Black_Labrador_Retriever_-_Male_IMG_3323.jpg)\n\n# Details\n\n• Walk 4+ KM\n\n• Bring treats\n\n• Bring lead",
  metadata: "test",
  outcomeMessages: ["Reject", "Accept"],
  daoObjectId: "",
  assetType: "",
  stableType: "",
  minAssetAmount: "0",
  minStableAmount: "0",
  senderAddress: "",
};

const tooltips = {
  title: "The title of your proposal",
  description: "A detailed description of your proposal",
  metadata: "Additional metadata for your proposal (optional)",
  outcomeMessages:
    "The first option must be 'Reject'. If there are two outcomes in total the second must be 'Accept'.",
  daoObjectId: "The DAO name or ID that this proposal is for",
};

interface CreateProposalFormProps {
  walletAddress: string;
  daoIdFromUrl?: string | null;
}

interface OutcomeMessagesProps {
  value: string;
  onChange: (
    e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>,
  ) => void;
  tooltip: string;
  customAmounts: number[];
  setCustomAmounts: (amounts: number[]) => void;
  daoData: DaoData | null;
}

const truncateAddress = (address: string) => {
  if (address.length <= 20) return address;
  return `${address.slice(0, 10)}...${address.slice(-10)}`;
};

const OutcomeMessages: React.FC<OutcomeMessagesProps> = ({
  value,
  onChange,
  tooltip,
  customAmounts,
  setCustomAmounts,
  daoData,
}) => {
  const [outcomes, setOutcomes] = useState<string[]>(() => {
    const initialOutcomes = value.split(",").map((o: string) => o.trim());
    if (initialOutcomes.length < 2) {
      return ["Reject", "Accept"];
    }
    return initialOutcomes;
  });

  const getMinAmounts = (daoData: DaoData | null) => {
    if (!daoData) return [0, 0];
    const minAssetAmount =
      parseFloat(
        convertToDisplayAmount(daoData.minAssetAmount, daoData.asset_decimals),
      ) || 0;
    const minStableAmount =
      parseFloat(
        convertToDisplayAmount(
          daoData.minStableAmount,
          daoData.stable_decimals,
        ),
      ) || 0;
    return [minAssetAmount, minStableAmount];
  };

  const convertToDisplayAmount = (amount: string, decimals: number) => {
    return (parseInt(amount) / Math.pow(10, decimals)).toString();
  };

  const MAX_OUTCOMES = 10;

  const addOutcome = () => {
    if (outcomes.length >= MAX_OUTCOMES) return;

    const newOutcomes = [...outcomes];
    const [minAssetAmount, minStableAmount] = getMinAmounts(daoData);
    const newCustomAmounts = [...customAmounts];

    if (outcomes.length === 2) {
      // When going from 2 to 3 outcomes, replace "Accept" with "Option 2" and add "Option 3"
      newOutcomes[1] = "Option 2";
      newOutcomes.push("Option 3");

      // Update amounts for Option 2 and add amounts for Option 3
      newCustomAmounts[2] = minAssetAmount;
      newCustomAmounts[3] = minStableAmount;
      newCustomAmounts.push(minAssetAmount);
      newCustomAmounts.push(minStableAmount);
    } else {
      // For subsequent additions, add the next option number (starting from where we left off)
      newOutcomes.push(`Option ${outcomes.length + 1}`);
      newCustomAmounts.push(minAssetAmount);
      newCustomAmounts.push(minStableAmount);
    }

    setCustomAmounts(newCustomAmounts);
    setOutcomes(newOutcomes);
    onChange({
      target: {
        name: "outcomeMessages",
        value: newOutcomes.join(", "),
      },
    } as React.ChangeEvent<HTMLInputElement>);
  };

  const removeOutcome = (index: number) => {
    if (outcomes.length <= 2) return;

    let newOutcomes;
    let newCustomAmounts;
    const [minAssetAmount, minStableAmount] = getMinAmounts(daoData);

    // If we're going back to 2 outcomes, restore "Accept"
    if (outcomes.length === 3) {
      newOutcomes = ["Reject", "Accept"];
      newCustomAmounts = [
        minAssetAmount,
        minStableAmount,
        minAssetAmount,
        minStableAmount,
      ];
    } else {
      newOutcomes = [...outcomes.slice(0, index), ...outcomes.slice(index + 1)];
      // Remove the corresponding amounts for the deleted outcome
      newCustomAmounts = [
        ...customAmounts.slice(0, index * 2),
        ...customAmounts.slice((index + 1) * 2),
      ];

      // Renumber remaining options
      newOutcomes = newOutcomes.map((_, i) =>
        i === 0 ? "Reject" : `Option ${i + 1}`,
      );
    }

    setCustomAmounts(newCustomAmounts);
    setOutcomes(newOutcomes);
    onChange({
      target: {
        name: "outcomeMessages",
        value: newOutcomes.join(", "),
      },
    } as React.ChangeEvent<HTMLInputElement>);
  };

  const updateOutcome = (index: number, newValue: string) => {
    if (index === 0) return;
    if (outcomes.length === 2 && index === 1) return;

    const newOutcomes = [...outcomes];
    newOutcomes[index] = newValue;
    setOutcomes(newOutcomes);
    onChange({
      target: {
        name: "outcomeMessages",
        value: newOutcomes.join(", "),
      },
    } as React.ChangeEvent<HTMLInputElement>);
  };

  return (
    <div className="space-y-2">
      <div className="flex items-center space-x-2">
        <label className="block text-sm font-medium text-gray-200">
          Outcome Messages
        </label>
        <div className="relative group">
          <InfoCircledIcon className="w-4 h-4 text-gray-400" />
          <div className="absolute left-1/2 -translate-x-1/2 bottom-full mb-2 px-3 py-2 bg-gray-900 text-white text-sm rounded-lg opacity-0 group-hover:opacity-100 pointer-events-none transition-opacity duration-200 w-64 z-50">
            {tooltip}
          </div>
        </div>
      </div>

      <div className="space-y-2">
        {outcomes.map((outcome: string, index: number) => {
          const isDisabled =
            index === 0 || (outcomes.length === 2 && index === 1);

          return (
            <div key={index} className="flex items-center space-x-2">
              <input
                type="text"
                value={outcome}
                onChange={(e) => updateOutcome(index, e.target.value)}
                className={`flex-1 p-2 rounded-md text-gray-100 ${
                  isDisabled
                    ? "bg-gray-900 cursor-not-allowed"
                    : "bg-black border border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
                }`}
                disabled={isDisabled}
              />
              {!isDisabled && outcomes.length > 2 && (
                <button
                  type="button"
                  onClick={() => removeOutcome(index)}
                  className="p-2 text-gray-400 hover:text-gray-200 bg-gray-900 rounded-md"
                >
                  −
                </button>
              )}
            </div>
          );
        })}

        {outcomes.length < MAX_OUTCOMES && (
          <button
            type="button"
            onClick={addOutcome}
            className="flex items-center space-x-1 text-blue-500 hover:text-blue-600 px-2 py-1 rounded border"
          >
            <span>+</span>
            <span>Add Option</span>
          </button>
        )}
      </div>
    </div>
  );
};

const CreateProposalForm = ({
  walletAddress,
  daoIdFromUrl,
}: CreateProposalFormProps) => {
  // Initialize form data with wallet address
  const [showAdvancedSettings, setShowAdvancedSettings] = useState(false);
  const [previewMarkdown, setPreviewMarkdown] = useState(false);
  const [customAmounts, setCustomAmounts] = useState<number[]>([]);
  const [formData, setFormData] = useState<CreateProposalData>(() => ({
    ...DEFAULT_FORM_DATA,
    senderAddress: walletAddress, // Set initial value
  }));

  // Add this query to fetch DAO data when loading from URL
  const { data: daoData } = useQuery({
    queryKey: ["dao", daoIdFromUrl],
    queryFn: async () => {
      if (!daoIdFromUrl) return null;
      const response = await fetch(
        `${CONSTANTS.apiEndpoint}daos?dao_id=${encodeURIComponent(daoIdFromUrl)}`,
      );
      if (!response.ok) {
        throw new Error(`API error: ${response.statusText}`);
      }
      const result = await response.json();
      return result.data[0] || null;
    },
    enabled: !!daoIdFromUrl,
  });

  // This is your existing useEffect
  useEffect(() => {
    setFormData((prev) => ({
      ...prev,
      senderAddress: walletAddress,
      daoObjectId: daoData?.dao_id || prev.daoObjectId,
      assetType: daoData?.assetType || prev.assetType,
      stableType: daoData?.stableType || prev.stableType,
      minAssetAmount: daoData
        ? convertToDisplayAmount(daoData.minAssetAmount, daoData.asset_decimals)
        : prev.minAssetAmount,
      minStableAmount: daoData
        ? convertToDisplayAmount(
            daoData.minStableAmount,
            daoData.stable_decimals,
          )
        : prev.minStableAmount,
    }));

    if (daoData && formData.outcomeMessages.length > 0) {
      setInitialAmounts(daoData);
    }
  }, [walletAddress, daoIdFromUrl, daoData]);

  // Helper function to convert display amount to chain amount
  const convertToChainAmount = (amount: number, decimals: number) => {
    return Math.floor(amount * Math.pow(10, decimals));
  };

  // Helper function to convert chain amount to display amount
  const convertToDisplayAmount = (amount: string, decimals: number) => {
    const value = parseInt(amount) / Math.pow(10, decimals);
    return value.toString();
  };

  const setInitialAmounts = (daoData: DaoData) => {
    const minAssetAmount =
      parseFloat(
        convertToDisplayAmount(daoData.minAssetAmount, daoData.asset_decimals),
      ) || 0;
    const minStableAmount =
      parseFloat(
        convertToDisplayAmount(
          daoData.minStableAmount,
          daoData.stable_decimals,
        ),
      ) || 0;
    const newAmounts: number[] = [];
    formData.outcomeMessages.forEach(() => {
      newAmounts.push(minAssetAmount);
      newAmounts.push(minStableAmount);
    });
    setCustomAmounts(newAmounts);
  };

  // This is your existing signAndExecute declaration
  const { mutate: signAndExecute } = useSignAndExecuteTransaction();
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Rest of your code stays the same
  const handleInputChange = (
    e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>,
  ) => {
    const { name, value } = e.target;
    setFormData((prev) => ({
      ...prev,
      [name]:
        name === "outcomeMessages"
          ? value.split(",").map((msg) => msg.trim())
          : value,
      senderAddress: walletAddress, // Maintain wallet address during input changes
    }));
  };

  const navigate = useNavigate();

  const handleDaoSelect = (daoData: DaoData | null) => {
    if (daoData) {
      setFormData((prev) => ({
        ...prev,
        daoObjectId: daoData.dao_id,
        assetType: daoData.assetType,
        stableType: daoData.stableType,
        minAssetAmount: convertToDisplayAmount(
          daoData.minAssetAmount,
          daoData.asset_decimals,
        ),
        minStableAmount: convertToDisplayAmount(
          daoData.minStableAmount,
          daoData.stable_decimals,
        ),
        senderAddress: walletAddress, // Ensure wallet address is maintained
      }));
      navigate(`/create?dao=${daoData.dao_id}`);
    } else {
      setFormData((prev) => ({
        ...prev,
        daoObjectId: "",
        assetType: "",
        stableType: "",
        minAssetAmount: "0",
        minStableAmount: "0",
        senderAddress: walletAddress, // Ensure wallet address is maintained
      }));
      navigate(`/create`);
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setCreating(true);
    setError(null);

    try {
      // Constants for maximum lengths
      const TITLE_MAX_LENGTH = 256;
      const METADATA_MAX_LENGTH = 512;
      const DETAILS_MAX_LENGTH = 16384; // 16KB

      // Validate required fields
      if (!formData.daoObjectId) {
        throw new Error("No DAO found for that ID");
      }
      if (!formData.assetType || !formData.stableType) {
        throw new Error("Asset and Stable types are required");
      }
      if (!formData.title) {
        throw new Error("Title is required");
      }
      if (!formData.description) {
        throw new Error("Description is required");
      }
      if (!formData.outcomeMessages || formData.outcomeMessages.length < 2) {
        throw new Error("At least two outcome messages are required");
      }
      if (!formData.senderAddress) {
        throw new Error("Sender address is missing");
      }

      // Validate character lengths
      const encoder = new TextEncoder();
      const titleLength = encoder.encode(formData.title).length;
      const metadataLength = encoder.encode(formData.metadata).length;
      const descriptionLength = encoder.encode(formData.description).length;

      if (titleLength > TITLE_MAX_LENGTH) {
        throw new Error(
          `Title exceeds maximum length of ${TITLE_MAX_LENGTH} characters (current: ${titleLength} characters)`,
        );
      }
      if (metadataLength > METADATA_MAX_LENGTH) {
        throw new Error(
          `Metadata exceeds maximum length of ${METADATA_MAX_LENGTH} characters (current: ${metadataLength} characters)`,
        );
      }
      if (descriptionLength > DETAILS_MAX_LENGTH) {
        throw new Error(
          `Description exceeds maximum length of ${DETAILS_MAX_LENGTH} characters (current: ${descriptionLength} characters)`,
        );
      }

      // Convert amounts to chain format before sending to smart contract
      let chainAmounts = null;
      if (showAdvancedSettings && customAmounts.length > 0) {
        chainAmounts = customAmounts.map((amount, index) => {
          // Even indices are asset amounts, odd indices are stable amounts
          if (index % 2 === 0) {
            return convertToChainAmount(amount, daoData?.asset_decimals || 0);
          } else {
            return convertToChainAmount(amount, daoData?.stable_decimals || 0);
          }
        });
      } else {
        // When not using advanced settings, we need to convert the min amounts to chain format
        const outcomeCount = formData.outcomeMessages.length;
        chainAmounts = [];
        for (let i = 0; i < outcomeCount; i++) {
          // For each outcome, add both asset and stable amounts
          chainAmounts.push(
            convertToChainAmount(
              parseFloat(formData.minAssetAmount),
              daoData?.asset_decimals || 0,
            ),
          );
          chainAmounts.push(
            convertToChainAmount(
              parseFloat(formData.minStableAmount),
              daoData?.stable_decimals || 0,
            ),
          );
        }
      }

      const txBlock = await createProposalTransaction(
        formData,
        chainAmounts, // This is new
        CONSTANTS.futarchyPackage,
      );

      await signAndExecute({
        transaction: txBlock,
      });

      setFormData((prev) => ({
        ...DEFAULT_FORM_DATA,
        senderAddress: prev.senderAddress,
      }));
    } catch (error: unknown) {
      console.error("Error creating proposal:", {
        message: error instanceof Error ? error.message : String(error),
        details: error,
      });
      setError(
        error instanceof Error ? error.message : "Failed to create proposal",
      );
    } finally {
      setCreating(false);
    }
  };
  return (
    <div className="p-6 max-w-2xl mx-auto">
      <form onSubmit={handleSubmit} className="space-y-4">
        <DaoSearchInput
          value={formData.daoObjectId}
          onChange={handleInputChange}
          onDaoSelect={handleDaoSelect}
          tooltip={tooltips.daoObjectId}
        />

        {formData.daoObjectId && (
          <div className="bg-gray-900 rounded-lg p-3">
            <div className="flex items-center space-x-3 mb-2">
              <div className="w-10 h-10 flex-shrink-0">
                <img
                  src={daoData?.icon_url || "/placeholder-dao.png"}
                  alt={daoData?.dao_name}
                  className="w-full h-full rounded-full object-cover"
                  onError={(e) => {
                    e.currentTarget.src = "/placeholder-dao.png";
                  }}
                />
              </div>
              <div className="flex-grow min-w-0">
                <div className="font-medium text-gray-200 truncate flex items-center">
                  {daoData?.dao_name}
                  {daoData?.verification?.verified && (
                    <VerifiedIcon className="ml-1 flex-shrink-0" />
                  )}
                </div>
                <div className="font-mono text-sm text-gray-400 truncate">
                  {truncateAddress(formData.daoObjectId)}
                </div>
              </div>
            </div>
            <div className="grid grid-cols-2 gap-x-4 gap-y-2 mt-2 pt-2 border-t border-gray-800">
              <div>
                <p className="text-sm font-medium">Asset Type:</p>
                <p className="text-xs truncate">
                  {truncateAddress(formData.assetType)}
                </p>
              </div>
              <div>
                <p className="text-sm font-medium">Stable Type:</p>
                <p className="text-xs truncate">
                  {truncateAddress(formData.stableType)}
                </p>
              </div>
              <div>
                <p className="text-sm font-medium">Min Asset Amount:</p>
                <p className="text-xs">{formData.minAssetAmount}</p>
              </div>
              <div>
                <p className="text-sm font-medium">Min Stable Amount:</p>
                <p className="text-xs">{formData.minStableAmount}</p>
              </div>
            </div>
          </div>
        )}

        <FormField
          label="Title"
          name="title"
          value={formData.title}
          onChange={handleInputChange}
          tooltip={tooltips.title}
          placeholder=""
        />

        <div className="space-y-2">
          <div>
            <label className="block text-sm font-medium">Description</label>
          </div>
          {previewMarkdown ? (
            <div className="prose px-6 border p-2 rounded bg-gray-900">
              <ReactMarkdown
                options={{
                  overrides: {
                    h1: {
                      component: "h1",
                      props: { className: "text-4xl font-bold my-4" },
                    },
                    h2: {
                      component: "h2",
                      props: { className: "text-3xl font-bold my-4" },
                    },
                    h3: {
                      component: "h3",
                      props: { className: "text-2xl font-bold my-3" },
                    },
                    h4: {
                      component: "h4",
                      props: { className: "text-xl font-bold my-2" },
                    },
                    h5: {
                      component: "h5",
                      props: { className: "text-lg font-bold my-2" },
                    },
                    h6: {
                      component: "h6",
                      props: { className: "text-base font-bold my-2" },
                    },
                  },
                }}
              >
                {formData.description}
              </ReactMarkdown>
            </div>
          ) : (
            <textarea
              name="description"
              value={formData.description}
              onChange={handleInputChange}
              className="w-full p-2 border rounded focus:ring-2 focus:ring-blue-500 min-h-[300px]"
              placeholder=""
              required
            />
          )}
          <div className="flex justify-end">
            <button
              type="button"
              onClick={() => setPreviewMarkdown(!previewMarkdown)}
              className="text-blue-500 text-sm"
            >
              {previewMarkdown ? "Edit" : "Preview"}
            </button>
          </div>
        </div>

        <OutcomeMessages
          value={formData.outcomeMessages.join(", ")}
          onChange={handleInputChange}
          customAmounts={customAmounts}
          setCustomAmounts={setCustomAmounts}
          daoData={daoData}
          tooltip={tooltips.outcomeMessages}
        />

        <div className="mt-6 pt-6">
          <div className="flex items-center gap-2 mb-4">
            <span className="text-sm font-medium text-gray-200">
              Advanced Settings
            </span>
            <button
              type="button"
              onClick={() => setShowAdvancedSettings(!showAdvancedSettings)}
              className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors ${
                showAdvancedSettings ? "bg-blue-500" : "bg-gray-700"
              }`}
            >
              <span
                className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${
                  showAdvancedSettings ? "translate-x-6" : "translate-x-1"
                }`}
              />
            </button>
          </div>

          {showAdvancedSettings && (
            <div className="space-y-4 p-4 rounded-lg">
              <div className="grid grid-cols-3 gap-4 mb-2">
                <div className="text-sm font-medium text-gray-300">Outcome</div>
                <div className="text-sm font-medium text-gray-300">{`${daoData?.asset_symbol || "Asset"} Amount`}</div>
                <div className="text-sm font-medium text-gray-300">{`${daoData?.stable_symbol || "Stable"} Amount`}</div>
              </div>
              {formData.outcomeMessages.map((outcome, index) => (
                <div
                  key={index}
                  className="grid grid-cols-3 gap-4 items-center"
                >
                  <div className="text-sm text-gray-200">{outcome}</div>
                  <div>
                    <input
                      type="number"
                      value={customAmounts[index * 2] || ""}
                      step={Math.pow(10, -(daoData?.asset_decimals || 0))}
                      onChange={(e) => {
                        const newAmounts = [...customAmounts];
                        newAmounts[index * 2] = parseFloat(e.target.value);
                        setCustomAmounts(newAmounts);
                      }}
                      min={parseFloat(
                        convertToDisplayAmount(
                          daoData?.minAssetAmount || "0",
                          daoData?.asset_decimals || 0,
                        ),
                      )}
                      className={`w-full p-2 rounded bg-gray-900 border ${
                        customAmounts[index * 2] <
                        parseFloat(
                          convertToDisplayAmount(
                            daoData?.minAssetAmount || "0",
                            daoData?.asset_decimals || 0,
                          ),
                        )
                          ? "border-red-500"
                          : "border-gray-700"
                      }`}
                    />
                    {customAmounts[index * 2] <
                      parseFloat(
                        convertToDisplayAmount(
                          daoData?.minAssetAmount || "0",
                          daoData?.asset_decimals || 0,
                        ),
                      ) && (
                      <p className="text-xs text-red-500 mt-1">
                        Below minimum (
                        {convertToDisplayAmount(
                          daoData?.minAssetAmount || "0",
                          daoData?.asset_decimals || 0,
                        )}
                        )
                      </p>
                    )}
                  </div>
                  <div>
                    <input
                      type="number"
                      value={customAmounts[index * 2 + 1] || ""}
                      step={Math.pow(10, -(daoData?.stable_decimals || 0))}
                      onChange={(e) => {
                        const newAmounts = [...customAmounts];
                        newAmounts[index * 2 + 1] = parseFloat(e.target.value);
                        setCustomAmounts(newAmounts);
                      }}
                      min={parseFloat(
                        convertToDisplayAmount(
                          daoData?.minStableAmount || "0",
                          daoData?.stable_decimals || 0,
                        ),
                      )}
                      className={`w-full p-2 rounded bg-gray-900 border ${
                        customAmounts[index * 2 + 1] <
                        parseFloat(
                          convertToDisplayAmount(
                            daoData?.minStableAmount || "0",
                            daoData?.stable_decimals || 0,
                          ),
                        )
                          ? "border-red-500"
                          : "border-gray-700"
                      }`}
                    />
                    {customAmounts[index * 2 + 1] <
                      parseFloat(
                        convertToDisplayAmount(
                          daoData?.minStableAmount || "0",
                          daoData?.stable_decimals || 0,
                        ),
                      ) && (
                      <p className="text-xs text-red-500 mt-1">
                        Below minimum (
                        {convertToDisplayAmount(
                          daoData?.minStableAmount || "0",
                          daoData?.stable_decimals || 0,
                        )}
                        )
                      </p>
                    )}
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>

        {error && <div className="text-red-500 text-sm">{error}</div>}

        {(daoData?.review_period_ms || daoData?.trading_period_ms) && (
          <p className="text-gray-200 text-sm mt-4">
            {(() => {
              const reviewPeriod = parseInt(daoData?.review_period_ms || "0");
              const tradingPeriod = parseInt(daoData?.trading_period_ms || "0");
              const totalDays = Math.ceil(
                (reviewPeriod + tradingPeriod) / (24 * 60 * 60 * 1000),
              );
              return (
                `Please be aware you may not be able to withdraw your liquidity for up to ${totalDays} ` +
                `${totalDays === 1 ? "day" : "days"}.`
              );
            })()}
          </p>
        )}

        <button
          type="submit"
          disabled={creating}
          className="w-full bg-blue-500 text-white py-2 px-4 rounded hover:bg-blue-600 disabled:bg-blue-300 disabled:cursor-not-allowed"
        >
          {creating ? "Creating..." : "Create Proposal"}
        </button>
      </form>
    </div>
  );
};

interface FormFieldProps {
  label: string;
  name: string;
  value: string;
  onChange: (
    e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>,
  ) => void;
  tooltip: string;
  isTextArea?: boolean;
  placeholder?: string;
}

const FormField = ({
  label,
  name,
  value,
  onChange,
  tooltip,
  isTextArea = false,
  placeholder = "",
}: FormFieldProps) => (
  <div className="space-y-2">
    <div className="flex items-center space-x-2">
      <label className="block text-sm font-medium">{label}</label>
      <div className="relative group">
        <InfoCircledIcon className="w-4 h-4 text-gray-400 hover:text-gray-600 cursor-help" />
        <div className="absolute left-1/2 -translate-x-1/2 bottom-full mb-2 px-3 py-2 bg-gray-900 text-white text-sm rounded-lg opacity-0 group-hover:opacity-100 pointer-events-none transition-opacity duration-200 w-64 z-50">
          {tooltip}
        </div>
      </div>
    </div>
    {isTextArea ? (
      <textarea
        name={name}
        value={value}
        onChange={onChange}
        className="w-full p-2 border rounded focus:ring-2 focus:ring-blue-500 min-h-[100px]"
        placeholder={placeholder}
        required
      />
    ) : (
      <input
        type="text"
        name={name}
        value={value}
        onChange={onChange}
        className="w-full p-2 border rounded focus:ring-2 focus:ring-blue-500"
        placeholder={placeholder}
        required
      />
    )}
  </div>
);

export default CreateProposalForm;
