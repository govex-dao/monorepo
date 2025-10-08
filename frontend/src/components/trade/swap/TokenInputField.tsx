import React, { useState, useRef, useEffect } from "react";
import WalletIcon from "../../icons/WalletIcon";

interface TokenInputFieldProps {
  label: "From" | "To";
  value: string;
  onChange?: (value: string) => void;
  placeholder?: string;
  symbol: string;
  balance: string;
  spotBalance?: string;
  conditionalBalance?: string;
  readOnly?: boolean;
  step?: number;
}

// Safe balance formatter with NaN guard
const formatBalance = (value: string | undefined, decimals = 3): string => {
  const num = parseFloat(value || "0");
  return isNaN(num) ? "0.000" : num.toFixed(decimals);
};

const TokenInputField: React.FC<TokenInputFieldProps> = ({
  label,
  value,
  onChange,
  placeholder = "0.0",
  symbol,
  balance,
  spotBalance,
  conditionalBalance,
  readOnly = false,
  step,
}) => {
  const [showBreakdown, setShowBreakdown] = useState(false);
  const dropdownRef = useRef<HTMLDivElement>(null);

  // Show breakdown if both spot and conditional balances are provided and conditional > 0
  const hasBreakdown = spotBalance && conditionalBalance && (parseFloat(conditionalBalance) || 0) > 0;

  // Close dropdown when clicking outside
  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target as Node)) {
        setShowBreakdown(false);
      }
    };

    if (showBreakdown) {
      document.addEventListener('mousedown', handleClickOutside);
      return () => document.removeEventListener('mousedown', handleClickOutside);
    }
  }, [showBreakdown]);

  return (
    <div className="bg-gray-800/70 rounded-lg p-3 border border-gray-700/50">
      <div className="flex justify-between mb-1">
        <span className="text-gray-400 text-xs font-medium">{label}</span>
        <div className="relative" ref={dropdownRef}>
          <button
            type="button"
            onClick={() => hasBreakdown && setShowBreakdown(!showBreakdown)}
            className="text-gray-400 text-xs flex items-center gap-1 hover:text-gray-300 transition-colors"
          >
            <WalletIcon className="h-3 w-3 fill-gray-500/30" />
            <span>
              {formatBalance(balance)} {symbol}
            </span>
            {hasBreakdown && (
              <svg
                className="h-3 w-3 fill-gray-500"
                viewBox="0 0 20 20"
                xmlns="http://www.w3.org/2000/svg"
              >
                <path
                  fillRule="evenodd"
                  d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z"
                  clipRule="evenodd"
                />
              </svg>
            )}
          </button>
          {hasBreakdown && showBreakdown && (
            <div className="absolute right-0 top-full mt-1 z-10 bg-gray-900 border border-gray-700 rounded-md px-2.5 py-2 text-xs text-gray-300 whitespace-nowrap shadow-lg">
              <div className="flex flex-col gap-1">
                <div className="flex justify-between gap-4">
                  <span className="text-gray-500">Spot:</span>
                  <span className="text-gray-300 font-medium">{formatBalance(spotBalance)}</span>
                </div>
                <div className="flex justify-between gap-4">
                  <span className="text-gray-500">Conditional:</span>
                  <span className="text-gray-300 font-medium">{formatBalance(conditionalBalance)}</span>
                </div>
                <div className="border-t border-gray-700 mt-1 pt-1 flex justify-between gap-4 font-medium">
                  <span>Total:</span>
                  <span>{formatBalance(balance)}</span>
                </div>
              </div>
            </div>
          )}
        </div>
      </div>
      <div className="flex items-center">
        <div className="flex-1">
          <input
            type="number"
            value={value}
            onChange={onChange ? (e) => onChange(e.target.value) : undefined}
            placeholder={placeholder}
            className="w-full bg-transparent text-white text-lg focus:outline-none font-medium appearance-none [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none [-moz-appearance:textfield]"
            step={step}
            readOnly={readOnly}
          />
        </div>
        <div className="bg-gray-700/80 px-2 py-1 rounded-md flex items-center">
          <span className="text-white font-medium text-sm">{symbol}</span>
        </div>
      </div>
    </div>
  );
};

export default TokenInputField;
