export function safeBigInt(value: string | undefined | null, defaultValue: bigint = 0n): bigint {
    if (!value) return defaultValue;
    try {
        return BigInt(value);
    } catch {
        return defaultValue;
    }
}

// Custom serializer for BigInt values
export function serializeBigInt(value: any): any {
    if (typeof value === 'bigint') {
        return value.toString();
    }
    return value;
}