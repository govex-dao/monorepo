export const getOutcomeColor = (
  index: number,
): { bg: string; text: string; border: string } => {
  const colors = [
    { bg: "bg-red-900/30", text: "text-red-400", border: "border-red-700/30" },
    {
      bg: "bg-green-900/30",
      text: "text-green-400",
      border: "border-green-700/30",
    },
    {
      bg: "bg-purple-900/30",
      text: "text-purple-400",
      border: "border-purple-700/30",
    },
    {
      bg: "bg-blue-900/30",
      text: "text-blue-400",
      border: "border-blue-700/30",
    },
    {
      bg: "bg-yellow-900/30",
      text: "text-yellow-400",
      border: "border-yellow-700/30",
    },
    {
      bg: "bg-pink-900/30",
      text: "text-pink-400",
      border: "border-pink-700/30",
    },
    {
      bg: "bg-indigo-900/30",
      text: "text-indigo-400",
      border: "border-indigo-700/30",
    },
  ];
  return colors[index % colors.length];
};
