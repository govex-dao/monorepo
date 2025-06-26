import React, { useState } from "react";
import { InfoCircledIcon } from "@radix-ui/react-icons";

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

const DEFAULT_PROPOSAL_SECTIONS = {
  intro: "",
  outcomes: {
    Accept: "",
    Reject: "",
  },
  footer: "",
};

export const OutcomeMessages: React.FC<OutcomeMessagesProps> = ({
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
