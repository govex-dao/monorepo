// Helper function to convert HSL color to HEX format.
const hslToHex = (h: number, s: number, l: number): string => {
  s /= 100;
  l /= 100;

  const k = (n: number) => (n + h / 30) % 12;
  const a = s * Math.min(l, 1 - l);
  const f = (n: number) =>
    l - a * Math.max(Math.min(k(n) - 3, 9 - k(n), 1), -1);

  const toHex = (x: number) =>
    Math.round(x * 255)
      .toString(16)
      .padStart(2, "0");

  return `#${toHex(f(0))}${toHex(f(8))}${toHex(f(4))}`;
};

/**
 * Generates an array of distinct colors for market outcomes based on the logic from the chart.
 * @param outcomeCount The number of outcomes.
 * @returns An array of hex color strings.
 */
export const getOutcomeColors = (outcomeCount: number): string[] => {
  if (outcomeCount <= 0) return [];
  if (outcomeCount === 1) return ["#ef4444"]; // Red
  if (outcomeCount === 2) return ["#ef4444", "#22c55e"]; // Red, Green

  // For >2 outcomes, generate visually distinct colors starting with Red.
  const generateDistantColors = (count: number) => {
    const startHue = 120; // Green
    const endHue = 300; // Magenta/Purple
    const step = (endHue - startHue) / (count - 1);
    return Array.from({ length: count - 1 }, (_, i) => {
      const hue = startHue + i * step;
      return hslToHex(hue, 100, 50);
    });
  };

  const additionalColors = generateDistantColors(outcomeCount);
  return ["#ef4444", ...additionalColors];
};
