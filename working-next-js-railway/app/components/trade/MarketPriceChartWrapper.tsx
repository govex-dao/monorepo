'use client';

import { useEffect, useState } from 'react';
import dynamic from 'next/dynamic';

// Dynamic import with no SSR
const MarketPriceChart = dynamic(
  () => import('./MarketPriceChart').then(mod => mod.default),
  {
    ssr: false,
    loading: () => (
      <div className="flex items-center justify-center h-[400px] bg-gray-800 rounded-lg">
        <div className="text-gray-400">Loading chart...</div>
      </div>
    ),
  }
);

export default function MarketPriceChartWrapper(props: any) {
  const [isMounted, setIsMounted] = useState(false);

  useEffect(() => {
    setIsMounted(true);
  }, []);

  if (!isMounted) {
    return (
      <div className="flex items-center justify-center h-[400px] bg-gray-800 rounded-lg">
        <div className="text-gray-400">Loading chart...</div>
      </div>
    );
  }

  return <MarketPriceChart {...props} />;
}