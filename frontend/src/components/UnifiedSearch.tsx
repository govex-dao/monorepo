import { useState, useRef, useEffect, ChangeEvent } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { Theme } from "@radix-ui/themes";
import { CONSTANTS } from "@/constants";
import { VerifiedIcon } from "./icons/VerifiedIcon";

interface DaoResult {
  type: "dao";
  id: number;
  dao_id: string;
  dao_name: string;
  icon_url: string | null;
  dao_icon: string;
  verification?: {
    verified: boolean;
  };
}

interface ProposalResult {
  type: "proposal";
  id: number;
  proposal_id: string;
  market_state_id: string;
  title: string;
  dao: {
    dao_id: string;
    dao_name: string;
    icon_url: string | null;
    dao_icon: string;
    verification?: {
      verified: boolean;
    };
  };
}

type SearchResult = DaoResult | ProposalResult;

const truncateId = (id: string) => {
  return `${id.slice(0, 5)}...${id.slice(-5)}`;
};

const UnifiedSearch = () => {
  const [_searchParams, setSearchParams] = useSearchParams();
  const navigate = useNavigate();
  const [isOpen, setIsOpen] = useState(false);
  const [searchTerm, setSearchTerm] = useState("");
  const dropdownRef = useRef<HTMLDivElement | null>(null);

  const { data: searchResults, isLoading } = useQuery({
    queryKey: ["unified-search", searchTerm],
    queryFn: async () => {
      if (!searchTerm) return { data: { daos: [], proposals: [] } };

      const response = await fetch(
        `${CONSTANTS.apiEndpoint}search?query=${encodeURIComponent(searchTerm)}`,
      );

      if (!response.ok) {
        throw new Error(`API error: ${response.statusText}`);
      }

      return response.json();
    },
    enabled: searchTerm.length > 0,
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
  };

  const handleSelectResult = (result: SearchResult) => {
    setIsOpen(false);

    if (result.type === "dao") {
      // Just update the search params, which will update the URL to /?dao={daoid}
      setSearchParams({ dao: result.dao_id });
    } else {
      // Navigate to proposal page
      navigate(`/trade/${result.market_state_id}`);
    }

    setSearchTerm("");
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
      <div className="w-full md:w-[380px]">
        <div className="relative w-full" ref={dropdownRef}>
          <input
            type="text"
            value={searchTerm}
            onChange={handleInputChange}
            onFocus={() => setIsOpen(true)}
            className="w-full p-2 bg-black border border-blue-500 rounded-md text-gray-100 placeholder-gray-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
            placeholder="Search DAOs and proposals..."
          />

          {isOpen && searchTerm && (
            <div className="absolute w-full mt-1 bg-gray-900 border border-gray-800 rounded-md shadow-xl z-10 max-h-96 overflow-auto">
              {isLoading ? (
                <div className="p-2 text-gray-400">Loading...</div>
              ) : searchResults?.data ? (
                <div>
                  {/* DAOs Section */}
                  {searchResults.data.daos?.length > 0 && (
                    <div className="border-b border-gray-800">
                      {searchResults.data.daos.map((dao: DaoResult) => (
                        <div
                          key={dao.id}
                          onClick={() => handleSelectResult(dao)}
                          className="p-2 hover:bg-gray-800 cursor-pointer"
                        >
                          <div className="flex items-center gap-2">
                            <span className="text-sm text-blue-400 whitespace-nowrap">
                              DAO:
                            </span>
                            <div className="w-5 h-5 rounded-full bg-transparent flex-shrink-0 overflow-hidden">
                              {dao.dao_icon ? (
                                <img
                                  src={dao.dao_icon}
                                  alt=""
                                  className="w-full h-full object-cover"
                                />
                              ) : (
                                <div className="w-full h-full bg-gray-700 rounded-full flex items-center justify-center text-xs text-gray-300 font-semibold">
                                  {dao.dao_name.charAt(0).toUpperCase()}
                                </div>
                              )}
                            </div>
                            <div className="flex items-center gap-1">
                              <span className="text-gray-100 font-medium truncate">
                                {highlightMatch(dao.dao_name, searchTerm)}
                              </span>
                              {dao.verification?.verified && (
                                <VerifiedIcon className="flex-shrink-0" />
                              )}
                            </div>
                            <span className="text-sm text-gray-400 whitespace-nowrap flex-shrink-0">
                              {truncateId(dao.dao_id)}
                            </span>
                          </div>
                        </div>
                      ))}
                    </div>
                  )}

                  {/* Proposals Section */}
                  {searchResults.data.proposals?.length > 0 && (
                    <div>
                      {searchResults.data.proposals.map(
                        (proposal: ProposalResult) => (
                          <div
                            key={proposal.id}
                            onClick={() => handleSelectResult(proposal)}
                            className="p-2 hover:bg-gray-800 cursor-pointer"
                          >
                            <div className="flex flex-col gap-1">
                              <div className="flex items-center gap-2">
                                <span className="text-sm text-green-400 whitespace-nowrap flex-shrink-0">
                                  PROPOSAL:
                                </span>
                                <div className="w-5 h-5 rounded-full bg-transparent flex-shrink-0 overflow-hidden">
                                  {proposal.dao.dao_icon ? (
                                    <img
                                      src={proposal.dao.dao_icon}
                                      alt=""
                                      className="w-full h-full object-cover"
                                    />
                                  ) : (
                                    <div className="w-full h-full bg-gray-700 rounded-full flex items-center justify-center text-xs text-gray-300 font-semibold">
                                      {proposal.dao.dao_name
                                        .charAt(0)
                                        .toUpperCase()}
                                    </div>
                                  )}
                                </div>
                                <span className="text-sm text-gray-400 whitespace-nowrap flex-shrink-0">
                                  {proposal.dao.dao_name}
                                </span>
                                {proposal.dao.verification?.verified && (
                                  <VerifiedIcon className="flex-shrink-0" />
                                )}
                              </div>
                              <div className="pl-[85px]">
                                <span className="text-gray-100 font-medium truncate">
                                  {highlightMatch(proposal.title, searchTerm)}
                                </span>
                              </div>
                            </div>
                          </div>
                        ),
                      )}
                    </div>
                  )}

                  {searchResults.data.daos?.length === 0 &&
                    searchResults.data.proposals?.length === 0 && (
                      <div className="p-2 text-gray-400">No results found</div>
                    )}
                </div>
              ) : (
                <div className="p-2 text-gray-400">Type to search...</div>
              )}
            </div>
          )}
        </div>
      </div>
    </Theme>
  );
};

export default UnifiedSearch;
