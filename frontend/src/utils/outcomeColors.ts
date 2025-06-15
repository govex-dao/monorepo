// Single source of truth for outcome colors
const OUTCOME_COLORS = [
  {
    hex: "#f87171", // red-400
    bg: "bg-red-900/30",
    text: "text-red-400",
    border: "border-red-700/30",
  },
  {
    hex: "#4ade80", // green-400
    bg: "bg-green-900/30",
    text: "text-green-400",
    border: "border-green-700/30",
  },
  {
    hex: "#60a5fa", // blue-400
    bg: "bg-blue-900/30",
    text: "text-blue-400",
    border: "border-blue-700/30",
  },
  {
    hex: "#c084fc", // purple-400
    bg: "bg-purple-900/30",
    text: "text-purple-400",
    border: "border-purple-700/30",
  },
  {
    hex: "#facc15", // yellow-400
    bg: "bg-yellow-900/30",
    text: "text-yellow-400",
    border: "border-yellow-700/30",
  },
  {
    hex: "#f472b6", // pink-400
    bg: "bg-pink-900/30",
    text: "text-pink-400",
    border: "border-pink-700/30",
  },
  {
    hex: "#a78bfa", // indigo-400
    bg: "bg-indigo-900/30",
    text: "text-indigo-400",
    border: "border-indigo-700/30",
  },
];

/**
 * Gets the color for a specific outcome by index.
 * Returns Tailwind classes for styling.
 */
export const getOutcomeColor = (
  index: number,
): { bg: string; text: string; border: string } => {
  const color = OUTCOME_COLORS[index % OUTCOME_COLORS.length];
  return { bg: color.bg, text: color.text, border: color.border };
};

/**
 * Generates an array of hex colors for market outcomes.
 * Used for chart visualization.
 */
export const getOutcomeColors = (outcomeCount: number): string[] => {
  if (outcomeCount <= 0) return [];
  
  return OUTCOME_COLORS.slice(0, Math.min(outcomeCount, OUTCOME_COLORS.length))
    .map(color => color.hex);
};