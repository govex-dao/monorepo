import React, { useState, useEffect, useRef } from "react";
import { useQuery } from "@tanstack/react-query";
import { useNavigate } from "react-router-dom";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { useTransactionExecution } from "@/hooks/useTransactionExecution";
import { InfoCircledIcon, ReloadIcon } from "@radix-ui/react-icons";
import toast from "react-hot-toast";
import DaoSearchInput from "./DaoSearchInput";
import {
  createProposalTransaction,
  CreateProposalData,
} from "./proposal-transaction";
import { CONSTANTS } from "../../constants";
import { VerifiedIcon } from "../icons/VerifiedIcon";
import MarkdownRenderer from "../MarkdownRenderer";

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

interface OutcomeMessagesProps {
  value: string;
  onChange: (
    e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>,
  ) => void;
  tooltip: string;
  customAmounts: number[];
  setCustomAmounts: (amounts: number[]) => void;
  daoData: DaoData | null;
  proposalSections: {
    intro: string;
    outcomes: Record<string, string>;
    footer: string;
  };
  setProposalSections: (sections: {
    intro: string;
    outcomes: Record<string, string>;
    footer: string;
  }) => void;
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
  proposalSections,
  setProposalSections,
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

      // Update proposal sections - rename Accept to Option 2 and add Option 3
      const acceptContent = proposalSections.outcomes["Accept"] || "";
      const newSections = {
        ...proposalSections,
        intro: proposalSections.intro,
        outcomes: {
          ...proposalSections.outcomes,
          "Option 2": acceptContent.replace(/Accept/g, "Option 2"),
          "Option 3": "",
        } as Record<string, string>,
      };
      delete newSections.outcomes["Accept"];
      setProposalSections(newSections);
    } else {
      // For subsequent additions, add the next option number (starting from where we left off)
      const newOption = `Option ${outcomes.length + 1}`;
      newOutcomes.push(newOption);
      newCustomAmounts.push(minAssetAmount);
      newCustomAmounts.push(minStableAmount);

      // Add new outcome section
      const newSections = {
        ...proposalSections,
        intro: proposalSections.intro,
        outcomes: {
          ...proposalSections.outcomes,
          [newOption]: "",
        },
      };
      setProposalSections(newSections);
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

      // Update proposal sections - restore Accept and remove Options
      const option2Content = proposalSections.outcomes["Option 2"] || "";
      const newSections = {
        ...proposalSections,
        intro: proposalSections.intro,
        outcomes: {
          Reject: proposalSections.outcomes["Reject"],
          Accept:
            option2Content.replace(/Option 2/g, "Accept") ||
            DEFAULT_PROPOSAL_SECTIONS.outcomes["Accept"],
        },
      };
      setProposalSections(newSections);
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

      // Update proposal sections - remove the deleted outcome and renumber others
      const newSections = {
        ...proposalSections,
        intro: proposalSections.intro,
        outcomes: {} as Record<string, string>,
      };
      let optionCounter = 2;
      outcomes.forEach((outcome, i) => {
        if (i !== index) {
          if (outcome === "Reject") {
            newSections.outcomes["Reject"] =
              proposalSections.outcomes["Reject"] || "";
          } else {
            const newName = `Option ${optionCounter}`;
            const oldContent = proposalSections.outcomes[outcome] || "";
            newSections.outcomes[newName] = oldContent.replace(
              new RegExp(outcome, "g"),
              newName,
            );
            optionCounter++;
          }
        }
      });
      setProposalSections(newSections);
    }

    setCustomAmounts(newCustomAmounts);
    setOutcomes(newOutcomes);
    onChange({
      target: {
        name: "outcomeMessages",
        value: newOutcomes.join(", "),
        // Pass the old outcomes so handleInputChange knows what was removed
        oldOutcomes: outcomes,
      } as any,
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

  // Initialize form data with wallet address
  const [showAdvancedSettings, setShowAdvancedSettings] = useState(false);
  const [previewMarkdown, setPreviewMarkdown] = useState(false);
  const [customAmounts, setCustomAmounts] = useState<number[]>([]);

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
  const executeTransaction = useTransactionExecution();
  const descriptionSaveTimeoutRef = useRef<NodeJS.Timeout>();

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
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // We no longer need these helper functions since we're managing description through sections

  // Simplified handleInputChange since description is now managed by sections
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

    if (!currentAccount?.address) {
      toast.error("Please connect your wallet before creating a proposal.");
      return;
    }

    const loadingToast = toast.loading("Preparing transaction...");
    const walletApprovalTimeout = setTimeout(() => {
      toast.error("Wallet approval timeout - no response after 1 minute", {
        id: loadingToast,
        duration: 5000,
      });
    }, 60000);

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

      toast.loading("Waiting for wallet approval...", { id: loadingToast });

      const response = await executeTransaction(txBlock);

      // Handle the response
      if (
        response &&
        response.digest &&
        "effects" in response &&
        response.effects?.status?.status === "success"
      ) {
        // Clear localStorage on successful submission
        localStorage.removeItem("proposalFormData");
        localStorage.removeItem("proposalDescription");
        setFormData((prev) => ({
          ...DEFAULT_FORM_DATA,
          senderAddress: prev.senderAddress,
        }));
      }
    } catch (error: unknown) {
      console.error("Error creating proposal:", {
        message: error instanceof Error ? error.message : String(error),
        details: error,
      });
    } finally {
      setCreating(false);
      clearTimeout(walletApprovalTimeout);
      toast.dismiss(loadingToast);
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

        <div className="space-y-4">
          <div className="flex items-center justify-between">
            <label className="block text-sm font-medium">
              Proposal Content
            </label>
          </div>

          {previewMarkdown ? (
            <div className="border border-blue-500 p-4 rounded bg-gray-900 min-h-[400px]">
              <MarkdownRenderer content={formData.description} />
            </div>
          ) : (
            <div className="space-y-4">
              {/* Static Introduction Header */}
              <div className="text-lg font-bold text-gray-200">
                # Introduction
              </div>

              {/* User Introduction Input */}
              <textarea
                value={proposalSections.intro}
                onChange={(e) => {
                  const newSections = {
                    ...proposalSections,
                    intro: e.target.value,
                  };
                  setProposalSections(newSections);
                  updateFormDataDescription(newSections);
                }}
                className="w-full p-3 bg-black border border-blue-500 rounded focus:outline-none focus:ring-1 focus:ring-blue-500 min-h-[100px] max-h-[500px] text-gray-100 resize-none overflow-y-auto"
                placeholder="Briefly introduce what you're proposing and why it matters to the DAO."
                style={{
                  height: "auto",
                  minHeight: "100px",
                  maxHeight: "500px",
                }}
                onInput={(e) => {
                  const target = e.target as HTMLTextAreaElement;
                  target.style.height = "auto";
                  target.style.height = `${Math.min(target.scrollHeight, 500)}px`;
                }}
              />

              {/* Static Binary/Multioption Text */}
              <div className="text-gray-300 whitespace-pre-line">
                {formData.outcomeMessages.length === 2 &&
                formData.outcomeMessages[0] === "Reject" &&
                formData.outcomeMessages[1] === "Accept"
                  ? "This is a binary proposal with 2 outcomes:\n- Reject\n- Accept"
                  : `This is a multioption proposal with ${formData.outcomeMessages.length} outcomes:\n${formData.outcomeMessages.map((o) => `- ${o}`).join("\n")}`}
              </div>

              {/* Outcome Sections */}
              {formData.outcomeMessages.map((outcome) => (
                <div key={outcome} className="space-y-2">
                  {/* Static Outcome Header */}
                  <div className="text-lg font-bold text-gray-200">
                    # If {outcome} is the winning outcome:
                  </div>

                  {/* User Outcome Input */}
                  <textarea
                    value={proposalSections.outcomes[outcome] || ""}
                    onChange={(e) => {
                      const newSections = {
                        ...proposalSections,
                        outcomes: {
                          ...proposalSections.outcomes,
                          [outcome]: e.target.value,
                        },
                      };
                      setProposalSections(newSections);
                      updateFormDataDescription(newSections);
                    }}
                    className="w-full p-3 bg-black border border-blue-500 rounded focus:outline-none focus:ring-1 focus:ring-blue-500 min-h-[150px] max-h-[500px] text-gray-100 resize-none overflow-y-auto"
                    placeholder="Describe what happens if this outcome wins..."
                    style={{
                      height: "auto",
                      minHeight: "150px",
                      maxHeight: "500px",
                    }}
                    onInput={(e) => {
                      const target = e.target as HTMLTextAreaElement;
                      target.style.height = "auto";
                      target.style.height = `${Math.min(target.scrollHeight, 500)}px`;
                    }}
                  />
                </div>
              ))}
            </div>
          )}

          {/* Bottom controls */}
          <div className="flex items-center justify-between mt-4">
            <button
              type="button"
              onClick={() => {
                // Reset all sections to default
                const outcomes = formData.outcomeMessages;
                const newSections = {
                  intro: DEFAULT_PROPOSAL_SECTIONS.intro,
                  outcomes: {} as Record<string, string>,
                  footer: DEFAULT_PROPOSAL_SECTIONS.footer,
                };

                // Set default content for each outcome
                outcomes.forEach((outcome) => {
                  if (outcome === "Reject") {
                    newSections.outcomes["Reject"] =
                      DEFAULT_PROPOSAL_SECTIONS.outcomes["Reject"];
                  } else if (outcomes.length === 2 && outcome === "Accept") {
                    newSections.outcomes["Accept"] =
                      DEFAULT_PROPOSAL_SECTIONS.outcomes["Accept"];
                  } else {
                    // For custom outcomes
                    newSections.outcomes[outcome] = "";
                  }
                });

                setProposalSections(newSections);
                updateFormDataDescription(newSections);
              }}
              className="flex items-center gap-2 px-3 py-1.5 text-gray-400 hover:text-gray-200 text-sm transition-colors"
            >
              <ReloadIcon className="w-4 h-4" />
              <span>Reset All</span>
            </button>

            <button
              type="button"
              onClick={() => setPreviewMarkdown(!previewMarkdown)}
              className="px-4 py-1.5 bg-blue-500 text-white text-sm rounded hover:bg-blue-600 transition-colors"
            >
              {previewMarkdown ? "Edit" : "Preview All"}
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
          proposalSections={proposalSections}
          setProposalSections={setProposalSections}
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
