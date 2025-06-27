import React from "react";
import { ReloadIcon } from "@radix-ui/react-icons";
import MarkdownRenderer from "../../MarkdownRenderer";

interface ProposalContentProps {
  previewMarkdown: boolean;
  setPreviewMarkdown: (value: boolean) => void;
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
  updateFormDataDescription: (sections: {
    intro: string;
    outcomes: Record<string, string>;
    footer: string;
  }) => void;
  formData: {
    outcomeMessages: string[];
    description: string;
  };
}

const DEFAULT_PROPOSAL_SECTIONS = {
  intro: "",
  outcomes: {
    Accept: "",
    Reject: "",
  },
  footer: "",
};

export const ProposalContent: React.FC<ProposalContentProps> = ({
  previewMarkdown,
  setPreviewMarkdown,
  proposalSections,
  setProposalSections,
  updateFormDataDescription,
  formData,
}) => {
  const handleTextareaResize = (e: React.FormEvent<HTMLTextAreaElement>) => {
    const target = e.target as HTMLTextAreaElement;
    target.style.height = "auto";
    target.style.height = `${Math.min(target.scrollHeight, 500)}px`;
  };

  const handleReset = () => {
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
        newSections.outcomes[outcome] = "";
      }
    });

    setProposalSections(newSections);
    updateFormDataDescription(newSections);
  };

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <label className="block text-sm font-medium">Proposal Content</label>
      </div>

      {previewMarkdown ? (
        <div className="border border-blue-500 p-4 rounded bg-gray-900 min-h-[400px]">
          <MarkdownRenderer content={formData.description} />
        </div>
      ) : (
        <div className="space-y-4">
          {/* Static Introduction Header */}
          <div className="text-lg font-bold text-gray-200"># Introduction</div>

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
            onInput={handleTextareaResize}
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
                onInput={handleTextareaResize}
              />
            </div>
          ))}
        </div>
      )}

      {/* Bottom controls */}
      <div className="flex items-center justify-between mt-4">
        <button
          type="button"
          onClick={handleReset}
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
  );
};
