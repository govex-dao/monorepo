const DECIMAL_SCALE = 1_000_000_000n; // Scale for decimal inputs (9 decimal places)

/**
 * Converts a decimal number to a scaled BigInt
 * @param value The decimal value to convert
 * @param scale The scale factor (default: DECIMAL_SCALE)
 * @returns A BigInt representing the scaled value
 */
export function toScaledBigInt(
  value: number,
  scale: bigint = DECIMAL_SCALE,
): bigint {
  if (value === 0) return 0n;

  const valueStr = value.toString();

  // Handle scientific notation
  if (valueStr.includes("e")) {
    try {
      // Parse the scientific notation
      const [coefficient, exponentStr] = valueStr.split("e");
      const exponent = parseInt(exponentStr, 10);

      // For numbers smaller than our scale precision (10^-9), return 0n
      if (exponent < -9) return 0n;

      // For less extreme cases, try to handle them properly
      const coefNum = parseFloat(coefficient);
      const scaleFactor = Math.pow(10, -exponent);

      const scaledValue = coefNum * scaleFactor;
      return toScaledBigInt(scaledValue, scale);
    } catch (error) {
      // If we encounter any error in processing, return 0n for very small numbers
      console.warn(`Could not convert ${value} to BigInt, returning 0`);
      return 0n;
    }
  }

  // Calculate the number of decimal places in the scale
  const scaleStr = scale.toString();
  const decimalPlaces = scaleStr.length - 1;

  if (valueStr.includes(".")) {
    const [whole, decimal] = valueStr.split(".");

    // Pad the decimal part to match the scale's decimal places
    const paddedDecimal = decimal.padEnd(decimalPlaces, "0");
    const combined = whole + paddedDecimal;

    return BigInt(combined);
  } else {
    // For whole numbers, append zeros based on the scale
    return BigInt(valueStr + "0".repeat(decimalPlaces));
  }
}

/**
 * Converts a scaled BigInt back to a decimal number
 * @param value The scaled BigInt value
 * @param scale The scale factor (default: DECIMAL_SCALE)
 * @returns A number representing the unscaled value
 */
export function fromScaledBigInt(
  value: bigint,
  scale: bigint = DECIMAL_SCALE,
): number {
  if (value === 0n) return 0;

  // Convert to string
  const valueStr = value.toString();

  // Calculate the number of decimal places in the scale
  const scaleStr = scale.toString();
  const decimalPlaces = scaleStr.length - 1;

  // If the value is less than the scale, we need to pad with leading zeros
  const paddedValue = valueStr.padStart(decimalPlaces + 1, "0");

  // Split into whole and decimal parts
  const whole = paddedValue.slice(0, -decimalPlaces) || "0";
  const decimal = paddedValue.slice(-decimalPlaces);

  // Combine and convert to number
  return parseFloat(`${whole}.${decimal}`);
}

/**
 * Performs multiplication and floor division with BigInts, mimicking Move's mul_div.
 * result = floor(a * b / denominator)
 */
export function mulDivFloor(a: bigint, b: bigint, denominator: bigint): bigint {
  if (denominator === 0n) throw new Error("Division by zero in mulDivFloor");
  if (a === 0n || b === 0n) return 0n;

  return (a * b) / denominator;
}
