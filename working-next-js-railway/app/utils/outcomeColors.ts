// Single source of truth for outcome colors
const OUTCOME_COLORS = [
  {
    hex: "#ef4444", // red-500
    bg: "bg-red-900/30",
    text: "text-red-400",
    border: "border-red-700/30",
  },
  {
    hex: "#22c55e", // green-500
    bg: "bg-green-900/30",
    text: "text-green-400",
    border: "border-green-700/30",
  },
  {
    hex: "#3b82f6", // blue-500
    bg: "bg-blue-900/30",
    text: "text-blue-400",
    border: "border-blue-700/30",
  },
  {
    hex: "#a855f7", // purple-500
    bg: "bg-purple-900/30",
    text: "text-purple-400",
    border: "border-purple-700/30",
  },
  {
    hex: "#eab308", // yellow-500
    bg: "bg-yellow-900/30",
    text: "text-yellow-400",
    border: "border-yellow-700/30",
  },
  {
    hex: "#ec4899", // pink-500
    bg: "bg-pink-900/30",
    text: "text-pink-400",
    border: "border-pink-700/30",
  },
  {
    hex: "#6366f1", // indigo-500
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

  return OUTCOME_COLORS.slice(
    0,
    Math.min(outcomeCount, OUTCOME_COLORS.length),
  ).map((color) => color.hex);
};
