// useSwapEvents.ts
import { useQuery, UseQueryOptions } from "@tanstack/react-query";
import { CONSTANTS } from "@/constants";

export interface SwapEvent {
  price: string;
  timestamp: string;
  is_buy: boolean;
  amount_in: string;
  outcome: number;
  asset_reserve: string;
  stable_reserve: string;
  sender: string;
}

type UseSwapEventsOptions = Omit<
  UseQueryOptions<SwapEvent[], Error>,
  "queryKey" | "queryFn"
>;

export const useSwapEvents = (
  proposalId: string,
  options?: UseSwapEventsOptions,
) => {

  return useQuery<SwapEvent[], Error>({
    queryKey: ["swaps", proposalId],
    queryFn: async () => {
      const response = await fetch(
        `${CONSTANTS.apiEndpoint}swaps?market_id=${proposalId}`,
      );
      if (!response.ok) {
        console.error("Failed to fetch swap events:", response.statusText);
        throw new Error("Failed to fetch swap events");
      }
      const data = await response.json();
      return data.data as SwapEvent[];
    },
    enabled: !!proposalId,
    refetchInterval: 1000, // Poll every second
    refetchIntervalInBackground: false, // Continue polling when tab is not active
    ...options,
  });
};
