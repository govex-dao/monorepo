import { Flex, Text } from "@radix-ui/themes";
import { ExplorerLink } from '../../components/ExplorerLink';
import { Tooltip } from '../../components/Tooltip';

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

  const tooltipContent = (
    <div className="space-y-1">
      <Flex justify="between" className="text-gray-300" gap="1">
        <Text size="1">Minimum AMM Amount</Text>
        <Text size="1" weight="bold">
          {parseFloat(minAmount) / Math.pow(10, decimals || 0)} {symbol}
        </Text>
      </Flex>
      <div className="pt-1 border-t border-gray-700">
        <Text size="1" className="text-gray-400 mb-1">
          Address
        </Text>
        <ExplorerLink id={tokenType} type="coin" />
      </div>
    </div>
  );

  return (
    <div className="p-3 bg-gray-800/70 rounded-lg border border-gray-700/50">
      <Flex align="center" gap="3">
        <div
          className={`w-8 h-8 rounded-full bg-transparent flex items-center justify-center shadow-md overflow-hidden flex-shrink-0`}
        >
          {iconUrl ? (
            <img
              src={iconUrl}
              alt={`${name || symbol} icon`}
              className="w-full h-full object-cover rounded-full"
            />
          ) : (
            <div
              className={`w-8 h-8 rounded-full bg-gradient-to-br ${gradientClasses} flex items-center justify-center shadow-md`}
            >
              <Text size="1" className={`${textColor} font-semibold`}>
                {symbol?.charAt(0) || (isAsset ? "A" : "S")}
              </Text>
            </div>
          )}
        </div>
        <Flex className="flex-1 min-w-0" direction="column">
          <Text weight="bold" size="2" className="text-gray-200">
            {symbol || name}
          </Text>
          <Text size="1" className="text-gray-400">
            {isAsset ? "Asset" : "Stable"}
          </Text>
        </Flex>
        <Tooltip content={tooltipContent}>
          <div className="w-5 h-5 rounded-full bg-gray-700 hover:bg-gray-600 flex items-center justify-center transition-colors">
            <Text size="1" className="text-gray-300 select-none">
              i
            </Text>
          </div>
        </Tooltip>
      </Flex>
    </div>
  );
}
