/*
import { useInfiniteQuery } from "@tanstack/react-query";
import { CONSTANTS, QueryKey } from "@/constants";
import { InfiniteScrollArea } from "@/components/InfiniteScrollArea";
import { constructUrlSearchParams, getNextPageParam } from "@/utils/helpers";
import { ApiDaoObject, DaoListingQuery } from "@/types/types";
import { Dao } from "./Dao";

export function DaoList({
    params,
  }: {
    params: DaoListingQuery;
  }) {
    const { data, fetchNextPage, hasNextPage, isLoading, isFetchingNextPage, error } =
      useInfiniteQuery({
        initialPageParam: null,
        queryKey: [QueryKey.Dao, params],
        queryFn: async ({ pageParam }) => {
          const url = CONSTANTS.apiEndpoint + 
            "daos" + 
            constructUrlSearchParams({
              ...params,
              ...(pageParam ? { cursor: pageParam as string } : {}),
            });
          
          console.log("Fetching URL:", url);
          
          const response = await fetch(url);
          if (!response.ok) {
            throw new Error(`API error: ${response.statusText}`);
          }
          
          const json = await response.json();
          console.log("API response:", json);
          return json;
        },
        select: (data) => {
          console.log("Processing data:", data);
          return data.pages
            .flatMap((page) => page.data || [])
            .filter((dao): dao is ApiDaoObject => dao !== null);
        },
        getNextPageParam,
      });
  
    if (error) {
      console.error("Query error:", error);
      return <div>Error loading DAOs: {error.message}</div>;
    }
  
    if (isLoading) {
      return <div>Loading...</div>;
    }
  
    if (!data?.length) {
      return <div>No DAOs found</div>;
    }
  
    return (
      <InfiniteScrollArea
        loadMore={() => fetchNextPage()}
        hasNextPage={hasNextPage}
        loading={isFetchingNextPage}
      >
        {data?.map((dao: ApiDaoObject) => (
          <Dao key={dao.objectId} dao={dao} />
        ))}
      </InfiniteScrollArea>
    );
  }
*/
