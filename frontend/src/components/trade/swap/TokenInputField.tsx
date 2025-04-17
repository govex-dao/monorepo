import React from "react";
import WalletIcon from "../../icons/WalletIcon";

interface TokenInputFieldProps {
  label: "From" | "To";
  value: string;
  onChange?: (value: string) => void;
  placeholder?: string;
  symbol: string;
  balance: string;
  readOnly?: boolean;
  step?: number;
}

const TokenInputField: React.FC<TokenInputFieldProps> = ({
  label,
  value,
  onChange,
  placeholder = "0.0",
  symbol,
  balance,
  readOnly = false,
  step,
}) => {
  return (
    <div className="bg-gray-800/70 rounded-lg p-3 border border-gray-700/50">
      <div className="flex justify-between mb-1">
        <span className="text-gray-400 text-xs font-medium">{label}</span>
        <span className="text-gray-400 text-xs flex items-center">
          <WalletIcon className="h-3 w-3 mr-1 fill-gray-500/30" />
          {parseFloat(balance).toFixed(3)} {symbol}
        </span>
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
