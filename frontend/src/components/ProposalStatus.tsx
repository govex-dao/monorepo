import { Badge } from "@radix-ui/themes";

interface ProposalStatusProps {
  state: number;
  variant?: "soft" | "solid";
  className?: string;
  winningOutcome?: string | null;
}

export const getStateLabel = (state: number | null, winningOutcome?: string | null): string => {
  switch (state) {
    case 0:
      return "Pre-market";
    case 1:
      return "Trading";
    case 2:
      return winningOutcome !== null ? "Passed" : "Failed";
    default:
      return "Pre-market";
  }
};

export const getStateColor = (state: number | null, winningOutcome?: string | null): "purple" | "blue" | "green" | "red" | "gray" => {
  switch (state) {
    case 0:
      return "purple";
    case 1:
      return "blue";
    case 2:
      return winningOutcome !== null ? "green" : "red";
    default:
      return "gray";
  }
};

export function ProposalStatus({ state, variant = "soft", className = "", winningOutcome }: ProposalStatusProps) {
  const stateLabel = getStateLabel(state, winningOutcome);
  const stateColor = getStateColor(state, winningOutcome);

  return (
    <Badge color={stateColor} variant={variant} className={className}>
      {stateLabel}
    </Badge>
  );
} 