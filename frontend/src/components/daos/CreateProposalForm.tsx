import React, { useState, useEffect, useRef } from "react";
import { useQuery } from "@tanstack/react-query";
import { useNavigate } from "react-router-dom";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { useSuiTransaction } from "@/hooks/useSuiTransaction";
import toast from "react-hot-toast";
import DaoSearchInput from "./DaoSearchInput";
import {
  createProposalTransaction,
  CreateProposalData,
} from "./proposal-transaction";
import { CONSTANTS } from "../../constants";
import { VerifiedIcon } from "../icons/VerifiedIcon";

// Import all the new components
import { FormField } from "./create-proposal/FormField";
import { OutcomeMessages } from "./create-proposal/OutcomeMessages";
import { ProposalContent } from "./create-proposal/ProposalContent";
import { AdvancedSettings } from "./create-proposal/AdvancedSettings";
import { AIReviewSection } from "./create-proposal/AIReviewSection";

interface DaoData {
  dao_id: string;
  minAssetAmount: string;
  minStableAmount: string;
  assetType: string;
  stableType: string;
  dao_name: string;
  dao_icon: string;
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
  description: "",
  metadata: "test",
  outcomeMessages: ["Reject", "Accept"],
  daoObjectId: "",
  assetType: "",
  stableType: "",
  minAssetAmount: "0",
  minStableAmount: "0",
  senderAddress: "",
};

const DEFAULT_PROPOSAL_SECTIONS = {
  intro: "",
  outcomes: {
    Accept: "",
    Reject: "",
  },
  footer: "",
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

const truncateAddress = (address: string) => {
  if (address.length <= 20) return address;
  return `${address.slice(0, 10)}...${address.slice(-10)}`;
};

const CreateProposalForm = ({
  walletAddress,
  daoIdFromUrl,
}: CreateProposalFormProps) => {
  // Helper function to get saved form data from localStorage
  const getSavedFormData = (): CreateProposalData | null => {
    const saved = localStorage.getItem("proposalFormData");
    if (!saved) return null;

    try {
      const parsed = JSON.parse(saved);
      const savedTime = parsed.timestamp;
      const currentTime = Date.now();

      // Check if data is older than 30 minutes (30 * 60 * 1000 milliseconds)
      if (currentTime - savedTime > 30 * 60 * 1000) {
        localStorage.removeItem("proposalFormData");
        return null;
      }

      return parsed.data;
    } catch {
      return null;
    }
  };

  // Helper function to save just the description/memo
  const saveDescription = (description: string) => {
    const saved = {
      description,
      timestamp: Date.now(),
    };
    localStorage.setItem("proposalDescription", JSON.stringify(saved));
  };

  // Helper function to get saved description
  const getSavedDescription = (): string | null => {
    const saved = localStorage.getItem("proposalDescription");
    if (!saved) return null;

    try {
      const parsed = JSON.parse(saved);
      const savedTime = parsed.timestamp;
      const currentTime = Date.now();

      // Check if data is older than 2 hours
      if (currentTime - savedTime > 2 * 60 * 60 * 1000) {
        localStorage.removeItem("proposalDescription");
        return null;
      }

      return parsed.description;
    } catch {
      return null;
    }
  };

  // State variables
  const [showAdvancedSettings, setShowAdvancedSettings] = useState(false);
  const [previewMarkdown, setPreviewMarkdown] = useState(false);
  const [customAmounts, setCustomAmounts] = useState<number[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [hasPassedReview, setHasPassedReview] = useState(false);

  // Initialize proposal sections state
  const [proposalSections, setProposalSections] = useState<{
    intro: string;
    outcomes: Record<string, string>;
    footer: string;
  }>(() => {
    const savedDescription = getSavedDescription();
    if (savedDescription) {
      // Try to parse saved description back into sections
      const sections = {
        intro: "",
        outcomes: {} as Record<string, string>,
        footer: DEFAULT_PROPOSAL_SECTIONS.footer,
      };

      // Extract intro section (from start to background)
      const bgIndex = savedDescription.indexOf(
        "#### 💡 Background & Motivation",
      );
      if (bgIndex > 0) {
        sections.intro = savedDescription.substring(0, bgIndex).trim();
      }

      // Extract background section and append to intro if found
      const bgMatch = savedDescription.match(
        /#### 💡 Background & Motivation[\s\S]*?(?=##|$)/,
      );
      if (bgMatch) {
        sections.intro = sections.intro + "\n\n" + bgMatch[0].trim();
      }

      // Extract outcome sections
      const acceptMatch = savedDescription.match(
        /## ✅ If Accepted[\s\S]*?(?=## ❌|---|\n## |$)/,
      );
      if (acceptMatch) {
        sections.outcomes["Accept"] = acceptMatch[0].trim();
      }

      const rejectMatch = savedDescription.match(
        /## ❌ If Rejected[\s\S]*?(?=---|$)/,
      );
      if (rejectMatch) {
        sections.outcomes["Reject"] = rejectMatch[0].trim();
      }

      // Extract footer
      const footerMatch = savedDescription.match(/---[\s\S]*$/);
      if (footerMatch) {
        sections.footer = footerMatch[0].trim();
      }

      return sections;
    }

    return {
      ...DEFAULT_PROPOSAL_SECTIONS,
      outcomes: { ...DEFAULT_PROPOSAL_SECTIONS.outcomes },
    };
  });

  const [formData, setFormData] = useState<CreateProposalData>(() => {
    const savedData = getSavedFormData();
    const savedDescription = getSavedDescription();

    if (savedData && savedData.daoObjectId === daoIdFromUrl) {
      return {
        ...savedData,
        // Use saved description if available, otherwise use saved data's description
        description: savedDescription || savedData.description,
        senderAddress: walletAddress, // Always use current wallet address
      };
    }

    // Even if no saved data, check for saved description
    if (savedDescription) {
      return {
        ...DEFAULT_FORM_DATA,
        description: savedDescription,
        senderAddress: walletAddress,
      };
    }

    return {
      ...DEFAULT_FORM_DATA,
      senderAddress: walletAddress, // Set initial value
    };
  });

  const currentAccount = useCurrentAccount();
  const { executeTransaction, isLoading } = useSuiTransaction();
  const descriptionSaveTimeoutRef = useRef<NodeJS.Timeout>();
  const navigate = useNavigate();

  // Helper function to combine sections into full description
  const updateFormDataDescription = (sections: typeof proposalSections) => {
    let fullDescription = "# Introduction\n\n";

    // Add user intro content
    if (sections.intro) {
      fullDescription += sections.intro + "\n\n";
    }

    // Add binary/multioption text
    if (
      formData.outcomeMessages.length === 2 &&
      formData.outcomeMessages[0] === "Reject" &&
      formData.outcomeMessages[1] === "Accept"
    ) {
      fullDescription +=
        "This is a binary proposal with 2 outcomes:\n- Reject\n- Accept";
    } else {
      fullDescription += `This is a multioption proposal with ${formData.outcomeMessages.length} outcomes:\n`;
      formData.outcomeMessages.forEach((outcome) => {
        fullDescription += `- ${outcome}\n`;
      });
    }

    // Add outcome sections with headers
    if (formData.outcomeMessages) {
      formData.outcomeMessages.forEach((outcome) => {
        fullDescription += `\n\n# If ${outcome} is the winning outcome:\n\n`;
        if (sections.outcomes[outcome]) {
          fullDescription += sections.outcomes[outcome];
        }
      });
    }

    // Add footer if it exists
    if (sections.footer) {
      fullDescription += "\n\n" + sections.footer;
    }

    setFormData((prev) => ({
      ...prev,
      description: fullDescription,
    }));
  };

  // Query to fetch DAO data when loading from URL
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

  // Auto-save form data to localStorage
  useEffect(() => {
    const saveData = {
      data: formData,
      timestamp: Date.now(),
    };
    localStorage.setItem("proposalFormData", JSON.stringify(saveData));
  }, [formData]);

  // Debounced save for description field
  useEffect(() => {
    if (formData.description) {
      // Clear existing timeout
      if (descriptionSaveTimeoutRef.current) {
        clearTimeout(descriptionSaveTimeoutRef.current);
      }

      // Set new timeout for saving description
      descriptionSaveTimeoutRef.current = setTimeout(() => {
        saveDescription(formData.description);
      }, 500); // Save after 500ms of no changes
    }

    // Cleanup on unmount
    return () => {
      if (descriptionSaveTimeoutRef.current) {
        clearTimeout(descriptionSaveTimeoutRef.current);
      }
    };
  }, [formData.description]);

  // Update description when proposal sections change
  useEffect(() => {
    if (proposalSections && formData.outcomeMessages) {
      updateFormDataDescription(proposalSections);
    }
  }, [proposalSections]);

  // Auto-resize textareas on mount and when content changes
  useEffect(() => {
    const textareas = document.querySelectorAll('textarea[style*="height"]');
    textareas.forEach((textarea) => {
      const target = textarea as HTMLTextAreaElement;
      target.style.height = "auto";
      target.style.height = `${Math.min(target.scrollHeight, 500)}px`;
    });
  }, [proposalSections, previewMarkdown]);

  // Update form data when wallet or DAO changes
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

  const handleInputChange = (
    e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>,
  ) => {
    const { name, value } = e.target;

    if (name === "outcomeMessages") {
      const newOutcomes = value.split(",").map((msg) => msg.trim());
      setFormData((prev) => {
        // Update the form data and let the sections handle the description
        updateFormDataDescription(proposalSections);
        return {
          ...prev,
          outcomeMessages: newOutcomes,
          senderAddress: walletAddress,
        };
      });
    } else {
      setFormData((prev) => ({
        ...prev,
        [name]: value,
        senderAddress: walletAddress, // Maintain wallet address during input changes
      }));
    }
  };

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

  const handleAIReviewComplete = (rating: number) => {
    setHasPassedReview(rating >= 6);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);

    if (!currentAccount?.address) {
      toast.error("Please connect your wallet before creating a proposal.");
      return;
    }

    // Check if AI review has been done and passed
    if (!hasPassedReview) {
      toast.error("Please get an AI review with a rating of at least 8/10 before submitting.");
      return;
    }

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

      await executeTransaction(
        txBlock,
        {
          onSuccess: () => {
            // Clear localStorage on successful submission
            localStorage.removeItem("proposalFormData");
            localStorage.removeItem("proposalDescription");
            setFormData((prev) => ({
              ...DEFAULT_FORM_DATA,
              senderAddress: prev.senderAddress,
            }));
            setHasPassedReview(false);
          },
          onError: (error) => {
            console.error("Error creating proposal:", {
              message: error.message,
              details: error,
            });
            setError(error.message);
          },
        },
        {
          loadingMessage: "Creating proposal...",
          successMessage: "Proposal created successfully!",
          errorMessage: (error) => {
            if (error.message?.includes("Rejected from user")) {
              return "Transaction cancelled by user";
            } else if (error.message?.includes("Insufficient gas")) {
              return "Insufficient SUI for gas fees";
            }
            return `Failed to create proposal: ${error.message}`;
          },
        },
      );
    } catch (error: unknown) {
      // Handle pre-transaction errors (validation, etc.)
      const errorMessage =
        error instanceof Error ? error.message : String(error);
      console.error("Error preparing proposal:", errorMessage);
      toast.error(errorMessage);
      setError(errorMessage);
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
                  src={daoData?.dao_icon || "/placeholder-dao.png"}
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

        <ProposalContent
          previewMarkdown={previewMarkdown}
          setPreviewMarkdown={setPreviewMarkdown}
          proposalSections={proposalSections}
          setProposalSections={setProposalSections}
          updateFormDataDescription={updateFormDataDescription}
          formData={formData}
        />

        <OutcomeMessages
          value={formData.outcomeMessages.join(", ")}
          onChange={handleInputChange}
          customAmounts={customAmounts}
          setCustomAmounts={setCustomAmounts}
          daoData={daoData}
          tooltip={tooltips.outcomeMessages}
          proposalSections={proposalSections}
          setProposalSections={setProposalSections}
        />

        {/* AI Review Section */}
        {formData.title && formData.description && formData.outcomeMessages.length >= 2 && (
          <AIReviewSection
            title={formData.title}
            outcomeMessages={formData.outcomeMessages}
            description={formData.description}
            onReviewComplete={handleAIReviewComplete}
            isDisabled={!formData.daoObjectId}
          />
        )}

        <AdvancedSettings
          showAdvancedSettings={showAdvancedSettings}
          setShowAdvancedSettings={setShowAdvancedSettings}
          customAmounts={customAmounts}
          setCustomAmounts={setCustomAmounts}
          outcomeMessages={formData.outcomeMessages}
          daoData={daoData}
        />

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
          disabled={isLoading || !hasPassedReview}
          className={`w-full py-2 px-4 rounded transition-colors ${
            hasPassedReview
              ? "bg-blue-500 text-white hover:bg-blue-600"
              : "bg-gray-700 text-gray-400 cursor-not-allowed"
          } disabled:cursor-not-allowed`}
        >
          {isLoading ? "Creating..." : hasPassedReview ? "Create Proposal" : "AI Review Required (8+ rating out of 10)"}
        </button>
      </form>
    </div>
  );
};

export default CreateProposalForm;
