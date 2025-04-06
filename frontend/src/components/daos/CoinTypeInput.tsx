// components/CoinTypeInput.tsx
import { useState, useEffect } from 'react';
import { useSuiClient } from "@mysten/dapp-kit";
import { InfoCircledIcon } from "@radix-ui/react-icons";

interface CoinMetadata {
  id: string;
  name: string;
  symbol: string;
  iconUrl?: string;
  decimals: number;
}

interface CoinTypeInputProps {
  value: string;
  onChange: (value: string, metadata?: CoinMetadata) => void;
  label: string;
  tooltipText: string;
  placeholder?: string;
  required?: boolean;
  onMetadataChange?: (metadata: CoinMetadata | null) => void;  // Add this prop
}

const CoinTypeInput = ({ 
  value, 
  onChange, 
  label, 
  tooltipText, 
  placeholder = "package::module::type",
  required = false,
  onMetadataChange
}: CoinTypeInputProps) => {
  const [metadata, setMetadata] = useState<CoinMetadata | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  
  const suiClient = useSuiClient();

  const validateTypeFormat = (value: string) => {
    // Special case for SUI token
    if (value === "0x2::sui::SUI") {
      return true;
    }
    
    // Strict regex for all other coin types
    const regex = /^0x[a-fA-F0-9]{64}::[a-z][a-z0-9_]*[a-z0-9]::[A-Z][A-Z0-9_]*[A-Z0-9]$/;
    return regex.test(value);
  };

  const handleInputChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const newValue = e.target.value;
    setError(null);
    onChange(newValue, undefined);
  };

  // Fetch metadata on mount if there's a default value
  useEffect(() => {
    if (value) {
      fetchMetadata(value);
    }
  }, []); // Run once on mount

  const fetchMetadata = async (type: string) => {
    if (!validateTypeFormat(type)) {
      setError('Invalid format. Expected: package::module::type');
      setMetadata(null);
      onChange(type, undefined);
      return;
    }

    setIsLoading(true);
    setError(null);

    try {
      const response = await suiClient.getCoinMetadata({ coinType: type });
      if (response) {
        setMetadata(response as CoinMetadata);
        onChange(type, response as CoinMetadata);
        onMetadataChange?.(response as CoinMetadata);
      } else {
        setError('Coin type not found');
        setMetadata(null);
        onChange(type, undefined);
        onMetadataChange?.(null);
      }
    } catch (err) {
      console.error('Metadata fetch error:', err);
      setError('Failed to fetch coin metadata');
      setMetadata(null);
      onChange(type, undefined);
      onMetadataChange?.(null);
    } finally {
      setIsLoading(false);
    }
  };

  const handleBlur = () => {
    if (value) {
      fetchMetadata(value);
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      fetchMetadata(value);
    }
  };

  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between">
        <div className="flex items-center space-x-2">
          <label className="block text-sm font-medium">{label}</label>
          <div className="relative group">
            <InfoCircledIcon className="w-4 h-4 text-gray-400 hover:text-gray-600 cursor-help" />
            <div className="absolute left-1/2 -translate-x-1/2 bottom-full mb-2 px-3 py-2 bg-gray-900 text-white text-sm rounded-lg opacity-0 group-hover:opacity-100 pointer-events-none transition-opacity duration-200 w-64 z-50">
              {tooltipText}
            </div>
          </div>
        </div>
        {metadata && (
          <span className="text-sm text-gray-500">
            {metadata.name} ({metadata.symbol})
          </span>
        )}
      </div>
      
      <div className="relative">
        <input
          type="text"
          value={value}
          onChange={handleInputChange}
          onBlur={handleBlur}
          onKeyDown={handleKeyDown}
          className={`w-full p-2 border rounded focus:ring-2 focus:ring-blue-500 ${
            error ? 'border-red-500' : metadata ? 'border-green-500' : ''
          }`}
          placeholder={placeholder}
          required={required}
        />
        {isLoading && (
          <div className="absolute right-2 top-1/2 -translate-y-1/2">
            <div className="animate-spin rounded-full h-4 w-4 border-2 border-gray-500 border-t-transparent"></div>
          </div>
        )}
      </div>

      {error && (
        <p className="text-sm text-red-500 mt-1">{error}</p>
      )}
    </div>
  );
};

export default CoinTypeInput;