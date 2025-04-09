import React from 'react';

interface TokenInputFieldProps {
  label: 'From' | 'To';
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
  placeholder = '0.0',
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
          <svg fill="#9ca3af50 " className="h-3 w-3 mr-1 text-gray-500" viewBox="0 0 458.531 458.531" xmlns="http://www.w3.org/2000/svg">
            <g>
              <path d="M336.688,343.962L336.688,343.962c-21.972-0.001-39.848-17.876-39.848-39.848v-66.176
                    c0-21.972,17.876-39.847,39.848-39.847h103.83c0.629,0,1.254,0.019,1.876,0.047v-65.922c0-16.969-13.756-30.725-30.725-30.725
                    H30.726C13.756,101.49,0,115.246,0,132.215v277.621c0,16.969,13.756,30.726,30.726,30.726h380.943
                    c16.969,0,30.725-13.756,30.725-30.726v-65.922c-0.622,0.029-1.247,0.048-1.876,0.048H336.688z"/>
              <path d="M440.518,219.925h-103.83c-9.948,0-18.013,8.065-18.013,18.013v66.176c0,9.948,8.065,18.013,18.013,18.013h103.83
                    c9.948,0,18.013-8.064,18.013-18.013v-66.176C458.531,227.989,450.466,219.925,440.518,219.925z M372.466,297.024
                    c-14.359,0-25.999-11.64-25.999-25.999s11.64-25.999,25.999-25.999c14.359,0,25.999,11.64,25.999,25.999
                    C398.465,285.384,386.825,297.024,372.466,297.024z"/>
              <path d="M358.169,45.209c-6.874-20.806-29.313-32.1-50.118-25.226L151.958,71.552h214.914L358.169,45.209z" />
            </g>
          </svg>
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