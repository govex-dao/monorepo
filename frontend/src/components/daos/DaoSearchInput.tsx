import { useState, useRef, useEffect, ChangeEvent } from "react";
import { InfoCircledIcon } from "@radix-ui/react-icons";
import { useQuery } from "@tanstack/react-query";
import { Theme } from "@radix-ui/themes";
import { CONSTANTS } from "@/constants";
import { VerifiedIcon } from "../icons/VerifiedIcon";

interface DaoData {
  dao_id: string;
  minAssetAmount: string;
  minStableAmount: string;
  timestamp: string;
  assetType: string;
  stableType: string;
  dao_name: string;
  dao_icon: string;
  icon_url: string;
  icon_cache_path: string | null;
  review_period_ms: string;
  trading_period_ms: string;
  asset_decimals: number;
  stable_decimals: number;
  asset_symbol: String;
  stable_symbol: String;
  verification?: {
    verified: boolean;
  };
}

interface DaoSearchInputProps {
  value: string;
  onChange: (e: ChangeEvent<HTMLInputElement>) => void;
  onDaoSelect?: (daoData: DaoData | null) => void;
  tooltip: string;
}

const truncateAddress = (address: string) => {
  if (address.length <= 20) return address;
  return `${address.slice(0, 10)}...${address.slice(-10)}`;
};

const DaoSearchInput = ({
  value,
  onChange,
  onDaoSelect,
  tooltip,
}: DaoSearchInputProps) => {
  const [isOpen, setIsOpen] = useState(false);
  const [searchTerm, setSearchTerm] = useState("");
  const dropdownRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    setSearchTerm(value);
  }, [value]);

  const {
    data: daos,
    isLoading,
    error,
  } = useQuery({
    queryKey: ["daos", searchTerm],
    queryFn: async () => {
      if (!searchTerm) return { data: [] };

      const response = await fetch(
        `${CONSTANTS.apiEndpoint}daos?dao_id=${encodeURIComponent(searchTerm)}`,
      );
      if (!response.ok) {
        throw new Error(`API error: ${response.statusText}`);
      }

      return response.json();
    },
    enabled: searchTerm.length > 0,
    staleTime: 1,
  });

  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (
        dropdownRef.current &&
        !dropdownRef.current.contains(event.target as Node)
      ) {
        setIsOpen(false);
      }
    };

    document.addEventListener("mousedown", handleClickOutside);
    return () => document.removeEventListener("mousedown", handleClickOutside);
  }, []);

  const handleInputChange = (e: ChangeEvent<HTMLInputElement>) => {
    const newValue = e.target.value;
    setSearchTerm(newValue);
    setIsOpen(true);
    onChange(e);

    if (newValue === "" && onDaoSelect) {
      onDaoSelect(null);
    }
  };

  const handleSelect = (dao: DaoData) => {
    const syntheticEvent = {
      target: {
        name: "daoId",
        value: dao.dao_id,
      },
    } as ChangeEvent<HTMLInputElement>;

    setSearchTerm(dao.dao_id);
    onChange(syntheticEvent);
    if (onDaoSelect) {
      onDaoSelect(dao);
    }
    setIsOpen(false);
  };

  const highlightMatch = (text: string, term: string) => {
    if (!term) return text;

    const regex = new RegExp(`(${term})`, "gi");
    const parts = text.split(regex);

    return (
      <>
        {parts.map((part, i) =>
          regex.test(part) ? (
            <span key={i} className="bg-blue-500 bg-opacity-30">
              {part}
            </span>
          ) : (
            <span key={i}>{part}</span>
          ),
        )}
      </>
    );
  };

  return (
    <Theme appearance="dark">
      <div className="space-y-2">
        <div className="flex items-center space-x-2">
          <label className="block text-sm font-medium text-gray-200">
            DAO Search
          </label>
          <div className="relative group">
            <InfoCircledIcon className="w-4 h-4 text-gray-400" />
            <div className="absolute left-1/2 -translate-x-1/2 bottom-full mb-2 px-3 py-2 bg-gray-800 text-gray-200 text-sm rounded-lg opacity-0 group-hover:opacity-100 pointer-events-none transition-opacity duration-200 w-64 z-50">
              {tooltip}
            </div>
          </div>
        </div>

        <div className="relative" ref={dropdownRef}>
          <input
            type="text"
            name="daoId"
            value={searchTerm}
            onChange={handleInputChange}
            onFocus={() => setIsOpen(true)}
            autoComplete="off"
            className="w-full p-2 bg-black border border-blue-500 rounded-md text-gray-100 placeholder-gray-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
            placeholder="Search by DAO name or ID"
          />

          {isOpen && (searchTerm || isLoading) && (
            <div className="absolute w-full mt-1 bg-gray-900 border border-gray-800 rounded-md shadow-xl z-10 max-h-60 overflow-auto">
              {isLoading ? (
                <div className="p-2 text-gray-400">Loading...</div>
              ) : error ? (
                <div className="p-2 text-red-400">
                  {error instanceof Error
                    ? error.message
                    : "Error loading DAOs"}
                </div>
              ) : daos?.data?.length ? (
                daos.data.map((dao: DaoData) => (
                  <div
                    key={dao.dao_id}
                    className="p-2 hover:bg-gray-800 cursor-pointer text-gray-200 transition-colors duration-150"
                    onClick={() => handleSelect(dao)}
                  >
                    <div className="flex items-center space-x-3">
                      <div className="w-8 h-8 flex-shrink-0 rounded-full bg-transparent overflow-hidden">
                        {dao.dao_icon ? (
                          <img
                            src={dao.dao_icon}
                            alt={dao.dao_name}
                            className="w-full h-full object-cover"
                          />
                        ) : (
                          <div className="w-full h-full bg-gray-700 rounded-full flex items-center justify-center text-sm text-gray-300 font-semibold">
                            {dao.dao_name.charAt(0).toUpperCase()}
                          </div>
                        )}
                      </div>
                      <div className="flex-grow min-w-0 space-y-1">
                        <div className="font-medium truncate flex items-center">
                          {highlightMatch(dao.dao_name, searchTerm)}
                          {dao.verification?.verified && (
                            <VerifiedIcon className="ml-1 flex-shrink-0" />
                          )}
                        </div>
                        <div className="font-mono text-sm text-gray-400 truncate">
                          {truncateAddress(dao.dao_id)}
                        </div>
                      </div>
                    </div>
                  </div>
                ))
              ) : (
                <div className="p-2 text-gray-400">No DAOs found</div>
              )}
            </div>
          )}
        </div>
      </div>
    </Theme>
  );
};

export default DaoSearchInput;
