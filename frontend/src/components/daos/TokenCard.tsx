import { Flex, Text } from "@radix-ui/themes";
import { ExplorerLink } from "@/components/ExplorerLink";

interface TokenCardProps {
  name: string;
  symbol: string;
  type: "asset" | "stable";
  iconUrl?: string;
  decimals: number;
  minAmount: string;
  tokenType: string;
}

export function TokenCard({
  name,
  symbol,
  type,
  iconUrl,
  decimals,
  minAmount,
  tokenType,
}: TokenCardProps) {
  const isAsset = type === "asset";
  const gradientClasses = isAsset
    ? "from-blue-500/40 to-blue-700/40"
    : "from-green-500/40 to-green-700/40";
  const textColor = isAsset ? "text-blue-300" : "text-green-300";

  return (
    <div className="p-3 bg-gray-800/70 rounded-lg border border-gray-700/50">
      <Flex align="center" gap="3">
        <div className={`w-8 h-8 rounded-full bg-gradient-to-br ${gradientClasses} flex items-center justify-center shadow-md overflow-hidden flex-shrink-0`}>
          {iconUrl ? (
            <img
              src={iconUrl}
              alt={`${name || symbol} icon`}
              className="w-full h-full object-cover"
              onError={(e) => {
                e.currentTarget.style.display = "none";
                const fallback = e.currentTarget.nextElementSibling as HTMLElement;
                if (fallback) fallback.style.display = "flex";
              }}
            />
          ) : null}
          <div
            className={`w-8 h-8 rounded-full bg-gradient-to-br ${gradientClasses} flex items-center justify-center shadow-md`}
            style={{ display: iconUrl ? "none" : "flex" }}
          >
            <Text size="1" className={`${textColor} font-semibold`}>
              {symbol?.charAt(0) || (isAsset ? "A" : "S")}
            </Text>
          </div>
        </div>
        <div className="flex-1 min-w-0">
          <Text weight="bold" size="2" className="text-gray-200">
            {name || symbol}
          </Text>
          <Text size="1" className="text-gray-400">
            • {isAsset ? "Asset" : "Stable"} Token
          </Text>
          <div className="mt-1">
            <ExplorerLink id={tokenType} isAddress={false} />
          </div>
        </div>
        <div className="relative group flex-shrink-0">
          <div className="w-5 h-5 rounded-full bg-gray-700 hover:bg-gray-600 flex items-center justify-center cursor-help transition-colors">
            <Text size="1" className="text-gray-300">
              i
            </Text>
          </div>
          <div className="absolute right-0 w-48 p-2 bg-gray-800/95 rounded-md shadow-xl border border-gray-700 hidden group-hover:block z-10 text-sm backdrop-blur-sm">
            <div className="space-y-1">
              <Flex justify="between" className="text-gray-300">
                <Text size="1">Decimals</Text>
                <Text size="1" weight="bold">
                  {decimals}
                </Text>
              </Flex>
              <Flex justify="between" className="text-gray-300">
                <Text size="1">Min Amount</Text>
                <Text size="1" weight="bold">
                  {parseFloat(minAmount) / Math.pow(10, decimals || 0)} {symbol}
                </Text>
              </Flex>
            </div>
          </div>
        </div>
      </Flex>
    </div>
  );
} 