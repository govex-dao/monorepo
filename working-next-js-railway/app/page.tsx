import { Suspense } from "react";
import { TradeDashboard } from "./routes/TradeDashboard";
import { CONSTANTS } from "./constants";
import { TradeDashboardSkeleton } from "./components/LoadingStates";

async function fetchInitialData() {
  try {
    const [proposalsRes, daosRes] = await Promise.all([
      fetch(`${CONSTANTS.apiEndpoint}proposals`, { 
        next: { revalidate: 60 } // Cache for 1 minute
      }),
      fetch(`${CONSTANTS.apiEndpoint}daos`, { 
        next: { revalidate: 300 } // Cache for 5 minutes
      }),
    ]);

    const [proposalsData, daosData] = await Promise.all([
      proposalsRes.ok ? proposalsRes.json() : null,
      daosRes.ok ? daosRes.json() : null,
    ]);

    return {
      proposals: proposalsData?.data || [],
      daos: daosData?.data || [],
    };
  } catch (error) {
    console.error('Error fetching initial data:', error);
    return { proposals: [], daos: [] };
  }
}

export default async function HomePage() {
  const initialData = await fetchInitialData();
  
  return (
    <Suspense fallback={<TradeDashboardSkeleton />}>
      <TradeDashboard initialData={initialData} />
    </Suspense>
  );
}